defmodule CodexPooler.Accounting.RequestLifecycle.LedgerEntries do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.Accounting.PricingResolution
  alias CodexPooler.Repo

  @entry_reservation "reservation"
  @entry_release "release"
  @entry_settlement "settlement"
  @amount_recorded "recorded"
  @usage_pending "usage_pending"
  @usage_known "usage_known"
  @source_event_conflict_target {:unsafe_fragment,
                                 "(source_event_id) WHERE source_event_id IS NOT NULL"}

  @type cost :: Decimal.t() | nil
  @type estimate :: %{
          required(:input_tokens) => non_neg_integer() | nil,
          required(:cached_input_tokens) => non_neg_integer() | nil,
          required(:output_tokens) => non_neg_integer() | nil,
          required(:reasoning_tokens) => non_neg_integer() | nil,
          required(:total_tokens) => non_neg_integer() | nil,
          required(:estimated_cost_micros) => cost(),
          required(:strategy) => String.t() | atom() | nil
        }
  @type ledger_attrs :: %{
          required(:request_id) => Ecto.UUID.t(),
          required(:pool_id) => Ecto.UUID.t(),
          required(:api_key_id) => Ecto.UUID.t(),
          required(:model_id) => Ecto.UUID.t() | nil,
          required(:entry_kind) => String.t(),
          required(:amount_status) => String.t(),
          required(:usage_status) => String.t(),
          required(:transport) => String.t(),
          required(:currency_code) => String.t(),
          required(:request_count) => pos_integer(),
          required(:estimated_cost_micros) => Decimal.t(),
          required(:settled_cost_micros) => Decimal.t(),
          required(:source_event_id) => String.t(),
          required(:occurred_at) => DateTime.t(),
          required(:created_at) => DateTime.t(),
          required(:details) => map(),
          optional(atom()) => term()
        }
  @type pricing :: map()
  @type settlement_context :: %{
          required(:response_status_code) => non_neg_integer() | nil,
          required(:retry_count) => non_neg_integer(),
          required(:settled_cost) => cost()
        }
  @type usage :: %{
          required(:status) => String.t(),
          required(:input_tokens) => non_neg_integer(),
          required(:cached_input_tokens) => non_neg_integer(),
          required(:output_tokens) => non_neg_integer(),
          required(:reasoning_tokens) => non_neg_integer(),
          required(:total_tokens) => non_neg_integer(),
          required(:source) => String.t(),
          required(:recorded_at) => DateTime.t(),
          optional(atom()) => term()
        }
  @type settlement_state :: %{
          required(:pricing) => pricing(),
          required(:usage) => usage(),
          required(:context) => settlement_context(),
          required(:timestamp) => DateTime.t()
        }
  @type release_state :: %{
          required(:pricing) => pricing(),
          required(:usage) => usage(),
          required(:timestamp) => DateTime.t()
        }
  @type create_status :: :inserted | :existing
  @type usage_window :: atom()
  @type window_usage :: %{
          required(:effective_request_count) => integer(),
          required(:effective_total_tokens) => integer(),
          required(:effective_cost_micros) => Decimal.t()
        }

  @spec create_or_get!(map()) :: LedgerEntry.t()
  def create_or_get!(attrs) do
    attrs
    |> create_or_get_with_status!()
    |> elem(0)
  end

  @spec create_or_get_with_status!(map()) :: {LedgerEntry.t(), create_status()}
  def create_or_get_with_status!(attrs) do
    source_event_id = attrs.source_event_id
    attrs = Map.put_new(attrs, :id, Ecto.UUID.generate())

    case Repo.insert_all(LedgerEntry, [attrs],
           on_conflict: :nothing,
           conflict_target: @source_event_conflict_target,
           returning: true
         ) do
      {1, [%LedgerEntry{} = entry]} ->
        {entry, :inserted}

      {1, [entry]} when is_map(entry) ->
        {struct(LedgerEntry, entry), :inserted}

      {0, []} ->
        {Repo.get_by!(LedgerEntry, source_event_id: source_event_id), :existing}
    end
  end

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
    Repo.one(
      from e in LedgerEntry,
        where:
          e.api_key_id == ^api_key_id and e.amount_status == @amount_recorded and
            e.occurred_at >= ^since,
        select: %{
          effective_request_count:
            type(
              fragment(
                "COALESCE(SUM(CASE WHEN ? = ? THEN -COALESCE(?, 0) ELSE COALESCE(?, 0) END), 0)::bigint",
                e.entry_kind,
                ^@entry_release,
                e.request_count,
                e.request_count
              ),
              :integer
            ),
          effective_total_tokens:
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
                e.total_tokens
              ),
              :integer
            ),
          effective_cost_micros:
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
              )
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
              e.estimated_cost_micros
            )
        }
    ) || empty_window_usage()
  end

  @spec reservation_attrs(
          Request.t(),
          CodexPooler.Access.auth_context(),
          APIKey.t(),
          pricing(),
          estimate(),
          DateTime.t()
        ) :: ledger_attrs()
  def reservation_attrs(request, auth, api_key, pricing, estimate, timestamp) do
    snapshot = pricing.snapshot

    %{
      request_id: request.id,
      pricing_snapshot_id: snapshot && snapshot.id,
      pool_id: request.pool_id,
      api_key_id: request.api_key_id,
      model_id: request.model_id,
      entry_kind: @entry_reservation,
      amount_status: @amount_recorded,
      usage_status: @usage_pending,
      transport: request.transport,
      currency_code: (snapshot && snapshot.currency_code) || "USD",
      input_tokens: positive_or_nil(estimate.input_tokens),
      cached_input_tokens: positive_or_nil(estimate.cached_input_tokens),
      output_tokens: positive_or_nil(estimate.output_tokens),
      reasoning_tokens: positive_or_nil(estimate.reasoning_tokens),
      total_tokens: positive_or_nil(estimate.total_tokens),
      request_count: 1,
      estimated_cost_micros: ledger_cost_value(estimate.estimated_cost_micros),
      settled_cost_micros: Decimal.new(0),
      source_event_id: reservation_source_event_id(request.id),
      occurred_at: timestamp,
      created_at: timestamp,
      details:
        %{
          "strategy" => estimate.strategy,
          "key_prefix" => Map.get(auth, :key_prefix) || api_key.key_prefix
        }
        |> Map.merge(PricingResolution.details(pricing))
    }
  end

  @spec settlement_attrs(Request.t(), Attempt.t(), LedgerEntry.t(), settlement_state()) ::
          ledger_attrs()
  def settlement_attrs(%Request{} = request, %Attempt{} = attempt, reservation, state) do
    snapshot = state.pricing.snapshot
    settled_cost = Map.fetch!(state.context, :settled_cost)

    %{
      request_id: request.id,
      attempt_id: attempt.id,
      pricing_snapshot_id: snapshot && snapshot.id,
      pool_id: request.pool_id,
      api_key_id: request.api_key_id,
      pool_upstream_assignment_id: attempt.pool_upstream_assignment_id,
      upstream_identity_id: attempt.upstream_identity_id,
      model_id: request.model_id,
      entry_kind: @entry_settlement,
      amount_status: @amount_recorded,
      usage_status: state.usage.status,
      transport: request.transport,
      currency_code: (snapshot && snapshot.currency_code) || reservation.currency_code,
      input_tokens: positive_or_nil(state.usage.input_tokens),
      cached_input_tokens: positive_or_nil(state.usage.cached_input_tokens),
      output_tokens: positive_or_nil(state.usage.output_tokens),
      reasoning_tokens: positive_or_nil(state.usage.reasoning_tokens),
      total_tokens: positive_or_nil(state.usage.total_tokens),
      request_count: 1,
      estimated_cost_micros: reservation.estimated_cost_micros,
      settled_cost_micros: ledger_cost_value(settled_cost),
      source_event_id: settlement_source_event_id(request.id),
      occurred_at: state.usage.recorded_at,
      created_at: state.timestamp,
      details: settlement_details(request, attempt, state.usage, state.pricing, state.context)
    }
  end

  @spec release_attrs(Request.t(), Attempt.t(), LedgerEntry.t(), release_state()) ::
          ledger_attrs()
  def release_attrs(%Request{} = request, %Attempt{} = attempt, reservation, state) do
    %{
      request_id: request.id,
      attempt_id: attempt.id,
      pricing_snapshot_id: reservation.pricing_snapshot_id,
      pool_id: request.pool_id,
      api_key_id: request.api_key_id,
      pool_upstream_assignment_id: attempt.pool_upstream_assignment_id,
      upstream_identity_id: attempt.upstream_identity_id,
      model_id: request.model_id,
      entry_kind: @entry_release,
      amount_status: @amount_recorded,
      usage_status: state.usage.status,
      transport: request.transport,
      currency_code: reservation.currency_code,
      input_tokens: reservation.input_tokens,
      cached_input_tokens: reservation.cached_input_tokens,
      output_tokens: reservation.output_tokens,
      reasoning_tokens: reservation.reasoning_tokens,
      total_tokens: reservation.total_tokens,
      request_count: reservation.request_count,
      estimated_cost_micros: reservation.estimated_cost_micros,
      settled_cost_micros: Decimal.new(0),
      source_event_id: release_source_event_id(request.id),
      occurred_at: state.timestamp,
      created_at: state.timestamp,
      details: release_details(request, state.pricing)
    }
  end

  @spec reservation_failure_release_attrs(
          Request.t(),
          LedgerEntry.t(),
          String.t(),
          String.t() | nil,
          DateTime.t()
        ) :: ledger_attrs()
  def reservation_failure_release_attrs(
        request,
        reservation,
        usage_status,
        last_error_code,
        timestamp
      ) do
    %{
      request_id: request.id,
      pricing_snapshot_id: reservation.pricing_snapshot_id,
      pool_id: request.pool_id,
      api_key_id: request.api_key_id,
      model_id: request.model_id,
      entry_kind: @entry_release,
      amount_status: @amount_recorded,
      usage_status: usage_status,
      transport: request.transport,
      currency_code: reservation.currency_code,
      input_tokens: reservation.input_tokens,
      cached_input_tokens: reservation.cached_input_tokens,
      output_tokens: reservation.output_tokens,
      reasoning_tokens: reservation.reasoning_tokens,
      total_tokens: reservation.total_tokens,
      request_count: reservation.request_count,
      estimated_cost_micros: reservation.estimated_cost_micros,
      settled_cost_micros: Decimal.new(0),
      source_event_id: release_source_event_id(request.id),
      occurred_at: timestamp,
      created_at: timestamp,
      details: reservation_failure_release_details(request, last_error_code)
    }
  end

  @spec reservation_source_event_id(Ecto.UUID.t()) :: String.t()
  def reservation_source_event_id(id), do: "request:#{id}:reservation"

  @spec settlement_source_event_id(Ecto.UUID.t()) :: String.t()
  def settlement_source_event_id(id), do: "request:#{id}:settlement"

  @spec release_source_event_id(Ecto.UUID.t()) :: String.t()
  def release_source_event_id(id), do: "request:#{id}:release"

  defp settlement_details(request, attempt, usage, pricing, context) do
    %{
      "usage_source" => usage.source,
      "request_status" => request.status,
      "attempt_status" => attempt.status,
      "response_status_code" => Map.fetch!(context, :response_status_code),
      "retry_count" => Map.fetch!(context, :retry_count),
      "estimated_from_reserve" => usage.status != "usage_known",
      "settled_cost_micros" => context |> Map.fetch!(:settled_cost) |> decimal_string_or_nil(),
      "cached_input_cost_micros" => cached_input_cost_micros(usage, pricing)
    }
    |> Map.merge(PricingResolution.details(pricing))
  end

  defp release_details(request, pricing) do
    %{
      "released_by_source_event_id" => settlement_source_event_id(request.id),
      "reservation_source_event_id" => reservation_source_event_id(request.id)
    }
    |> Map.merge(PricingResolution.details(pricing))
  end

  defp reservation_failure_release_details(request, last_error_code) do
    %{
      "reservation_source_event_id" => reservation_source_event_id(request.id),
      "release_reason" => last_error_code,
      "request_status" => request.status
    }
  end

  defp positive_or_nil(value), do: if(value && value > 0, do: value, else: nil)
  defp ledger_cost_value(nil), do: Decimal.new(0)
  defp ledger_cost_value(%Decimal{} = value), do: value
  defp decimal_string_or_nil(nil), do: nil
  defp decimal_string_or_nil(%Decimal{} = value), do: Decimal.to_string(value)
  defp decimal_string_or_nil(value), do: to_string(value)

  defp cached_input_cost_micros(
         %{input_tokens: input_tokens, cached_input_tokens: cached_input_tokens},
         %{snapshot: %{cached_input_token_micros: %Decimal{} = token_micros}}
       )
       when is_integer(input_tokens) and is_integer(cached_input_tokens) do
    cached_input_tokens
    |> min(input_tokens)
    |> max(0)
    |> Decimal.new()
    |> Decimal.mult(token_micros)
    |> decimal_string_or_nil()
  end

  defp cached_input_cost_micros(_usage, _pricing), do: nil

  defp normalize_windows(windows) when is_list(windows), do: Map.new(windows)
  defp normalize_windows(windows) when is_map(windows), do: windows

  defp empty_window_usage do
    %{
      effective_request_count: 0,
      effective_total_tokens: 0,
      effective_cost_micros: Decimal.new(0)
    }
  end
end
