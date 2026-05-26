defmodule CodexPooler.Upstreams.Lifecycle.AccountAudit do
  @moduledoc false

  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.Audit
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @spec record_change(term(), term(), String.t(), keyword()) :: term()
  def record_change(result, scope, action, opts \\ [])

  def record_change(
        {:ok, {%{} = result, %Pool{} = pool}},
        %Scope{user: %User{} = user},
        action,
        opts
      ) do
    result
    |> Map.put(:assignments, [result.assignment])
    |> record_events(user, action, opts, [pool.id])

    {:ok, result}
  end

  def record_change(
        {:ok, %{identity: %UpstreamIdentity{} = identity} = result} = ok,
        %Scope{user: %User{} = user},
        action,
        opts
      ) do
    record_events(
      result,
      user,
      action,
      Keyword.put_new(opts, :previous_status, identity.status),
      []
    )

    ok
  end

  def record_change(result, _scope, _action, _opts), do: result

  defp record_events(result, user, action, opts, fallback_pool_ids) do
    Enum.each(pool_ids(result, fallback_pool_ids), fn pool_id ->
      details =
        result
        |> details(opts)
        |> Map.put(:pool_id, pool_id)
        |> Map.put(:pool_assignment_ids, assignment_ids(result, pool_id))
        |> maybe_put_detail(:trigger_kind, Keyword.get(opts, :trigger_kind))
        |> maybe_put_detail(:job_conflict, Keyword.get(opts, :job_conflict?))

      Audit.record_user_event(user, %{
        pool_id: pool_id,
        action: action,
        target_type: "upstream_identity",
        target_id: result.identity.id,
        details: details
      })
    end)
  end

  defp maybe_put_detail(details, _key, nil), do: details
  defp maybe_put_detail(details, key, value), do: Map.put(details, key, value)

  defp pool_ids(result, fallback_pool_ids) do
    result
    |> assignments()
    |> Enum.map(& &1.pool_id)
    |> then(&(&1 ++ fallback_pool_ids))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp assignment_ids(result, pool_id) do
    result
    |> assignments()
    |> Enum.filter(&(&1.pool_id == pool_id))
    |> Enum.map(& &1.id)
    |> Enum.reject(&is_nil/1)
  end

  defp assignments(%{assignments: assignments}) when is_list(assignments),
    do: Enum.filter(assignments, &match?(%PoolUpstreamAssignment{}, &1))

  defp assignments(%{assignment: %PoolUpstreamAssignment{} = assignment}), do: [assignment]
  defp assignments(_result), do: []

  defp details(%{identity: %UpstreamIdentity{} = identity} = result, opts) do
    %{
      upstream_identity_id: identity.id,
      account_label: identity.account_label,
      onboarding_method: identity.onboarding_method,
      status: identity.status,
      previous_label: Keyword.get(opts, :previous_label),
      previous_status: Keyword.get(opts, :previous_status),
      result_status: result.status && to_string(result.status),
      assignment_count: length(assignments(result)),
      credential_status: result.secret_status && to_string(result.secret_status)
    }
  end
end
