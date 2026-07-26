defmodule CodexPooler.Admin.UpstreamCircuitReadiness do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Persistence.RoutingCircuitState
  alias CodexPooler.Gateway.Routing.CircuitHealth
  alias CodexPooler.{Repo, RouteClass}

  @blocked_reasons ~w(open_cooldown open_no_probe probe_saturated)
  @active_statuses ~w(open half_open)
  @unknown_model "unknown model"
  @unknown_route "unknown route"

  @type state :: :blocked | :recovering | :closed
  @type tone :: :error | :warning | :success
  @type representative :: %{
          required(:model_identifier) => String.t(),
          required(:route_class) => String.t()
        }
  @type summary :: %{
          required(:state) => state(),
          required(:ready?) => boolean(),
          required(:tone) => tone(),
          required(:label) => String.t(),
          required(:detail) => String.t(),
          required(:blocked_lane_count) => non_neg_integer(),
          required(:recovering_lane_count) => non_neg_integer(),
          required(:affected_lane_count) => non_neg_integer(),
          required(:blocked_reasons) => [String.t()],
          required(:representative) => representative() | nil
        }
  @type authorized_served_models_by_assignment_id :: %{
          optional(Ecto.UUID.t()) => [term()]
        }

  @spec by_assignment_id(
          authorized_served_models_by_assignment_id(),
          OperationalSettings.t(),
          DateTime.t()
        ) :: %{optional(Ecto.UUID.t()) => summary()}
  def by_assignment_id(authorized_models, %OperationalSettings{}, %DateTime{})
      when is_map(authorized_models) and map_size(authorized_models) == 0,
      do: %{}

  def by_assignment_id(
        authorized_models,
        %OperationalSettings{} = settings,
        %DateTime{} = observed_at
      )
      when is_map(authorized_models) do
    served_models = normalized_served_models(authorized_models)
    assignment_ids = Map.keys(authorized_models)
    recent_window_seconds = recent_window_seconds(settings)

    rows =
      Repo.all(
        from state in RoutingCircuitState,
          where:
            state.pool_upstream_assignment_id in ^assignment_ids and is_nil(state.api_key_id),
          order_by: [
            asc: state.pool_upstream_assignment_id,
            asc: state.model_identifier,
            asc: state.route_class,
            desc: state.updated_at,
            desc: state.created_at
          ],
          select: %{
            pool_upstream_assignment_id: state.pool_upstream_assignment_id,
            model_identifier: state.model_identifier,
            route_class: state.route_class,
            status: state.status,
            next_probe_at: state.next_probe_at,
            opened_at: state.opened_at,
            last_failure_at: state.last_failure_at,
            metadata: state.metadata,
            created_at: state.created_at,
            updated_at: state.updated_at
          }
      )

    lanes_by_assignment =
      rows
      |> Enum.group_by(&exact_lane_key/1)
      |> Enum.reduce(%{}, fn {_exact_lane, lane_rows}, acc ->
        latest = latest_row(lane_rows)
        assignment_id = latest.pool_upstream_assignment_id

        if served_model?(latest, Map.fetch!(served_models, assignment_id)) do
          lane =
            classify_lane(
              latest,
              lane_rows,
              settings,
              observed_at,
              recent_window_seconds
            )

          Map.update(acc, assignment_id, [lane], &[lane | &1])
        else
          acc
        end
      end)

    Map.new(authorized_models, fn {assignment_id, _models} ->
      lanes =
        lanes_by_assignment
        |> Map.get(assignment_id, [])
        |> collapse_normalized_lanes()

      {assignment_id, summarize(lanes)}
    end)
  end

  def by_assignment_id(_authorized_models, %OperationalSettings{}, %DateTime{}), do: %{}

  @spec clear() :: summary()
  def clear do
    %{
      state: :closed,
      ready?: true,
      tone: :success,
      label: "Circuit clear",
      detail: "No circuit protection is active",
      blocked_lane_count: 0,
      recovering_lane_count: 0,
      affected_lane_count: 0,
      blocked_reasons: [],
      representative: nil
    }
  end

  @spec aggregate([summary()]) :: summary()
  def aggregate(summaries) when is_list(summaries) do
    lanes =
      summaries
      |> Enum.filter(&is_map/1)
      |> Enum.flat_map(fn summary ->
        case Map.get(summary, :representative) do
          %{model_identifier: model_identifier, route_class: route_class} ->
            [
              %{
                state: Map.get(summary, :state, :closed),
                model_identifier: display_model(model_identifier),
                route_class: display_route(route_class),
                evidence_at: nil,
                reason: nil
              }
            ]

          _representative ->
            []
        end
      end)

    totals =
      Enum.reduce(summaries, clear(), fn
        summary, acc when is_map(summary) ->
          %{
            acc
            | blocked_lane_count:
                acc.blocked_lane_count + non_negative_count(summary, :blocked_lane_count),
              recovering_lane_count:
                acc.recovering_lane_count + non_negative_count(summary, :recovering_lane_count),
              affected_lane_count:
                acc.affected_lane_count + non_negative_count(summary, :affected_lane_count),
              blocked_reasons:
                bounded_reasons(acc.blocked_reasons ++ Map.get(summary, :blocked_reasons, []))
          }

        _summary, acc ->
          acc
      end)

    state =
      cond do
        totals.blocked_lane_count > 0 -> :blocked
        totals.recovering_lane_count > 0 -> :recovering
        true -> :closed
      end

    representative =
      lanes
      |> Enum.filter(&(&1.state == state))
      |> Enum.sort_by(&lane_sort_key/1)
      |> List.first()
      |> representative()

    present(totals, state, representative)
  end

  def aggregate(_summaries), do: clear()

  defp normalized_served_models(authorized_models) do
    Map.new(authorized_models, fn {assignment_id, models} ->
      normalized =
        models
        |> List.wrap()
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&normalize_identifier/1)
        |> Enum.reject(&(&1 == ""))
        |> MapSet.new()

      {assignment_id, normalized}
    end)
  end

  defp exact_lane_key(row) do
    {row.pool_upstream_assignment_id, row.model_identifier, row.route_class}
  end

  defp latest_row(rows) do
    Enum.max_by(rows, fn row ->
      {datetime_key(row.updated_at), datetime_key(row.created_at)}
    end)
  end

  defp served_model?(row, served_models) do
    MapSet.member?(served_models, normalize_identifier(row.model_identifier))
  end

  defp classify_lane(latest, rows, settings, observed_at, recent_window_seconds) do
    current = struct(RoutingCircuitState, latest)
    blocked? = CircuitHealth.blocked?(current, settings, observed_at)

    evidence_at =
      latest_eligible_evidence(rows, observed_at, recent_window_seconds)

    state =
      cond do
        blocked? -> :blocked
        latest.status in @active_statuses -> :recovering
        match?(%DateTime{}, evidence_at) -> :recovering
        true -> :closed
      end

    %{
      state: state,
      model_identifier: normalize_identifier(latest.model_identifier),
      route_class: normalize_identifier(latest.route_class),
      evidence_at: evidence_at,
      reason:
        if(blocked?, do: CircuitHealth.blocked_reason(current, settings, observed_at), else: nil)
    }
  end

  defp latest_eligible_evidence(rows, observed_at, recent_window_seconds) do
    lower_bound = DateTime.add(observed_at, -recent_window_seconds, :second)

    rows
    |> Enum.flat_map(&[&1.opened_at, &1.last_failure_at])
    |> Enum.filter(&eligible_evidence?(&1, lower_bound, observed_at))
    |> Enum.max_by(&datetime_key/1, fn -> nil end)
  end

  defp eligible_evidence?(%DateTime{} = timestamp, lower_bound, observed_at) do
    DateTime.compare(timestamp, lower_bound) in [:eq, :gt] and
      DateTime.compare(timestamp, observed_at) in [:eq, :lt]
  end

  defp eligible_evidence?(_timestamp, _lower_bound, _observed_at), do: false

  defp collapse_normalized_lanes(lanes) do
    lanes
    |> Enum.group_by(&{&1.model_identifier, &1.route_class})
    |> Enum.map(fn {_normalized_lane, duplicates} ->
      duplicates
      |> Enum.sort_by(&lane_sort_key/1)
      |> List.first()
    end)
  end

  defp summarize(lanes) do
    blocked_lanes = Enum.filter(lanes, &(&1.state == :blocked))
    recovering_lanes = Enum.filter(lanes, &(&1.state == :recovering))
    affected_lanes = blocked_lanes ++ recovering_lanes

    state =
      cond do
        blocked_lanes != [] -> :blocked
        recovering_lanes != [] -> :recovering
        true -> :closed
      end

    representative =
      affected_lanes
      |> Enum.sort_by(&lane_sort_key/1)
      |> List.first()
      |> representative()

    clear()
    |> Map.put(:blocked_lane_count, length(blocked_lanes))
    |> Map.put(:recovering_lane_count, length(recovering_lanes))
    |> Map.put(:affected_lane_count, length(affected_lanes))
    |> Map.put(:blocked_reasons, bounded_reasons(Enum.map(blocked_lanes, & &1.reason)))
    |> present(state, representative)
  end

  defp present(_summary, :closed, _representative), do: clear()

  defp present(summary, :blocked, representative) do
    %{
      summary
      | state: :blocked,
        ready?: false,
        tone: :error,
        label: "Circuit protection active",
        detail: detail(summary.blocked_lane_count, "blocked", representative),
        representative: representative
    }
  end

  defp present(summary, :recovering, representative) do
    %{
      summary
      | state: :recovering,
        ready?: true,
        tone: :warning,
        label: "Circuit recovery in progress",
        detail: detail(summary.recovering_lane_count, "recovering", representative),
        representative: representative
    }
  end

  defp detail(count, state, %{model_identifier: model_identifier, route_class: route_class}) do
    "#{lane_count_label(count)} #{state}; #{model_identifier} via #{route_class}"
  end

  defp detail(count, state, _representative), do: "#{lane_count_label(count)} #{state}"

  defp lane_count_label(1), do: "1 circuit lane"
  defp lane_count_label(count), do: "#{count} circuit lanes"

  defp representative(nil), do: nil

  defp representative(lane) do
    %{
      model_identifier: display_model(lane.model_identifier),
      route_class: display_route(lane.route_class)
    }
  end

  defp lane_sort_key(lane) do
    {
      severity(lane.state),
      lane.model_identifier,
      lane.route_class,
      -datetime_key(lane.evidence_at)
    }
  end

  defp severity(:blocked), do: 0
  defp severity(:recovering), do: 1
  defp severity(:closed), do: 2
  defp severity(_state), do: 3

  defp bounded_reasons(reasons) do
    reasons
    |> Enum.filter(&(&1 in @blocked_reasons))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.take(length(@blocked_reasons))
  end

  defp non_negative_count(summary, key) do
    case Map.get(summary, key, 0) do
      count when is_integer(count) and count > 0 -> count
      _count -> 0
    end
  end

  defp recent_window_seconds(%OperationalSettings{circuit_open_seconds: seconds})
       when is_integer(seconds) do
    seconds
    |> Kernel.*(10)
    |> max(300)
    |> min(3_600)
  end

  defp recent_window_seconds(%OperationalSettings{}), do: 300

  defp normalize_identifier(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_identifier(_value), do: ""

  defp display_model(value) do
    case sanitize_display(value, 80) do
      "" -> @unknown_model
      model -> model
    end
  end

  defp display_route(value) do
    route = normalize_identifier(value)
    if route in RouteClass.all(), do: route, else: @unknown_route
  end

  defp sanitize_display(value, max_graphemes) when is_binary(value) do
    value
    |> String.replace(~r/[[:cntrl:]]/u, " ")
    |> String.replace(~r/<[^>]*>/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.downcase()
    |> String.graphemes()
    |> Enum.take(max_graphemes)
    |> Enum.join()
  end

  defp sanitize_display(_value, _max_graphemes), do: ""

  defp datetime_key(%DateTime{} = timestamp), do: DateTime.to_unix(timestamp, :microsecond)
  defp datetime_key(_timestamp), do: 0
end
