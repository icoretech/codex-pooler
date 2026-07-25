defmodule CodexPooler.Gateway.Routing.CircuitTelemetry do
  @moduledoc false

  alias CodexPooler.Gateway.Persistence.RoutingCircuitState

  @event [:codex_pooler, :gateway, :routing, :circuit, :transition]
  @transitions ~w(
    closed_to_open
    open_to_half_open
    open_to_closed
    half_open_to_closed
    half_open_to_open
  )
  @reason_classes ~w(
    upstream_status
    retryable_upstream_status
    upstream_5xx
    upstream_rate_limited
    upstream_unauthorized
    upstream_network_error
    upstream_model_unavailable
    upstream_stream_error
    client_disconnected
    none
    unknown
  )

  @type transition :: String.t()
  @type reason_class :: String.t()

  @spec transitions() :: [transition()]
  def transitions, do: @transitions

  @spec reason_classes() :: [reason_class()]
  def reason_classes, do: @reason_classes

  @spec emit_transition(
          String.t(),
          String.t(),
          RoutingCircuitState.t(),
          keyword()
        ) :: :ok
  def emit_transition(from_status, to_status, %RoutingCircuitState{} = state, opts) do
    try do
      reason_code = Keyword.get(opts, :reason_code, state.reason_code)

      :telemetry.execute(
        @event,
        %{count: 1},
        %{
          transition: transition(from_status, to_status),
          from_status: from_status,
          to_status: to_status,
          route_class: state.route_class,
          reason_class: reason_class(reason_code),
          reason_code: reason_code,
          failure_count: state.failure_count,
          pool_id: state.pool_id,
          pool_upstream_assignment_id: state.pool_upstream_assignment_id,
          upstream_identity_id: state.upstream_identity_id,
          model_identifier: state.model_identifier
        }
      )
    rescue
      _error -> :ok
    catch
      _kind, _reason -> :ok
    end

    :ok
  end

  defp transition(from_status, to_status) do
    value = "#{from_status}_to_#{to_status}"
    if value in @transitions, do: value, else: "unknown"
  end

  defp reason_class(nil), do: "none"

  defp reason_class(reason_code) when is_atom(reason_code) do
    reason_code
    |> Atom.to_string()
    |> reason_class()
  end

  defp reason_class(reason_code) when reason_code in @reason_classes, do: reason_code
  defp reason_class(_reason_code), do: "unknown"
end
