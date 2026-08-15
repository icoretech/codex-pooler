defmodule CodexPooler.Gateway.OpenAICompatibility.PublicResponse do
  @moduledoc false

  alias CodexPooler.Gateway.Transports.MisalignmentPolicyViolation

  @type success_normalizer :: (map() -> map())
  @type error_status :: integer() | String.t() | nil
  @type error_origin :: :local_validation
  @type error_opts :: [status: error_status(), origin: error_origin()]

  @public_recovery_error_tokens ~w(pinned_continuation_reauth_required pinned_continuation_unavailable)
  @server_error_tokens ~w(internal_error server_error upstream_error server_is_overloaded)
  @overload_code "server_is_overloaded"
  @overload_message "gateway route class is temporarily overloaded"
  @bulkhead_reasons ~w(bulkhead_rejected bulkhead_queue_timeout)

  @spec stream_headers([{term(), term()}]) :: [{String.t(), String.t()} | {term(), term()}]
  def stream_headers(headers) do
    headers
    |> Enum.reject(fn {key, _value} -> String.downcase(to_string(key)) == "content-type" end)
    |> Kernel.++([{"content-type", "text/event-stream"}])
  end

  @spec normalize_raw_body(pos_integer(), term(), success_normalizer()) ::
          {:ok, map()} | :passthrough
  def normalize_raw_body(status, body, normalize_success) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) and status < 400 ->
        {:ok, normalize_success.(decoded)}

      {:ok, %{"error" => %{} = error}} when status >= 400 ->
        {:ok, %{"error" => normalize_error(error, status: status)}}

      {:ok, decoded} when is_map(decoded) and status >= 400 ->
        {:ok, normalize_error_body(status)}

      _error ->
        if status >= 400, do: {:ok, normalize_error_body(status)}, else: :passthrough
    end
  end

  def normalize_raw_body(status, _body, _normalize_success) do
    if status >= 400, do: {:ok, normalize_error_body(status)}, else: :passthrough
  end

  @spec normalize_error(term(), error_opts()) :: map()
  def normalize_error(error, opts \\ [])

  def normalize_error(%{} = error, opts) do
    status = error_status(error, opts)

    cond do
      misalignment_policy_violation?(error) -> misalignment_policy_violation_error(error)
      overload_error?(error) -> overload_error()
      local_validation_error?(error, status, opts) -> explicit_error(error, status)
      true -> redacted_error(error)
    end
  end

  def normalize_error(_error, opts), do: normalize_error(%{}, opts)

  @spec terminal_error_status(term(), error_opts()) :: 400 | 502
  def terminal_error_status(error, opts \\ []) do
    status = error_status(error, opts)

    if local_validation_error?(error, status, opts), do: 400, else: 502
  end

  @spec redacted_gateway_error?(term()) :: boolean()
  def redacted_gateway_error?(%{public_compaction_error?: true}), do: false

  def redacted_gateway_error?(%{} = error) do
    not public_recovery_error_token?(field(error, "code")) and
      public_failure_error?(error, error_status(error, []))
  end

  def redacted_gateway_error?(_error), do: false

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

  defp redacted_error(error) do
    %{
      "message" => "upstream request failed",
      "type" => "server_error",
      "code" => safe_error_code(error) || "upstream_error"
    }
  end

  defp overload_error do
    %{
      "message" => @overload_message,
      "type" => "server_error",
      "code" => @overload_code,
      "param" => nil
    }
  end

  defp normalize_error_body(status) do
    %{
      "error" => status_error(status)
    }
  end

  defp status_error(status) when status in 500..599, do: normalize_error(%{}, status: status)

  defp status_error(status) do
    error = %{"message" => "upstream returned #{status}", "code" => "upstream_status"}
    normalize_error(error, status: status)
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
