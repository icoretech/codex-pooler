defmodule CodexPoolerWeb.Admin.JobsPresentation do
  @moduledoc """
  Presentation read model for the admin jobs dashboard.
  """

  alias CodexPooler.Jobs.Schedule
  alias CodexPoolerWeb.Admin.AvatarComponents
  alias CodexPoolerWeb.Admin.JobsPresentation.{State, Targets}
  alias CodexPoolerWeb.DateTimeDisplay
  alias Oban.Cron.Expression

  @spec worker_cards(map(), DateTimeDisplay.preferences(), DateTime.t()) :: [map()]
  def worker_cards(jobs_by_group, datetime_preferences, now \\ DateTime.utc_now()) do
    Enum.map(worker_groups(), fn group ->
      worker_card(
        group,
        Map.get(jobs_by_group, group.key, empty_worker_summary()),
        datetime_preferences,
        now
      )
    end)
  end

  @spec format_attempts(map()) :: String.t()
  def format_attempts(%{attempt: attempt, max_attempts: max_attempts}) do
    "#{attempt || 0}/#{max_attempts || "-"}"
  end

  @spec job_failure_summary(map()) :: map() | nil
  def job_failure_summary(%{failure_summary: %{title: title, message: message}})
      when is_binary(title) and is_binary(message) do
    %{title: title, message: message}
  end

  def job_failure_summary(%{errors: [latest_error | _errors]}) when is_map(latest_error) do
    %{
      title: failure_title(latest_error),
      message: latest_error |> Map.get("error") |> safe_failure_message()
    }
  end

  def job_failure_summary(_job), do: nil

  @spec job_target(map()) :: map() | nil
  defdelegate job_target(job), to: Targets

  @spec format_job_timestamp(DateTime.t() | nil, DateTimeDisplay.preferences()) :: String.t()
  def format_job_timestamp(nil, _datetime_preferences), do: "No observed run"

  def format_job_timestamp(%DateTime{} = datetime, datetime_preferences) do
    DateTimeDisplay.format_datetime(datetime, datetime_preferences,
      missing_label: "No observed run"
    )
  end

  @spec timestamp_line(String.t(), DateTime.t() | nil, DateTimeDisplay.preferences()) ::
          String.t()
  def timestamp_line(label, nil, _datetime_preferences), do: "#{label} -"

  def timestamp_line(label, %DateTime{} = datetime, datetime_preferences) do
    "#{label} #{format_job_timestamp(datetime, datetime_preferences)}"
  end

  @spec job_state_icon(String.t() | nil) :: String.t()
  defdelegate job_state_icon(state), to: State, as: :icon

  @spec job_state_icon_class(String.t() | nil) :: String.t()
  defdelegate job_state_icon_class(state), to: State, as: :icon_class

  @spec job_state_badge_class(String.t() | nil) :: String.t()
  defdelegate job_state_badge_class(state), to: State, as: :badge_class

  @spec job_state_label(String.t() | nil) :: String.t()
  defdelegate job_state_label(state), to: State, as: :label

  defp worker_groups, do: Schedule.worker_groups()

  defp worker_card(group, summary, datetime_preferences, now) do
    latest_job = summary.latest
    success_job = summary.latest_success
    failure_job = summary.latest_failure
    state = worker_card_state(group, summary, latest_job)
    next_run = next_run_summary(group, summary.pending, datetime_preferences, now)

    %{
      id: group.id,
      key: group.key,
      title: group.title,
      description: group.description,
      icon: group.icon,
      workers: group.workers,
      worker_labels: Enum.map(group.workers, &worker_label/1),
      state: state,
      state_label: job_state_label(state),
      live_state: live_job_state?(state),
      next_run: next_run.label,
      next_run_title: next_run.title,
      cadence_label: next_run.cadence_label,
      attempts: if(latest_job, do: format_attempts(latest_job), else: "0/-"),
      active_markers: activity_markers(summary.active),
      failure_markers: failure_markers(summary.unresolved_failures),
      activity_label: activity_label(summary.active, summary.unresolved_failures),
      last_seen_at: job_event_timestamp(latest_job),
      last_success_at: job_event_timestamp(success_job),
      last_failure_at: job_event_timestamp(failure_job)
    }
  end

  defp worker_label(worker) do
    worker
    |> String.replace_prefix("CodexPooler.Jobs.", "")
    |> String.replace_suffix("Worker", "")
  end

  defp worker_card_state(_group, %{active: [_active | _rest]}, _latest_job), do: "executing"
  defp worker_card_state(_group, %{pending: %{state: state}}, _latest_job), do: state
  defp worker_card_state(_group, _summary, %{state: state}), do: state
  defp worker_card_state(group, _summary, _latest_job), do: empty_worker_state(group)

  defp activity_label(active, failures) when active != [] and failures != [],
    do: "Live targets and failures"

  defp activity_label(active, _failures) when active != [], do: "Live targets"
  defp activity_label(_active, failures) when failures != [], do: "Needs attention"
  defp activity_label(_active, _failures), do: nil

  defp empty_worker_state(%{cadence: %{cron: cron}}) when is_binary(cron),
    do: "awaiting_first_run"

  defp empty_worker_state(_group), do: "idle"

  defp next_run_summary(group, pending_job, datetime_preferences, now) do
    cadence = group.cadence

    cond do
      pending_job ->
        pending_job_next_run(pending_job, cadence, datetime_preferences, now)

      is_binary(cadence.cron) ->
        cron_next_run(cadence, datetime_preferences, now)

      true ->
        %{
          label: "On demand",
          title: cadence.label,
          cadence_label: cadence.label
        }
    end
  end

  defp pending_job_next_run(%{state: "executing"} = job, cadence, datetime_preferences, _now) do
    %{
      label: "Running now",
      title:
        timestamp_title(
          job.attempted_at || job.scheduled_at || job.inserted_at,
          datetime_preferences
        ),
      cadence_label: cadence.label
    }
  end

  defp pending_job_next_run(%{state: "available"} = job, cadence, datetime_preferences, _now) do
    %{
      label: "Queued now",
      title: timestamp_title(job.scheduled_at || job.inserted_at, datetime_preferences),
      cadence_label: cadence.label
    }
  end

  defp pending_job_next_run(%{state: "retryable"} = job, cadence, datetime_preferences, now) do
    label = if job.scheduled_at, do: relative_time(job.scheduled_at, now), else: "Retry pending"

    %{
      label: label,
      title:
        timestamp_title(
          job.scheduled_at || job.attempted_at || job.inserted_at,
          datetime_preferences
        ),
      cadence_label: cadence.label
    }
  end

  defp pending_job_next_run(job, cadence, datetime_preferences, now) do
    %{
      label: relative_time(job.scheduled_at || job.inserted_at, now),
      title: timestamp_title(job.scheduled_at || job.inserted_at, datetime_preferences),
      cadence_label: cadence.label
    }
  end

  defp cron_next_run(%{cron: cron, label: cadence_label}, datetime_preferences, now) do
    case cron |> Expression.parse!() |> Expression.next_at(now) do
      %DateTime{} = next_at ->
        %{
          label: relative_time(next_at, now),
          title: timestamp_title(next_at, datetime_preferences),
          cadence_label: cadence_label
        }

      :unknown ->
        %{label: cadence_label, title: cadence_label, cadence_label: cadence_label}
    end
  end

  defp empty_worker_summary do
    %{
      latest: nil,
      latest_success: nil,
      latest_failure: nil,
      pending: nil,
      active: [],
      unresolved_failures: []
    }
  end

  defp activity_markers(jobs) do
    Enum.map(jobs, fn job ->
      target = job_target(job)

      %{
        id: job.id,
        worker_label: worker_label(job.worker || "not recorded"),
        target_label: marker_target_label(target),
        title: marker_title(job, target),
        avatar_url: marker_avatar_url(target),
        glyph: marker_glyph(target)
      }
    end)
  end

  defp failure_markers(jobs) do
    jobs
    |> Enum.map(fn job ->
      target = job_target(job)

      %{
        id: job.id,
        worker_label: worker_label(job.worker || "not recorded"),
        target_label: marker_target_label(target),
        title: marker_title(job, target),
        avatar_url: marker_avatar_url(target),
        glyph: marker_glyph(target),
        failure: job_failure_summary(job),
        failed_at: job_event_timestamp(job),
        attempts: format_attempts(job)
      }
    end)
    |> Enum.reject(&is_nil(&1.failure))
  end

  defp marker_target_label(%{primary: primary}) when is_binary(primary), do: primary
  defp marker_target_label(_target), do: "System job"

  defp marker_glyph(%{primary: primary}) when is_binary(primary) do
    primary
    |> String.replace(~r/^[^:]+:\s*/, "")
    |> marker_glyph_from_label()
  end

  defp marker_glyph(_target), do: "S"

  defp marker_avatar_url(%{primary: primary}) do
    if email = AvatarComponents.email_identity(primary) do
      AvatarComponents.gravatar_url(email, size: 64)
    end
  end

  defp marker_avatar_url(_target), do: nil

  defp marker_glyph_from_label(label) do
    label = String.trim(label)

    cond do
      label == "" ->
        "?"

      String.contains?(label, "@") ->
        label
        |> String.split("@", parts: 2)
        |> List.first()
        |> compact_marker_glyph()

      true ->
        words =
          ~r/[A-Za-z0-9]+/
          |> Regex.scan(label)
          |> List.flatten()

        case words do
          [one] ->
            compact_marker_glyph(one)

          [first, second | _rest] ->
            glyph = (String.first(first) || "") <> (String.first(second) || "")
            String.upcase(glyph)

          [] ->
            "?"
        end
    end
  end

  defp compact_marker_glyph(token) do
    token = String.upcase(String.trim(token))
    digits = Regex.scan(~r/\d+/, token) |> List.flatten()

    cond do
      token == "" ->
        "?"

      digits != [] ->
        "#{String.first(token)}#{digits |> List.last() |> String.last()}"

      String.length(token) >= 2 ->
        String.slice(token, 0, 2)

      true ->
        token
    end
  end

  defp marker_title(job, target) do
    [
      job_state_label(job.state),
      worker_label(job.worker || "not recorded"),
      if(target, do: target.primary_title || target.primary)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
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
    |> String.replace(~r/(?i)\bsecret[-_a-z0-9]*\b/, "[redacted]")
    |> String.replace(
      ~r/(?i)\b(authorization|cookie|set-cookie|api[_-]?key|access[_-]?token|refresh[_-]?token|password|prompt|secret|token)\b\s*[:=]\s*[^,;\s]+/,
      "[redacted]"
    )
  end

  defp truncate_failure_message(message) when byte_size(message) > 240,
    do: message |> binary_part(0, 240) |> String.trim() |> Kernel.<>("…")

  defp truncate_failure_message(message), do: message

  defp timestamp_title(nil, _datetime_preferences), do: nil

  defp timestamp_title(%DateTime{} = datetime, datetime_preferences),
    do: format_job_timestamp(datetime, datetime_preferences)

  defp relative_time(nil, _now), do: "Unknown"

  defp relative_time(%DateTime{} = datetime, %DateTime{} = now) do
    diff_seconds = DateTime.diff(datetime, now, :second)

    cond do
      diff_seconds <= 0 ->
        "Due now"

      diff_seconds < 60 ->
        "in <1m"

      diff_seconds < 3_600 ->
        "in #{ceil(diff_seconds / 60)}m"

      diff_seconds < 86_400 ->
        "in #{ceil(diff_seconds / 3_600)}h"

      true ->
        "in #{ceil(diff_seconds / 86_400)}d"
    end
  end

  defp job_event_timestamp(nil), do: nil

  defp job_event_timestamp(job) do
    job.completed_at ||
      job.discarded_at ||
      job.cancelled_at ||
      job.attempted_at ||
      job.scheduled_at ||
      job.inserted_at
  end

  defp live_job_state?(state), do: state in ["available", "scheduled", "executing", "retryable"]
end
