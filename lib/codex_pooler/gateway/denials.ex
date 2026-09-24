defmodule CodexPooler.Gateway.Denials do
  @moduledoc """
  Accounting-safe denied request recording for gateway policy and routing failures.
  """

  alias CodexPooler.Accounting
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Contracts
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
    %{status: status, code: reason_code, message: message} = denial = policy_denial_error(reason)

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
          {status, reason_code},
          %{"policy_denial" => %{"code" => reason_code, "message" => message}}
        )
      )

    {:error, denial}
  end

  @doc """
  The one status and message for an API-key policy reason, as a marked denial.
  `PreDispatch` and `log_policy/1` both answer a reason through this mapping,
  so the same condition cannot surface with two statuses or two messages
  (findings#221). A reason without a dedicated message keeps its atom as the
  wire code and the generic policy message.
  """
  @spec policy_denial_error(atom()) :: map()
  def policy_denial_error(reason) when is_atom(reason),
    do: policy_error(policy_status(reason), Atom.to_string(reason), policy_message(reason), policy_param(reason))

  @doc """
  A policy denial the Pooler authors (never relayed from an upstream), marked
  by construction so `/v1` renders its own code and message instead of the
  upstream redaction. Every producer of such a denial builds it here, so a
  new producer cannot forget the marker (findings#221).
  """
  @spec policy_error(pos_integer(), String.t(), String.t(), String.t() | nil) :: map()
  def policy_error(status, code, message, param \\ nil)
      when is_integer(status) and is_binary(code) and is_binary(message),
      do: Map.put(error(status, code, message, param), :pooler_policy, true)

  @spec log_gateway(Context.t(), CodexPooler.Accounting.Request.t() | nil) :: {:error, map()}
  def log_gateway(context, turn_claim \\ nil)

  def log_gateway(
        %Context{reason: %{code: :api_key_concurrency_limit_exceeded}} = context,
        turn_claim
      ) do
    log_gateway(
      %{context | reason: policy_denial_error(:api_key_concurrency_limit_exceeded)},
      turn_claim
    )
  end

  # A reservation-policy refusal (`ReservationPolicy`) comes without a status:
  # a window that admits the request again once it moves answers `429` with
  # its retry hint, like the active-request cap; a per-request estimate cap
  # that no resend can pass answers `400` (findings#206 row 206-438). The
  # websocket rendered the missing status as a `500` and HTTP as a `403`,
  # while both recorded `400` (findings#206 row 206-427).
  def log_gateway(
        %Context{reason: %{code: :api_key_policy_limit_exceeded} = reason} = context,
        turn_claim
      )
      when not is_map_key(reason, :status) do
    log_gateway(%{context | reason: reservation_policy_error(reason)}, turn_claim)
  end

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
          {status, reason_code},
          %{"gateway_denial" => gateway_metadata(reason_code, message, reason)},
          turn_claim
        )
        |> fresh_unclaimed_concurrency_correlation(turn_claim, reason)
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

  @doc """
  The status and marked denial of a reservation-policy refusal: `429` for a
  window, with its `retry_after_seconds` when the window has a boundary of its
  own (findings#206 row 206-427), `400 invalid_request_error` for a
  per-request estimate cap that no resend of the same request can pass: the
  released Codex client ends the turn on a `400` and resent a `403` five
  times before falling back to HTTPS (findings#206 row 206-438).
  """
  @spec reservation_policy_error(map()) :: map()
  def reservation_policy_error(%{code: :api_key_policy_limit_exceeded, message: message} = reason) do
    status = if Map.get(reason, :limit_scope) == :window, do: 429, else: 400

    status
    |> policy_error("api_key_policy_limit_exceeded", message)
    |> maybe_put_retry_after(Map.get(reason, :retry_after_seconds))
  end

  defp maybe_put_retry_after(error, seconds) when is_integer(seconds) and seconds > 0,
    do: Map.put(error, :retry_after_seconds, seconds)

  defp maybe_put_retry_after(error, _seconds), do: error

  defp maybe_put_turn_claim(attrs, nil), do: attrs
  defp maybe_put_turn_claim(attrs, request), do: Map.put(attrs, :turn_claim, request)

  # An unreserved retry is a new rejection, not a durable execution claim.
  # A websocket's handshake request id is shared by all its response.create frames.
  defp fresh_unclaimed_concurrency_correlation(
         attrs,
         nil,
         %{pooler_policy: true, code: "api_key_concurrency_limit_exceeded"}
       ),
       do: Map.put(attrs, :correlation_id, Ecto.UUID.generate())

  defp fresh_unclaimed_concurrency_correlation(attrs, _turn_claim, _reason), do: attrs

  @spec enforced_model_metadata(RequestOptions.t()) :: String.t() | nil
  def enforced_model_metadata(%RequestOptions{
        routing: %{api_key_policy: %{enforced_model_identifier: model}}
      })
      when is_binary(model),
      do: model

  def enforced_model_metadata(_opts), do: nil

  defp request_attrs(
         auth,
         model,
         endpoint,
         payload,
         opts,
         {status, reason_code},
         metadata,
         turn_claim \\ nil
       ) do
    request_options = request_options(opts, endpoint, payload)

    %{
      endpoint: endpoint,
      transport: request_options.transport.transport,
      correlation_id: RequestOptions.websocket_denial_correlation_id(request_options, turn_claim),
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
    |> Map.merge(Contracts.usage_limit_record(reason))
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

  # The runtime auth boundary answers a disabled key with 401 (the credential
  # is not usable); the gateway policy path said 403 for the same reason. One
  # status for one condition (findings#221).
  defp policy_status(:api_key_missing), do: 401
  defp policy_status(:api_key_disabled), do: 401
  defp policy_status(:api_key_concurrency_limit_exceeded), do: 429
  # A model the key may not use is refused the way the Codex backend refuses a
  # model the account cannot serve, and the way the key's own reasoning-effort
  # policy refuses: `400`, which the released Codex client ends the turn on.
  # It resent a `403` five times, then fell back from websocket to HTTPS and
  # resent it again (findings#206 row 206-438).
  defp policy_status(:model_not_allowed), do: 400
  defp policy_status(_reason), do: 403

  defp policy_param(:model_not_allowed), do: "model"
  defp policy_param(_reason), do: nil

  defp policy_message(:api_key_missing), do: "api key is required"
  defp policy_message(:api_key_disabled), do: "api key is disabled"
  defp policy_message(:api_key_policy_malformed), do: "api key policy is invalid"
  defp policy_message(:model_not_allowed), do: "api key is not allowed to use this model"

  defp policy_message(:api_key_concurrency_limit_exceeded),
    do: "api key active request limit reached; retry shortly"

  defp policy_message(_reason), do: "api key policy denied this request"

  defp error(status, code, message, param),
    do: %{status: status, code: code, message: message, param: param}
end
