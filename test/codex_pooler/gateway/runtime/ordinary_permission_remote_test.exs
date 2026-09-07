defmodule CodexPooler.Gateway.Runtime.OrdinaryPermissionRemoteTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 2, start_upstream: 1, register_unboxed_pool_cleanup!: 1]

  alias CodexPooler.{Access, Accounting, FakeUpstream, Repo}
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Runtime.Dispatch.{CandidateDispatch, Context, PreDispatch}
  alias CodexPooler.Gateway.Runtime.Service
  alias CodexPooler.Gateway.Transports.WebsocketOwnerNodeHarness
  alias CodexPooler.Upstreams.Lifecycle.CredentialFencing
  alias CodexPooler.Upstreams.Quota.{AccountAvailabilityStore, Windows}
  alias CodexPooler.Upstreams.Reconciliation.PoolReconciliation
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint "/backend-api/codex/responses"

  setup_all do
    if node() == :nonode@nohost do
      {_, 0} = System.cmd("epmd", ["-daemon"])
      previous = Application.fetch_env(:kernel, :prevent_overlapping_partitions)
      Application.put_env(:kernel, :prevent_overlapping_partitions, false)

      {:ok, _} =
        :net_kernel.start([
          :"permission_local_#{System.unique_integer([:positive])}",
          :shortnames
        ])

      on_exit(fn ->
        :net_kernel.stop()

        case previous do
          {:ok, value} -> Application.put_env(:kernel, :prevent_overlapping_partitions, value)
          :error -> Application.delete_env(:kernel, :prevent_overlapping_partitions)
        end
      end)
    end

    {:ok, peer, remote} =
      :peer.start_link(%{
        name: :"permission_peer_#{System.unique_integer([:positive])}",
        args: [~c"+S", ~c"2:2", ~c"-kernel", ~c"prevent_overlapping_partitions", ~c"false"]
      })

    Process.unlink(peer)
    on_exit(fn -> :peer.stop(peer) end)
    :ok = :erpc.call(remote, :code, :add_paths, [:code.get_path()])
    repo_config = Repo.config() |> Keyword.put(:pool, DBConnection.ConnectionPool)
    repo = :erpc.call(remote, WebsocketOwnerNodeHarness, :start_repo, [repo_config])
    assert node(repo) == remote
    refute remote == node()
    %{remote: remote}
  end

  setup do
    upstream = start_upstream(routes())

    fixture =
      Sandbox.unboxed_run(Repo, fn ->
        fixture = gateway_setup(upstream, quota?: false)

        identity =
          fixture.identity
          |> Ecto.Changeset.change(
            metadata:
              Map.put(fixture.identity.metadata, "usage_base_url", FakeUpstream.url(upstream))
          )
          |> Repo.update!()

        assert {:ok, identity} =
                 PoolReconciliation.refresh_quota_from_usage(identity, fixture.assignment)

        %{fixture | identity: identity}
      end)

    register_unboxed_pool_cleanup!(fixture)
    %{fixture: fixture, upstream: upstream}
  end

  test "a second BEAM observes the committed full affirmative snapshot and ordinary dispatch succeeds",
       ctx do
    Sandbox.unboxed_run(Repo, fn ->
      assert_distinct_backends(ctx.remote)

      snapshots =
        :erpc.call(ctx.remote, Windows, :load_routing_quota_snapshots, [
          [ctx.fixture.identity.id],
          DateTime.utc_now()
        ])

      snapshot = Map.fetch!(snapshots, ctx.fixture.identity.id)
      assert snapshot.availability.state == :available
      assert snapshot.raw_windows != []

      assert Enum.all?(snapshot.raw_windows, fn window ->
               Decimal.equal?(window.used_percent, Decimal.new(100)) and
                 DateTime.compare(window.observed_at, snapshot.availability.observed_at) == :eq
             end)

      {auth, payload, options} = request_context(ctx.fixture)
      assert {:ok, %{status: 200}} = Service.execute(auth, @endpoint, payload, options)
      assert generation_count(ctx.upstream) == 1
      [wire] = Enum.filter(FakeUpstream.requests(ctx.upstream), &(&1.method == "POST"))
      assert wire.json["model"] == ctx.fixture.model.upstream_model_id
      request = Repo.one!(from(r in Accounting.Request, where: r.pool_id == ^ctx.fixture.pool.id))
      assert request.status == "succeeded"
      entries = Repo.all(from(e in Accounting.LedgerEntry, where: e.request_id == ^request.id))

      assert Enum.sort(Enum.map(entries, & &1.entry_kind)) == [
               "release",
               "reservation",
               "settlement"
             ]

      by_kind = Map.new(entries, &{&1.entry_kind, &1})
      assert by_kind["release"].total_tokens == by_kind["reservation"].total_tokens
      assert by_kind["release"].request_count == by_kind["reservation"].request_count

      assert Decimal.equal?(
               by_kind["release"].estimated_cost_micros,
               by_kind["reservation"].estimated_cost_micros
             )

      assert Repo.aggregate(
               from(a in Accounting.Attempt, where: a.model_id == ^ctx.fixture.model.id),
               :count
             ) == 1
    end)
  end

  test "a second BEAM retains permission after committed percent-only headers", ctx do
    Sandbox.unboxed_run(Repo, fn ->
      assert_distinct_backends(ctx.remote)

      snapshots =
        Windows.load_routing_quota_snapshots([ctx.fixture.identity.id], DateTime.utc_now())

      [usage_window] = snapshots[ctx.fixture.identity.id].raw_windows

      headers = [
        {"x-codex-secondary-used-percent", "100"},
        {"x-codex-secondary-window-minutes", "10080"},
        {"x-codex-secondary-reset-at", DateTime.to_iso8601(usage_window.reset_at)}
      ]

      assert {:ok, [_]} =
               Windows.upsert_quota_windows_from_codex_headers(ctx.fixture.identity, headers)

      snapshots =
        :erpc.call(ctx.remote, Windows, :load_routing_quota_snapshots, [
          [ctx.fixture.identity.id],
          DateTime.utc_now()
        ])

      snapshot = snapshots[ctx.fixture.identity.id]

      assert %{eligible?: true, routing_state: :provider_available} =
               :erpc.call(ctx.remote, Windows, :routing_quota_eligibility_from_snapshot, [
                 snapshot,
                 [
                   model: ctx.fixture.model.exposed_model_id,
                   upstream_model: ctx.fixture.model.upstream_model_id
                 ]
               ])

      {auth, payload, options} = request_context(ctx.fixture)
      assert {:ok, %{status: 200}} = Service.execute(auth, @endpoint, payload, options)
      assert generation_count(ctx.upstream) == 1
    end)
  end

  for change <- [:denial, :credential_epoch] do
    test "committed remote #{change} invalidates an already reserved affirmative selection",
         ctx do
      Sandbox.unboxed_run(Repo, fn ->
        assert_distinct_backends(ctx.remote)
        {auth, payload, options} = request_context(ctx.fixture)

        assert {:ok, prepared} =
                 PreDispatch.prepare(auth, @endpoint, payload, options, ctx.fixture.model)

        assert length(prepared.candidates) == 1

        assert {:ok, reserved} =
                 Accounting.reserve(auth, ctx.fixture.model, payload, %{
                   endpoint: @endpoint,
                   transport: "http_json",
                   correlation_id: Ecto.UUID.generate(),
                   request_metadata: %{}
                 })

        assert {:ok, context} =
                 Context.new(%{
                   auth: auth,
                   endpoint: @endpoint,
                   payload: payload,
                   model: ctx.fixture.model,
                   reserved: reserved,
                   candidates: prepared.candidates,
                   request_options: prepared.request_options,
                   route_state: prepared.route_state
                 })

        identity = ctx.fixture.identity

        metadata =
          case unquote(change) do
            :denial ->
              {:ok, snapshot} = AccountAvailabilityStore.load(identity.metadata)

              Map.put(
                identity.metadata,
                AccountAvailabilityStore.metadata_key(),
                AccountAvailabilityStore.encode!(
                  :blocked,
                  DateTime.utc_now(),
                  snapshot.credential_epoch
                )
              )

            :credential_epoch ->
              CredentialFencing.advance_credential_epoch_preserving_expiry(identity)
          end

        changeset = Ecto.Changeset.change(identity, metadata: metadata)
        updated = :erpc.call(ctx.remote, Repo, :update!, [changeset])
        assert Repo.reload!(identity).metadata == updated.metadata

        assert {:error, %{code: "no_eligible_backend"}} =
                 CandidateDispatch.dispatch(context, fn _ ->
                   flunk("committed remote revocation reached transport")
                 end)

        assert generation_count(ctx.upstream) == 0

        assert Repo.aggregate(
                 from(a in Accounting.Attempt, where: a.request_id == ^reserved.request.id),
                 :count
               ) == 0

        entries =
          Repo.all(from(e in Accounting.LedgerEntry, where: e.request_id == ^reserved.request.id))

        assert Enum.sort(Enum.map(entries, & &1.entry_kind)) == ["release", "reservation"]
        [release, reservation] = Enum.sort_by(entries, & &1.entry_kind)
        assert release.total_tokens == reservation.total_tokens
        assert release.request_count == reservation.request_count
        assert Decimal.equal?(release.estimated_cost_micros, reservation.estimated_cost_micros)
      end)
    end
  end

  defp assert_distinct_backends(remote) do
    %{rows: [[local_pid, database]]} = Repo.query!("SELECT pg_backend_pid(), current_database()")

    %{rows: [[remote_pid, ^database]]} =
      :erpc.call(remote, Repo, :query!, ["SELECT pg_backend_pid(), current_database()"])

    refute local_pid == remote_pid
  end

  defp request_context(fixture) do
    assert {:ok, auth} = Access.authenticate_authorization_header(fixture.authorization)
    assert {:ok, policy} = Access.normalize_api_key_policy(auth.api_key)
    payload = %{"model" => fixture.model.exposed_model_id, "input" => []}
    {auth, payload, RequestOptions.build(%{api_key_policy: policy}, @endpoint, payload)}
  end

  defp generation_count(upstream),
    do: Enum.count(FakeUpstream.requests(upstream), &(&1.method == "POST"))

  defp routes do
    usage = %{
      "plan_type" => "plus",
      "rate_limit" => %{
        "allowed" => true,
        "limit_reached" => false,
        "primary_window" => %{
          "used_percent" => 100,
          "limit_window_seconds" => 604_800,
          "reset_after_seconds" => 604_800,
          "reset_at" => DateTime.utc_now() |> DateTime.add(604_800, :second) |> DateTime.to_unix()
        }
      },
      "credits" => %{"has_credits" => false, "unlimited" => false, "balance" => "0"}
    }

    {:path_json,
     Map.new(
       ["/api/codex/usage", "/backend-api/codex/usage", "/wham/usage", "/backend-api/wham/usage"],
       &{&1, {200, usage}}
     )
     |> Map.put(
       @endpoint,
       {200, %{"id" => "resp_permission_remote", "object" => "response", "output" => []}}
     )}
  end
end
