defmodule CodexPoolerWeb.Admin.UpstreamQuotaReadiness do
  @moduledoc """
  Shared admin projection for account-level upstream quota readiness.
  """

  alias CodexPooler.Upstreams.Quota
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows

  @account_quota_key "account"
  @account_quota_scope "account"

  @type window :: Quota.AccountQuotaWindow.t()
  @type tone :: :success | :warning | :error
  @type t :: %{
          required(:state) => String.t(),
          required(:label) => String.t(),
          required(:tone) => tone(),
          required(:border_class) => String.t(),
          required(:routing_ready_now?) => boolean(),
          required(:reason_codes) => [String.t()],
          required(:primary_window) => window() | nil,
          required(:weekly_window) => window() | nil
        }

  @spec from_windows([window()], DateTime.t()) :: t()
  def from_windows(windows, as_of \\ DateTime.utc_now()) when is_list(windows) do
    account_windows = Enum.filter(windows, &account_window?/1)

    eligibility =
      QuotaWindows.routing_quota_eligibility_from_windows(account_windows, at: as_of)

    primary_window = get_in(eligibility, [:selection, :primary])
    weekly_window = get_in(eligibility, [:selection, :secondary])
    reason_codes = reason_codes(eligibility, account_windows, as_of)
    state = readiness_state(account_windows, eligibility, [primary_window, weekly_window], as_of)

    state
    |> state_projection()
    |> Map.merge(%{
      reason_codes: reason_codes,
      primary_window: primary_window,
      weekly_window: weekly_window
    })
  end

  @spec readiness_state([window()], map(), [window() | nil], DateTime.t()) :: String.t()
  defp readiness_state([], _eligibility, _selected_windows, _as_of), do: "missing_evidence"

  defp readiness_state(_account_windows, %{routing_state: :precise}, _selected_windows, _as_of),
    do: "ready"

  defp readiness_state(
         _account_windows,
         %{routing_state: :weekly_only_probe},
         _selected_windows,
         _as_of
       ),
       do: "weekly_only_probe"

  defp readiness_state(account_windows, eligibility, selected_windows, as_of) do
    cond do
      exhausted_quota?(account_windows, eligibility, as_of) ->
        "exhausted"

      stale_selected_window?(selected_windows, as_of) ->
        "stale"

      missing_evidence?(account_windows, eligibility, as_of) ->
        "missing_evidence"

      true ->
        "blocked"
    end
  end

  @spec state_projection(String.t()) :: t()
  defp state_projection("ready") do
    %{
      state: "ready",
      label: "Quota ready",
      tone: :success,
      border_class: "border-l-success",
      routing_ready_now?: true,
      reason_codes: [],
      primary_window: nil,
      weekly_window: nil
    }
  end

  defp state_projection("weekly_only_probe") do
    %{
      state: "weekly_only_probe",
      label: "Weekly quota probe",
      tone: :warning,
      border_class: "border-l-warning",
      routing_ready_now?: true,
      reason_codes: [],
      primary_window: nil,
      weekly_window: nil
    }
  end

  defp state_projection("exhausted") do
    %{
      state: "exhausted",
      label: "Quota exhausted",
      tone: :error,
      border_class: "border-l-error",
      routing_ready_now?: false,
      reason_codes: [],
      primary_window: nil,
      weekly_window: nil
    }
  end

  defp state_projection("stale") do
    %{
      state: "stale",
      label: "Quota refresh needed",
      tone: :warning,
      border_class: "border-l-warning",
      routing_ready_now?: false,
      reason_codes: [],
      primary_window: nil,
      weekly_window: nil
    }
  end

  defp state_projection("missing_evidence") do
    %{
      state: "missing_evidence",
      label: "Quota missing",
      tone: :warning,
      border_class: "border-l-warning",
      routing_ready_now?: false,
      reason_codes: [],
      primary_window: nil,
      weekly_window: nil
    }
  end

  defp state_projection("blocked") do
    %{
      state: "blocked",
      label: "Quota blocked",
      tone: :warning,
      border_class: "border-l-warning",
      routing_ready_now?: false,
      reason_codes: [],
      primary_window: nil,
      weekly_window: nil
    }
  end

  @spec exhausted_quota?([window()], map(), DateTime.t()) :: boolean()
  defp exhausted_quota?(account_windows, eligibility, as_of) do
    exclusion_code?(eligibility, "quota_weekly_exhausted") or
      account_window_reason?(account_windows, as_of, "exhausted")
  end

  @spec stale_selected_window?([window() | nil], DateTime.t()) :: boolean()
  defp stale_selected_window?(selected_windows, as_of) do
    selected_windows
    |> Enum.reject(&is_nil/1)
    |> Enum.any?(fn window ->
      reasons = QuotaWindows.routing_window_reason_codes(window, as_of)
      "not_fresh" in reasons or "expired" in reasons
    end)
  end

  @spec missing_evidence?([window()], map(), DateTime.t()) :: boolean()
  defp missing_evidence?(account_windows, eligibility, as_of) do
    exclusion_code?(eligibility, "quota_account_primary_missing") or
      exclusion_code?(eligibility, "quota_evidence_missing") or
      account_window_reason?(account_windows, as_of, "reset_missing")
  end

  @spec reason_codes(map(), [window()], DateTime.t()) :: [String.t()]
  defp reason_codes(eligibility, account_windows, as_of) do
    exclusions = Map.get(eligibility, :exclusions, [])
    warnings = Map.get(eligibility, :warnings, [])

    exclusion_codes = Enum.map(exclusions, &Map.get(&1, :code))
    warning_codes = Enum.map(warnings, &Map.get(&1, :code))

    exclusion_reason_codes = Enum.flat_map(exclusions, &Map.get(&1, :reason_codes, []))

    window_reason_codes =
      account_windows
      |> Enum.flat_map(&QuotaWindows.routing_window_reason_codes(&1, as_of))
      |> Enum.reject(&(&1 == "unknown_unusable"))

    [exclusion_codes, exclusion_reason_codes, warning_codes, window_reason_codes]
    |> List.flatten()
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  @spec exclusion_code?(map(), String.t()) :: boolean()
  defp exclusion_code?(eligibility, code) do
    eligibility
    |> Map.get(:exclusions, [])
    |> Enum.any?(&(Map.get(&1, :code) == code))
  end

  @spec account_window_reason?([window()], DateTime.t(), String.t()) :: boolean()
  defp account_window_reason?(account_windows, as_of, reason) do
    Enum.any?(account_windows, fn window ->
      reason in QuotaWindows.routing_window_reason_codes(window, as_of)
    end)
  end

  @spec account_window?(term()) :: boolean()
  defp account_window?(%{} = window) do
    Map.get(window, :quota_key) == @account_quota_key and
      Map.get(window, :quota_scope) == @account_quota_scope
  end

  defp account_window?(_window), do: false
end
