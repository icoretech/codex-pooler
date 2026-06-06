defmodule CodexPooler.Jobs do
  @moduledoc """
  Durable job enqueue and orchestration APIs backed by Oban.
  """

  alias CodexPooler.Alerts
  alias CodexPooler.Alerts.Schemas.{AlertIncident, AlertRule}
  alias CodexPooler.Events

  alias CodexPooler.Jobs.{
    AccountReconciliationWorker,
    AlertDeliveryWorker,
    AlertEvaluationWorker,
    CatalogSyncWorker,
    DailyRollupRebuildWorker,
    Options,
    PricingImportWorker,
    ReadModel,
    RuntimeStateCleanup,
    RuntimeStateCleanupWorker,
    UpstreamEnqueue
  }

  alias CodexPooler.Pools
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Reconciliation.AccountReconciliation
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @default_alert_evaluation_fanout_limit 500
  @dev_features_build_enabled Application.compile_env(
                                :codex_pooler,
                                :dev_features_build_enabled,
                                false
                              )

  @type pool_ref :: Pool.t() | %{required(:id) => Ecto.UUID.t()} | Ecto.UUID.t()
  @type alert_rule_ref :: AlertRule.t() | %{required(:id) => Ecto.UUID.t()} | Ecto.UUID.t()
  @type alert_incident_ref ::
          AlertIncident.t() | %{required(:id) => Ecto.UUID.t()} | Ecto.UUID.t()
  @type alert_channel_ref :: %{required(:id) => Ecto.UUID.t()} | Ecto.UUID.t()
  @type assignment_ref ::
          PoolUpstreamAssignment.t() | %{required(:id) => Ecto.UUID.t()} | Ecto.UUID.t()
  @type identity_ref :: UpstreamIdentity.t() | %{required(:id) => Ecto.UUID.t()} | Ecto.UUID.t()
  @type missing_ref_error ::
          :pool_id_required
          | :alert_rule_id_required
          | :alert_incident_id_required
          | :alert_channel_id_required
          | :pool_upstream_assignment_id_required
          | :upstream_identity_id_required
  @type job_insert_result ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t() | missing_ref_error()}
  @type batch_insert_result ::
          {:ok,
           %{
             required(:inserted) => [Oban.Job.t()],
             required(:conflicts) => [Oban.Job.t()],
             required(:errors) => [term()]
           }}
  @type manual_worker_group_enqueue_result ::
          job_insert_result()
          | batch_insert_result()
          | {:error, :unknown_worker_group | :worker_group_requires_target}
  @type job_summary :: ReadModel.job_summary()
  @type worker_job_summary :: ReadModel.worker_job_summary()
  @type worker_job_summaries_by_group :: ReadModel.worker_job_summaries_by_group()
  @type orchestration_result :: {:ok, map()} | {:error, term()}

  @manual_worker_groups %{
    "catalog_sync" => :catalog_sync,
    "pricing_import" => :pricing_import,
    "account_reconciliation" => :account_reconciliation,
    "alert_evaluation" => :alert_evaluation,
    "token_refresh" => :token_refresh,
    "daily_rollup_rebuild" => :daily_rollup_rebuild,
    "runtime_cleanup" => :runtime_cleanup
  }

  @spec enqueue_catalog_sync(pool_ref(), keyword()) :: job_insert_result()
  def enqueue_catalog_sync(pool_or_id, opts \\ []) do
    with {:ok, pool_id} <- pool_id(pool_or_id) do
      %{"pool_id" => pool_id, "trigger_kind" => Keyword.get(opts, :trigger_kind, "scheduled")}
      |> CatalogSyncWorker.new(Options.job_options(opts, unique_keys: [:pool_id]))
      |> Oban.insert()
      |> tap_job_status_event(pool_id, "catalog_sync", "scheduled")
    end
  end

  @spec enqueue_catalog_sync_for_active_pools(keyword()) :: batch_insert_result()
  def enqueue_catalog_sync_for_active_pools(opts \\ []) do
    Pools.list_active_pools()
    |> Enum.map(&enqueue_catalog_sync(&1, opts))
    |> split_insert_results()
  end

  @spec enqueue_account_reconciliation(pool_ref(), assignment_ref(), keyword()) ::
          job_insert_result()
  def enqueue_account_reconciliation(pool_or_id, assignment_or_id, opts \\ []) do
    UpstreamEnqueue.enqueue_account_reconciliation(pool_or_id, assignment_or_id, opts)
  end

  @spec enqueue_assignment_priming(pool_ref(), assignment_ref(), keyword()) ::
          job_insert_result() | {:error, term()}
  def enqueue_assignment_priming(pool_or_id, assignment_or_id, opts \\ []) do
    UpstreamEnqueue.enqueue_assignment_priming(pool_or_id, assignment_or_id, opts)
  end

  @spec enqueue_runtime_state_cleanup(keyword()) :: job_insert_result()
  def enqueue_runtime_state_cleanup(opts \\ []) do
    args =
      case Keyword.get(opts, :now) do
        %DateTime{} = now -> %{"now" => DateTime.to_iso8601(DateTime.truncate(now, :microsecond))}
        _value -> %{}
      end

    args
    |> RuntimeStateCleanupWorker.new(Keyword.take(opts, [:scheduled_at, :schedule_in, :unique]))
    |> Oban.insert()
  end

  @spec enqueue_pricing_import(keyword()) :: job_insert_result()
  def enqueue_pricing_import(opts \\ []) do
    %{}
    |> PricingImportWorker.new(Keyword.take(opts, [:scheduled_at, :schedule_in, :unique]))
    |> Oban.insert()
  end

  @spec worker_group_manual_enqueueable?(atom() | String.t()) :: boolean()
  def worker_group_manual_enqueueable?(worker_group) do
    case normalize_manual_worker_group(worker_group) do
      :unknown -> false
      :token_refresh -> false
      _worker_group -> true
    end
  end

  @spec enqueue_worker_group_now(atom() | String.t(), keyword()) ::
          manual_worker_group_enqueue_result()
  def enqueue_worker_group_now(worker_group, opts \\ []) do
    opts = Keyword.put(opts, :trigger_kind, "manual")

    case normalize_manual_worker_group(worker_group) do
      :catalog_sync -> enqueue_catalog_sync_for_active_pools(opts)
      :pricing_import -> enqueue_pricing_import(opts)
      :account_reconciliation -> enqueue_account_reconciliation_for_active_pools(opts)
      :alert_evaluation -> enqueue_alert_evaluations_for_active_rules(opts)
      :daily_rollup_rebuild -> enqueue_daily_rollup_rebuild(yesterday_utc(), opts)
      :runtime_cleanup -> enqueue_runtime_state_cleanup(opts)
      :token_refresh -> {:error, :worker_group_requires_target}
      :unknown -> {:error, :unknown_worker_group}
    end
  end

  @spec list_system_jobs(keyword()) :: [job_summary()]
  def list_system_jobs(opts \\ []) do
    ReadModel.list_system_jobs(opts)
  end

  @spec list_latest_jobs(ReadModel.scope_ref(), keyword()) :: [job_summary()]
  def list_latest_jobs(scope, opts \\ []), do: ReadModel.list_latest_jobs(scope, opts)

  @spec worker_job_summary(ReadModel.scope_ref(), [String.t()]) :: worker_job_summary()
  def worker_job_summary(scope, workers), do: ReadModel.worker_job_summary(scope, workers)

  @spec worker_job_summaries_by_group(ReadModel.scope_ref(), [ReadModel.worker_group()]) ::
          worker_job_summaries_by_group()
  def worker_job_summaries_by_group(scope, worker_groups) do
    ReadModel.worker_job_summaries_by_group(scope, worker_groups)
  end

  @spec cleanup_runtime_state(DateTime.t()) :: orchestration_result()
  def cleanup_runtime_state(now \\ DateTime.utc_now()) do
    RuntimeStateCleanup.run(now)
  end

  @spec enqueue_token_refresh(identity_ref(), keyword()) :: job_insert_result()
  def enqueue_token_refresh(identity_or_id, opts \\ []) do
    UpstreamEnqueue.enqueue_token_refresh(identity_or_id, opts)
  end

  @spec list_recent_token_refresh_jobs(identity_ref(), keyword()) :: [job_summary()]
  defdelegate list_recent_token_refresh_jobs(identity_or_id, opts \\ []), to: ReadModel

  @spec enqueue_account_reconciliations(pool_ref(), keyword()) ::
          batch_insert_result() | {:error, :pool_id_required}
  def enqueue_account_reconciliations(pool_or_id, opts \\ []) do
    with {:ok, pool_id} <- pool_id(pool_or_id) do
      pool_id
      |> PoolAssignments.list_active_pool_assignments()
      |> Enum.map(&enqueue_account_reconciliation(pool_id, &1, opts))
      |> split_insert_results()
    end
  end

  @spec enqueue_account_reconciliation_for_active_pools(keyword()) :: batch_insert_result()
  if @dev_features_build_enabled do
    alias CodexPooler.Jobs.DevelopmentControls

    def enqueue_account_reconciliation_for_active_pools(opts \\ []) do
      unless DevelopmentControls.account_reconciliation_paused?() do
        discard_stale_account_reconciliation_jobs()
      end

      active_pools_for_account_reconciliation()
      |> Enum.map(&enqueue_account_reconciliations(&1, opts))
      |> split_insert_results()
    end
  else
    def enqueue_account_reconciliation_for_active_pools(opts \\ []) do
      discard_stale_account_reconciliation_jobs()

      active_pools_for_account_reconciliation()
      |> Enum.map(&enqueue_account_reconciliations(&1, opts))
      |> split_insert_results()
    end
  end

  defp discard_stale_account_reconciliation_jobs do
    AccountReconciliation.discard_stale_jobs(
      DateTime.utc_now(),
      worker_name(AccountReconciliationWorker)
    )
  end

  @spec enqueue_alert_evaluation(alert_rule_ref(), keyword()) :: job_insert_result()
  def enqueue_alert_evaluation(rule_or_id, opts \\ []) do
    with {:ok, rule_id} <- alert_rule_id(rule_or_id) do
      evaluation_window_started_at = evaluation_window_started_at(Keyword.get(opts, :now))

      %{
        "alert_rule_id" => rule_id,
        "evaluation_window_started_at" => DateTime.to_iso8601(evaluation_window_started_at),
        "trigger_kind" => trigger_kind(opts)
      }
      |> AlertEvaluationWorker.new(
        Options.job_options(opts, unique_keys: [:alert_rule_id, :evaluation_window_started_at])
      )
      |> Oban.insert()
    end
  end

  @spec enqueue_alert_evaluations_for_active_rules(keyword()) :: batch_insert_result()
  def enqueue_alert_evaluations_for_active_rules(opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:trigger_kind, "scheduled")
      |> Keyword.put_new(:now, DateTime.utc_now())

    limit = Keyword.get(opts, :limit, @default_alert_evaluation_fanout_limit)

    [limit: limit]
    |> Alerts.list_active_rules_for_evaluation()
    |> Enum.map(&enqueue_alert_evaluation(&1, opts))
    |> split_insert_results()
  end

  @spec enqueue_alert_delivery(alert_incident_ref(), alert_channel_ref(), keyword()) ::
          job_insert_result()
  def enqueue_alert_delivery(incident_or_id, channel_or_id, opts \\ []) do
    with {:ok, incident_id} <- alert_incident_id(incident_or_id),
         {:ok, channel_id} <- alert_channel_id(channel_or_id) do
      %{
        "alert_incident_id" => incident_id,
        "alert_channel_id" => channel_id,
        "trigger_kind" => trigger_kind(opts)
      }
      |> AlertDeliveryWorker.new(
        Options.job_options(opts, unique_keys: [:alert_incident_id, :alert_channel_id])
      )
      |> Oban.insert()
    end
  end

  @spec enqueue_alert_deliveries_for_incident(alert_incident_ref(), keyword()) ::
          batch_insert_result() | {:error, missing_ref_error()}
  def enqueue_alert_deliveries_for_incident(incident_or_id, opts \\ []) do
    with {:ok, incident_id} <- alert_incident_id(incident_or_id) do
      incident_id
      |> Alerts.list_incident_delivery_channels_due(opts)
      |> Enum.map(&enqueue_alert_delivery(incident_id, &1.channel_id, opts))
      |> split_insert_results()
    end
  end

  @spec list_recent_account_reconciliation_jobs(pool_ref(), keyword()) :: [job_summary()]
  defdelegate list_recent_account_reconciliation_jobs(pool_or_id, opts \\ []), to: ReadModel

  @spec enqueue_daily_rollup_rebuild(Date.t(), keyword()) :: job_insert_result()
  def enqueue_daily_rollup_rebuild(date \\ yesterday_utc(), opts \\ []) do
    rollup_date = Date.to_iso8601(date)

    %{"rollup_date" => rollup_date}
    |> DailyRollupRebuildWorker.new(Options.job_options(opts, unique_keys: [:rollup_date]))
    |> Oban.insert()
  end

  defp tap_job_status_event({:ok, job} = result, pool_id, worker, status) do
    Events.broadcast_job_status(pool_id, "job_status_updated", %{
      id: Integer.to_string(job.id),
      worker: worker,
      status: status
    })

    result
  end

  defp tap_job_status_event(result, _pool_id, _worker, _status), do: result

  defp split_insert_results(results) do
    Enum.reduce(results, {:ok, %{inserted: [], conflicts: [], errors: []}}, fn
      {:ok, %{inserted: inserted, conflicts: conflicts, errors: errors}}, {:ok, acc} ->
        {:ok,
         %{
           inserted: inserted ++ acc.inserted,
           conflicts: conflicts ++ acc.conflicts,
           errors: errors ++ acc.errors
         }}

      {:ok, %{conflict?: true} = job}, {:ok, acc} ->
        {:ok, %{acc | conflicts: [job | acc.conflicts]}}

      {:ok, job}, {:ok, acc} ->
        {:ok, %{acc | inserted: [job | acc.inserted]}}

      {:error, reason}, {:ok, acc} ->
        {:ok, %{acc | errors: [reason | acc.errors]}}
    end)
  end

  if @dev_features_build_enabled do
    alias CodexPooler.Jobs.DevelopmentControls

    defp active_pools_for_account_reconciliation do
      if DevelopmentControls.account_reconciliation_paused?() do
        []
      else
        Pools.list_active_pools()
      end
    end
  else
    defp active_pools_for_account_reconciliation, do: Pools.list_active_pools()
  end

  defp evaluation_window_started_at(%DateTime{} = now) do
    now
    |> DateTime.to_unix()
    |> div(5 * 60)
    |> Kernel.*(5 * 60)
    |> DateTime.from_unix!()
    |> DateTime.truncate(:microsecond)
  end

  defp evaluation_window_started_at(_now), do: evaluation_window_started_at(DateTime.utc_now())

  defp trigger_kind(opts) do
    case Keyword.get(opts, :trigger_kind, "manual") do
      value when is_binary(value) -> value
      _value -> "manual"
    end
  end

  defp normalize_manual_worker_group(worker_group) when is_atom(worker_group) do
    worker_group
    |> Atom.to_string()
    |> normalize_manual_worker_group()
  end

  defp normalize_manual_worker_group(worker_group) when is_binary(worker_group) do
    worker_group
    |> String.replace("-", "_")
    |> then(&Map.get(@manual_worker_groups, &1, :unknown))
  end

  defp normalize_manual_worker_group(_worker_group), do: :unknown

  defp yesterday_utc, do: Date.utc_today() |> Date.add(-1)
  defp worker_name(worker), do: worker |> Atom.to_string() |> String.replace_prefix("Elixir.", "")
  defp alert_rule_id(%{id: id}) when is_binary(id), do: {:ok, id}
  defp alert_rule_id(id) when is_binary(id), do: {:ok, id}
  defp alert_rule_id(_rule_or_id), do: {:error, :alert_rule_id_required}
  defp alert_incident_id(%{id: id}) when is_binary(id), do: {:ok, id}
  defp alert_incident_id(id) when is_binary(id), do: {:ok, id}
  defp alert_incident_id(_incident_or_id), do: {:error, :alert_incident_id_required}
  defp alert_channel_id(%{id: id}) when is_binary(id), do: {:ok, id}
  defp alert_channel_id(id) when is_binary(id), do: {:ok, id}
  defp alert_channel_id(_channel_or_id), do: {:error, :alert_channel_id_required}
  defp pool_id(%{id: id}) when is_binary(id), do: {:ok, id}
  defp pool_id(id) when is_binary(id), do: {:ok, id}
  defp pool_id(_pool_or_id), do: {:error, :pool_id_required}
end
