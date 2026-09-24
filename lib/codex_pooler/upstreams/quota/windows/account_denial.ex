defmodule CodexPooler.Upstreams.Quota.Windows.AccountDenial do
  @moduledoc """
  Reads a workspace-level provider denial out of a routing quota snapshot.

  The provider names why it refused a request in `x-codex-rate-limit-reached-type`,
  which the header parser keeps on every window it records from that response.
  The four `workspace_*` values refuse the whole account, whatever model the
  request named and however far the reported windows are from 100%: the
  workspace ran out of credits or hit its own usage limit. `rate_limit_reached`
  is left out on purpose, because it also names an ordinary per-window limit
  whose percentage already says whether it is spent.

  A denial is in force from the observation that carried it until the earliest
  reset that observation reported, and it ends earlier when a later
  provider-attested `available` reading for the identity's current credential
  epoch arrives (the next usage poll after the workspace regains credits). An
  observation without a reset instant holds only while it is fresh.

  This is deliberately not part of `Windows.Routing` eligibility: that answer
  also feeds the saved-reset sibling-capacity rule, the admin readiness pages
  and the catalog partition choice, and none of them may change here. The
  gateway applies it as its own candidate filter after quota eligibility and
  the saved-reset decisions.
  """

  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Upstreams.Quota.AccountAvailabilityStore
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.RoutingQuotaSnapshot

  @account_denial_types ~w(
    workspace_owner_credits_depleted
    workspace_member_credits_depleted
    workspace_owner_usage_limit_reached
    workspace_member_usage_limit_reached
  )

  @type t :: %{
          reached_type: String.t(),
          observed_at: DateTime.t(),
          reset_at: DateTime.t() | nil,
          source: String.t() | nil
        }

  @spec account_denial_types() :: [String.t()]
  def account_denial_types, do: @account_denial_types

  @spec active(RoutingQuotaSnapshot.t() | nil) :: t() | nil
  def active(%RoutingQuotaSnapshot{as_of: %DateTime{} = as_of} = snapshot) do
    snapshot
    |> RoutingQuotaSnapshot.time_visible_raw_windows()
    |> Enum.filter(&account_denial_window?/1)
    |> Enum.reject(&superseded?(&1, snapshot))
    |> latest_observation()
    |> in_force(as_of)
  end

  def active(_snapshot), do: nil

  defp account_denial_window?(%AccountQuotaWindow{metadata: %{"rate_limit_reached_type" => type}, observed_at: %DateTime{}}),
    do: type in @account_denial_types

  defp account_denial_window?(%AccountQuotaWindow{}), do: false

  # A later provider-attested `available` reading for the current credential
  # epoch is newer evidence about the same account and ends the denial.
  defp superseded?(%AccountQuotaWindow{observed_at: denied_at}, %RoutingQuotaSnapshot{
         availability: %AccountAvailabilityStore.Snapshot{state: :available, credential_epoch: epoch, observed_at: available_at},
         credential_epoch: epoch,
         as_of: as_of
       }) do
    DateTime.compare(available_at, denied_at) == :gt and DateTime.compare(available_at, as_of) != :gt
  end

  defp superseded?(%AccountQuotaWindow{}, %RoutingQuotaSnapshot{}), do: false

  defp latest_observation([]), do: []

  defp latest_observation(windows) do
    latest_at = windows |> Enum.map(& &1.observed_at) |> Enum.max(DateTime)
    Enum.filter(windows, &(DateTime.compare(&1.observed_at, latest_at) == :eq))
  end

  defp in_force([], _as_of), do: nil

  defp in_force([first | _rest] = windows, as_of) do
    reset_at =
      windows
      |> Enum.map(& &1.reset_at)
      |> Enum.filter(&match?(%DateTime{}, &1))
      |> Enum.min(DateTime, fn -> nil end)

    if in_force?(reset_at, first.observed_at, as_of) do
      %{
        reached_type: first.metadata["rate_limit_reached_type"],
        observed_at: first.observed_at,
        reset_at: reset_at,
        source: first.source
      }
    end
  end

  defp in_force?(%DateTime{} = reset_at, _observed_at, as_of), do: DateTime.compare(reset_at, as_of) == :gt

  defp in_force?(nil, observed_at, as_of),
    do: DateTime.diff(as_of, observed_at, :second) <= Evidence.freshness_ttl_seconds()
end
