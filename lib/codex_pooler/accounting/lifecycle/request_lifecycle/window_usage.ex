defmodule CodexPooler.Accounting.RequestLifecycle.WindowUsage do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounting.{APIKeyUsageBucket, LedgerEntry}
  alias CodexPooler.Repo

  @entry_release "release"
  @entry_settlement "settlement"
  @amount_recorded "recorded"
  @usage_known "usage_known"

  @type usage_window :: atom()
  @type window_usage :: %{
          required(:effective_request_count) => integer(),
          required(:effective_total_tokens) => integer(),
          required(:effective_cost_micros) => Decimal.t()
        }

  @spec window_usages(Ecto.UUID.t(), keyword(DateTime.t()) | %{usage_window() => DateTime.t()}) ::
          %{
            usage_window() => window_usage()
          }
  def window_usages(api_key_id, windows) do
    windows = normalize_windows(windows)

    windows
    |> Enum.reject(fn {_window, since} -> is_nil(since) end)
    |> Map.new(fn {window, since} -> {window, window_usage(api_key_id, since)} end)
  end

  defp window_usage(api_key_id, since) do
    bucket_since = next_minute_boundary(since)
    bucket_usage = bucket_window_usage_query(api_key_id, bucket_since)

    if DateTime.compare(since, bucket_since) == :eq do
      Repo.one(bucket_usage) || empty_window_usage()
    else
      combined_window_usage(api_key_id, since, bucket_since, bucket_usage)
    end
  end

  defp combined_window_usage(api_key_id, since, bucket_since, bucket_usage) do
    # Keep the leading ledger edge and complete buckets in one snapshot so a
    # concurrent settlement correction cannot be observed half-applied.
    Repo.one(
      from e in LedgerEntry,
        right_join: bucket in subquery(bucket_usage),
        on:
          e.api_key_id == ^api_key_id and e.amount_status == @amount_recorded and
            e.occurred_at >= ^since and e.occurred_at < ^bucket_since,
        select: %{
          effective_request_count:
            type(
              fragment(
                """
                (
                  COALESCE(
                    SUM(CASE WHEN ? = ? THEN -COALESCE(?, 0) ELSE COALESCE(?, 0) END),
                    0
                  ) +
                  COALESCE(MAX(?), 0)
                )::bigint
                """,
                e.entry_kind,
                ^@entry_release,
                e.request_count,
                e.request_count,
                bucket.effective_request_count
              ),
              :integer
            ),
          effective_total_tokens:
            type(
              fragment(
                """
                (
                  COALESCE(
                    SUM(
                      CASE
                        WHEN ? = ? THEN -COALESCE(?, 0)
                        WHEN ? = ? AND ? = ? THEN COALESCE(?, 0)
                        WHEN ? = ? THEN 0
                        ELSE COALESCE(?, 0)
                      END
                    ),
                    0
                  ) +
                  COALESCE(MAX(?), 0)
                )::bigint
                """,
                e.entry_kind,
                ^@entry_release,
                e.total_tokens,
                e.entry_kind,
                ^@entry_settlement,
                e.usage_status,
                ^@usage_known,
                e.total_tokens,
                e.entry_kind,
                ^@entry_settlement,
                e.total_tokens,
                bucket.effective_total_tokens
              ),
              :integer
            ),
          effective_cost_micros:
            type(
              fragment(
                """
                COALESCE(
                  SUM(
                    CASE
                      WHEN ? = ? THEN -COALESCE(?, 0)
                      WHEN ? = ? AND ? = ? THEN COALESCE(?, 0)
                      WHEN ? = ? THEN 0
                      ELSE COALESCE(?, 0)
                    END
                  ),
                  0
                ) +
                COALESCE(MAX(?), 0)
                """,
                e.entry_kind,
                ^@entry_release,
                e.estimated_cost_micros,
                e.entry_kind,
                ^@entry_settlement,
                e.usage_status,
                ^@usage_known,
                e.settled_cost_micros,
                e.entry_kind,
                ^@entry_settlement,
                e.estimated_cost_micros,
                bucket.effective_cost_micros
              ),
              :decimal
            )
        }
    ) || empty_window_usage()
  end

  defp bucket_window_usage_query(api_key_id, since) do
    from bucket in APIKeyUsageBucket,
      where: bucket.api_key_id == ^api_key_id and bucket.bucket_started_at >= ^since,
      select: %{
        effective_request_count:
          type(
            fragment("COALESCE(SUM(?), 0)::bigint", bucket.effective_request_count),
            :integer
          ),
        effective_total_tokens:
          type(
            fragment("COALESCE(SUM(?), 0)::bigint", bucket.effective_total_tokens),
            :integer
          ),
        effective_cost_micros:
          type(fragment("COALESCE(SUM(?), 0)", bucket.effective_cost_micros), :decimal)
      }
  end

  defp normalize_windows(windows) when is_list(windows), do: Map.new(windows)
  defp normalize_windows(windows) when is_map(windows), do: windows

  defp next_minute_boundary(%DateTime{} = timestamp) do
    minute_start = %{timestamp | second: 0, microsecond: {0, 6}}

    if DateTime.compare(timestamp, minute_start) == :eq do
      minute_start
    else
      DateTime.add(minute_start, 1, :minute)
    end
  end

  defp empty_window_usage do
    %{
      effective_request_count: 0,
      effective_total_tokens: 0,
      effective_cost_micros: Decimal.new(0)
    }
  end
end
