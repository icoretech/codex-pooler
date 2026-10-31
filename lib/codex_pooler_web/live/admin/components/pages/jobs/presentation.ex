defmodule CodexPoolerWeb.Admin.JobsPresentation do
  @moduledoc """
  Presentation read model for the admin jobs dashboard.
  """

  use Gettext, backend: CodexPoolerWeb.Gettext

  alias CodexPooler.Jobs
  alias CodexPooler.Jobs.Schedule
  alias CodexPoolerWeb.Admin.AvatarComponents
  alias CodexPoolerWeb.Admin.BadgeComponents
  alias CodexPoolerWeb.Admin.JobsPresentation.{State, Targets}
  alias CodexPoolerWeb.DateTimeDisplay
  alias CodexPoolerWeb.RelativeTime
  alias Oban.Cron.Expression

  @visible_open_marker_limit 8
  @visible_failure_marker_limit 3

  defp worker_groups do
    Schedule.worker_groups()
    |> Enum.map(&translate_worker_group/1)
  end

  defp translate_worker_group(%{key: :catalog_sync} = group),
    do:
      translated_worker_group(
        group,
        gettext("Catalog sync"),
        gettext("Model catalog refresh"),
        gettext("Every 30 min")
      )

  defp translate_worker_group(%{key: :pricing_import} = group),
    do: translated_worker_group(group, gettext("Pricing import"), gettext("Pricing data refresh"), gettext("Hourly"))

  defp translate_worker_group(%{key: :account_reconciliation} = group),
    do:
      translated_worker_group(
        group,
        gettext("Account reconciliation"),
        gettext("Upstream account checks"),
        gettext("Every minute")
      )

  defp translate_worker_group(%{key: :alert_evaluation} = group),
    do: translated_worker_group(group, gettext("Alert evaluation"), gettext("Alert rule checks"), gettext("Every 5 min"))

  defp translate_worker_group(%{key: :token_refresh} = group),
    do: translated_worker_group(group, gettext("Token refresh"), gettext("Access-token renewal"), gettext("Every 15 min"))

  defp translate_worker_group(%{key: :daily_rollup_rebuild} = group),
    do:
      translated_worker_group(
        group,
        gettext("Daily rollup rebuild"),
        gettext("Usage rollup rebuild"),
        gettext("Hourly at :17")
      )

  defp translate_worker_group(%{key: :runtime_cleanup} = group),
    do: translated_worker_group(group, gettext("Runtime cleanup"), gettext("Expired state cleanup"), gettext("Every 15 min"))

  defp translate_worker_group(%{key: :request_replay_cleanup} = group),
    do: translated_worker_group(group, gettext("Request replay cleanup"), gettext("Expired replay cleanup"), gettext("Every minute"))

  defp translate_worker_group(%{key: :openai_status_sync} = group),
    do:
      translated_worker_group(
        group,
        gettext("OpenAI status polling"),
        gettext("OpenAI incident feed refresh"),
        gettext("Every 5 min")
      )

  defp translate_worker_group(%{key: :openai_status_cleanup} = group),
    do:
      translated_worker_group(
        group,
        gettext("OpenAI status retention"),
        gettext("Retired incident cleanup"),
        gettext("Daily at 00:00 UTC")
      )

  defp translate_worker_group(group), do: group

  defp translated_worker_group(group, title, description, cadence_label) do
    %{group | title: title, description: description, cadence: %{group.cadence | label: cadence_label}}
  end

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
    %{title: translate_failure_title(title), message: translate_failure_message(message)}
  end

  def job_failure_summary(%{errors: errors}) when is_list(errors) do
    if latest_error = latest_error_by_attempt(errors) do
      failure_summary_from_error(latest_error)
    end
  end

  def job_failure_summary(_job), do: nil

  defp failure_summary_from_error(error) do
    %{
      title: translate_failure_title(failure_title(error)),
      message: error |> Map.get("error") |> safe_failure_message() |> translate_failure_message()
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

  @spec job_target(map()) :: map() | nil
  defdelegate job_target(job), to: Targets

  @spec format_job_timestamp(DateTime.t() | nil, DateTimeDisplay.preferences()) :: String.t()
  def format_job_timestamp(nil, _datetime_preferences), do: gettext("No observed run")

  def format_job_timestamp(%DateTime{} = datetime, datetime_preferences) do
    DateTimeDisplay.format_datetime(datetime, datetime_preferences, missing_label: gettext("No observed run"))
  end

  @spec timestamp_line(String.t(), DateTime.t() | nil, DateTimeDisplay.preferences()) ::
          String.t()
  def timestamp_line(label, nil, _datetime_preferences),
    do: gettext("%{label} -", label: label)

  def timestamp_line(label, %DateTime{} = datetime, datetime_preferences) do
    gettext("%{label} %{timestamp}",
      label: label,
      timestamp: format_job_timestamp(datetime, datetime_preferences)
    )
  end

  @spec job_state_icon(String.t() | nil) :: String.t()
  defdelegate job_state_icon(state), to: State, as: :icon

  @spec job_state_icon_class(String.t() | nil) :: String.t()
  defdelegate job_state_icon_class(state), to: State, as: :icon_class

  @doc """
  Chip classes for a job state, from the shared badge vocabulary.

  Always a complete chip; a tone on its own has no shape and paints a band
  across whatever box it lands in.
  """
  @spec job_state_chip_class(String.t() | nil) :: String.t()
  def job_state_chip_class(state), do: BadgeComponents.metadata_chip_class(State.tone(state))

  @doc """
  Text-only variant of the state, for rows that name the state inline.
  """
  @spec job_state_text_class(String.t() | nil) :: String.t()
  def job_state_text_class(state), do: "font-semibold #{state_text_tone(State.tone(state))}"

  defp state_text_tone(:success), do: "text-success"
  defp state_text_tone(:warning), do: "text-warning"
  defp state_text_tone(:error), do: "text-error"
  defp state_text_tone(:info), do: "text-info"
  defp state_text_tone(_tone), do: "text-base-content/70"

  @spec job_state_label(String.t() | nil) :: String.t()
  defdelegate job_state_label(state), to: State, as: :label

  @spec job_state_tone(String.t() | nil) :: atom()
  defdelegate job_state_tone(state), to: State, as: :tone

  @doc """
  Operator-facing name for a worker module.

  `CodexPooler.Jobs.AccountReconciliationWorker` reads as
  "Account reconciliation". The module itself stays available for the title
  attribute and the drawer, which is where the exact value matters.
  """
  @spec job_worker_label(term()) :: String.t()
  def job_worker_label(worker) when is_binary(worker) and worker != "" do
    worker
    |> String.split(".")
    |> List.last()
    |> String.replace_suffix("Worker", "")
    |> humanize_module_segment()
    |> translate_worker_label()
  end

  def job_worker_label(_worker), do: gettext("Unnamed job")

  defp translate_worker_label("Account reconciliation"), do: gettext("Account reconciliation")
  defp translate_worker_label("Catalog sync"), do: gettext("Catalog sync")
  defp translate_worker_label("Catalog sync enqueue"), do: gettext("Catalog sync enqueue")
  defp translate_worker_label("Pricing import"), do: gettext("Pricing import")
  defp translate_worker_label("Token refresh"), do: gettext("Token refresh")
  defp translate_worker_label("Token refresh enqueue"), do: gettext("Token refresh enqueue")
  defp translate_worker_label("Runtime state cleanup"), do: gettext("Runtime state cleanup")
  defp translate_worker_label("Request replay cleanup"), do: gettext("Request replay cleanup")
  defp translate_worker_label("Alert evaluation"), do: gettext("Alert evaluation")
  defp translate_worker_label("Alert evaluation enqueue"), do: gettext("Alert evaluation enqueue")
  defp translate_worker_label("Daily rollup rebuild"), do: gettext("Daily rollup rebuild")
  defp translate_worker_label("Daily rollup rebuild enqueue"), do: gettext("Daily rollup rebuild enqueue")
  defp translate_worker_label("Open AI status sync"), do: gettext("OpenAI status sync")
  defp translate_worker_label("Open AI status cleanup"), do: gettext("OpenAI status cleanup")
  defp translate_worker_label("API key deletion"), do: gettext("API key deletion")
  defp translate_worker_label("Pool deletion"), do: gettext("Pool deletion")
  defp translate_worker_label(label), do: label

  defp humanize_module_segment(segment) do
    case Regex.scan(~r/[A-Z]+(?![a-z])|[A-Z][a-z0-9]*|[a-z0-9]+/, segment) do
      [] ->
        segment

      [[first] | rest] ->
        Enum.map_join([first | Enum.map(rest, fn [word] -> String.downcase(word) end)], " ", & &1)
    end
  end

  defp worker_card(group, summary, datetime_preferences, now) do
    latest_job = summary.latest
    success_job = summary.latest_success
    failure_job = summary.latest_failure
    state = worker_card_state(group, summary, latest_job)
    next_run = next_run_summary(group, summary.pending, datetime_preferences, now)
    open_markers = activity_markers(summary.open)
    failure_markers = failure_markers(summary.unresolved_failures)
    latest_unresolved_failure = List.first(summary.unresolved_failures)

    %{
      id: group.id,
      key: group.key,
      title: group.title,
      description: group.description,
      icon: group.icon,
      workers: group.workers,
      worker_labels: Enum.map(group.workers, &worker_label/1),
      manual_enqueue: manual_enqueue_worker_group?(group.key),
      state: state,
      state_label: job_state_label(state),
      live_state: live_job_state?(state),
      next_run: next_run.label,
      next_run_title: next_run.title,
      cadence_label: next_run.cadence_label,
      on_demand: !is_binary(group.cadence.cron),
      attempts: if(latest_job, do: format_attempts(latest_job), else: "0/-"),
      open_markers: open_markers,
      failure_markers: failure_markers,
      visible_open_markers: Enum.take(open_markers, @visible_open_marker_limit),
      open_marker_overflow_count: marker_overflow_count(open_markers, @visible_open_marker_limit),
      visible_failure_markers: Enum.take(failure_markers, @visible_failure_marker_limit),
      failure_marker_overflow_count: marker_overflow_count(failure_markers, @visible_failure_marker_limit),
      latest_failure: latest_failure_summary(latest_unresolved_failure),
      activity_label: activity_label(open_markers, failure_markers),
      last_seen_at: job_event_timestamp(latest_job),
      last_success_at: job_event_timestamp(success_job),
      last_failure_at: job_event_timestamp(failure_job)
    }
  end

  defp marker_overflow_count(markers, limit) do
    count = length(markers)
    if count > limit, do: count - limit, else: 0
  end

  defp worker_label(worker) do
    worker
    |> String.replace_prefix("CodexPooler.Jobs.", "")
    |> String.replace_suffix("Worker", "")
    |> humanize_module_segment()
    |> translate_worker_label()
  end

  defp manual_enqueue_worker_group?(worker_group),
    do: Jobs.worker_group_manual_enqueueable?(worker_group)

  defp worker_card_state(_group, %{pending: %{state: state}}, _latest_job), do: state
  defp worker_card_state(_group, _summary, %{state: state}), do: state
  defp worker_card_state(group, _summary, _latest_job), do: empty_worker_state(group)

  defp activity_label(open, failures) when open != [] and failures != [],
    do: gettext("Open targets and failures")

  defp activity_label(open, _failures) when open != [], do: gettext("Open targets")
  defp activity_label(_open, failures) when failures != [], do: gettext("Needs attention")
  defp activity_label(_open, _failures), do: nil

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
          label: gettext("On demand"),
          title: cadence.label,
          cadence_label: cadence.label
        }
    end
  end

  defp pending_job_next_run(%{state: "executing"} = job, cadence, datetime_preferences, _now) do
    %{
      label: gettext("Running now"),
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
      label: gettext("Queued now"),
      title: timestamp_title(job.scheduled_at || job.inserted_at, datetime_preferences),
      cadence_label: cadence.label
    }
  end

  defp pending_job_next_run(%{state: "retryable"} = job, cadence, datetime_preferences, now) do
    label = if job.scheduled_at, do: relative_time(job.scheduled_at, now), else: gettext("Retry pending")

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
      open: [],
      unresolved_failures: []
    }
  end

  defp activity_markers(jobs) do
    Enum.flat_map(jobs, fn job ->
      case job_target(job) do
        %{kind: kind} = target when kind in [:assignment, :direct_identity, :pool, :api_key] ->
          [
            %{
              id: job.id,
              worker_label: worker_label(job.worker || "not recorded"),
              target_label: marker_target_label(target),
              title: marker_title(job, target),
              avatar_email: marker_avatar_email(target),
              glyph: marker_glyph(target)
            }
          ]

        _target ->
          []
      end
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
        avatar_email: marker_avatar_email(target),
        glyph: marker_glyph(target),
        failure: job_failure_summary(job),
        failed_at: job_event_timestamp(job),
        attempts: format_attempts(job)
      }
    end)
    |> Enum.reject(&is_nil(&1.failure))
  end

  defp latest_failure_summary(nil), do: nil

  defp latest_failure_summary(job) do
    case job_failure_summary(job) do
      %{title: title, message: message} ->
        target = job_target(job)

        %{
          title: title,
          message: message,
          target_label: marker_target_label(target),
          failed_at: job_event_timestamp(job),
          attempts: format_attempts(job)
        }

      nil ->
        nil
    end
  end

  defp marker_target_label(%{primary: primary}) when is_binary(primary), do: primary
  defp marker_target_label(_target), do: gettext("System job")

  defp marker_glyph(%{primary: primary}) when is_binary(primary) do
    primary
    |> String.replace(~r/^[^:]+:\s*/, "")
    |> marker_glyph_from_label()
  end

  defp marker_glyph(_target), do: "S"

  defp marker_avatar_email(%{primary: primary}), do: AvatarComponents.email_identity(primary)
  defp marker_avatar_email(_target), do: nil

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
    technical_worker = technical_worker_label(job.worker || "not recorded")

    [
      job_state_label(job.state),
      worker_label(job.worker || "not recorded"),
      technical_worker,
      if(target, do: target.primary_title || target.primary)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.join(" · ")
  end

  defp technical_worker_label(worker) when is_binary(worker) and worker != "" do
    worker
    |> String.replace_prefix("CodexPooler.Jobs.", "")
    |> String.replace_suffix("Worker", "")
  end

  defp technical_worker_label(_worker), do: "not recorded"

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
  defp translate_failure_title("Failure detail"), do: gettext("Failure detail")
  defp translate_failure_title("Run discarded"), do: gettext("Run discarded")
  defp translate_failure_title("Invalid catalog sync trigger"), do: gettext("Invalid catalog sync trigger")
  defp translate_failure_title("Catalog sync already running"), do: gettext("Catalog sync already running")
  defp translate_failure_title("Quota refresh blocked"), do: gettext("Quota refresh blocked")
  defp translate_failure_title("Quota unavailable"), do: gettext("Quota unavailable")
  defp translate_failure_title("Quota refresh failed"), do: gettext("Quota refresh failed")

  defp translate_failure_title(title) do
    case Regex.run(~r/\AAttempt (\d+)(?: · (.+))?\z/, title) do
      [_, attempt, detail] -> gettext("Attempt %{attempt} · %{detail}", attempt: attempt, detail: translate_failure_code(detail))
      [_, attempt] -> gettext("Attempt %{attempt}", attempt: attempt)
      _other -> title
    end
  end

  defp translate_failure_message("No diagnostic message recorded."),
    do: gettext("No diagnostic message recorded.")

  defp translate_failure_message("The job stopped without additional diagnostics."),
    do: gettext("The job stopped without additional diagnostics.")

  defp translate_failure_message("Manual catalog sync could not start because the enqueue action used an unsupported trigger kind."),
    do: gettext("Manual catalog sync could not start because the enqueue action used an unsupported trigger kind.")

  defp translate_failure_message("Catalog sync could not start because this pool already has a sync run marked as running."),
    do: gettext("Catalog sync could not start because this pool already has a sync run marked as running.")

  defp translate_failure_message("Quota refresh needs account reauthentication."),
    do: gettext("Quota refresh needs account reauthentication.")

  defp translate_failure_message("Quota data was not available from the upstream account."),
    do: gettext("Quota data was not available from the upstream account.")

  defp translate_failure_message("Quota refresh failed for the upstream account."),
    do: gettext("Quota refresh failed for the upstream account.")

  defp translate_failure_message("Account reconciliation needs attention: " <> code),
    do: gettext("Account reconciliation needs attention: %{code}.", code: translate_failure_code(String.trim_trailing(code, ".")))

  defp translate_failure_message(message), do: message

  defp translate_failure_code("quota_refresh_auth_unavailable"),
    do: gettext("Quota refresh authentication unavailable")

  defp translate_failure_code("quota_refresh_unavailable"), do: gettext("Quota refresh unavailable")
  defp translate_failure_code("quota_refresh_failed"), do: gettext("Quota refresh failed")
  defp translate_failure_code("pool_account_not_reconcilable"), do: gettext("Pool account not reconcilable")
  defp translate_failure_code("catalog_sync_failed"), do: gettext("Catalog sync failed")
  defp translate_failure_code("catalog_sync_in_progress"), do: gettext("Catalog sync in progress")
  defp translate_failure_code(code), do: code

  defp safe_failure_message(message) when is_binary(message) do
    message
    |> String.replace(~r/[\r\n\t]+/, " ")
    |> redact_failure_secrets()
    |> unwrap_oban_failure_message()
    |> operator_failure_message()
    |> String.trim()
    |> truncate_failure_message()
    |> case do
      "" -> gettext("No diagnostic message recorded.")
      message -> message
    end
  end

  defp safe_failure_message(_message), do: gettext("No diagnostic message recorded.")

  defp redact_failure_secrets(message) do
    message
    |> String.replace(~r/(?i)bearer\s+[a-z0-9._~+\/=:-]+/, "Bearer [redacted]")
    |> String.replace(~r/(?i)\bsecret[-_a-z0-9]*\b/, "[redacted]")
    |> String.replace(
      ~r/(?i)\b(authorization|cookie|set-cookie|api[_-]?key|access[_-]?token|refresh[_-]?token|password|prompt|secret|token)\b\s*[:=]\s*[^,;\s]+/,
      "[redacted]"
    )
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

  defp timestamp_title(nil, _datetime_preferences), do: nil

  defp timestamp_title(%DateTime{} = datetime, datetime_preferences),
    do: format_job_timestamp(datetime, datetime_preferences)

  defp relative_time(nil, _now), do: gettext("Unknown")

  defp relative_time(%DateTime{} = datetime, %DateTime{} = now) do
    diff_seconds = RelativeTime.seconds_until(datetime, now)

    cond do
      DateTime.compare(datetime, now) != :gt ->
        gettext("Due now")

      diff_seconds < 60 ->
        gettext("in <1m")

      diff_seconds < 3_600 ->
        gettext("in %{count}m", count: ceil(diff_seconds / 60))

      diff_seconds < 86_400 ->
        gettext("in %{count}h", count: ceil(diff_seconds / 3_600))

      true ->
        gettext("in %{count}d", count: ceil(diff_seconds / 86_400))
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
