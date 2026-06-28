defmodule CodexPooler.Admin.UpstreamCockpitMetrics.Common do
  @moduledoc false

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Admin.UpstreamRoutingReadiness
  alias CodexPooler.Pools
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @spec visible_pool_ids(Scope.t()) :: [Ecto.UUID.t()]
  def visible_pool_ids(%Scope{} = scope) do
    scope
    |> Pools.list_visible_pools()
    |> Enum.map(& &1.id)
  end

  @spec filter_assignments_by_pool_ids([map()], [Ecto.UUID.t()]) :: [map()]
  def filter_assignments_by_pool_ids(assignments, pool_ids) do
    pool_id_set = MapSet.new(pool_ids)

    Enum.filter(assignments, &MapSet.member?(pool_id_set, &1.pool_id))
  end

  @spec identity_id(UpstreamIdentity.t() | Ecto.UUID.t() | term()) :: Ecto.UUID.t() | nil
  def identity_id(%UpstreamIdentity{id: id}), do: id
  def identity_id(id) when is_binary(id), do: id
  def identity_id(_identity_or_id), do: nil

  @spec routing_readiness(term(), map(), term()) :: UpstreamRoutingReadiness.t()
  def routing_readiness(identity_or_status, assignment, quota_readiness) do
    identity_or_status
    |> routing_identity_status(assignment)
    |> UpstreamRoutingReadiness.from_inputs(assignment, quota_readiness)
  end

  @spec routing_readiness_contract(UpstreamRoutingReadiness.t()) :: map()
  def routing_readiness_contract(routing_readiness) do
    %{
      routing_readiness_state: routing_readiness.state,
      routing_readiness_label: routing_readiness.label,
      routing_readiness_reason: routing_readiness.reason,
      routing_readiness_reason_code: routing_readiness.reason_code,
      routing_readiness_recovery_action: routing_readiness.recovery_action
    }
  end

  @spec percentage(non_neg_integer(), non_neg_integer()) :: float()
  def percentage(_count, 0), do: 0.0
  def percentage(count, total), do: Float.round(count / total * 100.0, 1)

  @spec decimal_to_float(Decimal.t() | nil) :: float() | nil
  def decimal_to_float(%Decimal{} = value), do: Decimal.to_float(value)
  def decimal_to_float(nil), do: nil

  @spec seven_day_window_start(DateTime.t()) :: DateTime.t()
  def seven_day_window_start(%DateTime{} = as_of) do
    as_of
    |> DateTime.to_date()
    |> Date.add(-6)
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
  end

  @spec now() :: DateTime.t()
  def now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp routing_identity_status(identity_or_status, assignment) do
    assignment_identity_status(assignment) || identity_or_status
  end

  defp assignment_identity_status(%{identity_status: status}) when is_binary(status), do: status

  defp assignment_identity_status(%{"identity_status" => status}) when is_binary(status),
    do: status

  defp assignment_identity_status(_assignment), do: nil
end
