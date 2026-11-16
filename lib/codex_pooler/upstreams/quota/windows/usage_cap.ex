defmodule CodexPooler.Upstreams.Quota.Windows.UsageCap do
  @moduledoc """
  Reads whether an account has reached its operator usage cap.

  An operator can keep part of an account's quota for its owner by setting
  `usage_cap_percent` (1 to 99). The cap is judged on the account's long
  window: its weekly window, or, on a plan that reports no weekly window, its
  30-day window. These are the same two windows saved-reset recovery treats as
  the account's long window (`WindowClassifier.saved_reset_window?/1`). The
  5-hour window never caps. The account is capped while that window, as routing
  selects it, reads `used_percent` at or above the cap and its `reset_at` is
  still ahead.

  Freshness is not required: inside one cycle the provider's usage only rises,
  so a stale reading at or above the cap stays true until that window resets,
  and a saved reset that starts a new cycle replaces the window the same way
  `ResetRecoverySelection` does for routing.

  An account whose long window cannot be read (no weekly or 30-day window, as on
  an account the provider attests without reporting windows, a window without
  `used_percent` or `reset_at`, or one whose reset has passed) is
  `:unmeasurable`: the cap has no effect on it until the provider reports such
  a window, and the admin card says so. The cap only holds back capacity the
  provider has shown, and quota eligibility already decides what unknown
  evidence means.

  This never changes what "exhausted" means: route filtering applies it as its
  own first step (`CodexPooler.Gateway.Routing.CandidateEligibility.UsageCap`).
  """

  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.RoutingQuotaSnapshot
  alias CodexPooler.Upstreams.Quota.Windows.ResetRecoverySelection
  alias CodexPooler.Upstreams.Quota.Windows.Routing
  alias CodexPooler.Upstreams.Quota.WindowSelector

  @type long_window_kind :: :weekly | :monthly
  @type t :: %{
          cap_percent: 1..99,
          used_percent: Decimal.t(),
          reset_at: DateTime.t(),
          window_kind: long_window_kind(),
          window: AccountQuotaWindow.t()
        }
  @type state :: :none | :unmeasurable | {:below, long_window_kind()} | {:reached, long_window_kind()}

  @doc """
  The cap in force for the snapshot's identity, or `nil` when the account is
  below its cap, has no cap, or has no long-window reading to judge it on.
  """
  @spec active(RoutingQuotaSnapshot.t() | nil) :: t() | nil
  def active(snapshot) do
    case evaluate(snapshot) do
      {:reached, cap} -> cap
      _other -> nil
    end
  end

  @doc """
  The cap's state for display: `:none` without a cap, `:unmeasurable` when the
  long window cannot be read, otherwise below or reached on the weekly or
  30-day window.
  """
  @spec state(RoutingQuotaSnapshot.t() | nil) :: state()
  def state(snapshot) do
    case evaluate(snapshot) do
      {:reached, cap} -> {:reached, cap.window_kind}
      {:below, kind} -> {:below, kind}
      other -> other
    end
  end

  @doc """
  The long window the cap is judged on, as routing selects it at the snapshot's
  instant: the weekly account window, or the 30-day one when there is no weekly
  window. `nil` when the account reports neither.
  """
  @spec long_window(RoutingQuotaSnapshot.t()) :: {long_window_kind(), AccountQuotaWindow.t()} | nil
  def long_window(%RoutingQuotaSnapshot{} = snapshot) do
    routing_windows =
      snapshot
      |> RoutingQuotaSnapshot.time_visible_raw_windows()
      |> ResetRecoverySelection.reject_recovered_prior_cycles(snapshot)
      |> Routing.selection_data_from_windows(at: snapshot.as_of, account_only: true)
      |> Map.fetch!(:routing_windows)

    case WindowSelector.best_account_window(routing_windows, :weekly_secondary, snapshot.as_of) do
      %AccountQuotaWindow{} = weekly ->
        {:weekly, weekly}

      nil ->
        case WindowSelector.best_account_window(routing_windows, :monthly_primary, snapshot.as_of) do
          %AccountQuotaWindow{} = monthly -> {:monthly, monthly}
          nil -> nil
        end
    end
  end

  defp evaluate(%RoutingQuotaSnapshot{usage_cap_percent: cap} = snapshot) when is_integer(cap) and cap >= 1 and cap <= 99 do
    with {kind, %AccountQuotaWindow{} = window} <- long_window(snapshot),
         %Decimal{} = used_percent <- window.used_percent,
         %DateTime{} = reset_at <- window.reset_at,
         :gt <- DateTime.compare(reset_at, snapshot.as_of) do
      if Decimal.compare(used_percent, Decimal.new(cap)) == :lt,
        do: {:below, kind},
        else: {:reached, %{cap_percent: cap, used_percent: used_percent, reset_at: reset_at, window_kind: kind, window: window}}
    else
      _unreadable -> :unmeasurable
    end
  end

  defp evaluate(_snapshot), do: :none
end
