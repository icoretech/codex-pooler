defmodule CodexPoolerWeb.Admin.UpstreamAccountsReadModel.TokenBurnProjection do
  @moduledoc false

  alias CodexPooler.Accounting
  alias CodexPooler.Catalog
  alias CodexPoolerWeb.Admin.Format

  @token_burn_recent_seconds 5 * 60
  @token_burn_baseline_seconds 60 * 60
  @unknown_model_label "unknown model"

  @type recent_model :: %{
          required(:label) => String.t(),
          required(:tokens) => non_neg_integer(),
          required(:cost_micros) => non_neg_integer()
        }
  @type usage_state :: :idle | :complete | :partial | :unknown
  @type token_burn :: %{
          required(:level) => non_neg_integer() | nil,
          required(:label) => String.t(),
          required(:title) => String.t(),
          required(:recent_tokens) => non_neg_integer(),
          required(:recent_requests) => non_neg_integer(),
          required(:known_request_count) => non_neg_integer(),
          required(:unknown_request_count) => non_neg_integer(),
          required(:usage_state) => usage_state(),
          required(:baseline_tokens) => non_neg_integer(),
          required(:recent_models) => [recent_model()]
        }

  @type opts :: [now: DateTime.t()]

  @spec summaries([map()], opts()) :: %{optional(Ecto.UUID.t()) => token_burn()}
  def summaries(identities, opts \\ [])

  def summaries([], _opts), do: %{}

  def summaries(identities, opts) do
    upstream_identity_ids = Enum.map(identities, & &1.id)
    ended_at = Keyword.get(opts, :now, DateTime.utc_now())
    recent_started_at = DateTime.add(ended_at, -@token_burn_recent_seconds, :second)
    baseline_started_at = DateTime.add(recent_started_at, -@token_burn_baseline_seconds, :second)

    recent_model_totals =
      Accounting.token_totals_by_upstream_identity_and_model_ids(
        upstream_identity_ids,
        recent_started_at,
        ended_at
      )

    baseline_totals =
      Accounting.token_totals_by_upstream_identity_ids(
        upstream_identity_ids,
        baseline_started_at,
        recent_started_at
      )

    model_labels = model_labels(recent_model_totals)

    Map.new(upstream_identity_ids, fn upstream_identity_id ->
      model_totals = Map.get(recent_model_totals, upstream_identity_id, [])
      recent_models = recent_models(model_totals, model_labels)
      recent_tokens = model_totals |> Enum.map(& &1.total_tokens) |> Enum.sum()
      recent_requests = model_totals |> Enum.map(& &1.request_count) |> Enum.sum()
      known_request_count = model_totals |> Enum.map(& &1.known_request_count) |> Enum.sum()
      unknown_request_count = model_totals |> Enum.map(& &1.unknown_request_count) |> Enum.sum()
      baseline_tokens = Map.get(baseline_totals, upstream_identity_id, 0)

      {upstream_identity_id,
       summary(
         recent_tokens,
         recent_requests,
         known_request_count,
         unknown_request_count,
         baseline_tokens,
         recent_models
       )}
    end)
  end

  defp model_labels(recent_model_totals) do
    recent_model_totals
    |> Enum.flat_map(fn {_identity_id, model_totals} -> Enum.map(model_totals, & &1.model_id) end)
    |> Catalog.exposed_model_ids_by_ids()
  end

  defp recent_models(model_totals, model_labels) do
    model_totals
    |> Enum.group_by(fn row -> Map.get(model_labels, row.model_id, @unknown_model_label) end)
    |> Enum.map(fn {label, rows} ->
      %{
        label: label,
        tokens: rows |> Enum.map(& &1.total_tokens) |> Enum.sum(),
        cost_micros: rows |> Enum.map(& &1.settled_cost_micros) |> Enum.sum()
      }
    end)
    |> Enum.sort_by(&{&1.tokens, &1.label}, :desc)
  end

  defp summary(
         recent_tokens,
         recent_requests,
         known_request_count,
         unknown_request_count,
         baseline_tokens,
         recent_models
       ) do
    usage_state = usage_state(recent_requests, known_request_count)
    level = level(usage_state, recent_tokens, baseline_tokens)

    %{
      level: level,
      label: level_label(usage_state, level),
      title:
        usage_title(
          usage_state,
          recent_tokens,
          baseline_tokens,
          recent_requests,
          known_request_count,
          unknown_request_count
        ),
      recent_tokens: recent_tokens,
      recent_requests: recent_requests,
      known_request_count: known_request_count,
      unknown_request_count: unknown_request_count,
      usage_state: usage_state,
      baseline_tokens: baseline_tokens,
      recent_models: recent_models
    }
  end

  defp usage_state(0, _known_request_count), do: :idle
  defp usage_state(recent_requests, 0) when recent_requests > 0, do: :unknown

  defp usage_state(recent_requests, known_request_count)
       when recent_requests == known_request_count,
       do: :complete

  defp usage_state(_recent_requests, _known_request_count), do: :partial

  defp level(:unknown, _recent_tokens, _baseline_tokens), do: nil
  defp level(_usage_state, recent_tokens, _baseline_tokens) when recent_tokens <= 0, do: 0
  defp level(_usage_state, _recent_tokens, baseline_tokens) when baseline_tokens <= 0, do: 1

  defp level(_usage_state, recent_tokens, baseline_tokens) do
    recent_rate = recent_tokens / (@token_burn_recent_seconds / 60)
    baseline_rate = baseline_tokens / (@token_burn_baseline_seconds / 60)
    ratio = recent_rate / baseline_rate

    cond do
      ratio < 0.5 -> 1
      ratio < 1.5 -> 2
      ratio < 3 -> 3
      ratio <= 6 -> 4
      true -> 5
    end
  end

  defp level_label(:unknown, _level), do: "usage unavailable"
  defp level_label(_usage_state, level), do: "x#{level}"

  defp usage_title(:idle, _recent_tokens, _baseline_tokens, _recent_requests, _known, _unknown),
    do: "No requests in the last 5 minutes."

  defp usage_title(
         :complete,
         recent_tokens,
         baseline_tokens,
         recent_requests,
         _known,
         _unknown
       ) do
    token_comparison_title(recent_tokens, baseline_tokens) <>
      "; complete usage for #{request_count_label(recent_requests)}"
  end

  defp usage_title(
         :partial,
         recent_tokens,
         baseline_tokens,
         recent_requests,
         known_request_count,
         unknown_request_count
       ) do
    token_comparison_title(recent_tokens, baseline_tokens) <>
      "; settled usage reported for #{known_request_count} of #{recent_requests} requests; #{usage_record_count_label(unknown_request_count)} missing"
  end

  defp usage_title(
         :unknown,
         _recent_tokens,
         _baseline_tokens,
         recent_requests,
         _known,
         unknown_request_count
       ) do
    "last 5m: #{request_count_label(recent_requests)}; #{usage_record_count_label(unknown_request_count)} missing"
  end

  defp token_comparison_title(recent_tokens, baseline_tokens) do
    "last 5m: #{Format.token_count(recent_tokens)} tokens; previous 1h: #{Format.token_count(baseline_tokens)} tokens"
  end

  defp request_count_label(1), do: "1 request"
  defp request_count_label(count), do: "#{count} requests"

  defp usage_record_count_label(1), do: "1 usage record"
  defp usage_record_count_label(count), do: "#{count} usage records"
end
