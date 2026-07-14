defmodule CodexPooler.Upstreams.SavedResets.PostResetEvidence do
  @moduledoc """
  Decides whether fresh provider quota evidence confirms, reblocks, or leaves
  pending a redemption that already consumed a credit.

  This is the evidence gate for the self-healing convergence: a consumed reset
  stays `consumed_pending_probe` until the provider supplies *fresh, explicitly
  covered, parse-safe account evidence observed at or after the consume time*.

    * `:confirmed` — a fresh post-consume account window is usable; the identity
      recovered and normal evidence-based routing resumes.
    * `:reblocked` — a fresh post-consume account window is genuinely exhausted;
      the reset did not clear the block.
    * `:pending` — no qualifying fresh account evidence (the provider omitted or
      nulled the account window, or only stale/inferred evidence exists). Nothing
      transitions; the old exhausted row is preserved untouched.

  Because an omitted account descriptor leaves the previously stored window with
  its *old* `observed_at`, the `observed_at >= consumed_at` filter alone keeps
  that stale evidence from confirming — no fabricated quota, fail-closed.

  Pure: it never touches the repo and reuses the routing window classifiers so
  "usable" and "exhausted" mean exactly what routing means.
  """

  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows

  @account_quota_key "account"
  # A window carrying "unknown" precision was not parsed into a trustworthy
  # descriptor; everything else (observed/authoritative/inferred) is explicit
  # enough — the descriptor was present in the provider payload.
  @unparseable_precision "unknown"

  @type classification :: :confirmed | :reblocked | :pending

  @doc """
  Classifies the account-level evidence for an identity that consumed a credit
  at `consumed_at`. `windows` are that identity's stored account quota windows.

  Fail-closed: a single fresh exhausted account window reblocks (it would still
  exclude the identity from routing), and confirmation requires every fresh
  account window to be usable.
  """
  @spec classify([AccountQuotaWindow.t()], DateTime.t(), DateTime.t()) :: classification()
  def classify(windows, %DateTime{} = consumed_at, %DateTime{} = now) when is_list(windows) do
    fresh_account_windows =
      windows
      |> Enum.filter(&account_window?/1)
      |> Enum.filter(&parse_safe?/1)
      |> Enum.filter(&observed_at_or_after?(&1, consumed_at))

    cond do
      fresh_account_windows == [] -> :pending
      Enum.any?(fresh_account_windows, &exhausted?(&1, now)) -> :reblocked
      Enum.all?(fresh_account_windows, &Windows.usable_window?(&1, now)) -> :confirmed
      true -> :pending
    end
  end

  defp account_window?(%AccountQuotaWindow{quota_key: @account_quota_key}), do: true
  defp account_window?(_window), do: false

  defp parse_safe?(%AccountQuotaWindow{source_precision: @unparseable_precision}), do: false
  defp parse_safe?(%AccountQuotaWindow{}), do: true

  defp observed_at_or_after?(
         %AccountQuotaWindow{observed_at: %DateTime{} = observed_at},
         consumed_at
       ),
       do: DateTime.compare(observed_at, consumed_at) != :lt

  defp observed_at_or_after?(_window, _consumed_at), do: false

  defp exhausted?(%AccountQuotaWindow{} = window, now),
    do: "exhausted" in Windows.routing_window_reason_codes(window, now)
end
