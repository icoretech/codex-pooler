defmodule CodexPooler.Jobs.AccountQuotaConfirmationWorker do
  @moduledoc """
  Confirms a reset-shaped weekly usage observation after the safety span.

  Manual quota refreshes enqueue this worker only when their first provider
  observation leaves a pending zero candidate. The delayed probe is a distinct
  worker so it cannot collide with the reconciliation job that discovered the
  candidate.
  """

  use Oban.Worker,
    queue: :jobs,
    max_attempts: 1,
    tags: ["account_reconciliation", "quota_confirmation"],
    unique: [
      fields: [:args, :queue, :worker],
      keys: [:upstream_identity_id],
      states: :incomplete,
      period: {15, :minutes}
    ]

  alias CodexPooler.Jobs.UpstreamEnqueue
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Quota.Windows.EvidenceStore
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @manual_triggers ~w(admin_upstreams_live admin_upstream_cockpit_live)
  @settle_buffer_seconds 5
  @reconcilable_statuses [
    PoolUpstreamAssignment.active_status(),
    PoolUpstreamAssignment.refresh_due_status(),
    PoolUpstreamAssignment.refresh_failed_status()
  ]

  @spec enqueue_if_pending(map(), String.t()) ::
          :not_needed | {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def enqueue_if_pending(
        %{
          identity: %UpstreamIdentity{} = identity,
          assignment: %PoolUpstreamAssignment{} = assignment
        },
        trigger_kind
      )
      when trigger_kind in @manual_triggers do
    case pending_zero_confirmation(identity.id) do
      %{due_at: due_at, observed_at: observed_at} ->
        %{
          "pool_id" => assignment.pool_id,
          "pool_upstream_assignment_id" => assignment.id,
          "upstream_identity_id" => identity.id,
          "target_kind" => "upstream_identity",
          "trigger_kind" => "admin_quota_confirmation",
          "confirmation_candidate_observed_at" => DateTime.to_iso8601(observed_at)
        }
        |> new(scheduled_at: DateTime.add(due_at, @settle_buffer_seconds, :second))
        |> Oban.insert()

      nil ->
        :not_needed
    end
  end

  def enqueue_if_pending(_result, _trigger_kind), do: :not_needed

  @impl Oban.Worker
  def timeout(%Oban.Job{}), do: :timer.minutes(20)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"upstream_identity_id" => identity_id}}) do
    timestamp = now()

    case pending_zero_confirmation(identity_id, timestamp) do
      %{due_at: due_at} ->
        maybe_enqueue_confirmation(identity_id, due_at, timestamp)

      nil ->
        :ok
    end
  end

  defp maybe_enqueue_confirmation(identity_id, due_at, timestamp) do
    remaining_seconds = DateTime.diff(due_at, timestamp, :second)

    cond do
      remaining_seconds > 0 ->
        {:snooze, remaining_seconds + @settle_buffer_seconds}

      assignment = reconcilable_assignment(identity_id) ->
        enqueue_reconciliation(assignment, due_at)

      true ->
        :ok
    end
  end

  defp enqueue_reconciliation(%PoolUpstreamAssignment{} = assignment, due_at) do
    case UpstreamEnqueue.enqueue_identity_account_reconciliation(
           assignment.pool_id,
           assignment,
           trigger_kind: "admin_quota_confirmation",
           bypass_successful_cooldown?: true
         ) do
      {:ok, %Oban.Job{conflict?: true} = job} -> confirmation_conflict_result(job, due_at)
      {:ok, %Oban.Job{}} -> :ok
      {:error, _reason} -> {:error, "quota confirmation reconciliation enqueue failed"}
    end
  end

  defp confirmation_conflict_result(
         %Oban.Job{state: "executing", attempted_at: %DateTime{} = attempted_at},
         due_at
       ) do
    if DateTime.compare(attempted_at, due_at) == :lt, do: {:snooze, 30}, else: :ok
  end

  defp confirmation_conflict_result(%Oban.Job{state: state}, _due_at)
       when state in ["suspended", "executing"],
       do: {:snooze, 60}

  defp confirmation_conflict_result(%Oban.Job{}, _due_at), do: :ok

  defp pending_zero_confirmation(identity_id, timestamp \\ now()) do
    identity_id
    |> Windows.list_evidence()
    |> Enum.flat_map(fn window ->
      case EvidenceStore.pending_weekly_zero_confirmation(window, timestamp) do
        {:ok, confirmation} -> [confirmation]
        :none -> []
      end
    end)
    |> Enum.min_by(&DateTime.to_unix(&1.due_at, :microsecond), fn -> nil end)
  end

  defp reconcilable_assignment(identity_id) do
    identity_id
    |> PoolAssignments.list_pool_assignments_for_identity()
    |> Enum.find(&(&1.status in @reconcilable_statuses))
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
