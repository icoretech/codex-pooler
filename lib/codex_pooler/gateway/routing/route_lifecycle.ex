defmodule CodexPooler.Gateway.Routing.RouteLifecycle do
  @moduledoc false

  require Logger

  alias CodexPooler.Accounting.FailureResponse
  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.Routing.{BridgeRing, CircuitState, RoutingSelection}

  @type gateway_error :: Contracts.gateway_error()
  @type success_result :: :ok | {:error, gateway_error()}
  @type failure_result :: {:ok, term()} | {:error, gateway_error()}

  @spec selection_success(map(), CodexPooler.Catalog.Model.t(), RoutingSelection.t()) ::
          success_result()
  def selection_success(auth, model, %RoutingSelection{} = selection) do
    BridgeRing.record_success(selection.route_plan, selection.assignment, selection.identity)
    record_routing_circuit_success(auth, model, selection)
  end

  @spec selection_failure(
          map(),
          CodexPooler.Catalog.Model.t(),
          RoutingSelection.t(),
          term(),
          term()
        ) ::
          failure_result()
  def selection_failure(auth, model, %RoutingSelection{} = selection, request_id, code) do
    demotion_reason =
      BridgeRing.record_failure(
        selection.route_plan,
        selection.assignment,
        selection.identity,
        code,
        request_id
      )

    case CircuitState.record_failure(
           auth,
           model,
           selection.assignment,
           selection.route_class,
           demotion_reason,
           selection.circuit_admission || :none
         ) do
      {:ok, _state} -> {:ok, demotion_reason}
      {:error, reason} -> lifecycle_failure(:record_route_circuit_failure, reason)
    end
  end

  @spec selection_neutral_completion(map(), CodexPooler.Catalog.Model.t(), RoutingSelection.t()) ::
          success_result()
  def selection_neutral_completion(auth, model, %RoutingSelection{} = selection) do
    case CircuitState.record_neutral_completion(
           auth,
           model,
           selection.assignment,
           selection.route_class,
           selection.circuit_admission || :none
         ) do
      {:ok, _state} -> :ok
      {:error, reason} -> lifecycle_failure(:record_route_circuit_neutral_completion, reason)
    end
  end

  @spec log_optional_result(String.t(), keyword(), success_result() | failure_result()) :: :ok
  def log_optional_result(_operation, _metadata, :ok), do: :ok
  def log_optional_result(_operation, _metadata, {:ok, _value}), do: :ok

  def log_optional_result(operation, metadata, {:error, reason}) do
    Logger.warning(
      "gateway route lifecycle side effect failed",
      [operation: operation, reason: route_lifecycle_failure_code(reason)] ++ metadata
    )

    :ok
  end

  defp record_routing_circuit_success(auth, model, %RoutingSelection{} = selection) do
    case CircuitState.record_success(
           auth,
           model,
           selection.assignment,
           selection.route_class,
           selection.circuit_admission || :none
         ) do
      {:ok, _state} -> :ok
      {:error, reason} -> lifecycle_failure(:record_route_circuit_success, reason)
    end
  end

  defp lifecycle_failure(operation, reason) do
    FailureResponse.accounting_failure(operation, nil, nil, reason)
  end

  defp route_lifecycle_failure_code(%{code: code}) when is_binary(code), do: code
  defp route_lifecycle_failure_code(%{code: code}) when is_atom(code), do: Atom.to_string(code)
  defp route_lifecycle_failure_code(_reason), do: "unknown"
end
