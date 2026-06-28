defmodule CodexPooler.Gateway.Routing.QuotaRefresh.Executor do
  @moduledoc """
  Executor for synchronous stale quota refresh plans during routing.
  """

  require Logger

  alias CodexPooler.Gateway.Routing.CandidateEligibility
  alias CodexPooler.Gateway.Routing.QuotaRefresh.Plan
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment

  @quota_refresh_timeout_ms :timer.seconds(3)

  @spec refresh_stale_candidates(CandidateEligibility.quota_refresh_plan()) ::
          Plan.filter_after_refresh_result()
  def refresh_stale_candidates(refresh_plan) when is_map(refresh_plan) do
    refresh_plan
    |> Plan.refresh_candidates()
    |> Enum.each(fn {assignment, _identity} -> refresh_assignment_once(assignment) end)

    Plan.filter_after_refresh(refresh_plan)
  end

  defp refresh_assignment_once(%PoolUpstreamAssignment{} = assignment) do
    assignment
    |> do_refresh_assignment_once()
    |> log_refresh_result(assignment)
  rescue
    exception in [
      DBConnection.ConnectionError,
      Ecto.Query.CastError,
      Ecto.QueryError,
      Postgrex.Error
    ] ->
      log_refresh_failure(:exception, exception, assignment)

    exception in RuntimeError ->
      log_refresh_failure(:exception, exception, assignment)
  catch
    kind, reason ->
      log_refresh_failure(kind, reason, assignment)
  end

  defp do_refresh_assignment_once(%PoolUpstreamAssignment{} = assignment) do
    lock_key =
      :erlang.phash2({__MODULE__, :quota_refresh, assignment.id}, 2_147_483_647)

    Repo.checkout(fn ->
      case Repo.query("select pg_try_advisory_lock($1)", [lock_key]) do
        {:ok, %{rows: [[true]]}} ->
          with_advisory_lock(assignment, lock_key)

        {:ok, _locked} ->
          :already_refreshing

        {:error, reason} ->
          {:error, {:advisory_lock_failed, reason}}
      end
    end)
  end

  defp with_advisory_lock(%PoolUpstreamAssignment{} = assignment, lock_key) do
    Upstreams.reconcile_pool_account(assignment.pool_id, assignment.id,
      receive_timeout: @quota_refresh_timeout_ms
    )
  after
    unlock_advisory_lock(assignment, lock_key)
  end

  defp unlock_advisory_lock(%PoolUpstreamAssignment{} = assignment, lock_key) do
    case Repo.query("select pg_advisory_unlock($1)", [lock_key]) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        log_refresh_failure(:unlock_error, reason, assignment)
    end
  end

  defp log_refresh_result({:ok, _result}, _assignment), do: :ok
  defp log_refresh_result(:already_refreshing, _assignment), do: :already_refreshing

  defp log_refresh_result({:error, reason}, %PoolUpstreamAssignment{} = assignment) do
    log_refresh_failure(:error, reason, assignment)
  end

  defp log_refresh_result(other, %PoolUpstreamAssignment{} = assignment) do
    log_refresh_failure(:unexpected_result, other, assignment)
  end

  defp log_refresh_failure(kind, reason, %PoolUpstreamAssignment{} = assignment) do
    Logger.warning(
      "quota refresh skipped " <>
        "pool_id=#{safe_id(assignment.pool_id)} " <>
        "assignment_id=#{safe_id(assignment.id)} " <>
        "failure_kind=#{failure_kind(kind)} " <>
        "failure_reason=#{failure_reason(reason)}"
    )

    :error
  end

  defp safe_id(value) when is_binary(value), do: value
  defp safe_id(_value), do: "unknown"

  defp failure_kind(kind) when kind in [:error, :exit, :throw], do: Atom.to_string(kind)
  defp failure_kind(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp failure_kind(_kind), do: "unknown"

  defp failure_reason(%module{}) when is_atom(module), do: inspect(module)
  defp failure_reason({reason, _details}) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_reason(reason) when is_binary(reason), do: sanitized_reason_token(reason)
  defp failure_reason(_reason), do: "unavailable"

  defp sanitized_reason_token(reason) do
    reason
    |> String.replace(~r/[^a-zA-Z0-9_.:-]+/, "_")
    |> String.slice(0, 80)
    |> case do
      "" -> "binary_reason"
      value -> value
    end
  end
end
