defmodule CodexPooler.Gateway.Routing.DurableConversationAffinityTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Gateway.Payloads.RequestOptions

  alias CodexPooler.Gateway.Persistence.{
    BridgeAffinity,
    BridgeDemotion,
    CodexSession,
    ConversationAffinity,
    RuntimeCleanup,
    SessionContinuity
  }

  alias CodexPooler.Gateway.Routing.{BridgeRing, RoutePlanInput}
  alias CodexPooler.Gateway.Routing.SessionContinuity, as: RoutingContinuity
  alias CodexPooler.Pools
  alias CodexPooler.Pools.RoutingSettings
  alias CodexPoolerWeb.GatewayControllerHelpers

  setup do
    pool = pool_fixture()
    auth = active_api_key_fixture(pool)

    candidates =
      for _ <- 1..3 do
        %{assignment: assignment, identity: identity} = active_upstream_assignment_fixture(pool)
        {assignment, identity}
      end

    model =
      model_fixture(pool, %{
        metadata: %{"source_assignment_ids" => Enum.map(candidates, &elem(&1, 0).id)}
      })

    settings =
      pool
      |> Pools.ensure_routing_settings()
      |> Ecto.Changeset.change(durable_conversation_affinity_enabled: true)
      |> Repo.update!()

    %{
      pool: pool,
      auth: %{pool: pool, api_key: auth.api_key},
      model: model,
      candidates: candidates,
      settings: settings
    }
  end

  test "off by default and idle retention is bounded", context do
    assert %RoutingSettings{
             durable_conversation_affinity_enabled: false,
             durable_conversation_affinity_idle_seconds: 86_400
           } = Pools.routing_settings_with_defaults(Ecto.UUID.generate())

    for invalid <- [0, 59, 2_592_001] do
      refute RoutingSettings.changeset(context.settings, %{
               durable_conversation_affinity_idle_seconds: invalid
             }).valid?
    end

    Repo.update!(
      Ecto.Changeset.change(context.settings, durable_conversation_affinity_enabled: false)
    )

    refute plan(context, options()).affinity.kind == "durable_conversation"
    assert Repo.aggregate(durable_rows(), :count) == 0
  end

  test "HTTP ingress captures typed stable identity separately from rotating window and turn state",
       context do
    first = ingress_options("window-a", "turn-a", "conversation")
    second = ingress_options("window-b", "turn-b", "conversation")
    assert first.continuity.session_header == "window-a"
    assert second.continuity.session_header == "window-b"

    assert first.continuity.durable_conversation_key_hash ==
             second.continuity.durable_conversation_key_hash

    assert plan(context, first).affinity.key_hash == plan(context, second).affinity.key_hash
  end

  test "thread IDs separate children sharing a root session; invalid selected headers fail closed",
       context do
    root = [{"session-id", "shared-root"}, {"x-codex-window-id", "window"}]

    hashes =
      for thread <- ["child-a", "child-b"] do
        conn = %{Phoenix.ConnTest.build_conn() | req_headers: [{"thread-id", thread} | root]}

        opts =
          conn
          |> GatewayControllerHelpers.request_opts()
          |> RequestOptions.build("/backend-api/codex/responses", %{})

        plan(context, opts).affinity.key_hash
      end

    assert length(Enum.uniq(hashes)) == 2

    for invalid <- [
          [],
          [{"thread-id", " "}],
          [{"thread-id", String.duplicate("x", 1025)}],
          [{"thread-id", "a"}, {"thread-id", "b"}, {"x-codex-conversation-id", "fallback"}]
        ] do
      conn = %{Phoenix.ConnTest.build_conn() | req_headers: invalid ++ root}

      opts =
        conn
        |> GatewayControllerHelpers.request_opts()
        |> RequestOptions.build("/backend-api/codex/responses", %{})

      refute plan(context, opts).affinity.kind == "durable_conversation"
    end
  end

  test "initial choice is stable without a prior row despite a new request correlation",
       context do
    first = plan(context, options())
    Repo.delete!(first.affinity.row)
    second = plan(context, options())
    assert second.selected_assignment_id == first.selected_assignment_id
    refute second.affinity.row.id == first.affinity.row.id
  end

  test "older same-account completion cannot shorten stored timestamps or expiry", context do
    first = plan(context, options())
    {assignment, identity} = hd(first.candidates)
    later = DateTime.add(DateTime.utc_now(), 30, :second)

    row =
      first.affinity.row
      |> Ecto.Changeset.change(
        last_hit_at: later,
        updated_at: later,
        expires_at: DateTime.add(later, 86_400, :second)
      )
      |> Repo.update!()

    BridgeRing.record_success(first, assignment, identity)
    updated = Repo.get!(BridgeAffinity, row.id)

    assert Map.take(updated, [:last_hit_at, :updated_at, :expires_at]) ==
             Map.take(row, [:last_hit_at, :updated_at, :expires_at])
  end

  test "idle transport expiration recreates DB UUID but another process reuses durable account",
       context do
    opts = options()
    {:ok, session_a} = SessionContinuity.start_codex_session(context.auth, opts)
    first = plan(context, RequestOptions.put_continuity(opts, codex_session: session_a))
    succeed(first, hd(first.candidates))
    expired_at = DateTime.add(DateTime.utc_now(), -120, :second)
    Repo.update!(Ecto.Changeset.change(session_a, owner_lease_expires_at: expired_at))
    {:ok, session_b} = SessionContinuity.start_codex_session(context.auth, opts)
    refute session_a.id == session_b.id

    second =
      Task.async(fn ->
        plan(context, RequestOptions.put_continuity(opts, codex_session: session_b))
      end)
      |> Task.await()

    assert second.selected_assignment_id == first.selected_assignment_id
    assert second.affinity.row.id == first.affinity.row.id
    assert second.affinity.status == "hit"
    assert Repo.aggregate(durable_rows(), :count) == 1
  end

  test "stable initial routing and unchanged prompt-cache input", context do
    payload = %{
      "model" => context.model.exposed_model_id,
      "prompt_cache_key" => "original-cache-key"
    }

    opts = options(%{}, payload)
    normalized_cache_key = opts.routing.prompt_cache_key
    first = plan(context, opts)
    second = plan(context, opts)
    assert first.selected_assignment_id == second.selected_assignment_id
    assert first.affinity.row.id == second.affinity.row.id
    assert first.locality.status == "applied"
    assert opts.routing.prompt_cache_key == normalized_cache_key
    refute inspect(first.request_metadata) =~ "conversation-fixture"
    refute inspect(first.affinity.row) =~ "conversation-fixture"
  end

  test "scope isolates pool, API key, model and typed key", context do
    first = plan(context, options())
    other_auth = active_api_key_fixture(context.pool)
    other_model = model_fixture(context.pool, %{exposed_model_id: "other-affinity-model"})
    other_pool = pool_fixture()
    other_pool_auth = active_api_key_fixture(other_pool)

    %{assignment: other_assignment, identity: other_identity} =
      active_upstream_assignment_fixture(other_pool)

    Pools.ensure_routing_settings(other_pool)
    |> Ecto.Changeset.change(durable_conversation_affinity_enabled: true)
    |> Repo.update!()

    variants = [
      plan(%{context | auth: %{pool: context.pool, api_key: other_auth.api_key}}, options()),
      plan(%{context | model: other_model}, options()),
      plan(context, options(%{conversation_key: "conversation-fixture"})),
      plan(context, options(%{session_header: "other-conversation"})),
      plan(
        %{
          context
          | pool: other_pool,
            auth: %{pool: other_pool, api_key: other_pool_auth.api_key},
            candidates: [{other_assignment, other_identity}]
        },
        options()
      )
    ]

    hashes = Enum.map([first | variants], & &1.affinity.key_hash)
    assert length(Enum.uniq(hashes)) == 6
  end

  test "missing, random session keys, turn-state and window-only inputs create no durable mapping",
       context do
    for raw <- [
          %{},
          %{session_key: "random-key"},
          %{accepted_turn_state: "rotating-turn"},
          %{session_header_source: "x-codex-window-id", session_header: "window-only"},
          %{session_header_source: "x-codex-conversation-id", session_header: " "}
        ] do
      opts = RequestOptions.build(raw, "/backend-api/codex/responses", %{})
      refute plan(context, opts).affinity.kind == "durable_conversation"
    end

    assert Repo.aggregate(durable_rows(), :count) == 0
    assert plan(%{context | candidates: []}, options()).candidates == []
    assert Repo.aggregate(durable_rows(), :count) == 0
  end

  for {label, reason} <- [{"429", "upstream_rate_limited"}, {"503", "upstream_5xx"}] do
    test "successful #{label} failover survives A recovery and late A completion", context do
      first = plan(context, options())
      [a, b | _] = first.candidates
      succeed(first, a)
      stale_a = plan(context, options())
      failover = plan(context, options())

      assert BridgeRing.record_failure(failover, elem(a, 0), elem(a, 1), unquote(reason)) ==
               unquote(reason)

      succeed(failover, b)
      before_late = Repo.get!(BridgeAffinity, first.affinity.row.id)
      assert before_late.generation == 1
      succeed(stale_a, a)
      assert Repo.get!(BridgeAffinity, before_late.id) == before_late

      Repo.update_all(BridgeDemotion,
        set: [demoted_until: DateTime.add(DateTime.utc_now(), -1, :second)]
      )

      old_session = %CodexSession{
        id: Ecto.UUID.generate(),
        pool_upstream_assignment_id: elem(a, 0).id
      }

      recovered =
        plan(context, RequestOptions.put_continuity(options(), codex_session: old_session))

      assert recovered.selected_assignment_id == elem(b, 0).id
    end
  end

  test "eligible quota fallback becomes durable and never restores an excluded account",
       context do
    first = plan(context, options())
    [a, b | _] = first.candidates
    succeed(first, a)
    reduced = %{context | candidates: [b]}
    fallback = plan(reduced, options())
    assert fallback.candidates == [b]
    succeed(fallback, b)
    assert plan(context, options()).selected_assignment_id == elem(b, 0).id
  end

  test "strict previous response, file and active websocket pins retain precedence", context do
    first = plan(context, options())
    [a, b | _] = first.candidates
    succeed(first, b)
    session = %CodexSession{id: Ecto.UUID.generate(), pool_upstream_assignment_id: elem(a, 0).id}

    for pin <- [
          %{previous_response_id: "resp-strict"},
          %{file_affinity_assignment_id: elem(a, 0).id},
          %{upstream_websocket_session: self()}
        ] do
      opts = options(Map.put(pin, :codex_session, session))

      assert {:ok, pinned} =
               RoutingContinuity.apply_codex_session_assignment(
                 context.candidates,
                 opts,
                 context.model
               )

      assert pinned == [a]
      assert plan(%{context | candidates: pinned}, opts).selected_assignment_id == elem(a, 0).id
    end
  end

  test "failures do not renew idle expiry; cleanup is bounded and fences recreated rows",
       context do
    first = plan(context, options())
    [a, b | _] = first.candidates
    BridgeRing.record_failure(first, elem(a, 0), elem(a, 1), "upstream_rate_limited")

    assert Repo.get!(BridgeAffinity, first.affinity.row.id).expires_at ==
             first.affinity.row.expires_at

    expired_at = DateTime.add(DateTime.utc_now(), -1, :second)
    Repo.update!(Ecto.Changeset.change(first.affinity.row, expires_at: expired_at))
    second = plan(context, options(%{session_header: "second"}))
    Repo.update!(Ecto.Changeset.change(second.affinity.row, expires_at: expired_at))
    assert BridgeRing.routing_status(context.pool).active_affinity_count == 0
    assert ConversationAffinity.cleanup(DateTime.utc_now(), 1) == 1
    assert {:ok, %{expired_conversation_affinities: 1}} = RuntimeCleanup.cleanup_expired()
    fresh = plan(context, options())
    refute fresh.affinity.row.id == first.affinity.row.id
    succeed(fresh, b)
    fresh_row = Repo.get!(BridgeAffinity, fresh.affinity.row.id)
    succeed(first, a)
    assert Repo.get!(BridgeAffinity, fresh_row.id) == fresh_row
  end

  test "successful completion alone renews idle retention", context do
    first = plan(context, options())
    older_expiry = DateTime.add(first.affinity.row.expires_at, -100, :second)
    Repo.update!(Ecto.Changeset.change(first.affinity.row, expires_at: older_expiry))
    planned = plan(context, options())
    assert planned.affinity.row.expires_at == older_expiry
    succeed(planned, hd(planned.candidates))

    assert DateTime.after?(
             Repo.get!(BridgeAffinity, first.affinity.row.id).expires_at,
             older_expiry
           )
  end

  defp durable_rows,
    do: from(affinity in BridgeAffinity, where: affinity.affinity_kind == "durable_conversation")

  defp ingress_options(window, turn, conversation) do
    Phoenix.ConnTest.build_conn(:post, "/backend-api/codex/responses")
    |> Plug.Conn.put_req_header("x-codex-window-id", window)
    |> Plug.Conn.put_req_header("x-codex-turn-state", turn)
    |> Plug.Conn.put_req_header("thread-id", conversation)
    |> Plug.Conn.put_req_header("session-id", "shared-root")
    |> GatewayControllerHelpers.request_opts()
    |> RequestOptions.build("/backend-api/codex/responses", %{})
  end

  defp options(overrides \\ %{}, payload \\ %{}) do
    %{session_header_source: "x-codex-conversation-id", session_header: "conversation-fixture"}
    |> Map.merge(overrides)
    |> RequestOptions.build("/backend-api/codex/responses", payload)
  end

  defp plan(context, opts) do
    BridgeRing.plan_route(%{
      auth: context.auth,
      model: context.model,
      candidates: context.candidates,
      request_options: opts,
      route_plan_input: %RoutePlanInput{correlation_id: Ecto.UUID.generate()}
    })
  end

  defp succeed(plan, {assignment, identity}),
    do: BridgeRing.record_success(plan, assignment, identity)
end
