defmodule CodexPooler.Dev.LensFixture do
  @moduledoc "Metadata-only model evidence for a disabled, synthetic Lens Pool."
  import Ecto.Query

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.Pools
  alias CodexPooler.Pools.{Membership, Pool}
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @marker "dev-inspector-v1"
  @slug "dev-inspector-demo"

  @spec seed!() :: map()
  def seed! do
    owner = Repo.one!(from u in User, join: m in Membership, on: m.user_id == u.id, where: m.role == "instance_owner" and m.status == "active" and is_nil(u.deleted_at), order_by: [asc: u.created_at, asc: u.id], limit: 1)
    seed!(Scope.for_user(owner))
  end

  @spec seed!(Scope.t()) :: map()
  def seed!(scope) do
    unless Pools.owner?(scope), do: raise(ArgumentError, "Lens fixtures require an instance owner")

    {:ok, result} = Repo.transaction(fn -> seed_rows(scope) end)
    CodexPooler.Events.broadcast_request_logs(result.pool.id, "fixture_seeded", %{})
    result
  end

  defp seed_rows(scope) do
    now = DateTime.utc_now()
    pool = ensure_pool(scope)
    key = ensure_key(pool, scope, now)
    assignments = for index <- 1..2, do: ensure_assignment(pool, scope, now, index)

    # Only this fixture's requests are replaced; ordinary local history is untouched.
    Repo.delete_all(from r in Request, where: r.pool_id == ^pool.id and fragment("?->>'dev_seed' = ?", r.request_metadata, ^@marker))

    for index <- 1..96 do
      seed_attempt(pool, key, Enum.at(assignments, rem(index, 2)), now, index)
    end

    %{pool: pool, attempts: 96, path: "/admin/lens?pool_id=#{pool.id}&evidence=signals&window=24h"}
  end

  defp ensure_pool(scope) do
    case Repo.get_by(Pool, slug: @slug) do
      nil ->
        {:ok, pool} = Pools.create_pool(scope, %{name: "Lens demo (synthetic)", slug: @slug, status: "disabled"}, broadcast: false)
        pool

      %Pool{status: "disabled", name: "Lens demo (synthetic)"} = pool ->
        pool

      %Pool{status: "disabled", name: "Inspector demo (synthetic)"} = pool ->
        # This seed owns a deliberately disabled Pool; retain its identity and status.
        pool |> Pool.changeset(%{name: "Lens demo (synthetic)", updated_at: DateTime.utc_now()}) |> Repo.update!()

      _other ->
        raise ArgumentError, "Lens fixture Pool name is already in use"
    end
  end

  defp ensure_key(pool, scope, now) do
    case Repo.get_by(APIKey, pool_id: pool.id, display_name: @marker) do
      nil ->
        %APIKey{}
        |> APIKey.changeset(%{pool_id: pool.id, display_name: @marker, key_prefix: "synthetic", key_hash: :crypto.strong_rand_bytes(32), status: "revoked", dashboard_access: false, metadata: %{"dev_seed" => @marker}, created_by_user_id: scope.user.id, created_at: now, revoked_at: now})
        |> Repo.insert!()

      %APIKey{status: "revoked", metadata: %{"dev_seed" => @marker}} = key ->
        key

      _other ->
        raise ArgumentError, "Lens fixture key is not owned by this fixture"
    end
  end

  defp ensure_assignment(pool, scope, now, index) do
    label = "Synthetic upstream #{index}"

    case Repo.get_by(PoolUpstreamAssignment, pool_id: pool.id, assignment_label: label) do
      %PoolUpstreamAssignment{status: "disabled", metadata: %{"dev_seed" => @marker}} = assignment -> assignment
      nil -> create_assignment(pool, scope, now, label)
      _other -> raise ArgumentError, "Lens fixture assignment is not owned by this fixture"
    end
  end

  defp create_assignment(pool, scope, now, label) do
    metadata = %{"dev_seed" => @marker}
    identity = %UpstreamIdentity{} |> UpstreamIdentity.changeset(%{account_label: label, onboarding_method: "import", status: "disabled", headers_profile_version: 1, created_by_user_id: scope.user.id, created_at: now, updated_at: now, metadata: metadata}) |> Repo.insert!()
    %PoolUpstreamAssignment{} |> PoolUpstreamAssignment.changeset(%{pool_id: pool.id, upstream_identity_id: identity.id, assignment_label: label, status: "disabled", health_status: "unknown", eligibility_status: "ineligible", created_by_user_id: scope.user.id, created_at: now, updated_at: now, metadata: metadata}) |> Repo.insert!()
  end

  defp seed_attempt(pool, key, assignment, now, index) do
    timestamp = DateTime.add(now, -index * 800, :second)
    {sent, first, conflict, coverage, terminal} = scenario(rem(index, 12))
    status = if terminal in [nil, "failed"], do: "failed", else: "succeeded"
    transport = Enum.at(~w(http_sse websocket http_json), rem(index, 3))
    endpoint = "/backend-api/codex/responses"
    request = %Request{pool_id: pool.id, api_key_id: key.id, requested_model: sent, endpoint: endpoint, transport: transport, status: status, usage_status: "usage_unknown", correlation_id: "#{@marker}-#{index}", request_metadata: %{"dev_seed" => @marker}, admitted_at: timestamp, completed_at: timestamp, response_status_code: if(status == "failed", do: 502, else: 200), retry_count: 0} |> Repo.insert!()
    observation = if coverage, do: %{"version" => 1, "coverage" => coverage, "conflict" => if(first, do: not is_nil(conflict)), "first_conflicting_model" => conflict, "terminal_model" => if(terminal, do: conflict || first), "terminal_status" => terminal}
    %Attempt{request_id: request.id, attempt_number: 1, pool_upstream_assignment_id: assignment.id, upstream_identity_id: assignment.upstream_identity_id, upstream_model_id: sent, served_model: first, model_observation: observation, transport: transport, status: status, started_at: timestamp, completed_at: timestamp, upstream_status_code: request.response_status_code, retryable: false, usage_status: "usage_unknown", response_metadata: %{"dev_seed" => @marker}} |> Repo.insert!()
  end

  defp scenario(0), do: {"model-pro", "model-lite", nil, "full", "completed"}
  defp scenario(1), do: {"model-pro", "model-pro", "model-lite", "full", "completed"}
  defp scenario(2), do: {"model-reasoning", "model-fast", "model-lite", "full", "completed"}
  defp scenario(3), do: {"model-pro", "model-lite", nil, "partial", nil}
  defp scenario(4), do: {"model-fast", nil, nil, "full", "completed"}
  defp scenario(5), do: {"model-pro", nil, nil, "partial", "failed"}
  defp scenario(6), do: {"model-pro", "model-pro", nil, nil, "completed"}
  defp scenario(7), do: {"model-pro", nil, nil, nil, "completed"}
  defp scenario(_), do: {"model-fast", "model-fast", nil, "full", "completed"}
end
