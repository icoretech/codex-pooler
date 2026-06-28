defmodule CodexPooler.Admin.Stats.SourceSummary do
  @moduledoc false

  @spec build([map()], [map()], [map()], [map()], [map()], map(), term(), non_neg_integer()) ::
          map()
  def build(
        requests,
        attempts,
        settlements,
        daily_rollups,
        turns,
        activity_counts,
        model_usage_source,
        model_usage_rows
      ) do
    %{
      requests: length(requests),
      attempts: length(attempts),
      settlements: length(settlements),
      daily_rollups: length(daily_rollups),
      codex_turns: length(turns),
      audit_events: activity_counts.audit_events,
      jobs: activity_counts.jobs,
      model_usage_source: model_usage_source,
      model_usage_rows: model_usage_rows,
      usage_source:
        if(daily_rollups == [], do: :raw_ledger_fallback, else: :raw_ledger_with_rollup_context)
    }
  end
end
