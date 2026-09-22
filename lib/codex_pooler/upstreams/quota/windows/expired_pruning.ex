defmodule CodexPooler.Upstreams.Quota.Windows.ExpiredPruning do
  @moduledoc """
  Deletes `account_quota_windows` rows whose reset passed long ago.

  Evidence rows are keyed by identity, source and descriptor, and a writer
  only ever rewrites the row of a descriptor it observes again. A descriptor
  the provider stops reporting (a retired model window, a response-header or
  rate-limit-event shape an account no longer produces, a Usage API window a
  complete poll no longer covers) therefore keeps its last row forever, still
  carrying the `freshness_state` it was written with. Every reader already
  treats such a row as stale; this pass removes it once it can no longer
  describe any cycle, so the table only holds evidence that can still matter.

  A row is deleted when its `reset_at` passed more than
  `retention_seconds/0` ago. A row carrying the saved-reset
  automatic-confirmation marker is deleted only when that marker has lapsed
  by the same cutoff (`AutomaticConfirmation.lapsed_before?/2`: every reset
  instant it carries passed before the cutoff, or it is malformed), so no
  confirmation, approach witness or claim can still read it. A row another
  transaction holds locked is never deleted: a saved-reset claim and its
  reservation lock their proof rows `FOR UPDATE`, and those rows are skipped
  rather than waited for. Deletion runs per identity under the same identity-first locks as the
  evidence writers (`EvidenceStore.lock_evidence_identity!/1`), and the
  candidate conditions are re-evaluated under those locks, so a row a
  concurrent observation refreshed is kept. A pass handles at most
  `batch_size/0` rows; the rest wait for the next cleanup run.
  """

  import Ecto.Query

  require Logger

  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Quota.Windows.EvidenceStore
  alias CodexPooler.Upstreams.SavedResets.AutomaticConfirmation

  # DECISION: one full cycle of the longest window Codex exposes, the 30-day
  # monthly primary (`WindowClassifier`, 43_200 minutes). A row whose reset
  # passed that long ago describes a cycle whose successor has also ended for
  # every window kind (5h, weekly, monthly), so it can describe neither the
  # running nor the previous cycle of anything. It is a module constant, not
  # an Instance Setting: the rows it removes are never routing-usable and never
  # win a logical window over a sibling with a future reset, so no operator
  # decision depends on the value, and it is not tuned to any one install.
  @retention_seconds 43_200 * 60
  @batch_size 500

  @type summary :: %{expired_quota_windows_pruned: non_neg_integer()}

  @spec retention_seconds() :: pos_integer()
  def retention_seconds, do: @retention_seconds

  @spec batch_size() :: pos_integer()
  def batch_size, do: @batch_size

  @spec prune(DateTime.t(), keyword()) :: {:ok, summary()}
  def prune(%DateTime{} = now, opts \\ []) do
    cutoff = DateTime.add(now, -@retention_seconds, :second)
    batch_size = Keyword.get(opts, :batch_size, @batch_size)

    pruned =
      cutoff
      |> candidate_query()
      |> order_by([window], asc: fragment("jsonb_exists(?, ?)", window.metadata, ^AutomaticConfirmation.metadata_key()), asc: window.reset_at, asc: window.id)
      |> limit(^batch_size)
      |> select([window], {window.upstream_identity_id, window.id, window.metadata})
      |> Repo.all()
      |> Enum.filter(&lapsed_marker?(&1, cutoff))
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce(0, fn {identity_id, window_ids}, total ->
        total + prune_identity(identity_id, window_ids, cutoff)
      end)

    if pruned > 0 do
      Logger.info("quota window cleanup deleted #{pruned} rows whose reset passed more than #{div(@retention_seconds, 86_400)} days ago")
    end

    {:ok, %{expired_quota_windows_pruned: pruned}}
  end

  defp prune_identity(identity_id, window_ids, cutoff) do
    {:ok, deleted} =
      Repo.transaction(fn ->
        :ok = EvidenceStore.lock_evidence_identity!(identity_id)

        deletable_ids =
          cutoff
          |> candidate_query()
          |> where([window], window.upstream_identity_id == ^identity_id and window.id in ^window_ids)
          |> lock("FOR UPDATE SKIP LOCKED")
          |> select([window], {window.upstream_identity_id, window.id, window.metadata})
          |> Repo.all()
          |> Enum.filter(&lapsed_marker?(&1, cutoff))
          |> Enum.map(&elem(&1, 1))

        {count, _rows} =
          Repo.delete_all(from(window in AccountQuotaWindow, where: window.id in ^deletable_ids))

        count
      end)

    if deleted > 0, do: Windows.broadcast_quota_update(identity_id)

    deleted
  end

  # Unmarked rows sort first, so a marker that has not lapsed can never fill a
  # batch ahead of rows that are deletable.
  defp candidate_query(cutoff) do
    from(window in AccountQuotaWindow, where: window.reset_at < ^cutoff)
  end

  defp lapsed_marker?({_identity_id, _id, metadata}, cutoff),
    do: AutomaticConfirmation.lapsed_before?(metadata, cutoff)
end
