defmodule CodexPooler.Gateway.Usage do
  @moduledoc false

  alias CodexPooler.Access
  alias CodexPooler.Accounting
  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.Denials
  alias CodexPooler.Gateway.Facade
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
          |> usage_result(&project_codex_usage/1)

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
          |> usage_result(&project_v1_usage/1)

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
      |> usage_result(&project_codex_usage/1)
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

  @spec project_v1_usage(map()) :: map()
  def project_v1_usage(usage) when is_map(usage) do
    %{
      request_count: field(usage, :request_count, 0),
      total_tokens: field(usage, :total_tokens, 0),
      cached_input_tokens: field(usage, :cached_input_tokens, 0),
      total_cost_usd: field(usage, :total_cost_usd),
      total_cost_status: field(usage, :total_cost_status, "unpriced"),
      limits: project_limits(field(usage, :limits, []), :local),
      upstream_limits: project_limits(field(usage, :upstream_limits, []), :capacity)
    }
    |> maybe_put_model_buckets(usage)
  end

  @spec project_codex_usage(map()) :: map()
  def project_codex_usage(usage) when is_map(usage) do
    %{
      plan_type: "api_key",
      rate_limit: project_rate_limit(field(usage, :rate_limit, %{}))
    }
    |> maybe_put_credits(field(usage, :credits))
  end

  defp project_limits(limits, kind) when is_list(limits) do
    Enum.flat_map(limits, fn
      %{} = limit -> [project_limit(limit, kind)]
      _limit -> []
    end)
  end

  defp project_limits(_limits, _kind), do: []

  defp project_limit(limit, kind) do
    %{
      limit_type: field(limit, :limit_type),
      limit_window: field(limit, :limit_window),
      max_value: field(limit, :max_value),
      current_value: field(limit, :current_value),
      remaining_value: field(limit, :remaining_value),
      model_filter: public_model_filter(field(limit, :model_filter)),
      reset_at: field(limit, :reset_at),
      source: public_limit_source(kind)
    }
  end

  defp public_model_filter(nil), do: nil
  defp public_model_filter(_model), do: Facade.public_model()

  defp public_limit_source(:local), do: "pool_limit"
  defp public_limit_source(:capacity), do: "pool_capacity"

  defp maybe_put_model_buckets(projected, usage) do
    case field(usage, :model_buckets) do
      buckets when is_list(buckets) and buckets != [] ->
        Map.put(projected, :model_buckets, [collapse_model_buckets(buckets)])

      _buckets ->
        projected
    end
  end

  defp collapse_model_buckets(buckets) do
    numeric_keys = [
      :request_count,
      :input_tokens,
      :cached_input_tokens,
      :output_tokens,
      :reasoning_tokens,
      :total_tokens,
      :total_cost_usd
    ]

    totals =
      Map.new(numeric_keys, fn key ->
        total =
          Enum.reduce(buckets, 0, fn
            %{} = bucket, acc -> add_number(acc, field(bucket, key, 0))
            _bucket, acc -> acc
          end)

        {key, total}
      end)

    totals
    |> Enum.reject(fn {_key, value} -> value == 0 end)
    |> Map.new()
    |> Map.put(:model, Facade.public_model())
  end

  defp add_number(left, right) when is_number(left) and is_number(right), do: left + right
  defp add_number(left, _right), do: left

  defp project_rate_limit(rate_limit) when is_map(rate_limit) do
    %{
      allowed: field(rate_limit, :allowed, true) == true,
      limit_reached: field(rate_limit, :limit_reached, false) == true,
      primary_window: project_rate_window(field(rate_limit, :primary_window)),
      secondary_window: project_rate_window(field(rate_limit, :secondary_window))
    }
  end

  defp project_rate_limit(_rate_limit) do
    %{allowed: true, limit_reached: false, primary_window: nil, secondary_window: nil}
  end

  defp project_rate_window(%{} = window) do
    %{
      used_percent: field(window, :used_percent),
      limit_window_seconds: field(window, :limit_window_seconds),
      reset_after_seconds: field(window, :reset_after_seconds),
      reset_at: field(window, :reset_at)
    }
  end

  defp project_rate_window(_window), do: nil

  defp maybe_put_credits(projected, %{} = credits) do
    Map.put(projected, :credits, %{
      has_credits: field(credits, :has_credits, false) == true,
      unlimited: field(credits, :unlimited, false) == true,
      balance: safe_balance(field(credits, :balance))
    })
  end

  defp maybe_put_credits(projected, _credits), do: projected

  defp safe_balance(balance) when is_binary(balance) do
    case Integer.parse(balance) do
      {value, ""} when value >= 0 -> Integer.to_string(value)
      _invalid -> "0"
    end
  end

  defp safe_balance(balance) when is_integer(balance) and balance >= 0,
    do: Integer.to_string(balance)

  defp safe_balance(_balance), do: "0"

  defp usage_result({:ok, usage}, projector) when is_function(projector, 1) do
    {:ok, %{status: 200, headers: json_headers(), body: projector.(usage)}}
  end

  defp usage_result({:error, reason}, _projector), do: {:error, usage_error(reason)}

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

  defp field(map, key, default \\ nil) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp request_options(%RequestOptions{} = request_options, endpoint, payload),
    do: RequestOptions.for_payload(request_options, endpoint, payload)

  defp json_headers, do: [{"content-type", "application/json"}]
end
