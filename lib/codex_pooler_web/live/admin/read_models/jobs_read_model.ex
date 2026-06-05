defmodule CodexPoolerWeb.Admin.JobsReadModel do
  @moduledoc false

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Jobs
  alias CodexPooler.Jobs.ReadModel
  alias CodexPooler.Jobs.Schedule
  alias CodexPooler.Pools
  alias CodexPoolerWeb.Admin.JobFilterForm

  @explorer_filter_keys [
    :state,
    :worker,
    :queue,
    :attention,
    :target_kind,
    :target_id,
    :page,
    :show_completed
  ]

  @sensitive_projection_keys [:args, :meta, :errors, "args", "meta", "errors"]

  @type worker_jobs_by_group :: %{optional(atom()) => ReadModel.worker_job_summary()}
  @type filter_options :: %{
          required(:state) => [JobFilterForm.option()],
          required(:attention) => [JobFilterForm.option()],
          required(:target_kind) => [JobFilterForm.option()],
          required(:worker) => [JobFilterForm.option()],
          required(:queue) => [JobFilterForm.option()]
        }
  @type load_opts :: keyword() | map()
  @type page_state :: %{
          required(:overview) => ReadModel.jobs_overview(),
          required(:explorer) => ReadModel.explorer_page(),
          required(:filters) => JobFilterForm.filters(),
          required(:form_values) => JobFilterForm.form_values(),
          required(:filter_options) => filter_options(),
          required(:filter_warnings) => [JobFilterForm.filter_error()],
          required(:selected_job) => ReadModel.explorer_job_summary() | nil,
          required(:worker_jobs_by_group) => worker_jobs_by_group()
        }

  @spec load(ReadModel.scope_ref(), load_opts()) :: page_state()
  def load(scope, opts \\ []) do
    if owner_projection_scope?(scope) do
      load_owner_projection(scope, opts)
    else
      empty_page_state()
    end
  end

  @spec worker_jobs_by_group(ReadModel.scope_ref()) :: worker_jobs_by_group()
  def worker_jobs_by_group(scope) do
    worker_groups = Schedule.worker_groups()

    if owner_projection_scope?(scope) do
      Jobs.worker_job_summaries_by_group(scope, worker_groups)
    else
      Jobs.worker_job_summaries_by_group(nil, worker_groups)
    end
  end

  defp load_owner_projection(scope, opts) do
    {filters, form_values, filter_warnings} =
      opts |> params_from_load_opts() |> JobFilterForm.parse_filters()

    explorer_filters = explorer_filters(filters)
    read_opts = read_opts_from_load_opts(opts)

    overview =
      scope |> ReadModel.jobs_overview(explorer_filters, read_opts) |> sanitize_projection()

    explorer =
      scope |> ReadModel.list_explorer_jobs(explorer_filters, read_opts) |> sanitize_projection()

    grouped_jobs = scope |> worker_jobs_by_group() |> sanitize_projection()

    %{
      overview: overview,
      explorer: explorer,
      filters: filters,
      form_values: form_values,
      filter_options: filter_options(explorer.items, filters),
      filter_warnings: filter_warnings,
      selected_job: selected_job(filters.job_id, explorer.items),
      worker_jobs_by_group: grouped_jobs
    }
  end

  defp empty_page_state do
    {filters, form_values, []} = JobFilterForm.parse_filters(%{})
    explorer_filters = explorer_filters(filters)

    %{
      overview: ReadModel.jobs_overview(nil, explorer_filters),
      explorer: ReadModel.list_explorer_jobs(nil, explorer_filters),
      filters: filters,
      form_values: form_values,
      filter_options: filter_options([], filters),
      filter_warnings: [],
      selected_job: nil,
      worker_jobs_by_group: worker_jobs_by_group(nil)
    }
  end

  defp owner_projection_scope?(:system), do: true
  defp owner_projection_scope?(%Scope{} = scope), do: Pools.owner?(scope)
  defp owner_projection_scope?(_scope), do: false

  defp params_from_load_opts(opts) when is_list(opts), do: Keyword.get(opts, :params, %{})
  defp params_from_load_opts(params) when is_map(params), do: params
  defp params_from_load_opts(_opts), do: %{}

  defp read_opts_from_load_opts(opts) when is_list(opts), do: Keyword.take(opts, [:now])
  defp read_opts_from_load_opts(_opts), do: []

  defp explorer_filters(filters), do: Map.take(filters, @explorer_filter_keys)

  defp selected_job(nil, _items), do: nil
  defp selected_job(job_id, items), do: Enum.find(items, &(&1.id == job_id))

  defp filter_options(items, filters) do
    %{
      state: JobFilterForm.state_options(),
      attention: JobFilterForm.attention_options(),
      target_kind: JobFilterForm.target_kind_options(),
      worker: items |> projection_values(:worker) |> JobFilterForm.worker_options(filters.worker),
      queue: items |> projection_values(:queue) |> JobFilterForm.queue_options(filters.queue)
    }
  end

  defp projection_values(items, key) do
    items
    |> Enum.map(&Map.get(&1, key))
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
  end

  defp sanitize_projection(value) when is_list(value), do: Enum.map(value, &sanitize_projection/1)

  defp sanitize_projection(%DateTime{} = value), do: value
  defp sanitize_projection(%NaiveDateTime{} = value), do: value
  defp sanitize_projection(%Date{} = value), do: value

  defp sanitize_projection(%{errors: errors} = value) when is_list(errors) do
    value
    |> Map.drop(@sensitive_projection_keys)
    |> maybe_put_failure_summary(latest_error_by_attempt(errors))
    |> Map.new(fn {key, nested_value} -> {key, sanitize_projection(nested_value)} end)
  end

  defp sanitize_projection(value) when is_map(value) do
    value
    |> Map.drop(@sensitive_projection_keys)
    |> Map.new(fn {key, nested_value} -> {key, sanitize_projection(nested_value)} end)
  end

  defp sanitize_projection(value), do: value

  defp maybe_put_failure_summary(value, latest_error) when is_map(latest_error),
    do: Map.put(value, :failure_summary, failure_summary(latest_error))

  defp maybe_put_failure_summary(value, _latest_error), do: value

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

      code == "quota_refresh_auth_unavailable" ->
        "Quota refresh blocked"

      code == "quota_refresh_unavailable" ->
        "Quota unavailable"

      code == "quota_refresh_failed" ->
        "Quota refresh failed"

      is_binary(code) ->
        humanize_failure_code(code)

      true ->
        nil
    end
  end

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
