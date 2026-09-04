defmodule CodexPooler.DBInvariantsTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Pools
  alias CodexPooler.Pools.Membership
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams

  test "database rejects invalid upstream lifecycle status values" do
    user_id = create_user!("owner-upstream-lifecycle-status@example.com")
    pool_id = create_pool!(user_id, "upstream-lifecycle-status", "Upstream Lifecycle Status")
    upstream_identity_id = create_upstream_identity!(user_id, "upstream-lifecycle-status")

    assert_db_error(:check_violation, fn ->
      Repo.query!(
        "UPDATE upstream_identities SET status = 'hard_deleted' WHERE id = $1",
        [upstream_identity_id]
      )
    end)

    assert_db_error(:check_violation, fn ->
      Repo.query!(
        """
        INSERT INTO pool_upstream_assignments (
          pool_id, upstream_identity_id, assignment_label, status, health_status,
          eligibility_status, metadata, created_by_user_id
        ) VALUES ($1, $2, 'Invalid Assignment', 'hard_deleted', 'active', 'eligible', '{}'::jsonb, $3)
        """,
        [pool_id, upstream_identity_id, user_id]
      )
    end)
  end

  test "database accepts all supported upstream lifecycle status values" do
    user_id = create_user!("owner-upstream-lifecycle-values@example.com")
    pool_id = create_pool!(user_id, "upstream-lifecycle-values", "Upstream Lifecycle Values")

    for status <- upstream_lifecycle_statuses() do
      upstream_identity_id = create_upstream_identity!(user_id, "identity-#{status}")

      Repo.query!("UPDATE upstream_identities SET status = $1 WHERE id = $2", [
        status,
        upstream_identity_id
      ])

      assignment_id =
        create_assignment!(pool_id, upstream_identity_id, user_id, "assignment-#{status}")

      Repo.query!("UPDATE pool_upstream_assignments SET status = $1 WHERE id = $2", [
        status,
        assignment_id
      ])
    end
  end

  test "database accepts kept request endpoints and rejects pruned runtime endpoints" do
    user_id = create_user!("owner-request-endpoint@example.com")
    pool_id = create_pool!(user_id, "request-endpoint", "Request Endpoint")
    api_key_id = create_api_key!(pool_id, user_id, "sk_request_endpoint")

    kept_endpoints = [
      "/backend-api/codex/models",
      "/backend-api/codex/responses",
      "/backend-api/codex/responses/compact",
      "/backend-api/codex/images/generations",
      "/backend-api/codex/images/edits",
      "/backend-api/transcribe",
      "/backend-api/files",
      "/backend-api/files/uploaded",
      "/api/codex/usage",
      "/wham/usage",
      "/backend-api/wham/usage",
      "/v1/models",
      "/v1/responses",
      "/v1/usage",
      "/v1/files",
      "/v1/files/content",
      "/v1/files/delete"
    ]

    for endpoint <- kept_endpoints do
      Repo.query!(
        """
        INSERT INTO requests (
          pool_id, api_key_id, requested_model, endpoint, transport, status, usage_status, correlation_id
        ) VALUES ($1, $2, 'gpt-example', $3, 'http_json', 'accepted', 'usage_pending', $4)
        """,
        [pool_id, api_key_id, endpoint, "corr-kept-#{:erlang.phash2(endpoint)}"]
      )
    end

    pruned_endpoints = [
      "/backend-api/codex/thread/goal/get",
      "/backend-api/codex/thread/goal/set",
      "/backend-api/codex/thread/goal/clear",
      "/backend-api/codex/analytics-events/events",
      "/backend-api/codex/memories/trace_summarize",
      "/backend-api/codex/alpha/search",
      "/backend-api/codex/realtime/calls",
      "/backend-api/codex/safety/arc",
      "/backend-api/codex/agent-identities/jwks",
      "/backend-api/wham/agent-identities/jwks",
      "/api/codex/rate-limit-reset-credits/consume",
      "/wham/rate-limit-reset-credits/consume",
      "/backend-api/wham/rate-limit-reset-credits/consume",
      "/backend-api/codex/thread/goal",
      "/backend-api/codex/not-added"
    ]

    for endpoint <- pruned_endpoints do
      assert_db_error(:check_violation, fn ->
        Repo.query!(
          """
          INSERT INTO requests (
            pool_id, api_key_id, requested_model, endpoint, transport, status, usage_status, correlation_id
          ) VALUES ($1, $2, 'gpt-example', $3, 'http_json', 'accepted', 'usage_pending', $4)
          """,
          [pool_id, api_key_id, endpoint, "corr-pruned-#{:erlang.phash2(endpoint)}"]
        )
      end)
    end
  end

  test "database rejects orphaned child rows" do
    user_id = create_user!("owner-orphan@example.com")
    pool_id = create_pool!(user_id, "orphan", "Orphan")
    missing_api_key_id = Ecto.UUID.generate() |> Ecto.UUID.dump!()

    assert_db_error(:foreign_key_violation, fn ->
      Repo.query!(
        """
        INSERT INTO requests (
          pool_id, api_key_id, requested_model, endpoint, transport, status, usage_status, correlation_id
        ) VALUES ($1, $2, 'gpt-example', '/backend-api/codex/responses', 'http_json', 'accepted', 'usage_pending', $3)
        """,
        [pool_id, missing_api_key_id, "corr-orphan-api-key"]
      )
    end)
  end

  test "database cascades pool deletion through API keys and requests" do
    user_id = create_user!("owner-pool-cascade@example.com")
    pool_id = create_pool!(user_id, "pool-cascade", "Pool Cascade")
    api_key_id = create_api_key!(pool_id, user_id, "sk_pool_cascade")
    model_id = create_model!(pool_id, "pool-cascade")

    request_id = create_request!(pool_id, api_key_id, "corr-pool-cascade")
    set_request_model!(request_id, model_id)

    upstream_identity_id = create_upstream_identity!(user_id, "pool-cascade")
    assignment_id = create_assignment!(pool_id, upstream_identity_id, user_id, "pool-cascade")

    operator_pool_assignment_id =
      create_operator_pool_assignment!(user_id, pool_id, "active", "NULL")

    fixture = %{
      api_key_id: api_key_id,
      assignment_id: assignment_id,
      model_id: model_id,
      pool_id: pool_id,
      pricing_snapshot_id: create_pricing_snapshot!("pool-cascade"),
      request_id: request_id,
      upstream_identity_id: upstream_identity_id
    }

    attempt_id = create_attempt!(fixture)

    ledger_entry_id =
      create_ledger_entry!(fixture, attempt_id, %{
        entry_kind: "settlement",
        source_event_id: "pool-cascade:settlement"
      })

    Repo.query!("DELETE FROM pools WHERE id = $1", [pool_id])

    assert count_rows("pools", pool_id) == 0
    assert count_rows("api_keys", api_key_id) == 0
    assert count_rows("models", model_id) == 0
    assert count_rows("operator_pool_assignments", operator_pool_assignment_id) == 0
    assert count_rows("requests", request_id) == 0
    assert count_rows("attempts", attempt_id) == 0
    assert count_rows("ledger_entries", ledger_entry_id) == 0
  end

  test "database cascades assignment deletion to attempts and codex sessions while nulling ledger entries" do
    fixture = create_execution_fixture!("assignment-cascade")

    attempt_id = create_attempt!(fixture)
    create_codex_session!(fixture.pool_id, fixture.assignment_id)

    ledger_entry_id =
      create_ledger_entry!(fixture, nil, %{
        entry_kind: "reservation",
        source_event_id: "assignment-cascade:reservation"
      })

    Repo.query!("DELETE FROM pool_upstream_assignments WHERE id = $1", [fixture.assignment_id])

    assert count_rows("attempts", attempt_id) == 0
    assert count_rows("codex_sessions", fixture.codex_session_id) == 0

    assert [[nil]] =
             Repo.query!(
               "SELECT pool_upstream_assignment_id FROM ledger_entries WHERE id = $1",
               [ledger_entry_id]
             ).rows
  end

  test "database preserves composite final-attempt ownership for Codex turns" do
    fixture = create_execution_fixture!("codex-turn-composite")
    attempt_id = create_attempt!(fixture)
    other_request_id = create_request!(fixture.pool_id, fixture.api_key_id, "corr-other-turn")

    assert_db_error(:foreign_key_violation, fn ->
      Repo.query!(
        """
        INSERT INTO codex_turns (
          codex_session_id, request_id, turn_sequence, transport_kind, final_attempt_id
        ) VALUES ($1, $2, 1, 'http_json', $3)
        """,
        [fixture.codex_session_id, other_request_id, attempt_id]
      )
    end)
  end

  @tag :replay_schema
  test "database enforces replay digests, generations, tuples, and semantic turn uniqueness" do
    fixture = replay_execution_fixture!("replay-shape")
    attempt_id = create_attempt!(fixture)
    turn_id = create_replay_turn!(fixture, <<1::256>>)

    assert_db_constraint(:check_violation, "attempts_replay_generation_check", fn ->
      Repo.query!("UPDATE attempts SET replay_generation = -1 WHERE id = $1", [attempt_id])
    end)

    assert_db_constraint(:check_violation, "codex_turns_semantic_turn_digest_shape_check", fn ->
      Repo.query!("UPDATE codex_turns SET semantic_turn_digest = $1 WHERE id = $2", [
        <<1>>,
        turn_id
      ])
    end)

    assert_db_constraint(:unique_violation, "codex_turns_active_semantic_turn_uq", fn ->
      create_request!(fixture.pool_id, fixture.api_key_id, "corr-replay-semantic-duplicate")
      |> then(fn request_id ->
        create_replay_turn!(%{fixture | request_id: request_id}, <<1::256>>)
      end)
    end)

    base = replay_entitlement_params(fixture, turn_id, attempt_id)

    assert_db_constraint(
      :check_violation,
      "request_replay_entitlements_semantic_turn_digest_shape_check",
      fn -> insert_replay_entitlement!(%{base | semantic_turn_digest: <<1>>}) end
    )

    assert_db_constraint(
      :check_violation,
      "request_replay_entitlements_replay_generation_check",
      fn -> insert_replay_entitlement!(%{base | replay_generation: 0}) end
    )

    assert_db_constraint(
      :check_violation,
      "request_replay_entitlements_api_key_runtime_epoch_check",
      fn -> insert_replay_entitlement!(%{base | api_key_runtime_epoch: -1}) end
    )

    assert_db_constraint(
      :check_violation,
      "request_replay_entitlements_lifecycle_tuple_check",
      fn -> insert_replay_entitlement!(%{base | status: "consumed"}) end
    )

    entitlement_id = insert_replay_entitlement!(base)

    assert_db_constraint(
      :check_violation,
      "request_replay_entitlements_snapshot_immutable_check",
      fn ->
        Repo.query!(
          "UPDATE request_replay_entitlements SET owner_lease_key_version = 'v2' WHERE id = $1",
          [entitlement_id]
        )
      end
    )
  end

  @tag :replay_schema
  test "database rejects cross-request replay turn and attempt ownership" do
    fixture = replay_execution_fixture!("replay-cross-request")
    eligible_attempt_id = create_attempt!(fixture)
    turn_id = create_replay_turn!(fixture, <<2::256>>)
    other_request_id = create_request!(fixture.pool_id, fixture.api_key_id, "corr-replay-other")
    other_fixture = %{fixture | request_id: other_request_id}
    other_attempt_id = create_attempt!(other_fixture)
    other_turn_id = create_replay_turn!(other_fixture, <<3::256>>)
    base = replay_entitlement_params(fixture, turn_id, eligible_attempt_id)

    assert_db_constraint(
      :foreign_key_violation,
      "request_replay_entitlements_codex_turn_request_fkey",
      fn -> insert_replay_entitlement!(%{base | codex_turn_id: other_turn_id}) end
    )

    assert_db_constraint(
      :foreign_key_violation,
      "request_replay_entitlements_eligible_attempt_request_fkey",
      fn -> insert_replay_entitlement!(%{base | eligible_attempt_id: other_attempt_id}) end
    )
  end

  @tag :replay_schema
  test "database preserves legacy generation zero and advances replay wall clock within transactions" do
    fixture = replay_execution_fixture!("replay-default-clock")
    attempt_id = create_attempt!(fixture)

    assert [[0]] =
             Repo.query!("SELECT replay_generation FROM attempts WHERE id = $1", [attempt_id]).rows

    assert {:ok, [first, second]} =
             Repo.transaction(fn ->
               [[first]] = Repo.query!("SELECT request_replay_db_now()").rows
               [[second]] = Repo.query!("SELECT request_replay_db_now()").rows
               [first, second]
             end)

    assert NaiveDateTime.compare(first, second) == :lt
  end

  @tag :replay_schema
  test "database enforces every replay digest, epoch, text, and time shape" do
    fixture = replay_execution_fixture!("replay-complete-shapes")
    eligible_attempt_id = create_attempt!(fixture)
    turn_id = create_replay_turn!(fixture, <<1::256>>)
    base = replay_entitlement_params(fixture, turn_id, eligible_attempt_id)

    for {field, constraint, extras} <- [
          {:replay_claim_digest, "request_replay_entitlements_replay_claim_digest_shape_check",
           %{}},
          {:provisional_binding_digest,
           "request_replay_entitlements_provisional_digest_shape_check",
           consumed_tuple(%{replay_attempt_id: eligible_attempt_id})},
          {:owner_lease_digest, "request_replay_entitlements_owner_lease_digest_shape_check", %{}}
        ] do
      assert_db_constraint(:check_violation, constraint, fn ->
        base
        |> Map.merge(extras)
        |> Map.put(field, <<1>>)
        |> insert_replay_entitlement!()
      end)
    end

    assert_db_constraint(
      :check_violation,
      "request_replay_entitlements_predecessor_epoch_check",
      fn -> insert_replay_entitlement!(%{base | predecessor_epoch: 0}) end
    )

    for {field, constraint} <- [
          {:model_identifier, "request_replay_entitlements_model_identifier_present_check"},
          {:owner_lease_key_version,
           "request_replay_entitlements_lease_key_version_present_check"}
        ] do
      assert_db_constraint(:check_violation, constraint, fn ->
        insert_replay_entitlement!(Map.put(base, field, "  \t"))
      end)
    end

    assert_db_constraint(:check_violation, "request_replay_entitlements_expiry_check", fn ->
      insert_replay_entitlement!(Map.put(base, :expires_offset_seconds, 0))
    end)

    assert_db_constraint(:check_violation, "request_replay_entitlements_status_check", fn ->
      insert_replay_entitlement!(%{base | status: "unknown"})
    end)
  end

  @tag :replay_schema
  test "database accepts the complete replay lifecycle tuple matrix" do
    for {suffix, attrs} <- replay_legal_tuple_matrix() do
      fixture = replay_execution_fixture!("replay-legal-#{suffix}")
      eligible_attempt_id = create_attempt!(fixture)
      replay_attempt_id = create_attempt!(%{fixture | request_id: fixture.request_id}, 2)
      turn_id = create_replay_turn!(fixture, <<1::256>>)

      params =
        fixture
        |> replay_entitlement_params(turn_id, eligible_attempt_id)
        |> Map.put(:replay_attempt_id, replay_attempt_id)
        |> Map.merge(attrs)
        |> materialize_replay_attempt(replay_attempt_id)

      entitlement_id = insert_replay_entitlement!(params)
      assert count_rows("request_replay_entitlements", entitlement_id) == 1
    end
  end

  @tag :replay_schema
  test "database rejects malformed replay lifecycle tuples and timestamp orderings" do
    for {suffix, attrs} <- replay_illegal_tuple_matrix() do
      fixture =
        replay_execution_fixture!(
          "replay-illegal-#{suffix}-#{System.unique_integer([:positive])}"
        )

      eligible_attempt_id = create_attempt!(fixture)
      replay_attempt_id = create_attempt!(%{fixture | request_id: fixture.request_id}, 2)
      turn_id = create_replay_turn!(fixture, <<1::256>>)

      params =
        fixture
        |> replay_entitlement_params(turn_id, eligible_attempt_id)
        |> Map.put(:replay_attempt_id, replay_attempt_id)
        |> Map.merge(attrs)
        |> materialize_replay_attempt(replay_attempt_id)

      assert_db_constraint(
        :check_violation,
        "request_replay_entitlements_lifecycle_tuple_check",
        fn -> insert_replay_entitlement!(params) end
      )
    end
  end

  @tag :replay_schema
  test "database enforces semantic equality, request snapshots, and replay-attempt ownership" do
    fixture = replay_execution_fixture!("replay-cross-snapshot")
    eligible_attempt_id = create_attempt!(fixture)
    replay_attempt_id = create_attempt!(fixture, 2)
    turn_id = create_replay_turn!(fixture, <<1::256>>)
    base = replay_entitlement_params(fixture, turn_id, eligible_attempt_id)

    assert_db_constraint(
      :check_violation,
      "request_replay_entitlements_semantic_turn_match_check",
      fn -> insert_replay_entitlement!(%{base | semantic_turn_digest: <<9::256>>}) end
    )

    for {field, value} <- [
          {:model_identifier, "wrong-model"},
          {:api_key_runtime_epoch, 1}
        ] do
      assert_db_constraint(
        :check_violation,
        "request_replay_entitlements_request_snapshot_match_check",
        fn -> insert_replay_entitlement!(Map.put(base, field, value)) end
      )
    end

    other_request_id =
      create_request!(fixture.pool_id, fixture.api_key_id, "corr-replay-cross-attempt")

    other_attempt_id = create_attempt!(%{fixture | request_id: other_request_id})

    assert_db_constraint(
      :foreign_key_violation,
      "request_replay_entitlements_replay_attempt_request_fkey",
      fn ->
        base
        |> Map.merge(%{
          status: "consumed",
          replay_attempt_id: other_attempt_id,
          provisional_binding_digest: <<4::256>>,
          consumed_offset_seconds: 1,
          abandon_offset_seconds: 10
        })
        |> insert_replay_entitlement!()
      end
    )

    entitlement_id =
      base
      |> Map.merge(%{
        status: "consumed",
        replay_attempt_id: replay_attempt_id,
        provisional_binding_digest: <<4::256>>,
        consumed_offset_seconds: 1,
        abandon_offset_seconds: 10
      })
      |> insert_replay_entitlement!()

    assert_db_constraint(
      :check_violation,
      "request_replay_entitlements_semantic_turn_immutable_check",
      fn ->
        Repo.query!("UPDATE codex_turns SET semantic_turn_digest = $1 WHERE id = $2", [
          <<8::256>>,
          turn_id
        ])
      end
    )

    assert_db_constraint(
      :check_violation,
      "request_replay_entitlements_request_snapshot_immutable_check",
      fn ->
        Repo.query!("UPDATE requests SET requested_model = 'changed' WHERE id = $1", [
          fixture.request_id
        ])
      end
    )

    assert count_rows("request_replay_entitlements", entitlement_id) == 1
  end

  @tag :replay_schema
  test "database makes every replay entitlement identity snapshot immutable" do
    immutable_fields = [
      :request_id,
      :codex_turn_id,
      :eligible_attempt_id,
      :api_key_id,
      :api_key_runtime_epoch,
      :pool_id,
      :model_id,
      :model_identifier,
      :semantic_turn_digest,
      :replay_claim_digest,
      :replay_generation,
      :owner_lease_digest,
      :owner_lease_key_version,
      :predecessor_epoch,
      :armed_at,
      :expires_at
    ]

    for field <- immutable_fields do
      fixture = replay_execution_fixture!("replay-immutable-#{field}")
      eligible_attempt_id = create_attempt!(fixture)
      turn_id = create_replay_turn!(fixture, <<1::256>>)

      entitlement_id =
        fixture
        |> replay_entitlement_params(turn_id, eligible_attempt_id)
        |> insert_replay_entitlement!()

      assert_db_constraint(
        :check_violation,
        "request_replay_entitlements_snapshot_immutable_check",
        fn -> mutate_entitlement_snapshot!(entitlement_id, field) end
      )
    end
  end

  @tag :replay_schema
  test "database makes every replay request identity snapshot immutable" do
    request_snapshot_fields = [
      :pool_id,
      :api_key_id,
      :model_id,
      :requested_model,
      :reasoning_effort,
      :requested_service_tier,
      :actual_service_tier,
      :service_tier,
      :upstream_account_label,
      :upstream_account_email,
      :upstream_account_plan_label,
      :upstream_account_plan_family
    ]

    for field <- request_snapshot_fields do
      fixture = replay_execution_fixture!("replay-request-immutable-#{field}")
      eligible_attempt_id = create_attempt!(fixture)
      turn_id = create_replay_turn!(fixture, <<1::256>>)

      fixture
      |> replay_entitlement_params(turn_id, eligible_attempt_id)
      |> insert_replay_entitlement!()

      assert_db_constraint(
        :check_violation,
        "request_replay_entitlements_request_snapshot_immutable_check",
        fn -> mutate_request_snapshot!(fixture.request_id, field) end
      )
    end
  end

  @tag :replay_schema
  test "database forbids replay rearm and terminal transition after consumption" do
    fixture = replay_execution_fixture!("replay-no-rearm")
    eligible_attempt_id = create_attempt!(fixture)
    replay_attempt_id = create_attempt!(fixture, 2)
    turn_id = create_replay_turn!(fixture, <<1::256>>)

    entitlement_id =
      fixture
      |> replay_entitlement_params(turn_id, eligible_attempt_id)
      |> Map.merge(%{
        status: "consumed",
        replay_attempt_id: replay_attempt_id,
        provisional_binding_digest: <<4::256>>,
        consumed_offset_seconds: 1,
        abandon_offset_seconds: 10
      })
      |> insert_replay_entitlement!()

    for status <- ["armed", "expired", "revoked"] do
      assert_db_constraint(
        :check_violation,
        "request_replay_entitlements_status_transition_check",
        fn ->
          Repo.query!(
            """
            UPDATE request_replay_entitlements
            SET status = $1,
                replay_attempt_id = NULL,
                provisional_binding_digest = NULL,
                consumed_at = NULL,
                abandon_at = NULL,
                terminal_at = CASE WHEN $1 IN ('expired', 'revoked') THEN request_replay_db_now() + interval '31 seconds' ELSE NULL END,
                closed_at = CASE WHEN $1 IN ('expired', 'revoked') THEN request_replay_db_now() + interval '32 seconds' ELSE NULL END
            WHERE id = $2
            """,
            [status, entitlement_id]
          )
        end
      )
    end

    assert_db_constraint(
      :check_violation,
      "request_replay_entitlements_consumption_immutable_check",
      fn ->
        Repo.query!(
          "UPDATE request_replay_entitlements SET consumed_at = consumed_at + interval '1 second', abandon_at = abandon_at + interval '1 second' WHERE id = $1",
          [entitlement_id]
        )
      end
    )

    for {suffix, initial_status, target_status} <- [
          {"expired-to-armed", "expired", "armed"},
          {"revoked-to-armed", "revoked", "armed"}
        ] do
      terminal_fixture = replay_execution_fixture!("replay-terminal-#{suffix}")
      terminal_attempt = create_attempt!(terminal_fixture)
      terminal_turn = create_replay_turn!(terminal_fixture, <<1::256>>)

      terminal_id =
        terminal_fixture
        |> replay_entitlement_params(terminal_turn, terminal_attempt)
        |> Map.merge(%{
          status: initial_status,
          terminal_offset_seconds: if(initial_status == "expired", do: 30, else: 1),
          closed_offset_seconds: 31
        })
        |> insert_replay_entitlement!()

      assert_db_constraint(
        :check_violation,
        "request_replay_entitlements_status_transition_check",
        fn ->
          Repo.query!(
            """
            UPDATE request_replay_entitlements
            SET status = $1,
                terminal_at = CASE WHEN $1 IN ('expired', 'revoked') THEN terminal_at ELSE NULL END,
                closed_at = CASE WHEN $1 IN ('expired', 'revoked') THEN closed_at ELSE NULL END
            WHERE id = $2
            """,
            [target_status, terminal_id]
          )
        end
      )
    end

    for {suffix, initial_status, target_status} <- [
          {"expired-to-revoked", "expired", "revoked"},
          {"revoked-to-expired", "revoked", "expired"}
        ] do
      terminal_fixture = replay_execution_fixture!("replay-terminal-#{suffix}")
      terminal_attempt = create_attempt!(terminal_fixture)
      terminal_turn = create_replay_turn!(terminal_fixture, <<1::256>>)

      terminal_id =
        terminal_fixture
        |> replay_entitlement_params(terminal_turn, terminal_attempt)
        |> Map.merge(%{
          status: initial_status,
          terminal_offset_seconds: 30,
          closed_offset_seconds: 31
        })
        |> insert_replay_entitlement!()

      assert_db_constraint(
        :check_violation,
        "request_replay_entitlements_status_transition_check",
        fn ->
          Repo.query!(
            "UPDATE request_replay_entitlements SET status = $1 WHERE id = $2",
            [target_status, terminal_id]
          )
        end
      )
    end
  end

  test "soft deleting an upstream account preserves historical references" do
    fixture = create_execution_fixture!("soft-delete-preserve")
    attempt_id = create_attempt!(fixture)

    ledger_entry_id =
      create_ledger_entry!(fixture, attempt_id, %{
        entry_kind: "settlement",
        source_event_id: "soft-delete-preserve:settlement"
      })

    upstream_identity_id = Ecto.UUID.load!(fixture.upstream_identity_id)
    user = Repo.get_by!(User, email: "owner-soft-delete-preserve@example.com")
    scope = owner_scope_for(user)

    assert {:ok, result} =
             Upstreams.soft_delete_account_for_scope(scope, upstream_identity_id, %{})

    assert result.status == :deleted

    assert count_rows("upstream_identities", fixture.upstream_identity_id) == 1
    assert count_rows("pool_upstream_assignments", fixture.assignment_id) == 1
    assert count_rows("attempts", attempt_id) == 1
    assert count_rows("ledger_entries", ledger_entry_id) == 1
    assert count_rows("codex_sessions", fixture.codex_session_id) == 1

    assert [["deleted"]] =
             Repo.query!("SELECT status FROM upstream_identities WHERE id = $1", [
               fixture.upstream_identity_id
             ]).rows

    assert [["deleted"]] =
             Repo.query!("SELECT status FROM pool_upstream_assignments WHERE id = $1", [
               fixture.assignment_id
             ]).rows
  end

  test "database rejects duplicate active operator pool assignments by status predicate" do
    user_id = create_user!("owner-operator-pool-assignment-unique@example.com")
    pool_id = create_pool!(user_id, "operator-pool-assignment-unique", "Operator Assignment")

    create_operator_pool_assignment!(user_id, pool_id, "active", "now()")
    create_operator_pool_assignment!(user_id, pool_id, "revoked", "now()")

    assert_db_error(:unique_violation, fn ->
      create_operator_pool_assignment!(user_id, pool_id, "active", "now()")
    end)
  end

  test "database enforces operator pool assignment statuses" do
    user_id = create_user!("owner-operator-pool-assignment-status@example.com")

    pool_id =
      create_pool!(user_id, "operator-pool-assignment-status", "Operator Assignment Status")

    assert_db_error(:check_violation, fn ->
      create_operator_pool_assignment!(user_id, pool_id, "disabled", "NULL")
    end)

    assert_db_error(:check_violation, fn ->
      create_operator_pool_assignment!(user_id, pool_id, "unknown", "NULL")
    end)
  end

  test "database preserves revoked operator assignment history while allowing regrant" do
    user_id = create_user!("owner-operator-pool-assignment-regrant@example.com")

    pool_id =
      create_pool!(user_id, "operator-pool-assignment-regrant", "Operator Assignment Regrant")

    first_active_id = create_operator_pool_assignment!(user_id, pool_id, "active", "NULL")

    Repo.query!(
      "UPDATE operator_pool_assignments SET status = 'revoked', revoked_at = now() WHERE id = $1",
      [first_active_id]
    )

    first_revoked_id = create_operator_pool_assignment!(user_id, pool_id, "revoked", "now()")
    second_active_id = create_operator_pool_assignment!(user_id, pool_id, "active", "NULL")

    assert [[2]] =
             Repo.query!(
               "SELECT COUNT(*) FROM operator_pool_assignments WHERE user_id = $1 AND pool_id = $2 AND status = 'revoked'",
               [user_id, pool_id]
             ).rows

    assert [[1]] =
             Repo.query!(
               "SELECT COUNT(*) FROM operator_pool_assignments WHERE user_id = $1 AND pool_id = $2 AND status = 'active'",
               [user_id, pool_id]
             ).rows

    assert count_rows("operator_pool_assignments", first_active_id) == 1
    assert count_rows("operator_pool_assignments", first_revoked_id) == 1
    assert count_rows("operator_pool_assignments", second_active_id) == 1
  end

  test "database allows multiple active owner memberships" do
    first_owner_id = create_user!("owner-multiple-active-owner-1@example.com")
    second_owner_id = create_user!("owner-multiple-active-owner-2@example.com")

    first_membership_id =
      create_membership!(first_owner_id, "instance_owner", "active", first_owner_id)

    second_membership_id =
      create_membership!(second_owner_id, "instance_owner", "active", first_owner_id)

    assert [[2]] =
             Repo.query!(
               """
               SELECT COUNT(*)
               FROM memberships
               WHERE role = 'instance_owner'
                 AND status = 'active'
                 AND id = ANY($1::uuid[])
               """,
               [[first_membership_id, second_membership_id]]
             ).rows
  end

  test "legacy active instance admin membership backfill rewrites all rows to active owners" do
    existing_owner_id = create_user!("owner-legacy-admin-existing-owner@example.com")
    first_admin_id = create_user!("owner-legacy-admin-backfill-1@example.com")
    second_admin_id = create_user!("owner-legacy-admin-backfill-2@example.com")

    owner_membership_id =
      create_membership!(existing_owner_id, "instance_owner", "active", existing_owner_id)

    first_membership_id =
      create_membership!(first_admin_id, "instance_admin", "active", existing_owner_id)

    second_membership_id =
      create_membership!(second_admin_id, "instance_admin", "active", existing_owner_id)

    rewrite_legacy_instance_admin_memberships!()

    rows =
      Repo.query!(
        """
        SELECT id, role, status, revoked_at
        FROM memberships
        WHERE id = ANY($1::uuid[])
        """,
        [[first_membership_id, owner_membership_id, second_membership_id]]
      ).rows

    assert Enum.sort(rows) ==
             Enum.sort([
               [first_membership_id, "instance_owner", "active", nil],
               [owner_membership_id, "instance_owner", "active", nil],
               [second_membership_id, "instance_owner", "active", nil]
             ])

    assert [[0]] =
             Repo.query!(
               "SELECT COUNT(*) FROM memberships WHERE role = 'instance_admin' AND status = 'active'"
             ).rows
  end

  test "membership role demotion blocks the final active owner" do
    revoke_all_active_memberships!()
    owner_id = create_user!("owner-final-role-demotion@example.com")
    membership_id = create_membership!(owner_id, "instance_owner", "active", owner_id)
    owner = Repo.get!(User, load_uuid!(owner_id))
    membership = Repo.get!(Membership, load_uuid!(membership_id))

    assert {:error, :last_active_owner} =
             Pools.change_membership_role(Scope.for_user(owner, []), membership, "instance_admin")

    assert %Membership{role: "instance_owner", status: "active"} = Repo.reload!(membership)

    refute Repo.get_by(AuditEvent,
             action: "membership.role_update",
             actor_user_id: owner.id,
             target_id: membership.id
           )
  end

  test "membership revocation blocks the final active owner" do
    revoke_all_active_memberships!()
    owner_id = create_user!("owner-final-membership-revoke@example.com")
    membership_id = create_membership!(owner_id, "instance_owner", "active", owner_id)
    owner = Repo.get!(User, load_uuid!(owner_id))
    membership = Repo.get!(Membership, load_uuid!(membership_id))

    assert {:error, :last_active_owner} =
             Pools.revoke_membership(Scope.for_user(owner, []), membership)

    assert %Membership{role: "instance_owner", status: "active", revoked_at: nil} =
             Repo.reload!(membership)

    refute Repo.get_by(AuditEvent,
             action: "membership.revoke",
             actor_user_id: owner.id,
             target_id: membership.id
           )
  end

  test "membership owner demotion and revocation are deterministic and audited when another active owner remains" do
    revoke_all_active_memberships!()
    actor_id = create_user!("owner-membership-change-actor@example.com")
    demoted_owner_id = create_user!("owner-membership-change-demoted@example.com")
    revoked_owner_id = create_user!("owner-membership-change-revoked@example.com")

    create_membership!(actor_id, "instance_owner", "active", actor_id)

    demoted_membership_id =
      create_membership!(demoted_owner_id, "instance_owner", "active", actor_id)

    revoked_membership_id =
      create_membership!(revoked_owner_id, "instance_owner", "active", actor_id)

    actor = Repo.get!(User, load_uuid!(actor_id))
    demoted_membership = Repo.get!(Membership, load_uuid!(demoted_membership_id))
    revoked_membership = Repo.get!(Membership, load_uuid!(revoked_membership_id))
    scope = Scope.for_user(actor, [])

    assert {:ok, %Membership{} = demoted} =
             Pools.change_membership_role(scope, demoted_membership, "instance_admin")

    assert demoted.role == "instance_admin"
    assert demoted.status == "active"

    assert {:ok, %Membership{} = revoked} = Pools.revoke_membership(scope, revoked_membership)

    assert revoked.role == "instance_owner"
    assert revoked.status == "revoked"
    refute is_nil(revoked.revoked_at)

    assert Repo.get_by(AuditEvent,
             action: "membership.role_update",
             actor_user_id: actor.id,
             target_id: demoted_membership.id
           )

    assert Repo.get_by(AuditEvent,
             action: "membership.revoke",
             actor_user_id: actor.id,
             target_id: revoked_membership.id
           )
  end

  test "legacy admin backfill keeps an existing same-user active owner grant" do
    user_id = create_user!("owner-legacy-admin-duplicate-owner@example.com")

    owner_membership_id =
      create_membership!(user_id, "instance_owner", "active", user_id)

    duplicate_admin_membership_id =
      create_membership!(user_id, "instance_admin", "active", user_id)

    rewrite_legacy_instance_admin_memberships!()

    rows =
      Repo.query!(
        """
        SELECT id, role, status, revoked_at
        FROM memberships
        WHERE id = ANY($1::uuid[])
        """,
        [[owner_membership_id, duplicate_admin_membership_id]]
      ).rows
      |> Map.new(fn [id, role, status, revoked_at] -> {id, {role, status, revoked_at}} end)

    assert {"instance_owner", "active", nil} = rows[owner_membership_id]
    assert {"instance_owner", "revoked", revoked_at} = rows[duplicate_admin_membership_id]
    refute is_nil(revoked_at)

    assert [[1]] =
             Repo.query!(
               """
               SELECT COUNT(*)
               FROM memberships
               WHERE user_id = $1
                 AND role = 'instance_owner'
                 AND status = 'active'
               """,
               [user_id]
             ).rows

    assert [[0]] =
             Repo.query!(
               """
               SELECT COUNT(*)
               FROM memberships
               WHERE user_id = $1
                 AND role = 'instance_admin'
                 AND status = 'active'
               """,
               [user_id]
             ).rows
  end

  defp load_uuid!(uuid), do: Ecto.UUID.load!(uuid)

  defp revoke_all_active_memberships! do
    Repo.query!("""
    UPDATE memberships
    SET status = 'revoked',
        revoked_at = COALESCE(revoked_at, now())
    WHERE status = 'active'
    """)
  end

  defp create_user!(email) do
    [[id]] =
      Repo.query!(
        """
        INSERT INTO users (email, display_name, password_hash, status)
        VALUES ($1, 'Owner', '$argon2id$v=19$m=65536,t=3,p=2$fixture$fixture', 'active')
        RETURNING id
        """,
        [email]
      ).rows

    id
  end

  defp create_pool!(user_id, slug, name) do
    [[id]] =
      Repo.query!(
        """
        INSERT INTO pools (slug, name, status, created_by_user_id)
        VALUES ($1, $2, 'active', $3)
        RETURNING id
        """,
        [slug, name, user_id]
      ).rows

    id
  end

  defp owner_scope_for(user) do
    case existing_owner() do
      %User{} = owner ->
        Scope.for_user(owner, ["instance_owner"])

      nil ->
        %Membership{}
        |> Membership.changeset(%{
          user_id: user.id,
          role: "instance_owner",
          status: "active",
          created_by_user_id: user.id
        })
        |> Repo.insert!()

        Scope.for_user(user, ["instance_owner"])
    end
  end

  defp existing_owner do
    Repo.one(
      from user in User,
        join: membership in Membership,
        on: membership.user_id == user.id,
        where: membership.role == "instance_owner" and membership.status == "active",
        limit: 1,
        select: user
    )
  end

  defp create_api_key!(pool_id, user_id, prefix) do
    [[id]] =
      Repo.query!(
        """
        INSERT INTO api_keys (pool_id, display_name, key_prefix, key_hash, status, created_by_user_id)
        VALUES ($1, 'Primary key', $2, $3, 'active', $4)
        RETURNING id
        """,
        [pool_id, prefix, prefix <> ":hash", user_id]
      ).rows

    id
  end

  defp create_model!(pool_id, suffix) do
    [[id]] =
      Repo.query!(
        """
        INSERT INTO models (
          pool_id, upstream_model_id, exposed_model_id, display_name, status,
          supports_responses, supports_streaming, supports_tools, supports_reasoning,
          metadata
        ) VALUES (
          $1, 'gpt-example', $2, 'GPT Example', 'active',
          true, true, true, true, '{}'::jsonb
        )
        RETURNING id
        """,
        [pool_id, "gpt-example-#{suffix}"]
      ).rows

    id
  end

  defp create_execution_fixture!(suffix) do
    user_id = create_user!("owner-#{suffix}@example.com")
    pool_id = create_pool!(user_id, suffix, String.replace(suffix, "-", " "))
    api_key_id = create_api_key!(pool_id, user_id, "sk_#{suffix}")
    upstream_identity_id = create_upstream_identity!(user_id, suffix)
    assignment_id = create_assignment!(pool_id, upstream_identity_id, user_id, suffix)
    pricing_snapshot_id = create_pricing_snapshot!(suffix)
    request_id = create_request!(pool_id, api_key_id, "corr-#{suffix}")
    codex_session_id = create_codex_session!(pool_id, assignment_id)

    %{
      api_key_id: api_key_id,
      assignment_id: assignment_id,
      codex_session_id: codex_session_id,
      model_id: nil,
      pool_id: pool_id,
      pricing_snapshot_id: pricing_snapshot_id,
      request_id: request_id,
      upstream_identity_id: upstream_identity_id
    }
  end

  defp create_upstream_identity!(user_id, suffix) do
    [[id]] =
      Repo.query!(
        """
        INSERT INTO upstream_identities (
          account_label, onboarding_method, status, plan_family, plan_label,
          auth_fresh_at, auth_verified_at, metadata, created_by_user_id
        ) VALUES (
          $1, 'device', 'active', 'pro', 'Pro', now(), now(), '{}'::jsonb, $2
        )
        RETURNING id
        """,
        ["Upstream #{suffix}", user_id]
      ).rows

    id
  end

  defp create_assignment!(pool_id, upstream_identity_id, user_id, suffix) do
    [[id]] =
      Repo.query!(
        """
        INSERT INTO pool_upstream_assignments (
          pool_id, upstream_identity_id, assignment_label, status, health_status,
          eligibility_status, metadata, created_by_user_id
        ) VALUES ($1, $2, $3, 'active', 'active', 'eligible', '{}'::jsonb, $4)
        RETURNING id
        """,
        [pool_id, upstream_identity_id, "Assignment #{suffix}", user_id]
      ).rows

    id
  end

  defp create_operator_pool_assignment!(user_id, pool_id, status, revoked_at_sql) do
    [[id]] =
      Repo.query!(
        """
        INSERT INTO operator_pool_assignments (
          user_id, pool_id, status, created_by_user_id, revoked_at
        ) VALUES ($1, $2, $3, $4, #{revoked_at_sql})
        RETURNING id
        """,
        [user_id, pool_id, status, user_id]
      ).rows

    id
  end

  defp create_membership!(user_id, role, status, created_by_user_id) do
    [[id]] =
      Repo.query!(
        """
        INSERT INTO memberships (user_id, role, status, created_by_user_id)
        VALUES ($1, $2, $3, $4)
        RETURNING id
        """,
        [user_id, role, status, created_by_user_id]
      ).rows

    id
  end

  defp rewrite_legacy_instance_admin_memberships! do
    Repo.query!("DROP INDEX IF EXISTS public.memberships_single_instance_owner_active_uq")

    Repo.query!("""
    UPDATE public.memberships legacy_admin
    SET status = 'revoked',
        revoked_at = COALESCE(legacy_admin.revoked_at, now())
    WHERE legacy_admin.role = 'instance_admin'
      AND legacy_admin.status = 'active'
      AND EXISTS (
        SELECT 1
        FROM public.memberships active_owner
        WHERE active_owner.user_id = legacy_admin.user_id
          AND active_owner.role = 'instance_owner'
          AND active_owner.status = 'active'
      )
    """)

    Repo.query!("""
    UPDATE public.memberships membership
    SET role = 'instance_owner'
    WHERE membership.role = 'instance_admin'
    """)
  end

  defp create_pricing_snapshot!(suffix) do
    [[id]] =
      Repo.query!(
        """
        INSERT INTO pricing_snapshots (
          model_identifier, price_version, currency_code, billing_unit,
          input_token_micros, output_token_micros, effective_at, config
        ) VALUES ('gpt-example', $1, 'USD', 'token', 1, 2, now(), '{}'::jsonb)
        RETURNING id
        """,
        ["test-#{suffix}"]
      ).rows

    id
  end

  defp create_request!(pool_id, api_key_id, correlation_id) do
    [[id]] =
      Repo.query!(
        """
        INSERT INTO requests (
          pool_id, api_key_id, requested_model, endpoint, transport, status, usage_status,
          correlation_id, request_metadata
        ) VALUES ($1, $2, 'gpt-example', '/backend-api/codex/responses', 'http_json', 'accepted', 'usage_pending', $3, '{}'::jsonb)
        RETURNING id
        """,
        [pool_id, api_key_id, correlation_id]
      ).rows

    id
  end

  defp set_request_model!(request_id, model_id) do
    Repo.query!("UPDATE requests SET model_id = $1 WHERE id = $2", [model_id, request_id])
  end

  defp create_attempt!(fixture, attempt_number \\ 1) do
    [[id]] =
      Repo.query!(
        """
        INSERT INTO attempts (
          request_id, attempt_number, pool_upstream_assignment_id, upstream_identity_id,
          pricing_snapshot_id, model_id, upstream_model_id, transport, status,
          retryable, usage_status, response_metadata
        ) VALUES ($1, $2, $3, $4, $5, $6, 'gpt-example', 'http_json', 'succeeded', false, 'usage_known', '{}'::jsonb)
        RETURNING id
        """,
        [
          fixture.request_id,
          attempt_number,
          fixture.assignment_id,
          fixture.upstream_identity_id,
          fixture.pricing_snapshot_id,
          fixture.model_id
        ]
      ).rows

    id
  end

  defp create_codex_session!(pool_id, assignment_id) do
    [[id]] =
      Repo.query!(
        """
        INSERT INTO codex_sessions (pool_id, session_key, pool_upstream_assignment_id)
        VALUES ($1, $2, $3)
        RETURNING id
        """,
        [pool_id, "session-#{Ecto.UUID.generate()}", assignment_id]
      ).rows

    id
  end

  defp create_replay_turn!(fixture, semantic_turn_digest) do
    [[id]] =
      Repo.query!(
        """
        INSERT INTO codex_turns (
          codex_session_id, request_id, turn_sequence, transport_kind, semantic_turn_digest
        ) VALUES (
          $1, $2,
          (SELECT COALESCE(MAX(turn_sequence), 0) + 1 FROM codex_turns WHERE codex_session_id = $1),
          'websocket', $3
        )
        RETURNING id
        """,
        [fixture.codex_session_id, fixture.request_id, semantic_turn_digest]
      ).rows

    id
  end

  defp replay_execution_fixture!(suffix) do
    fixture = create_execution_fixture!(suffix)
    model_id = create_model!(fixture.pool_id, suffix)
    set_request_model!(fixture.request_id, model_id)
    %{fixture | model_id: model_id}
  end

  defp replay_entitlement_params(fixture, turn_id, eligible_attempt_id) do
    %{
      request_id: fixture.request_id,
      codex_turn_id: turn_id,
      eligible_attempt_id: eligible_attempt_id,
      api_key_id: fixture.api_key_id,
      api_key_runtime_epoch: 0,
      pool_id: fixture.pool_id,
      model_id: fixture.model_id,
      model_identifier: "gpt-example",
      semantic_turn_digest: <<1::256>>,
      replay_claim_digest: <<2::256>>,
      replay_generation: 1,
      owner_lease_digest: <<3::256>>,
      owner_lease_key_version: "v1",
      predecessor_epoch: 1,
      status: "armed",
      expires_offset_seconds: 30
    }
  end

  defp insert_replay_entitlement!(attrs) do
    timestamp_fields = [
      {:consumed_at, :consumed_offset_seconds},
      {:started_at, :started_offset_seconds},
      {:last_liveness_at, :last_liveness_offset_seconds},
      {:abandon_at, :abandon_offset_seconds},
      {:terminal_at, :terminal_offset_seconds},
      {:closed_at, :closed_offset_seconds}
    ]

    timestamp_columns =
      Enum.map_join(timestamp_fields, ", ", fn {column, _offset} -> to_string(column) end)

    timestamp_values =
      timestamp_fields
      |> Enum.with_index(19)
      |> Enum.map_join(", ", fn {{_column, _offset}, index} ->
        "CASE WHEN $#{index}::integer IS NULL THEN NULL ELSE witness.now + ($#{index}::integer * interval '1 second') END"
      end)

    [[id]] =
      Repo.query!(
        """
        WITH witness AS MATERIALIZED (SELECT request_replay_db_now() AS now)
        INSERT INTO request_replay_entitlements (
          request_id, codex_turn_id, eligible_attempt_id, replay_attempt_id, api_key_id,
          api_key_runtime_epoch, pool_id, model_id, model_identifier,
          semantic_turn_digest, replay_claim_digest, provisional_binding_digest, replay_generation,
          owner_lease_digest, owner_lease_key_version, predecessor_epoch,
          status, armed_at, expires_at, #{timestamp_columns}
        ) SELECT
          $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14,
          $15, $16, $17, witness.now,
          witness.now + ($18::integer * interval '1 second'),
          #{timestamp_values}
        FROM witness
        RETURNING id
        """,
        [
          attrs.request_id,
          attrs.codex_turn_id,
          attrs.eligible_attempt_id,
          Map.get(attrs, :replay_attempt_id),
          attrs.api_key_id,
          attrs.api_key_runtime_epoch,
          attrs.pool_id,
          attrs.model_id,
          attrs.model_identifier,
          attrs.semantic_turn_digest,
          attrs.replay_claim_digest,
          Map.get(attrs, :provisional_binding_digest),
          attrs.replay_generation,
          attrs.owner_lease_digest,
          attrs.owner_lease_key_version,
          attrs.predecessor_epoch,
          attrs.status,
          attrs.expires_offset_seconds
        ] ++ Enum.map(timestamp_fields, fn {_column, offset} -> Map.get(attrs, offset) end)
      ).rows

    id
  end

  defp replay_legal_tuple_matrix do
    [
      {"armed", %{replay_attempt_id: nil}},
      {"consumed-open", consumed_tuple()},
      {"consumed-open-started",
       consumed_tuple(%{started_offset_seconds: 2, last_liveness_offset_seconds: 3})},
      {"consumed-closed", consumed_tuple(%{closed_offset_seconds: 11})},
      {"consumed-closed-started",
       consumed_tuple(%{
         started_offset_seconds: 2,
         last_liveness_offset_seconds: 3,
         closed_offset_seconds: 11
       })},
      {"expired",
       %{
         status: "expired",
         replay_attempt_id: nil,
         terminal_offset_seconds: 30,
         closed_offset_seconds: 31
       }},
      {"revoked",
       %{
         status: "revoked",
         replay_attempt_id: nil,
         terminal_offset_seconds: 1,
         closed_offset_seconds: 2
       }}
    ]
  end

  defp replay_illegal_tuple_matrix do
    [
      {"armed-replay-attempt", %{replay_attempt_id: :use_replay_attempt}},
      {"armed-provisional", %{provisional_binding_digest: <<4::256>>}},
      {"consumed-missing-replay", consumed_tuple(%{replay_attempt_id: nil})},
      {"consumed-missing-provisional", consumed_tuple(%{provisional_binding_digest: nil})},
      {"consumed-missing-abandon", consumed_tuple(%{abandon_offset_seconds: nil})},
      {"consumed-abandon-not-after", consumed_tuple(%{abandon_offset_seconds: 1})},
      {"consumed-start-only", consumed_tuple(%{started_offset_seconds: 2})},
      {"consumed-liveness-only", consumed_tuple(%{last_liveness_offset_seconds: 2})},
      {"consumed-start-before",
       consumed_tuple(%{started_offset_seconds: 0, last_liveness_offset_seconds: 2})},
      {"consumed-liveness-before-start",
       consumed_tuple(%{started_offset_seconds: 3, last_liveness_offset_seconds: 2})},
      {"consumed-liveness-at-abandon",
       consumed_tuple(%{started_offset_seconds: 2, last_liveness_offset_seconds: 10})},
      {"consumed-closed-too-early", consumed_tuple(%{closed_offset_seconds: 1})},
      {"consumed-terminal", consumed_tuple(%{terminal_offset_seconds: 4})},
      {"expired-too-early",
       %{
         status: "expired",
         replay_attempt_id: nil,
         terminal_offset_seconds: 29,
         closed_offset_seconds: 31
       }},
      {"expired-consumed",
       %{
         status: "expired",
         replay_attempt_id: :use_replay_attempt,
         provisional_binding_digest: <<4::256>>,
         consumed_offset_seconds: 1,
         terminal_offset_seconds: 30,
         closed_offset_seconds: 31
       }},
      {"revoked-missing-close",
       %{status: "revoked", replay_attempt_id: nil, terminal_offset_seconds: 1}},
      {"revoked-close-at-terminal",
       %{
         status: "revoked",
         replay_attempt_id: nil,
         terminal_offset_seconds: 1,
         closed_offset_seconds: 1
       }}
    ]
  end

  defp consumed_tuple(overrides \\ %{}) do
    Map.merge(
      %{
        status: "consumed",
        replay_attempt_id: :use_replay_attempt,
        provisional_binding_digest: <<4::256>>,
        consumed_offset_seconds: 1,
        abandon_offset_seconds: 10
      },
      overrides
    )
  end

  defp materialize_replay_attempt(%{replay_attempt_id: :use_replay_attempt} = attrs, id),
    do: %{attrs | replay_attempt_id: id}

  defp materialize_replay_attempt(attrs, _id), do: attrs

  defp mutate_entitlement_snapshot!(id, field) do
    expression =
      case field do
        field
        when field in [
               :request_id,
               :codex_turn_id,
               :eligible_attempt_id,
               :api_key_id,
               :pool_id,
               :model_id
             ] ->
          "gen_random_uuid()"

        field when field in [:api_key_runtime_epoch, :replay_generation, :predecessor_epoch] ->
          "#{field} + 1"

        field when field in [:model_identifier, :owner_lease_key_version] ->
          "#{field} || '-changed'"

        field when field in [:semantic_turn_digest, :replay_claim_digest, :owner_lease_digest] ->
          "digest(#{field}, 'sha256')"

        field when field in [:armed_at, :expires_at] ->
          "#{field} + interval '1 second'"
      end

    Repo.query!("UPDATE request_replay_entitlements SET #{field} = #{expression} WHERE id = $1", [
      id
    ])
  end

  defp mutate_request_snapshot!(id, field) do
    expression =
      case field do
        field when field in [:pool_id, :api_key_id, :model_id] ->
          "gen_random_uuid()"

        :requested_model ->
          "requested_model || '-changed'"

        :reasoning_effort ->
          "'high'"

        field when field in [:requested_service_tier, :actual_service_tier, :service_tier] ->
          "'priority'"

        :upstream_account_label ->
          "'changed-label'"

        :upstream_account_email ->
          "'changed@example.com'"

        :upstream_account_plan_label ->
          "'changed-plan'"

        :upstream_account_plan_family ->
          "'changed-family'"
      end

    Repo.query!("UPDATE requests SET #{field} = #{expression} WHERE id = $1", [id])
  end

  defp create_ledger_entry!(fixture, attempt_id, attrs) do
    [[id]] =
      Repo.query!(
        """
        INSERT INTO ledger_entries (
          request_id, attempt_id, pricing_snapshot_id, pool_id, api_key_id,
          pool_upstream_assignment_id, upstream_identity_id, model_id, entry_kind,
          amount_status, usage_status, transport, currency_code, input_tokens,
          total_tokens, request_count, estimated_cost_micros, settled_cost_micros,
          source_event_id, details
        ) VALUES (
          $1, $2, $3, $4, $5, $6, $7, $8, $9,
          'recorded', 'usage_pending', 'http_json', 'USD', 10,
          10, 1, 100, 0, $10, '{}'::jsonb
        )
        RETURNING id
        """,
        [
          fixture.request_id,
          attempt_id,
          fixture.pricing_snapshot_id,
          fixture.pool_id,
          fixture.api_key_id,
          fixture.assignment_id,
          fixture.upstream_identity_id,
          fixture.model_id,
          attrs.entry_kind,
          attrs.source_event_id
        ]
      ).rows

    id
  end

  defp count_rows(table_name, id) do
    [[count]] = Repo.query!("SELECT COUNT(*) FROM #{table_name} WHERE id = $1", [id]).rows
    count
  end

  defp assert_db_error(code, fun) do
    assert_raise Postgrex.Error, fn ->
      try do
        fun.()
      rescue
        error in Postgrex.Error ->
          assert error.postgres.code == code
          reraise error, __STACKTRACE__
      end
    end
  end

  defp assert_db_constraint(code, constraint, fun) do
    assert_raise Postgrex.Error, fn ->
      try do
        fun.()
      rescue
        error in Postgrex.Error ->
          assert error.postgres.code == code
          assert error.postgres.constraint == constraint
          reraise error, __STACKTRACE__
      end
    end
  end

  defp upstream_lifecycle_statuses do
    ~w(active paused refresh_due refreshing refresh_failed reauth_required deleted)
  end
end
