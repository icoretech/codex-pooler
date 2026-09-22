defmodule CodexPooler.Upstreams.Quota.Windows.Retention do
  @moduledoc """
  The one definition of when an `account_quota_windows` row has outlived its
  retention.

  `ExpiredPruning` deletes exactly these rows on the runtime-cleanup cadence,
  and every read surface (`WindowSelector.logical_windows/2`, the routing
  snapshot's time-visible rows, quota priming) ignores them at the evaluation
  instant, so a decision never depends on whether a cleanup pass has run yet.

  A row is past retention when its `reset_at` passed more than
  `retention_seconds/0` before the evaluation instant and its saved-reset
  automatic-confirmation marker, if any, has lapsed by the same cutoff
  (`AutomaticConfirmation.lapsed_before?/2`). Rows without a reset never
  expire here.
  """

  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.SavedResets.AutomaticConfirmation

  # DECISION: one full cycle of the longest window Codex exposes, the 30-day
  # monthly primary (`WindowClassifier`, 43_200 minutes). A row whose reset
  # passed that long ago describes a cycle whose successor has also ended for
  # every window kind (5h, weekly, monthly), so it can describe neither the
  # running nor the previous cycle of anything. It is a module constant, not
  # an Instance Setting: the rows it retires are never routing-usable and never
  # win a logical window over a sibling with a future reset, so no operator
  # decision depends on the value, and it is not tuned to any one install.
  @retention_seconds 43_200 * 60

  @spec retention_seconds() :: pos_integer()
  def retention_seconds, do: @retention_seconds

  @spec cutoff(DateTime.t()) :: DateTime.t()
  def cutoff(%DateTime{} = as_of), do: DateTime.add(as_of, -@retention_seconds, :second)

  @spec past_retention?(AccountQuotaWindow.t(), DateTime.t()) :: boolean()
  def past_retention?(%AccountQuotaWindow{reset_at: %DateTime{} = reset_at, metadata: metadata}, %DateTime{} = as_of) do
    cutoff = cutoff(as_of)
    DateTime.compare(reset_at, cutoff) == :lt and AutomaticConfirmation.lapsed_before?(metadata, cutoff)
  end

  def past_retention?(%AccountQuotaWindow{}, %DateTime{}), do: false

  @spec reject_past_retention([AccountQuotaWindow.t()], DateTime.t()) :: [AccountQuotaWindow.t()]
  def reject_past_retention(windows, %DateTime{} = as_of) when is_list(windows),
    do: Enum.reject(windows, &past_retention?(&1, as_of))
end
