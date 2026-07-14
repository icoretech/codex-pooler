defmodule CodexPooler.Upstreams.Quota.WindowSelector do
  @moduledoc false

  alias CodexPooler.Quotas.{Evidence, WindowClassifier}
  alias CodexPooler.Upstreams.Quota

  @fresh "fresh"

  @spec best_account_window(
          [Quota.AccountQuotaWindow.t()],
          WindowClassifier.descriptor(),
          DateTime.t()
        ) :: Quota.AccountQuotaWindow.t() | nil
  def best_account_window(windows, descriptor, as_of \\ DateTime.utc_now())

  def best_account_window(windows, descriptor, %DateTime{} = as_of) when is_list(windows) do
    windows
    |> Enum.filter(&(WindowClassifier.classify(&1) == descriptor))
    |> best_by_score(as_of)
  end

  @spec best_account_primary_variant([Quota.AccountQuotaWindow.t()], DateTime.t()) ::
          Quota.AccountQuotaWindow.t() | nil
  def best_account_primary_variant(windows, as_of \\ DateTime.utc_now())

  def best_account_primary_variant(windows, %DateTime{} = as_of) when is_list(windows) do
    windows
    |> Enum.filter(&(WindowClassifier.primary_5h?(&1) or WindowClassifier.monthly_primary?(&1)))
    |> best_by_score(as_of, &primary_variant_rank/1)
  end

  @spec logical_windows([Quota.AccountQuotaWindow.t()], DateTime.t()) ::
          [Quota.AccountQuotaWindow.t()]
  def logical_windows(windows, as_of \\ DateTime.utc_now())

  def logical_windows(windows, %DateTime{} = as_of) when is_list(windows) do
    windows
    |> Enum.reject(&future_observation?(&1, as_of))
    |> Enum.map(&normalize_legacy_weekly_primary/1)
    |> Enum.group_by(&logical_key/1)
    |> Enum.map(fn {_logical_key, candidates} ->
      candidates
      |> reject_prior_cycle_windows(as_of)
      |> best_by_score(as_of)
    end)
    |> Enum.sort_by(&logical_sort_key/1)
  end

  # A fresh sibling whose reset lies a full margin beyond a STALE row's reset
  # proves the provider started a new cycle after that row was last observed:
  # rows still describing the ended cycle must not compete for selection, or
  # their pessimistic pressure keeps winning the merge and masks the restart
  # from operators and routing alike (observed live: a stale rate-limit-event
  # row at 94 percent from the ended cycle displayed as 6 percent remaining
  # while the account was genuinely unused). Fresh rows are never rejected —
  # same-cycle resets legitimately drift up to the window's own duration across
  # provider surfaces — and groups without any fresh reset-bearing row are left
  # untouched, so an all-stale exhausted group keeps its fail-closed pessimism.
  @prior_cycle_margin_seconds 60 * 60

  defp reject_prior_cycle_windows(candidates, as_of) do
    fresh_resets =
      for window <- candidates,
          fresh?(window, as_of),
          match?(%DateTime{}, window.reset_at),
          do: window.reset_at

    case fresh_resets do
      [] ->
        candidates

      resets ->
        newest = Enum.max(resets, DateTime)

        Enum.reject(candidates, fn window ->
          not fresh?(window, as_of) and
            match?(%DateTime{}, window.reset_at) and
            DateTime.diff(newest, window.reset_at, :second) > @prior_cycle_margin_seconds
        end)
    end
  end

  # Evidence observed after the evaluation instant did not exist in that form
  # yet: a historical `as_of` must never rank, select, or supersede against
  # rows from its future. This is strictly non-future — the clock-skew
  # tolerance applies to freshness classification, not to existence, so even
  # a row observed one second past `as_of` is excluded.
  defp future_observation?(
         %Quota.AccountQuotaWindow{observed_at: %DateTime{} = observed_at},
         %DateTime{} = as_of
       ) do
    DateTime.compare(observed_at, as_of) == :gt
  end

  defp future_observation?(_window, _as_of), do: false

  # Rows persisted before the parsers remapped the provider's weekly-duration
  # primary slot — or recreated by a not-yet-upgraded replica during a rolling
  # update — carry the weekly limit under a `primary`/10080 identity. They are
  # the same logical weekly window as the normalized `secondary`/10080 rows,
  # so fold them read-side: selection, routing, and operator projections then
  # see a single weekly window regardless of whether the one-shot purge
  # migration has run or been raced by an old writer.
  defp normalize_legacy_weekly_primary(
         %Quota.AccountQuotaWindow{window_kind: "primary", window_minutes: 10_080} = window
       ),
       do: %{window | window_kind: "secondary"}

  defp normalize_legacy_weekly_primary(window), do: window

  @spec logical_key(Quota.AccountQuotaWindow.t()) :: tuple()
  def logical_key(%Quota.AccountQuotaWindow{} = window) do
    window
    |> Evidence.logical_window_key()
    |> normalize_scope_dimensions()
    |> normalize_spark_alias()
  end

  defp normalize_scope_dimensions(
         {"model", family, model, _upstream_model, quota_key, kind, minutes}
       ),
       do: {"model", family, model, nil, quota_key, kind, minutes}

  defp normalize_scope_dimensions(
         {"upstream_model", family, _model, upstream_model, quota_key, kind, minutes}
       ),
       do: {"upstream_model", family, nil, upstream_model, quota_key, kind, minutes}

  defp normalize_scope_dimensions(logical_key), do: logical_key

  defp normalize_spark_alias({scope, family, model, upstream_model, quota_key, kind, minutes})
       when quota_key in ["codex_bengalfox", "gpt_5_3_codex_spark"] do
    {scope, family, model, upstream_model, "codex_spark", kind, minutes}
  end

  defp normalize_spark_alias(logical_key), do: logical_key

  defp best_by_score(windows, as_of, extra_rank \\ fn _window -> 0 end) do
    Enum.max_by(
      windows,
      &selection_score(&1, as_of, extra_rank),
      fn -> nil end
    )
  end

  defp selection_score(%Quota.AccountQuotaWindow{} = window, as_of, extra_rank) do
    {
      usable_rank(window, as_of),
      extra_rank.(window),
      measurement_rank(window),
      pressure_rank(window),
      fresh_rank(window, as_of),
      reset_rank(window),
      source_precision_rank(window.source_precision),
      window.merge_precedence || 0,
      timestamp_rank(window.observed_at),
      timestamp_rank(window.last_sync_at),
      timestamp_rank(window.updated_at),
      timestamp_rank(window.reset_at),
      to_string(window.id || "")
    }
  end

  defp pressure_rank(%Quota.AccountQuotaWindow{used_percent: %Decimal{} = used_percent}),
    do: used_percent

  defp pressure_rank(%Quota.AccountQuotaWindow{}), do: Decimal.new(-1)

  defp logical_sort_key(%Quota.AccountQuotaWindow{} = window) do
    {window.quota_key, window.window_kind, window.window_minutes, window.quota_scope,
     window.quota_family, window.model || "", window.upstream_model || ""}
  end

  defp usable_rank(%Quota.AccountQuotaWindow{} = window, as_of) do
    if fresh?(window, as_of) and reset_bearing?(window) and not expired?(window, as_of) and
         not exhausted?(window) do
      1
    else
      0
    end
  end

  defp fresh_rank(%Quota.AccountQuotaWindow{} = window, as_of) do
    if fresh?(window, as_of), do: 1, else: 0
  end

  defp measurement_rank(%Quota.AccountQuotaWindow{active_limit: active_limit, credits: credits})
       when is_integer(active_limit) and active_limit > 0 and is_integer(credits),
       do: 4

  defp measurement_rank(%Quota.AccountQuotaWindow{used_percent: %Decimal{} = used_percent}) do
    if Decimal.compare(used_percent, Decimal.new(0)) == :gt, do: 3, else: 1
  end

  defp measurement_rank(%Quota.AccountQuotaWindow{credits: credits})
       when is_integer(credits) and credits > 0,
       do: 2

  defp measurement_rank(%Quota.AccountQuotaWindow{}), do: 0

  defp reset_rank(%Quota.AccountQuotaWindow{} = window) do
    if reset_bearing?(window), do: 1, else: 0
  end

  defp primary_variant_rank(%Quota.AccountQuotaWindow{} = window) do
    case WindowClassifier.classify(window) do
      :monthly_primary -> 2
      :primary_5h -> 1
      _descriptor -> 0
    end
  end

  defp source_precision_rank("authoritative"), do: 4
  defp source_precision_rank("observed"), do: 3
  defp source_precision_rank("inferred"), do: 2
  defp source_precision_rank("unknown"), do: 1
  defp source_precision_rank(_precision), do: 0

  defp timestamp_rank(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :microsecond)

  defp timestamp_rank(%NaiveDateTime{} = datetime),
    do: datetime |> DateTime.from_naive!("Etc/UTC") |> timestamp_rank()

  defp timestamp_rank(_datetime), do: 0

  defp fresh?(%Quota.AccountQuotaWindow{} = window, as_of) do
    Evidence.current_freshness_state(window, as_of) == @fresh
  end

  defp reset_bearing?(%Quota.AccountQuotaWindow{} = window), do: Evidence.reset_bearing?(window)
  defp expired?(%Quota.AccountQuotaWindow{} = window, as_of), do: Evidence.expired?(window, as_of)

  defp exhausted?(%Quota.AccountQuotaWindow{used_percent: %Decimal{} = used_percent}) do
    Decimal.compare(used_percent, Decimal.new(100)) != :lt
  end

  defp exhausted?(%Quota.AccountQuotaWindow{}), do: false
end
