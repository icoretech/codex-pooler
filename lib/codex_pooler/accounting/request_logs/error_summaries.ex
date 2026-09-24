defmodule CodexPooler.Accounting.RequestLogs.ErrorSummaries do
  @moduledoc false

  alias CodexPooler.Accounting

  @pinned_continuation_reauth_operator_action "reauthenticate the pinned upstream account and restart the client without continuation anchors"
  @pinned_continuation_unavailable_operator_action "wait for the pinned upstream to recover, then restart the client without continuation anchors"

  @spec build(map(), map(), [map()]) :: [map()]
  def build(request, metadata, attempts) do
    []
    |> maybe_add_request_error(request)
    |> Kernel.++(metadata_error_summaries(metadata))
    |> Kernel.++(attempt_error_summaries(attempts))
  end

  defp maybe_add_request_error(errors, %{last_error_code: nil}), do: errors

  defp maybe_add_request_error(errors, request) do
    errors ++
      [
        clean_error_summary(%{
          source: "request",
          code: request.last_error_code,
          status: request.status,
          response_status_code: request.response_status_code
        })
      ]
  end

  defp metadata_error_summaries(metadata) when is_map(metadata) do
    []
    |> Kernel.++(metadata_named_error(metadata, "policy_denial"))
    |> Kernel.++(metadata_named_error(metadata, "gateway_denial"))
    |> Kernel.++(metadata_named_error(metadata, "continuity_denial"))
    |> Kernel.++(metadata_named_error(metadata, "retryable_summary"))
    |> Kernel.++(metadata_named_error(metadata, "degraded_summary"))
    |> Kernel.++(candidate_exclusion_error_summaries(metadata))
  end

  defp metadata_error_summaries(_metadata), do: []

  defp metadata_named_error(metadata, key) do
    case Map.get(metadata, key) do
      summary when is_map(summary) -> [metadata_error_from_summary(key, summary)]
      _summary -> []
    end
  end

  defp metadata_error_from_summary("continuity_denial" = key, summary) do
    clean_error_summary(%{
      source: "metadata",
      kind: key,
      code: Map.get(summary, "code") || Map.get(summary, "denial_family"),
      denial_family: Map.get(summary, "denial_family"),
      continuity_family: Map.get(summary, "continuity_family"),
      pin_mode: Map.get(summary, "pin_mode"),
      pin_reason: Map.get(summary, "pin_reason"),
      internal_reason: Map.get(summary, "internal_reason"),
      upstream_lifecycle_family: Map.get(summary, "upstream_lifecycle_family"),
      token_refresh_reason_code_preview: Map.get(summary, "token_refresh_reason_code_preview"),
      pool_upstream_assignment_id: Map.get(summary, "pool_upstream_assignment_id"),
      upstream_identity_id: Map.get(summary, "upstream_identity_id"),
      operator_action: Map.get(summary, "operator_action") || operator_action(summary)
    })
  end

  defp metadata_error_from_summary(key, summary) do
    clean_error_summary(%{
      source: "metadata",
      kind: key,
      code: Map.get(summary, "code") || Map.get(summary, "error_code") || Map.get(summary, "reason"),
      message: Map.get(summary, "message"),
      reset_at: advised_reset_at(Map.get(summary, "resets_at"))
    })
  end

  # The reset a terminal usage-limit refusal advised (findings#206 row
  # 206-553), shown by the drawer's quota line ahead of any exclusion's own
  # window reset.
  defp advised_reset_at(resets_at) when is_integer(resets_at) and resets_at > 0 do
    case DateTime.from_unix(resets_at) do
      {:ok, reset_at} -> DateTime.to_iso8601(reset_at)
      {:error, _reason} -> nil
    end
  end

  defp advised_reset_at(_resets_at), do: nil

  defp candidate_exclusion_error_summaries(%{"candidate_exclusions" => exclusions})
       when is_list(exclusions) do
    exclusions
    |> Enum.flat_map(fn
      %{"reasons" => reasons} when is_list(reasons) -> reasons
      _exclusion -> []
    end)
    |> Enum.flat_map(fn
      reason when is_map(reason) ->
        [
          clean_error_summary(%{
            source: "metadata",
            kind: "candidate_exclusion",
            code: Map.get(reason, "code") || Map.get(reason, "reason"),
            message: Map.get(reason, "message"),
            reason_codes: Map.get(reason, "reason_codes"),
            reset_at: Map.get(reason, "reset_at"),
            route_class: Map.get(reason, "route_class")
          })
        ]

      _reason ->
        []
    end)
  end

  defp candidate_exclusion_error_summaries(_metadata), do: []

  defp attempt_error_summaries(attempts) do
    attempts
    |> Enum.flat_map(fn attempt ->
      metadata = Accounting.sanitize_metadata(attempt.response_metadata || %{})

      code =
        attempt.network_error_code || Map.get(metadata, "error_code") ||
          Map.get(metadata, "error_kind")

      message = attempt_error_message(attempt, metadata)

      if blank?(code) and blank?(message) do
        []
      else
        [
          clean_error_summary(%{
            source: "attempt",
            attempt_number: attempt.attempt_number,
            status: attempt.status,
            retryable: attempt.retryable,
            upstream_status_code: attempt.upstream_status_code,
            code: code,
            message: message
          })
        ]
      end
    end)
  end

  defp attempt_error_message(attempt, metadata) do
    cond do
      not blank?(attempt.error_message) ->
        sanitized_message(attempt.error_message)

      not blank?(Map.get(metadata, "message")) ->
        sanitized_message(Map.get(metadata, "message"))

      true ->
        nil
    end
  end

  defp sanitized_message(message) when is_binary(message) do
    %{"message" => message}
    |> Accounting.sanitize_metadata()
    |> Map.fetch!("message")
  end

  defp sanitized_message(message), do: message

  defp clean_error_summary(summary) do
    summary
    |> Accounting.sanitize_metadata()
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  defp operator_action(%{"denial_family" => "pinned_continuation_unavailable"}),
    do: @pinned_continuation_unavailable_operator_action

  defp operator_action(_summary), do: @pinned_continuation_reauth_operator_action

  defp blank?(value), do: is_nil(value) or String.trim(to_string(value)) == ""
end
