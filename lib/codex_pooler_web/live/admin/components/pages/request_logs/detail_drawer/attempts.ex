defmodule CodexPoolerWeb.Admin.RequestLogDetailDrawer.Attempts do
  @moduledoc false

  use Gettext, backend: CodexPoolerWeb.Gettext

  import CodexPoolerWeb.Admin.RequestLogsDisplay, only: [format_route_latency: 1]

  alias CodexPoolerWeb.Admin.RequestLogDetailDrawer.Rows

  @type detail_row :: %{
          id: String.t(),
          label: String.t(),
          value: term(),
          mono: boolean()
        }

  @spec attempt_rows(map()) :: [detail_row()]
  def attempt_rows(attempt) do
    rows = [
      detail(
        "request-log-detail-attempt-#{attempt.attempt_number}-ref",
        gettext("Attempt ref"),
        attempt.attempt_ref,
        mono: true
      ),
      detail(
        "request-log-detail-attempt-#{attempt.attempt_number}-assignment",
        gettext("Assignment id"),
        attempt.pool_upstream_assignment_id,
        mono: true
      ),
      detail(
        "request-log-detail-attempt-#{attempt.attempt_number}-status-code",
        gettext("Upstream status"),
        attempt.upstream_status_code
      ),
      detail(
        "request-log-detail-attempt-#{attempt.attempt_number}-network-error",
        gettext("Network error"),
        attempt.network_error_code,
        mono: true
      ),
      detail(
        "request-log-detail-attempt-#{attempt.attempt_number}-upstream-error-code",
        gettext("Provider terminal code"),
        Map.get(attempt, :upstream_error_code),
        mono: true
      ),
      detail(
        "request-log-detail-attempt-#{attempt.attempt_number}-stream-terminal-type",
        gettext("Terminal event"),
        Map.get(attempt, :stream_terminal_type),
        mono: true
      ),
      detail(
        "request-log-detail-attempt-#{attempt.attempt_number}-compaction-invalid-reason",
        gettext("Compaction rejection reason"),
        Map.get(attempt, :compaction_invalid_reason),
        mono: true
      ),
      detail(
        "request-log-detail-attempt-#{attempt.attempt_number}-upstream-error-param",
        gettext("Upstream error parameter"),
        Map.get(attempt, :upstream_error_param),
        mono: true
      ),
      detail(
        "request-log-detail-attempt-#{attempt.attempt_number}-rejection-error-code",
        gettext("Provider rejection code"),
        Map.get(attempt, :rejection_error_code),
        mono: true
      ),
      detail(
        "request-log-detail-attempt-#{attempt.attempt_number}-rejection-error-type",
        gettext("Provider rejection type"),
        Map.get(attempt, :rejection_error_type),
        mono: true
      ),
      detail(
        "request-log-detail-attempt-#{attempt.attempt_number}-rejection-error-param",
        gettext("Provider rejection parameter"),
        Map.get(attempt, :rejection_error_param),
        mono: true
      ),
      detail(
        "request-log-detail-attempt-#{attempt.attempt_number}-latency",
        gettext("Latency"),
        format_route_latency(attempt.latency_ms),
        mono: true
      ),
      detail(
        "request-log-detail-attempt-#{attempt.attempt_number}-retryable",
        gettext("Retryable"),
        attempt.retryable
      ),
      detail("request-log-detail-attempt-#{attempt.attempt_number}-final", gettext("Final"), attempt.final)
    ]

    mode_rows =
      Rows.serving_mode_rows(
        "request-log-detail-attempt-#{attempt.attempt_number}",
        Map.get(attempt, :model_serving_mode)
      )

    present_rows(rows ++ model_rows(attempt) ++ mode_rows ++ websocket_connection_rows(attempt) ++ downstream_delivery_rows(attempt))
  end

  defp model_rows(attempt) do
    observation = Map.get(attempt, :model_observation)
    prefix = "request-log-detail-attempt-#{attempt.attempt_number}-model"

    [
      detail("#{prefix}-sent", gettext("Sent model"), Map.get(attempt, :upstream_model)),
      detail("#{prefix}-first", gettext("First model reported"), Map.get(attempt, :served_model) || gettext("Unavailable")),
      detail("#{prefix}-coverage", gettext("Model-name recording"), if(observation, do: gettext("%{coverage} · collector v%{version}", coverage: observation["coverage"], version: observation["version"]), else: gettext("Not collected"))),
      detail("#{prefix}-conflict", gettext("Model name changed within response"), conflict_label(observation)),
      detail("#{prefix}-first-conflict", gettext("First different name reported"), observation && observation["first_conflicting_model"]),
      detail("#{prefix}-terminal", gettext("Model reported at end"), (observation && observation["terminal_model"]) || gettext("No final model reported")),
      detail("#{prefix}-terminal-status", gettext("Final response event"), (observation && observation["terminal_status"]) || if(observation, do: gettext("No final event recorded"), else: gettext("Not collected")))
    ]
  end

  defp conflict_label(%{"conflict" => true}), do: gettext("Yes — provider reported different names in one response")
  defp conflict_label(%{"conflict" => false}), do: gettext("No name change observed")
  defp conflict_label(_observation), do: gettext("Unknown")

  @spec transport_failure_rows(map()) :: [detail_row()]
  def transport_failure_rows(attempt) do
    failure = attempt.transport_failure
    prefix = "request-log-detail-transport-#{attempt.attempt_number}"

    [
      detail("#{prefix}-evidence-source", gettext("Evidence source"), Map.get(failure, :evidence_source)),
      detail("#{prefix}-termination-source", gettext("Termination source"), Map.get(failure, :termination_source), mono: true),
      detail("#{prefix}-exception", gettext("Exception"), Map.get(failure, :exception), mono: true),
      detail("#{prefix}-reason-class", gettext("Reason class"), Map.get(failure, :reason_class), mono: true),
      detail("#{prefix}-reason", gettext("Reason"), Map.get(failure, :reason), mono: true),
      detail("#{prefix}-phase", gettext("Phase"), Map.get(failure, :phase), mono: true),
      detail(
        "#{prefix}-pre-visible-output",
        gettext("Pre-visible output"),
        Map.get(failure, :pre_visible_output)
      ),
      detail("#{prefix}-terminal-seen", gettext("Terminal seen"), Map.get(failure, :terminal_seen)),
      detail(
        "#{prefix}-text-frame-count",
        gettext("Text frame count"),
        Map.get(failure, :text_frame_count)
      )
    ]
    |> present_rows()
  end

  @spec debug_attempts(map()) :: [map()]
  def debug_attempts(%{debug: %{attempts: attempts}}) when is_list(attempts), do: attempts
  def debug_attempts(_log), do: []

  @spec transport_failure_attempts(map()) :: [map()]
  def transport_failure_attempts(log) do
    log
    |> debug_attempts()
    |> Enum.filter(&(is_map(Map.get(&1, :transport_failure)) and map_size(&1.transport_failure) > 0))
  end

  defp websocket_connection_rows(%{attempt_number: attempt_number} = attempt) do
    case Map.get(attempt, :upstream_websocket_connection) do
      %{
        lifecycle_id: lifecycle_id,
        generation: generation,
        reused: reused,
        reconnected: reconnected
      }
      when is_binary(lifecycle_id) and is_integer(generation) and generation > 0 and
             is_boolean(reused) and is_boolean(reconnected) ->
        prefix = "request-log-detail-attempt-#{attempt_number}"

        [
          detail("#{prefix}-lifecycle-id", gettext("Lifecycle ID"), lifecycle_id, mono: true),
          detail("#{prefix}-generation", gettext("Generation"), generation, mono: true),
          detail("#{prefix}-reused", gettext("Reused"), reused),
          detail("#{prefix}-reconnected", gettext("Reconnected"), reconnected)
        ]

      _invalid ->
        []
    end
  end

  # One compact line per attempt built only from the admin projection's fixed
  # vocabulary (`DebugProjection.DownstreamDelivery`); absent receipts render
  # nothing. The highest frame class a websocket pushed (findings#232 row
  # 232-203) follows the frame count, then how many items it pushed completed
  # (row 232-241, the count only, never their digests) and the class of the
  # connection's failed write that kept the receipt from `delivered` (row
  # 232-256); a receipt without them (HTTP SSE, older rows) renders the line
  # without them.
  defp downstream_delivery_rows(%{attempt_number: attempt_number} = attempt) do
    case Map.get(attempt, :downstream_delivery) do
      %{
        outcome: outcome,
        terminal_class: terminal_class,
        pushed_at: pushed_at,
        frames_after_visible: frames,
        transport: transport
      } = receipt
      when is_binary(outcome) and is_binary(terminal_class) and is_integer(frames) and
             frames >= 0 and is_binary(transport) and (is_binary(pushed_at) or is_nil(pushed_at)) ->
        [
          detail(
            "request-log-detail-attempt-#{attempt_number}-downstream-delivery",
            gettext("Downstream delivery"),
            downstream_delivery_line(outcome, terminal_class, frames, receipt, pushed_at, transport),
            mono: true
          )
        ]

      _invalid ->
        []
    end
  end

  defp highest_frame_class(%{highest_frame_class: class}) when is_binary(class), do: gettext("highest frame %{class}", class: class)
  defp highest_frame_class(_receipt), do: nil

  defp completed_items(%{completed_items: count}) when is_integer(count) and count >= 0,
    do: ngettext("%{count} completed item", "%{count} completed items", count, count: count)

  defp completed_items(_receipt), do: nil

  defp write_failure(%{write_failure: failure}) when is_binary(failure), do: gettext("write failed %{failure}", failure: failure)
  defp write_failure(_receipt), do: nil

  defp downstream_delivery_line(outcome, terminal_class, frames, receipt, pushed_at, transport) do
    [
      outcome,
      gettext("terminal %{class}", class: terminal_class),
      ngettext("%{count} frame after visible", "%{count} frames after visible", frames, count: frames),
      highest_frame_class(receipt),
      completed_items(receipt),
      write_failure(receipt),
      pushed_at && gettext("pushed %{time}", time: pushed_at),
      transport
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" \u00b7 ")
  end

  defp detail(id, label, value, opts \\ []) do
    %{id: id, label: label, value: value, mono: Keyword.get(opts, :mono, false)}
  end

  defp present_rows(rows), do: Enum.reject(rows, &(blank?(&1.value) or &1.value == "-"))

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false
end
