defmodule CodexPooler.Gateway.Denials do
  @moduledoc """
  Accounting-safe denied request recording for gateway policy and routing failures.
  """

  alias CodexPooler.Accounting
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Routing.SessionContinuity

  @known_reasoning_efforts ~w(none minimal low medium high xhigh max ultra)

  @pinned_continuation_reauth_operator_action "reauthenticate the pinned upstream account and restart the client without continuation anchors"
  @pinned_continuation_unavailable_operator_action "wait for the pinned upstream to recover, then restart the client without continuation anchors"

  defmodule Context do
    @moduledoc false

    defstruct [:auth, :model, :reason, :endpoint, :payload, :opts]

    @type t :: %__MODULE__{
            auth: map(),
            model: Model.t() | nil,
            reason: atom() | map(),
            endpoint: String.t(),
            payload: map(),
            opts: RequestOptions.t()
          }
  end

  @spec log_policy(Context.t()) :: {:error, map()}
  def log_policy(%Context{
        auth: auth,
        model: model,
        reason: reason,
        endpoint: endpoint,
        payload: payload,
        opts: opts
      }) do
    status = policy_status(reason)
    reason_code = to_string(reason)
    message = policy_message(reason)

    _ignored =
      Accounting.record_denied_request(
        auth,
        model,
        request_attrs(auth, model, endpoint, payload, opts, status, reason_code, %{
          "policy_denial" => %{"code" => reason_code, "message" => message}
        })
      )

    {:error, error(status, reason_code, message)}
  end

  @spec log_gateway(Context.t(), CodexPooler.Accounting.Request.t() | nil) :: {:error, map()}
  def log_gateway(context, turn_claim \\ nil)

  def log_gateway(
        %Context{
          auth: auth,
          model: model,
          reason: %{code: code, message: message} = reason,
          endpoint: endpoint,
          payload: payload,
          opts: opts
        },
        turn_claim
      ) do
    status = Map.get(reason, :status) || 400
    reason_code = to_string(code)
    request_options = request_options(opts, endpoint, payload)

    _ignored =
      Accounting.record_denied_request(
        auth,
        model,
        request_attrs(
          auth,
          model,
          endpoint,
          payload,
          opts,
          status,
          reason_code,
          %{"gateway_denial" => gateway_metadata(reason_code, message, reason)}
        )
        |> maybe_put_turn_claim(turn_claim)
        |> update_in([:request_metadata], fn metadata ->
          metadata
          |> SessionContinuity.put_session_metadata(request_options)
          |> maybe_put_metadata("candidate_exclusions", Map.get(reason, :candidate_exclusions))
          |> maybe_put_metadata(
            "canonical_partition",
            request_options.routing.canonical_partition
          )
          |> maybe_put_metadata("continuity_denial", continuity_denial_metadata(reason))
        end)
      )

    {:error, reason}
  end

  defp maybe_put_turn_claim(attrs, nil), do: attrs
  defp maybe_put_turn_claim(attrs, request), do: Map.put(attrs, :turn_claim, request)

  @spec enforced_model_metadata(RequestOptions.t()) :: String.t() | nil
  def enforced_model_metadata(%RequestOptions{
        routing: %{api_key_policy: %{enforced_model_identifier: model}}
      })
      when is_binary(model),
      do: model

  def enforced_model_metadata(_opts), do: nil

  defp request_attrs(auth, model, endpoint, payload, opts, status, reason_code, metadata) do
    request_options = request_options(opts, endpoint, payload)

    %{
      endpoint: endpoint,
      transport: request_options.transport.transport,
      correlation_id: RequestOptions.websocket_request_correlation_id(request_options),
      idempotency_key: request_options.request_metadata.idempotency_key,
      client_ip: request_options.request_metadata.client_ip,
      user_agent: request_options.request_metadata.user_agent,
      requested_model: requested_model(model, payload, endpoint),
      response_status_code: status,
      last_error_code: reason_code,
      request_metadata:
        request_options
        |> request_metadata(auth, endpoint)
        |> Map.merge(metadata)
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()
    }
  end

  defp request_metadata(%RequestOptions{} = request_options, auth, endpoint) do
    %{
      "key_prefix" => auth.key_prefix,
      "endpoint" => endpoint,
      "requested_model" => request_options.routing.requested_model,
      "effective_model" => request_options.routing.effective_model,
      "enforced_model" => enforced_model_metadata(request_options),
      "request_bytes" => request_options.request_metadata.request_bytes,
      "upload_bytes" => request_options.request_metadata.upload_bytes,
      "request_content_type" => request_options.request_metadata.request_content_type
    }
    |> Map.merge(RequestOptions.client_request_metadata(request_options))
  end

  defp gateway_metadata(reason_code, message, reason) do
    %{
      "code" => reason_code,
      "message" => message,
      "param" => Map.get(reason, :param),
      "reasoning_policy" => safe_reasoning_policy(Map.get(reason, :reasoning_policy))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp safe_reasoning_policy(policy) when is_map(policy) do
    policy
    |> Map.take([:policy_mode, :configured_effort, :requested_effort, :applied_effort])
    |> Map.update(:requested_effort, nil, &safe_requested_effort/1)
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
  end

  defp safe_reasoning_policy(_policy), do: nil

  defp safe_requested_effort(value) when value in @known_reasoning_efforts, do: value
  defp safe_requested_effort(nil), do: nil
  defp safe_requested_effort(_value), do: "unknown"

  defp request_options(%RequestOptions{} = request_options, endpoint, payload),
    do: RequestOptions.for_payload(request_options, endpoint, payload)

  defp maybe_put_metadata(metadata, _key, nil), do: metadata
  defp maybe_put_metadata(metadata, key, value), do: Map.put(metadata, key, value)

  defp continuity_denial_metadata(%{continuity_denial: metadata}) when is_map(metadata) do
    metadata
    |> Map.put(
      "operator_action",
      Map.get(metadata, "operator_action") || operator_action(metadata)
    )
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp continuity_denial_metadata(_reason), do: nil

  defp operator_action(%{"denial_family" => "pinned_continuation_unavailable"}),
    do: @pinned_continuation_unavailable_operator_action

  defp operator_action(_metadata), do: @pinned_continuation_reauth_operator_action

  defp requested_model(%Model{} = model, _payload, _endpoint), do: model.exposed_model_id

  defp requested_model(_model, payload, endpoint) when is_map(payload) do
    case Map.get(payload, "model") || Map.get(payload, :model) do
      value when is_binary(value) and value != "" -> String.trim(value)
      _value -> endpoint
    end
  end

  defp policy_status(:api_key_missing), do: 401
  defp policy_status(_reason), do: 403

  defp policy_message(:api_key_missing), do: "api key is required"
  defp policy_message(:api_key_disabled), do: "api key is disabled"
  defp policy_message(:api_key_policy_malformed), do: "api key policy is invalid"
  defp policy_message(:model_not_allowed), do: "api key is not allowed to use this model"

  defp error(status, code, message, param \\ nil),
    do: %{status: status, code: code, message: message, param: param}
end
