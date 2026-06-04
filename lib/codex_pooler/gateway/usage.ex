defmodule CodexPooler.Gateway.Usage do
  @moduledoc false

  alias CodexPooler.Access
  alias CodexPooler.Accounting
  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.Denials
  alias CodexPooler.Gateway.Metadata.Accounting, as: MetadataAccounting
  alias CodexPooler.Gateway.OpenAICompatibility.Error
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias CodexPooler.Upstreams.Secrets

  @secret_kind "access_token"

  @type auth :: Access.auth_context()
  @type opts :: RequestOptions.t()
  @type codex_usage_auth ::
          {:api_key, auth()} | {:chatgpt_account_token, UpstreamIdentity.t()}
  @type gateway_error :: Contracts.gateway_error()
  @type gateway_result :: Contracts.body_result()

  @spec codex_usage(auth(), String.t(), opts()) ::
          {:ok, gateway_result()} | {:error, gateway_error()}
  def codex_usage(auth, endpoint, %RequestOptions{} = request_options) do
    request_options = request_options(request_options, endpoint, %{})

    with {:ok, _policy} <- normalize_policy_or_log(auth, endpoint, request_options) do
      case record_metadata_request(auth, endpoint, request_options) do
        :ok ->
          auth.pool
          |> Accounting.build_codex_usage_for_api_key(auth.api_key)
          |> usage_result()

        {:error, reason} ->
          {:error, usage_error(reason)}
      end
    end
  end

  @spec v1_usage(auth(), map(), opts()) :: {:ok, gateway_result()} | {:error, gateway_error()}
  def v1_usage(auth, params, %RequestOptions{} = request_options) when is_map(params) do
    request_options = request_options(request_options, "/v1/usage", %{})

    with :ok <- validate_v1_usage_filters(params),
         {:ok, _policy} <- normalize_policy_or_log(auth, "/v1/usage", request_options) do
      case record_metadata_request(auth, "/v1/usage", request_options) do
        :ok ->
          auth.pool
          |> Accounting.build_v1_usage_for_api_key(auth.api_key)
          |> usage_result()

        {:error, reason} ->
          {:error, usage_error(reason)}
      end
    end
  end

  @spec resolve_codex_usage_auth({:ok, auth()} | {:error, term()}, opts()) ::
          {:ok, codex_usage_auth()} | {:error, gateway_error()}
  def resolve_codex_usage_auth({:ok, auth}, %RequestOptions{}), do: {:ok, {:api_key, auth}}

  def resolve_codex_usage_auth({:error, _reason}, %RequestOptions{} = request_options) do
    request_options = request_options(request_options, "/api/codex/usage", %{})
    chatgpt_account_id = request_options.usage_authentication.chatgpt_account_id

    if present?(chatgpt_account_id) do
      resolve_codex_account_usage_auth(chatgpt_account_id, request_options)
    else
      {:error, %{status: 401, code: "invalid_api_key", message: "api key is invalid"}}
    end
  end

  @spec codex_usage_for_resolved_auth(codex_usage_auth(), String.t(), opts()) ::
          {:ok, gateway_result()} | {:error, gateway_error()}
  def codex_usage_for_resolved_auth(
        {:api_key, auth},
        endpoint,
        %RequestOptions{} = request_options
      ) do
    codex_usage(auth, endpoint, request_options)
  end

  def codex_usage_for_resolved_auth(
        {:chatgpt_account_token, identity},
        endpoint,
        %RequestOptions{} = request_options
      ) do
    request_options = request_options(request_options, endpoint, %{})

    with :ok <- record_chatgpt_usage_request(identity, endpoint, request_options) do
      identity
      |> Accounting.build_codex_usage_for_upstream_identity()
      |> usage_result()
    end
  end

  @spec codex_usage_with_fallback({:ok, auth()} | {:error, term()}, String.t(), opts()) ::
          {:ok, gateway_result()} | {:error, gateway_error()}
  def codex_usage_with_fallback(auth_result, endpoint, %RequestOptions{} = request_options) do
    request_options = request_options(request_options, endpoint, %{})

    with {:ok, usage_auth} <- resolve_codex_usage_auth(auth_result, request_options) do
      codex_usage_for_resolved_auth(usage_auth, endpoint, request_options)
    end
  end

  defp resolve_codex_account_usage_auth(chatgpt_account_id, %RequestOptions{} = request_options) do
    with token when token != "" <- bearer_token(request_options),
         {:ok, identity} <- authenticate_chatgpt_account_token(chatgpt_account_id, token) do
      {:ok, {:chatgpt_account_token, identity}}
    else
      "" ->
        {:error,
         %{status: 401, code: "invalid_authorization", message: "chatgpt token is required"}}

      {:error, _reason} ->
        {:error,
         %{
           status: 401,
           code: "invalid_authorization",
           message: "chatgpt token is invalid for this account"
         }}
    end
  end

  defp authenticate_chatgpt_account_token(chatgpt_account_id, token) do
    chatgpt_account_id
    |> Upstreams.list_upstream_identities_by_chatgpt_account()
    |> Enum.find_value(fn identity ->
      with {:ok, stored_token} <- Secrets.decrypt_active_secret(identity, @secret_kind),
           true <- secure_token_match?(stored_token, token) do
        {:ok, identity}
      else
        _invalid -> nil
      end
    end)
    |> case do
      {:ok, %UpstreamIdentity{}} = ok -> ok
      nil -> {:error, :invalid_token}
    end
  end

  defp record_chatgpt_usage_request(identity, endpoint, %RequestOptions{} = request_options) do
    request_metadata = request_options.request_metadata

    MetadataAccounting.record_optional_upstream_identity_metadata_request(
      :record_chatgpt_usage_metadata_request,
      identity,
      %{
        endpoint: endpoint,
        transport: "http_json",
        correlation_id: RequestOptions.server_correlation_id(request_options),
        client_ip: request_metadata.client_ip,
        user_agent: request_metadata.user_agent,
        response_status_code: 200,
        request_metadata:
          %{
            "endpoint" => endpoint,
            "operation" => "usage"
          }
          |> Map.merge(RequestOptions.client_request_metadata(request_options))
      }
    )
  end

  defp record_metadata_request(
         %{pool: %{id: pool_id}, api_key: %{id: api_key_id}} = auth,
         endpoint,
         %RequestOptions{} = request_options
       )
       when is_binary(pool_id) and is_binary(api_key_id) do
    request_metadata = request_options.request_metadata

    MetadataAccounting.record_metadata_request(:record_usage_metadata_request, auth, %{
      endpoint: endpoint,
      transport: "http_json",
      correlation_id: RequestOptions.server_correlation_id(request_options),
      idempotency_key: request_metadata.idempotency_key,
      client_ip: request_metadata.client_ip,
      user_agent: request_metadata.user_agent,
      response_status_code: 200,
      request_metadata:
        %{
          "key_prefix" => auth.key_prefix,
          "endpoint" => endpoint,
          "operation" => "usage"
        }
        |> Map.merge(RequestOptions.client_request_metadata(request_options))
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()
    })
  end

  defp record_metadata_request(_auth, _endpoint, %RequestOptions{}) do
    {:error, %{code: :invalid_request, message: "authenticated pool and api key are required"}}
  end

  defp normalize_policy_or_log(auth, endpoint, %RequestOptions{} = request_options) do
    case Access.normalize_api_key_policy(auth.api_key) do
      {:ok, policy} ->
        {:ok, policy}

      {:error, reason} ->
        Denials.log_policy(denial_context(auth, reason, endpoint, request_options))
    end
  end

  defp denial_context(auth, reason, endpoint, %RequestOptions{} = request_options) do
    %Denials.Context{
      auth: auth,
      model: nil,
      reason: reason,
      endpoint: endpoint,
      payload: %{},
      opts: request_options
    }
  end

  defp validate_v1_usage_filters(params) when map_size(params) == 0, do: :ok

  defp validate_v1_usage_filters(params) do
    {field, _value} = params |> Enum.sort_by(&elem(&1, 0)) |> List.first()
    {:error, Error.unsupported_parameter(field)}
  end

  defp usage_result({:ok, usage}), do: {:ok, %{status: 200, headers: json_headers(), body: usage}}
  defp usage_result({:error, reason}), do: {:error, usage_error(reason)}

  defp usage_error(%{status: status, code: code, message: message} = reason) do
    Error.reason(status, code, message, Map.get(reason, :param))
  end

  defp usage_error(%{code: :invalid_request, message: message}) do
    Error.reason(400, "invalid_request", message)
  end

  defp usage_error(%{code: :invalid_chatgpt_account, message: message}) do
    Error.reason(404, "invalid_chatgpt_account", message)
  end

  defp usage_error(%{code: :no_upstream_usage, message: message}) do
    Error.reason(404, "no_upstream_usage", message)
  end

  defp usage_error(%{code: code, message: message}) do
    Error.reason(502, code, message)
  end

  defp secure_token_match?(expected, actual)
       when is_binary(expected) and is_binary(actual) and byte_size(expected) == byte_size(actual) do
    Plug.Crypto.secure_compare(expected, actual)
  end

  defp secure_token_match?(_expected, _actual), do: false

  defp bearer_token(%RequestOptions{} = request_options) do
    case request_options.usage_authentication.authorization_header do
      "Bearer " <> token -> String.trim(token)
      _value -> ""
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp request_options(%RequestOptions{} = request_options, endpoint, payload),
    do: RequestOptions.for_payload(request_options, endpoint, payload)

  defp json_headers, do: [{"content-type", "application/json"}]
end
