defmodule CodexPooler.Gateway.Routing.ServingSignals do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Gateway.Persistence.RoutingCircuitState
  alias CodexPooler.Repo

  @route_classes ~w(proxy_http proxy_stream proxy_websocket)
  @model_unavailable_reason "upstream_model_unavailable"

  @type model_tuple :: {Ecto.UUID.t(), Ecto.UUID.t(), String.t()}
  @type serving_state ::
          :unverified
          | :available_observed
          | :serving_rejection_observed
          | :temporarily_unavailable
          | :probe_in_progress
          | :probe_due
  @type summary :: %{
          required(:pool_id) => Ecto.UUID.t(),
          required(:assignment_id) => Ecto.UUID.t(),
          required(:exposed_model_id) => String.t(),
          required(:route_class) => String.t(),
          required(:serving_state) => serving_state(),
          required(:status) => String.t() | nil,
          required(:reason_code) => String.t() | nil,
          required(:failure_count) => non_neg_integer(),
          required(:last_failure_at) => DateTime.t() | nil,
          required(:last_success_at) => DateTime.t() | nil,
          required(:next_probe_at) => DateTime.t() | nil
        }

  @spec list_summaries(term()) :: [summary()]
  def list_summaries(authorized_models) do
    case normalize_authorized_models(authorized_models) do
      {:ok, [_ | _] = authorized} -> list_authorized(authorized)
      _empty_or_invalid -> []
    end
  end

  defp list_authorized(authorized) do
    pool_ids = authorized |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    assignment_ids = authorized |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    model_ids = authorized |> Enum.map(&elem(&1, 2)) |> Enum.uniq()
    authorized_filter = authorized_filter(authorized)

    states =
      RoutingCircuitState
      |> where(
        [state],
        state.pool_id in ^pool_ids and is_nil(state.api_key_id) and
          state.pool_upstream_assignment_id in ^assignment_ids and
          state.model_identifier in ^model_ids and state.route_class in ^@route_classes
      )
      |> where(^authorized_filter)
      |> distinct(
        [state],
        [
          state.pool_id,
          state.pool_upstream_assignment_id,
          state.model_identifier,
          state.route_class
        ]
      )
      |> order_by(
        [state],
        asc: state.pool_id,
        asc: state.pool_upstream_assignment_id,
        asc: state.model_identifier,
        asc: state.route_class,
        desc: state.updated_at,
        desc: state.created_at
      )
      |> select([state], %{
        pool_id: state.pool_id,
        assignment_id: state.pool_upstream_assignment_id,
        exposed_model_id: state.model_identifier,
        route_class: state.route_class,
        status: state.status,
        reason_code: state.reason_code,
        failure_count: state.failure_count,
        last_failure_at: state.last_failure_at,
        last_success_at: state.last_success_at,
        next_probe_at: state.next_probe_at
      })
      |> Repo.all()
      |> Map.new(&{state_key(&1), &1})

    for {pool_id, assignment_id, exposed_model_id} <- authorized,
        route_class <- @route_classes do
      key = {pool_id, assignment_id, exposed_model_id, route_class}

      states
      |> Map.get(key)
      |> project(pool_id, assignment_id, exposed_model_id, route_class)
    end
  end

  defp project(nil, pool_id, assignment_id, model_id, route_class) do
    base_summary(pool_id, assignment_id, model_id, route_class)
  end

  defp project(state, pool_id, assignment_id, model_id, route_class) do
    if relevant_state?(state) do
      pool_id
      |> base_summary(assignment_id, model_id, route_class)
      |> Map.merge(%{
        serving_state: serving_state(state),
        status: state.status,
        reason_code: bounded_reason(state.reason_code),
        failure_count: max(state.failure_count || 0, 0),
        last_failure_at: state.last_failure_at,
        last_success_at: state.last_success_at,
        next_probe_at: state.next_probe_at
      })
    else
      base_summary(pool_id, assignment_id, model_id, route_class)
    end
  end

  defp base_summary(pool_id, assignment_id, model_id, route_class) do
    %{
      pool_id: pool_id,
      assignment_id: assignment_id,
      exposed_model_id: model_id,
      route_class: route_class,
      serving_state: :unverified,
      status: nil,
      reason_code: nil,
      failure_count: 0,
      last_failure_at: nil,
      last_success_at: nil,
      next_probe_at: nil
    }
  end

  defp relevant_state?(%{reason_code: @model_unavailable_reason}), do: true
  defp relevant_state?(%{reason_code: nil, last_success_at: %DateTime{}}), do: true
  defp relevant_state?(_state), do: false

  defp serving_state(%{status: "half_open"}), do: :probe_in_progress

  defp serving_state(%{status: "open", next_probe_at: %DateTime{} = next_probe_at}) do
    if DateTime.compare(next_probe_at, now()) == :gt,
      do: :temporarily_unavailable,
      else: :probe_due
  end

  defp serving_state(%{status: "open"}), do: :temporarily_unavailable

  defp serving_state(%{status: "closed", reason_code: @model_unavailable_reason}),
    do: :serving_rejection_observed

  defp serving_state(%{status: "closed", reason_code: nil, last_success_at: %DateTime{}}),
    do: :available_observed

  defp serving_state(_state), do: :unverified

  defp normalize_authorized_models(models) when is_list(models) do
    with {:ok, normalized} <- normalize_model_entries(models) do
      {:ok, normalized |> Enum.uniq() |> Enum.sort()}
    end
  end

  defp normalize_authorized_models(_models), do: :error

  defp normalize_model_entries(models) do
    Enum.reduce_while(models, {:ok, []}, fn
      {pool_id, assignment_id, model_id}, {:ok, normalized}
      when is_binary(pool_id) and is_binary(assignment_id) and is_binary(model_id) ->
        with {:ok, pool_id} <- Ecto.UUID.cast(pool_id),
             {:ok, assignment_id} <- Ecto.UUID.cast(assignment_id),
             model_id when model_id != "" <- String.trim(model_id) do
          {:cont, {:ok, [{pool_id, assignment_id, model_id} | normalized]}}
        else
          _invalid -> {:halt, :error}
        end

      _invalid, _normalized ->
        {:halt, :error}
    end)
  end

  defp authorized_filter(authorized) do
    Enum.reduce(authorized, dynamic(false), fn {pool_id, assignment_id, model_id}, filter ->
      dynamic(
        [state],
        ^filter or
          (state.pool_id == ^pool_id and
             state.pool_upstream_assignment_id == ^assignment_id and
             state.model_identifier == ^model_id)
      )
    end)
  end

  defp state_key(state),
    do: {state.pool_id, state.assignment_id, state.exposed_model_id, state.route_class}

  defp bounded_reason(@model_unavailable_reason), do: @model_unavailable_reason
  defp bounded_reason(_reason), do: nil
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
