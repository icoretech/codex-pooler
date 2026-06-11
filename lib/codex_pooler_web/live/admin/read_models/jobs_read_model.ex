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
      scope
      |> ReadModel.jobs_overview(explorer_filters, read_opts)
      |> ReadModel.sanitize_projection()

    explorer =
      scope
      |> ReadModel.list_explorer_jobs(explorer_filters, read_opts)
      |> ReadModel.sanitize_projection()

    grouped_jobs = scope |> worker_jobs_by_group() |> ReadModel.sanitize_projection()

    %{
      overview: overview,
      explorer: explorer,
      filters: filters,
      form_values: form_values,
      filter_options: filter_options(ReadModel.explorer_filter_values(scope), filters),
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
      filter_options: filter_options(ReadModel.explorer_filter_values(nil), filters),
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

  defp filter_options(filter_values, filters) do
    %{
      state: JobFilterForm.state_options(),
      attention: JobFilterForm.attention_options(),
      target_kind: JobFilterForm.target_kind_options(),
      worker: JobFilterForm.worker_options(filter_values.workers, filters.worker),
      queue: JobFilterForm.queue_options(filter_values.queues, filters.queue)
    }
  end
end
