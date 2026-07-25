defmodule CodexPooler.Alerts.Evaluation.CircuitTerm do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Routing.CircuitHealth
  alias CodexPooler.Repo
  alias CodexPooler.RouteClass

  @alert_evaluation_cadence_seconds 300
  @circuit_recency_ticks 3
  @blocked_reasons ~w(open_cooldown open_no_probe probe_saturated)

  @type projection_cache :: map()
  @type assignment_term :: %{
          required(:serves_model?) => boolean(),
          required(:circuit_blocked?) => boolean(),
          required(:blocked_lanes) => [map()]
        }

  @spec default_evidence() :: map()
  def default_evidence do
    empty_evidence(nil, false)
  end

  @spec evidence_cache_key(
          Ecto.UUID.t() | nil,
          String.t() | nil,
          map(),
          boolean()
        ) :: tuple()
  def evidence_cache_key(pool_id, model, context, circuit_term?) do
    {:circuit_evidence, pool_id, model, context.route_class, context.circuit_observed_at,
     circuit_term?}
  end

  @spec apply([map()], Ecto.UUID.t() | nil, String.t() | nil, map(), projection_cache()) ::
          {[map()], map(), projection_cache()}
  def apply(assignments, pool_id, model, context, projection_cache) do
    settings = CircuitHealth.settings()
    recency_seconds = recency_seconds(settings)
    {models, projection_cache} = models_from_cache(pool_id, projection_cache)

    case resolved_models(models, model) do
      {:unresolved, _models} ->
        evidence = empty_evidence(recency_seconds, false)
        {apply_inert_term(assignments), evidence, projection_cache}

      {:resolved, scoped_models} ->
        {circuits, projection_cache} = circuits_from_cache(pool_id, projection_cache)

        assignments =
          Enum.map(assignments, fn assignment ->
            term =
              assignment_term(
                assignment.assignment_id,
                scoped_models,
                circuits,
                context,
                settings,
                recency_seconds
              )

            Map.merge(assignment, term)
          end)

        evidence = evidence(assignments, recency_seconds)
        {assignments, evidence, projection_cache}
    end
  end

  defp models_from_cache(pool_id, projection_cache) do
    cache_key = {:models, pool_id}

    case Map.fetch(projection_cache, cache_key) do
      {:ok, models} ->
        {models, projection_cache}

      :error ->
        models =
          Repo.all(
            from model in Model,
              where: model.pool_id == ^pool_id and model.status == "active",
              order_by: [asc: fragment("lower(?)", model.exposed_model_id)],
              select: %{
                exposed_model_id: model.exposed_model_id,
                metadata: model.metadata
              }
          )

        {models, Map.put(projection_cache, cache_key, models)}
    end
  end

  defp circuits_from_cache(pool_id, projection_cache) do
    cache_key = {:circuits, pool_id}

    case Map.fetch(projection_cache, cache_key) do
      {:ok, circuits} ->
        {circuits, projection_cache}

      :error ->
        circuits = CircuitHealth.active_circuits(pool_id)
        {circuits, Map.put(projection_cache, cache_key, circuits)}
    end
  end

  defp resolved_models([], _model), do: {:unresolved, []}

  defp resolved_models(models, nil), do: {:resolved, models}

  defp resolved_models(models, model) do
    normalized_model = normalize_model(model)

    case Enum.find(models, &(normalize_model(&1.exposed_model_id) == normalized_model)) do
      nil -> {:unresolved, []}
      resolved -> {:resolved, [resolved]}
    end
  end

  defp assignment_term(
         assignment_id,
         models,
         circuits,
         context,
         settings,
         recency_seconds
       ) do
    served_models = Enum.filter(models, &serves_assignment?(&1, assignment_id))

    blocked_lanes =
      circuits
      |> Enum.filter(&(&1.pool_upstream_assignment_id == assignment_id))
      |> Enum.filter(&route_class_in_scope?(&1, context.route_class))
      |> Enum.filter(&circuit_model_served?(&1, served_models))
      |> Enum.filter(&blocked_lane?(&1, settings, context.circuit_observed_at, recency_seconds))
      |> Enum.map(&blocked_lane(&1, settings, context.circuit_observed_at))

    blocked_models =
      blocked_lanes
      |> Enum.map(& &1.model_identifier)
      |> MapSet.new()

    circuit_blocked? =
      served_models != [] and
        Enum.all?(
          served_models,
          &MapSet.member?(blocked_models, normalize_model(&1.exposed_model_id))
        )

    %{
      serves_model?: served_models != [],
      circuit_blocked?: circuit_blocked?,
      blocked_lanes: blocked_lanes
    }
  end

  defp apply_inert_term(assignments) do
    Enum.map(assignments, fn assignment ->
      Map.merge(assignment, %{
        serves_model?: true,
        circuit_blocked?: false,
        blocked_lanes: []
      })
    end)
  end

  defp serves_assignment?(model, assignment_id) do
    assignment_id in source_assignment_ids(model)
  end

  defp source_assignment_ids(%{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, "source_assignment_ids") do
      ids when is_list(ids) -> Enum.filter(ids, &is_binary/1)
      _value -> []
    end
  end

  defp source_assignment_ids(_model), do: []

  defp route_class_in_scope?(_circuit, nil), do: true
  defp route_class_in_scope?(circuit, route_class), do: circuit.route_class == route_class

  defp circuit_model_served?(circuit, served_models) do
    circuit_model = normalize_model(circuit.model_identifier)
    Enum.any?(served_models, &(normalize_model(&1.exposed_model_id) == circuit_model))
  end

  defp blocked_lane?(circuit, settings, observed_at, recency_seconds) do
    CircuitHealth.blocked?(circuit, settings, observed_at) or
      recent_failure?(circuit.last_failure_at, observed_at, recency_seconds)
  end

  defp recent_failure?(%DateTime{} = last_failure_at, observed_at, recency_seconds) do
    lower_bound = DateTime.add(observed_at, -recency_seconds, :second)

    DateTime.compare(last_failure_at, lower_bound) in [:eq, :gt] and
      DateTime.compare(last_failure_at, observed_at) in [:eq, :lt]
  end

  defp recent_failure?(_last_failure_at, _observed_at, _recency_seconds), do: false

  defp blocked_lane(circuit, settings, observed_at) do
    %{
      model_identifier: normalize_model(circuit.model_identifier),
      route_class: circuit.route_class,
      reason: CircuitHealth.blocked_reason(circuit, settings, observed_at)
    }
  end

  defp evidence(assignments, recency_seconds) do
    enabled = Enum.filter(assignments, & &1.enabled_assignment?)
    blocked_lanes = Enum.flat_map(enabled, & &1.blocked_lanes)

    %{
      circuit_blocked_assignment_count: Enum.count(enabled, & &1.circuit_blocked?),
      circuit_blocked_route_classes:
        blocked_lanes
        |> Enum.map(& &1.route_class)
        |> Enum.filter(&(&1 in RouteClass.all()))
        |> Enum.uniq()
        |> Enum.sort(),
      circuit_blocked_reasons:
        blocked_lanes
        |> Enum.map(& &1.reason)
        |> Enum.filter(&(&1 in @blocked_reasons))
        |> Enum.uniq()
        |> Enum.sort(),
      circuit_blocked_lane_count: length(blocked_lanes),
      circuit_recency_seconds: recency_seconds,
      model_membership_resolved: true,
      non_serving_assignment_count: Enum.count(enabled, &(not &1.serves_model?))
    }
  end

  defp empty_evidence(recency_seconds, model_membership_resolved) do
    %{
      circuit_blocked_assignment_count: 0,
      circuit_blocked_route_classes: [],
      circuit_blocked_reasons: [],
      circuit_blocked_lane_count: 0,
      circuit_recency_seconds: recency_seconds,
      model_membership_resolved: model_membership_resolved,
      non_serving_assignment_count: 0
    }
  end

  defp recency_seconds(settings) do
    max(
      @alert_evaluation_cadence_seconds * @circuit_recency_ticks,
      settings.circuit_open_seconds
    )
  end

  defp normalize_model(model) when is_binary(model),
    do: model |> String.trim() |> String.downcase()
end
