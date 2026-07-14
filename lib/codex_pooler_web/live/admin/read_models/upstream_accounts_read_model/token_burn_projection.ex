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
  @type token_burn :: %{
          required(:level) => non_neg_integer(),
          required(:label) => String.t(),
          required(:title) => String.t(),
          required(:recent_tokens) => non_neg_integer(),
          required(:recent_requests) => non_neg_integer(),
          required(:baseline_tokens) => non_neg_integer(),
          required(:recent_models) => [recent_model()]
        }

  @spec summaries([map()]) :: %{optional(Ecto.UUID.t()) => token_burn()}
  def summaries([]), do: %{}

  def summaries(identities) do
    upstream_identity_ids = Enum.map(identities, & &1.id)
    ended_at = DateTime.utc_now()
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
      baseline_tokens = Map.get(baseline_totals, upstream_identity_id, 0)

      {upstream_identity_id,
       summary(recent_tokens, recent_requests, baseline_tokens, recent_models)}
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
    |> Enum.sort_by(&{-&1.tokens, &1.label})
  end

  defp summary(recent_tokens, recent_requests, baseline_tokens, recent_models) do
    level = level(recent_tokens, baseline_tokens)

    %{
      level: level,
      label: "x#{level}",
      title:
        "last 5m: #{Format.token_count(recent_tokens)} tokens; previous 1h: #{Format.token_count(baseline_tokens)} tokens",
      recent_tokens: recent_tokens,
      recent_requests: recent_requests,
      baseline_tokens: baseline_tokens,
      recent_models: recent_models
    }
  end

  defp level(recent_tokens, _baseline_tokens) when recent_tokens <= 0, do: 0
  defp level(_recent_tokens, baseline_tokens) when baseline_tokens <= 0, do: 1

  defp level(recent_tokens, baseline_tokens) do
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
end
