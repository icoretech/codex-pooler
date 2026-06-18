defmodule CodexPooler.Jobs.ReadModel.FailurePresentation do
  @moduledoc false

  @sensitive_projection_keys [:args, :meta, :errors, "args", "meta", "errors"]
  @sensitive_secret_key_pattern "(?:secret(?:[_-][a-z0-9]+)*|[a-z0-9]+(?:[_-][a-z0-9]+)*[_-]secret(?:[_-][a-z0-9]+)*)"
  @sensitive_body_key_pattern "(?:auth[_-]?json|provider[_-]?body|request[_-]?body|response[_-]?body|body)"
  @sensitive_failure_key_pattern "(?:authorization|cookie|set-cookie|api[_-]?key|(?:access|refresh|id|session|api)[_-]?token|[a-z0-9]+(?:[_-][a-z0-9]+)*[_-]token|#{@sensitive_body_key_pattern}|password|prompt|#{@sensitive_secret_key_pattern}|token)"
  @sensitive_spaced_secret_key_pattern "(?:password|#{@sensitive_secret_key_pattern})"
  @sensitive_quoted_string_body_failure_fragment ~r/(?i)(?:"?\b#{@sensitive_body_key_pattern}\b"?\s*[:=]\s*)"(?:\\.|[^"\\])*"/
  @sensitive_jsonish_failure_fragment ~r/(?i)(?:"?\b#{@sensitive_failure_key_pattern}\b"?\s*[:=]\s*)(?:\{(?:[^{}]|\{[^{}]*\})*\}|\[(?:[^\[\]]|\[[^\[\]]*\])*\]|"[^"]*"|'[^']*')/
  @sensitive_body_failure_fragment ~r/(?i)(?:"?\b#{@sensitive_body_key_pattern}\b"?\s*[:=]\s*).*?(?=\s+"?\b#{@sensitive_failure_key_pattern}\b"?\s*[:=]|\z)/
  @sensitive_spaced_secret_failure_fragment ~r/(?i)(?:"?\b#{@sensitive_spaced_secret_key_pattern}\b"?\s*[:=]\s*).*?(?=[,;]|\.\s+|\s+"?\b#{@sensitive_failure_key_pattern}\b"?\s*[:=]|\z)/
  @sensitive_text_failure_fragment ~r/(?i)(?:"?\b#{@sensitive_failure_key_pattern}\b"?\s*[:=]\s*)[^,;\s]+/

  @type failure_summary :: %{
          required(:title) => String.t(),
          required(:message) => String.t()
        }

  @spec sanitize_jobs([term()]) :: [term()]
  def sanitize_jobs(jobs) when is_list(jobs), do: sanitize_projection(jobs)

  @spec sanitize_job(map()) :: map()
  def sanitize_job(job) when is_map(job), do: sanitize_projection(job)

  @spec sanitize_projection(term()) :: term()
  def sanitize_projection(value) when is_list(value), do: Enum.map(value, &sanitize_projection/1)

  def sanitize_projection(%DateTime{} = value), do: value
  def sanitize_projection(%NaiveDateTime{} = value), do: value
  def sanitize_projection(%Date{} = value), do: value

  def sanitize_projection(%{trigger_kind: trigger_kind} = value) when trigger_kind in [nil, ""] do
    value
    |> Map.delete(:trigger_kind)
    |> sanitize_projection()
  end

  def sanitize_projection(%{errors: errors} = value) when is_list(errors) do
    value
    |> Map.drop(@sensitive_projection_keys)
    |> maybe_put_failure_summary(latest_error_by_attempt(errors))
    |> Map.new(fn {key, nested_value} -> {key, sanitize_projection(nested_value)} end)
  end

  def sanitize_projection(value) when is_map(value) do
    value
    |> Map.drop(@sensitive_projection_keys)
    |> Map.new(fn {key, nested_value} -> {key, sanitize_projection(nested_value)} end)
  end

  def sanitize_projection(value), do: value

  defp maybe_put_failure_summary(job, latest_error) when is_map(latest_error),
    do: Map.put(job, :failure_summary, failure_summary(latest_error))

  defp maybe_put_failure_summary(job, _latest_error), do: job

  defp failure_summary(error) do
    %{
      title: failure_title(error),
      message: error |> Map.get("error") |> safe_failure_message()
    }
  end

  defp latest_error_by_attempt(errors) do
    errors
    |> Enum.filter(&is_map/1)
    |> Enum.max_by(&error_attempt_number/1, fn -> nil end)
  end

  defp error_attempt_number(%{"attempt" => attempt}) when is_integer(attempt), do: attempt

  defp error_attempt_number(%{"attempt" => attempt}) when is_binary(attempt) do
    case Integer.parse(attempt) do
      {attempt, ""} -> attempt
      _not_integer -> -1
    end
  end

  defp error_attempt_number(_error), do: -1

  defp failure_title(%{"error" => message} = error) when is_binary(message) do
    [failure_attempt(error), operator_failure_title(message) || failure_kind(error)]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "Failure detail"
      parts -> Enum.join(parts, " · ")
    end
  end

  defp failure_title(error) do
    [failure_attempt(error), failure_kind(error)]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "Failure detail"
      parts -> Enum.join(parts, " · ")
    end
  end

  defp failure_attempt(%{"attempt" => attempt}) when is_integer(attempt), do: "Attempt #{attempt}"
  defp failure_attempt(%{"attempt" => attempt}) when is_binary(attempt), do: "Attempt #{attempt}"
  defp failure_attempt(_error), do: nil

  defp failure_kind(%{"kind" => kind}) when is_binary(kind) and kind != "", do: kind
  defp failure_kind(_error), do: nil

  defp safe_failure_message(message) when is_binary(message) do
    message
    |> String.replace(~r/[\r\n\t]+/, " ")
    |> redact_failure_secrets()
    |> unwrap_oban_failure_message()
    |> operator_failure_message()
    |> String.trim()
    |> truncate_failure_message()
    |> case do
      "" -> "No diagnostic message recorded."
      message -> message
    end
  end

  defp safe_failure_message(_message), do: "No diagnostic message recorded."

  defp redact_failure_secrets(message) do
    message
    |> String.replace(~r/(?i)bearer\s+[a-z0-9._~+\/=:-]+/, "Bearer [redacted]")
    |> String.replace(@sensitive_quoted_string_body_failure_fragment, "[redacted]")
    |> String.replace(@sensitive_jsonish_failure_fragment, "[redacted]")
    |> String.replace(@sensitive_body_failure_fragment, "[redacted]")
    |> String.replace(@sensitive_spaced_secret_failure_fragment, "[redacted]")
    |> String.replace(@sensitive_text_failure_fragment, "[redacted]")
    |> String.replace(~r/(?i)\bsecret[-_a-z0-9]*\b/, "[redacted]")
  end

  defp unwrap_oban_failure_message(message) do
    cond do
      match = Regex.run(~r/failed with \{:error, "([^"]+)"\}/, message) ->
        [_full, inner] = match
        inner

      match = Regex.run(~r/failed with \{:error, %\{[^}]*message: "([^"]+)"/, message) ->
        [_full, inner] = match
        inner

      oban_discard_failure?(message) ->
        "The job stopped without additional diagnostics."

      true ->
        message
    end
  end

  defp operator_failure_title(message) do
    code = message |> unwrap_oban_failure_message() |> reconciliation_failure_code()
    code = code || oban_map_failure_code(message)

    cond do
      oban_discard_failure?(message) ->
        "Run discarded"

      catalog_sync_invalid_trigger_kind?(message) ->
        "Invalid catalog sync trigger"

      catalog_sync_in_progress?(message) ->
        "Catalog sync already running"

      title = quota_failure_title(code) ->
        title

      is_binary(code) ->
        humanize_failure_code(code)

      true ->
        nil
    end
  end

  defp quota_failure_title("quota_refresh_auth_unavailable"), do: "Quota refresh blocked"
  defp quota_failure_title("quota_refresh_unavailable"), do: "Quota unavailable"
  defp quota_failure_title("quota_refresh_failed"), do: "Quota refresh failed"
  defp quota_failure_title(_code), do: nil

  defp operator_failure_message(message) do
    cond do
      catalog_sync_invalid_trigger_kind?(message) ->
        "Manual catalog sync could not start because the enqueue action used an unsupported trigger kind."

      catalog_sync_in_progress?(message) ->
        "Catalog sync could not start because this pool already has a sync run marked as running."

      true ->
        case reconciliation_failure_code(message) do
          "quota_refresh_auth_unavailable" ->
            "Quota refresh needs account reauthentication."

          "quota_refresh_unavailable" ->
            "Quota data was not available from the upstream account."

          "quota_refresh_failed" ->
            "Quota refresh failed for the upstream account."

          code when is_binary(code) ->
            "Account reconciliation needs attention: #{humanize_failure_code(code)}."

          nil ->
            message
        end
    end
  end

  defp reconciliation_failure_code("account reconciliation partial: " <> code),
    do: String.trim(code)

  defp reconciliation_failure_code(_message), do: nil

  defp oban_map_failure_code(message) do
    case Regex.run(~r/failed with \{:error, %\{[^}]*code: :([a-z0-9_]+)/, message) do
      [_full, code] -> code
      _no_match -> nil
    end
  end

  defp oban_discard_failure?(message), do: Regex.match?(~r/failed with :discard\b/, message)

  defp catalog_sync_invalid_trigger_kind?(message) do
    String.contains?(message, "CodexPooler.Jobs.CatalogSyncWorker") and
      String.contains?(message, "trigger_kind:") and
      String.contains?(message, "is invalid")
  end

  defp catalog_sync_in_progress?(message) do
    String.contains?(message, "catalog sync already running") or
      String.contains?(message, "code: :catalog_sync_in_progress")
  end

  defp humanize_failure_code(code) do
    code
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp truncate_failure_message(message) when byte_size(message) > 240,
    do: message |> binary_part(0, 240) |> String.trim() |> Kernel.<>("…")

  defp truncate_failure_message(message), do: message
end
