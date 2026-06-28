defmodule CodexPooler.Accounting.RequestLogFacts do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request, RequestLogFact}
  alias CodexPooler.Catalog.PricingSnapshot
  alias CodexPooler.Repo

  @entry_settlement "settlement"
  @amount_recorded "recorded"
  @usage_known "usage_known"
  @type write_result :: :ok

  @spec record_request_created!(Request.t()) :: write_result()
  def record_request_created!(%Request{id: request_id}) do
    timestamp = now()

    Repo.insert_all(
      RequestLogFact,
      [
        %{
          request_id: request_id,
          inserted_at: timestamp,
          updated_at: timestamp
        }
      ],
      on_conflict: :nothing,
      conflict_target: :request_id
    )

    :ok
  end

  @spec record_attempt_written!(Attempt.t()) :: write_result()
  def record_attempt_written!(%Attempt{} = attempt) do
    timestamp = now()

    attrs = %{
      latest_attempt_id: attempt.id,
      latest_attempt_number: attempt.attempt_number,
      latest_attempt_status: attempt.status,
      latest_attempt_retryable: attempt.retryable,
      latest_upstream_status_code: attempt.upstream_status_code,
      latest_pool_upstream_assignment_id: attempt.pool_upstream_assignment_id,
      latest_upstream_identity_id: attempt.upstream_identity_id,
      latest_network_error_code: attempt.network_error_code,
      latest_latency_ms: attempt.latency_ms,
      updated_at: timestamp
    }

    Repo.insert_all(
      RequestLogFact,
      [
        attrs
        |> Map.put(:request_id, attempt.request_id)
        |> Map.put(:inserted_at, timestamp)
      ],
      on_conflict: attempt_conflict_query(attrs),
      conflict_target: :request_id
    )

    :ok
  end

  @spec record_settlement_written!(LedgerEntry.t() | map()) :: write_result()
  def record_settlement_written!(
        %LedgerEntry{entry_kind: @entry_settlement, amount_status: @amount_recorded} = entry
      ) do
    write_settlement_fact!(entry)
  end

  def record_settlement_written!(
        %{entry_kind: @entry_settlement, amount_status: @amount_recorded} = entry
      ) do
    write_settlement_fact!(entry)
  end

  def record_settlement_written!(%LedgerEntry{}), do: :ok
  def record_settlement_written!(%{}), do: :ok

  defp write_settlement_fact!(entry) do
    timestamp = now()
    attrs = settlement_attrs(entry, timestamp)

    Repo.insert_all(
      RequestLogFact,
      [
        attrs
        |> Map.put(:request_id, entry.request_id)
        |> Map.put(:inserted_at, timestamp)
      ],
      on_conflict: settlement_conflict_query(attrs),
      conflict_target: :request_id
    )

    :ok
  end

  defp settlement_attrs(entry, timestamp) do
    %{
      latest_settlement_entry_id: entry.id,
      latest_settlement_usage_status: entry.usage_status,
      latest_settlement_pricing_status: pricing_status(entry),
      latest_input_tokens: known_usage_value(entry, :input_tokens),
      latest_cached_input_tokens: known_usage_value(entry, :cached_input_tokens),
      latest_output_tokens: known_usage_value(entry, :output_tokens),
      latest_reasoning_tokens: known_usage_value(entry, :reasoning_tokens),
      latest_total_tokens: known_usage_value(entry, :total_tokens),
      latest_settled_cost_micros: settled_cost_micros(entry),
      latest_cached_input_cost_micros: cached_input_cost_micros(entry),
      latest_cached_input_token_micros: cached_input_token_micros(entry),
      latest_settlement_occurred_at: entry.occurred_at,
      latest_settlement_created_at: entry.created_at,
      updated_at: timestamp
    }
  end

  defp attempt_conflict_query(attrs) do
    attempt_id = Map.fetch!(attrs, :latest_attempt_id)
    attempt_number = Map.fetch!(attrs, :latest_attempt_number)
    updates = Map.to_list(attrs)

    from fact in RequestLogFact,
      where:
        is_nil(fact.latest_attempt_number) or
          ^attempt_number > fact.latest_attempt_number or
          ^attempt_id == fact.latest_attempt_id,
      update: [set: ^updates]
  end

  defp settlement_conflict_query(attrs) do
    entry_id = Map.fetch!(attrs, :latest_settlement_entry_id)
    occurred_at = Map.fetch!(attrs, :latest_settlement_occurred_at)
    created_at = Map.fetch!(attrs, :latest_settlement_created_at)
    updates = Map.to_list(attrs)

    from fact in RequestLogFact,
      where:
        is_nil(fact.latest_settlement_occurred_at) or
          ^entry_id == fact.latest_settlement_entry_id or
          ^occurred_at > fact.latest_settlement_occurred_at or
          (^occurred_at == fact.latest_settlement_occurred_at and
             ^created_at > fact.latest_settlement_created_at) or
          (^occurred_at == fact.latest_settlement_occurred_at and
             ^created_at == fact.latest_settlement_created_at and
             ^entry_id > fact.latest_settlement_entry_id),
      update: [set: ^updates]
  end

  defp pricing_status(%LedgerEntry{details: details}) when is_map(details),
    do: Map.get(details, "pricing_status")

  defp pricing_status(%{pricing_status: pricing_status}), do: pricing_status
  defp pricing_status(_entry), do: nil

  defp known_usage_value(entry, field) do
    if usage_known?(entry), do: Map.get(entry, field), else: nil
  end

  defp usage_known?(%{usage_status: @usage_known}), do: true
  defp usage_known?(_entry), do: false

  defp cached_input_token_micros(entry) do
    if usage_known?(entry), do: cached_input_token_micros_for_known_usage(entry), else: nil
  end

  defp cached_input_token_micros_for_known_usage(%{pricing_snapshot_id: nil}), do: nil

  defp cached_input_token_micros_for_known_usage(%{pricing_snapshot_id: pricing_snapshot_id}) do
    PricingSnapshot
    |> where([snapshot], snapshot.id == ^pricing_snapshot_id)
    |> select([snapshot], snapshot.cached_input_token_micros)
    |> Repo.one()
    |> integer_micros()
  end

  defp settled_cost_micros(entry) do
    if usage_known?(entry), do: settled_cost_micros_for_known_usage(entry), else: nil
  end

  defp settled_cost_micros_for_known_usage(%LedgerEntry{
         details: details,
         settled_cost_micros: settled_cost_micros
       })
       when is_map(details) do
    if Map.has_key?(details, "settled_cost_micros") do
      details |> Map.get("settled_cost_micros") |> integer_micros()
    else
      integer_micros(settled_cost_micros)
    end
  end

  defp settled_cost_micros_for_known_usage(%{settled_cost_micros: value}),
    do: integer_micros(value)

  defp cached_input_cost_micros(entry) do
    if usage_known?(entry), do: cached_input_cost_micros_for_known_usage(entry), else: nil
  end

  defp cached_input_cost_micros_for_known_usage(%LedgerEntry{details: details})
       when is_map(details),
       do: Map.get(details, "cached_input_cost_micros") |> integer_micros()

  defp cached_input_cost_micros_for_known_usage(%{cached_input_cost_micros: value}),
    do: integer_micros(value)

  defp cached_input_cost_micros_for_known_usage(_entry), do: nil

  defp integer_micros(nil), do: nil
  defp integer_micros(value) when is_integer(value), do: value

  defp integer_micros(value) when is_binary(value),
    do: value |> Decimal.new() |> integer_micros()

  defp integer_micros(%Decimal{} = value), do: value |> Decimal.round(0) |> Decimal.to_integer()

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
