defmodule CodexPooler.Gateway.OpenAICompatibility.PublicResponse do
  @moduledoc false

  alias CodexPooler.Gateway.ErrorClassification
  alias CodexPooler.Gateway.Runtime.Finalization.ValidationRejection
  alias CodexPooler.Gateway.Transports.MisalignmentPolicyViolation

  @type success_normalizer :: (map() -> map())
  @type error_status :: integer() | String.t() | nil
  @type terminal_error_status :: 400 | 404 | 502
  @type error_origin :: :local_validation
  @type error_opts :: [
          status: error_status(),
          origin: error_origin(),
          input_file_upstream_404?: boolean(),
          source_code: String.t() | nil
        ]

  @public_recovery_error_tokens ~w(pinned_continuation_reauth_required pinned_continuation_unavailable)
  @server_error_tokens ~w(internal_error server_error upstream_error server_is_overloaded)
  @redacted_message "upstream request failed"
  @rate_limit_error_type "rate_limit_error"
  @overload_code "server_is_overloaded"
  @overload_message "gateway route class is temporarily overloaded"
  @bulkhead_reasons ~w(bulkhead_rejected bulkhead_queue_timeout)

  @spec stream_headers([{term(), term()}]) :: [{String.t(), String.t()} | {term(), term()}]
  def stream_headers(headers) do
    headers
    |> Enum.reject(fn {key, _value} -> String.downcase(to_string(key)) == "content-type" end)
    |> Kernel.++([{"content-type", "text/event-stream"}])
  end

  @spec normalize_raw_body(pos_integer(), term(), success_normalizer(), error_opts()) ::
          {:ok, map()} | :passthrough
  def normalize_raw_body(status, body, normalize_success, opts \\ [])

  def normalize_raw_body(status, body, normalize_success, opts) when is_binary(body) do
    case CodexPooler.JSON.decode(body) do
      {:ok, decoded} when is_map(decoded) and status < 400 ->
        {:ok, normalize_success.(decoded)}

      {:ok, %{"error" => %{} = error}} when status >= 400 ->
        {:ok, %{"error" => normalize_error(error, Keyword.put(opts, :status, status))}}

      {:ok, decoded} when is_map(decoded) and status >= 400 ->
        {:ok, normalize_error_body(status, opts)}

      _error ->
        if status >= 400, do: {:ok, normalize_error_body(status, opts)}, else: :passthrough
    end
  end

  def normalize_raw_body(status, _body, _normalize_success, opts) do
    if status >= 400, do: {:ok, normalize_error_body(status, opts)}, else: :passthrough
  end

  @doc """
  The public websocket event for a provider refusal the upstream websocket
  sent as its wrapped error frame (`{"type": "error", "status": 4xx,
  "error": {...}}`): the OpenAI websocket mode's `error` event carrying the
  status and error object a streaming `/v1/responses` request answers over
  HTTP for the same provider response under the default (mode-scoped)
  projection, i.e. the relayed parameter-validation rejection when it
  qualifies and otherwise the redacted upstream error under the stream
  startup code `upstream_status` (findings#254 row 254-15). Provider message
  text never travels. The socket holds no per-turn input index map, so an
  `input[N]` param loses its index (`input[]...`) rather than name a position
  a Lite rewrite may have moved (findings#254 row 254-61).
  """
  @spec provider_rejection_websocket_event(400..499, map()) :: map()
  def provider_rejection_websocket_event(status, %{} = error) when status in 400..499 do
    response = %Req.Response{status: status, body: CodexPooler.JSON.encode!(%{"error" => error})}

    public_error =
      case ValidationRejection.fetch_ordinary_route(response) do
        %{} = rejection -> rejection |> ValidationRejection.for_client(:unknown) |> validation_rejection_error()
        nil -> normalize_error(error, status: status, source_code: "upstream_status")
      end

    %{"type" => "error", "status" => public_http_error_status(status), "error" => public_error}
  end

  # `/v1` answers an upstream 404 as 502 (`PublicGatewayResult`), the public
  # websocket event carries the same status.
  defp public_http_error_status(404), do: 502
  defp public_http_error_status(status), do: status

  @doc """
  Renders a relayed upstream parameter-validation rejection as the public
  OpenAI error object, mapping the upstream param path to the client field.
  """
  @spec validation_rejection_error(
          ValidationRejection.rejection(),
          ValidationRejection.param_mapper()
        ) :: map()
  def validation_rejection_error(rejection, param_mapper \\ &Function.identity/1),
    do: ValidationRejection.error(rejection, param_mapper)

  @spec normalize_error(term(), error_opts()) :: map()
  def normalize_error(error, opts \\ [])

  def normalize_error(%{} = error, opts) do
    status = error_status(error, opts)

    cond do
      input_file_capability_error?(status, opts) -> input_file_capability_error()
      misalignment_policy_violation?(error) -> misalignment_policy_violation_error(error)
      overload_error?(error) -> overload_error()
      local_validation_error?(error, status, opts) -> explicit_error(error, status)
      true -> redacted_error(error, opts)
    end
  end

  def normalize_error(_error, opts), do: normalize_error(%{}, opts)

  @spec terminal_error_status(term(), error_opts()) :: terminal_error_status()
  def terminal_error_status(error, opts \\ []) do
    status = error_status(error, opts)

    cond do
      input_file_capability_error?(status, opts) -> 404
      local_validation_error?(error, status, opts) -> 400
      true -> 502
    end
  end

  @doc """
  True for the redacted error this module renders for an upstream 429
  (`upstream request failed`, `rate_limit_error`). A public terminal that is
  normalized a second time (the owner's masked frame on the public websocket)
  keeps that type instead of the terminal projection's `server_error`
  (findings#254 row 254-82). Only the type survives: the code is sanitized
  again and the message is the Pooler's.
  """
  @spec redacted_throttle_error?(term()) :: boolean()
  def redacted_throttle_error?(%{} = error),
    do: field(error, "message") == @redacted_message and field(error, "type") == @rate_limit_error_type

  def redacted_throttle_error?(_error), do: false

  @spec redacted_gateway_error?(term()) :: boolean()
  def redacted_gateway_error?(%{public_compaction_error?: true}), do: false

  # An all-exhausted Pool's terminal answer is authored by the Pooler from its
  # own quota evidence, never relayed: `/v1` renders its code, message, reset
  # fields and retry headers the way the backend routes do (findings#206 row
  # 206-508). Keyed on the atom-only `usage_limit` marker quota routing sets.
  def redacted_gateway_error?(%{usage_limit: %{}}), do: false

  def redacted_gateway_error?(%{} = error) do
    not public_recovery_error_token?(field(error, "code")) and
      not pooler_policy_denial?(error) and
      public_failure_error?(error, error_status(error, []))
  end

  def redacted_gateway_error?(_error), do: false

  # An API-key policy denial is authored by Codex Pooler, never relayed from
  # the upstream: its 401/403/429 status, code and message are the Pooler's own
  # decision, so `/v1` renders them the way the backend routes do instead of
  # blaming the upstream with `server_error` / "upstream request failed"
  # (findings#221). The exemption is keyed on the `pooler_policy` marker that
  # `Denials.log_policy/1` sets by construction, never on the wire code: an
  # upstream error that happened to carry one of these codes stays redacted.
  # The list below is the documented vocabulary of that marker (the reasons
  # `Access` policy checks return plus the image-generation denial), kept as a
  # dependency-free literal for the matrix and the docs; the marker, not the
  # list, decides rendering, so a new marked reason renders before it is
  # listed here. Every other gateway error, including the quota 503s and every
  # upstream-derived 401/403/429, keeps the redaction.
  @unredacted_policy_denial_codes ~w(api_key_missing api_key_disabled api_key_policy_malformed model_not_allowed image_generation_disabled api_key_concurrency_limit_exceeded api_key_policy_limit_exceeded)

  @doc false
  @spec unredacted_policy_denial_codes() :: [String.t()]
  def unredacted_policy_denial_codes, do: @unredacted_policy_denial_codes

  # Atom key only: a decoded provider or client body can never carry it.
  defp pooler_policy_denial?(error), do: Map.get(error, :pooler_policy) == true

  defp input_file_capability_error?(404, opts),
    do: Keyword.get(opts, :input_file_upstream_404?) === true

  defp input_file_capability_error?(_status, _opts), do: false

  defp input_file_capability_error do
    %{
      "message" => "upstream request failed",
      "type" => "invalid_request_error",
      "code" => "upstream_status",
      "upstream_status" => 404
    }
  end

  defp misalignment_policy_violation_error(error) do
    %{
      "message" =>
        error
        |> field("message")
        |> MisalignmentPolicyViolation.normalize_message(),
      "type" => "invalid_request_error",
      "code" => MisalignmentPolicyViolation.code()
    }
  end

  defp explicit_error(error, status) do
    %{
      "message" => safe_error_message(error),
      "type" => safe_error_type(error, status),
      "code" => safe_error_code(error) || "upstream_error",
      "param" => clean_string(field(error, "param"))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp redacted_error(error, opts) do
    code = safe_source_code(opts) || safe_error_code(error) || "upstream_error"

    %{
      "message" => @redacted_message,
      "type" => redacted_error_type(code, error_status(error, opts)),
      "code" => code
    }
  end

  # The redacted envelope is Codex Pooler-authored, so a refusal the client
  # caused is typed by the shared classifier from the status it is answered
  # with: a refused 4xx is the client's `invalid_request_error`, never
  # `server_error`, which names the retryable class and contradicted the 400 it
  # rode on (findings#254 row 254-51), and a 429 is the classifier's
  # `rate_limit_error`, OpenAI's type for a throttle (row 254-72; the SDKs
  # retry a 429 on the status alone, so only the reported class changes). The
  # upstream 401/403 keep `server_error`: they are the upstream account's
  # credential or standing, not the caller's request. `/v1` answers an
  # upstream 404 as a 502, so it keeps `server_error` too, as does every 5xx
  # and a status-less error.
  defp redacted_error_type(code, status)
       when is_integer(status) and status in 400..499 and status not in [401, 403, 404],
       do: ErrorClassification.error_type(code, status)

  defp redacted_error_type(_code, _status), do: "server_error"

  defp overload_error do
    %{
      "message" => @overload_message,
      "type" => "server_error",
      "code" => @overload_code,
      "param" => nil
    }
  end

  defp normalize_error_body(status, opts), do: %{"error" => status_error(status, opts)}

  defp status_error(status, opts) when status in 500..599,
    do: normalize_error(%{}, Keyword.put(opts, :status, status))

  defp status_error(status, opts) do
    error = %{"message" => "upstream returned #{status}", "code" => "upstream_status"}
    normalize_error(error, Keyword.put(opts, :status, status))
  end

  defp server_class_error?(error, status) do
    status in 500..599 or server_error_token?(field(error, "type")) or
      server_error_token?(field(error, "code"))
  end

  defp local_validation_error?(error, status, opts) do
    Keyword.get(opts, :origin) == :local_validation and
      field(error, "type") == "invalid_request_error" and validation_status?(status)
  end

  defp public_failure_error?(error, status) do
    server_class_error?(error, status) or gateway_failure_status?(status) or
      provider_api_error?(error) or provider_invalid_request_error?(error)
  end

  defp validation_status?(nil), do: true
  defp validation_status?(status) when is_integer(status), do: status in 400..499

  defp gateway_failure_status?(status) when is_integer(status), do: status in [401, 403, 429]
  defp gateway_failure_status?(_status), do: false

  defp provider_api_error?(error), do: field(error, "type") == "api_error"

  defp provider_invalid_request_error?(error),
    do: field(error, "type") == "invalid_request_error"

  defp overload_error?(error) do
    field(error, "code") == @overload_code and
      field(error, "internal_reason") in @bulkhead_reasons
  end

  defp misalignment_policy_violation?(error),
    do: field(error, "code") == MisalignmentPolicyViolation.code()

  defp public_recovery_error_token?(value) when is_binary(value),
    do: value in @public_recovery_error_tokens

  defp public_recovery_error_token?(_value), do: false

  defp server_error_token?(value) when is_binary(value), do: value in @server_error_tokens
  defp server_error_token?(_value), do: false

  defp error_status(error, opts) when is_list(opts) do
    opts
    |> Keyword.get(:status)
    |> Kernel.||(field(error, "status"))
    |> Kernel.||(field(error, "status_code"))
    |> normalize_status()
  end

  defp normalize_status(status) when is_integer(status), do: status

  defp normalize_status(status) when is_binary(status) do
    case Integer.parse(status) do
      {status, ""} -> status
      _other -> nil
    end
  end

  defp normalize_status(_status), do: nil

  defp safe_error_message(error) do
    case clean_string(field(error, "message")) do
      nil -> "upstream request failed"
      message -> message
    end
  end

  defp safe_error_type(error, _status),
    do: clean_string(field(error, "type")) || "invalid_request_error"

  defp safe_error_code(error) do
    error
    |> field("code")
    |> clean_string()
    |> case do
      nil -> nil
      code -> if safe_error_token?(code), do: code
    end
  end

  defp safe_source_code(opts) do
    opts
    |> Keyword.get(:source_code)
    |> clean_string()
    |> case do
      nil -> nil
      code -> if safe_error_token?(code), do: code
    end
  end

  defp safe_error_token?(token) do
    byte_size(token) <= 80 and Regex.match?(~r/^[A-Za-z0-9_.-]+$/, token)
  end

  defp field(map, "message"), do: Map.get(map, "message") || Map.get(map, :message)
  defp field(map, "type"), do: Map.get(map, "type") || Map.get(map, :type)
  defp field(map, "code"), do: Map.get(map, "code") || Map.get(map, :code)
  defp field(map, "param"), do: Map.get(map, "param") || Map.get(map, :param)
  defp field(map, "status"), do: Map.get(map, "status") || Map.get(map, :status)
  defp field(map, "status_code"), do: Map.get(map, "status_code") || Map.get(map, :status_code)

  defp field(map, "internal_reason"),
    do: Map.get(map, "internal_reason") || Map.get(map, :internal_reason)

  defp field(_map, _key), do: nil

  defp clean_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp clean_string(_value), do: nil
end
