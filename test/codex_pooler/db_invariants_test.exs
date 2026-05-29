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

  test "database accepts explicit control-plane request endpoints and rejects unlisted endpoints" do
    user_id = create_user!("owner-request-endpoint@example.com")
    pool_id = create_pool!(user_id, "request-endpoint", "Request Endpoint")
    api_key_id = create_api_key!(pool_id, user_id, "sk_request_endpoint")

    allowed_endpoints = [
      "/backend-api/codex/thread/goal/get",
      "/backend-api/codex/thread/goal/set",
      "/backend-api/codex/thread/goal/clear",
      "/backend-api/codex/analytics-events/events",
      "/backend-api/codex/memories/trace_summarize",
      "/backend-api/codex/realtime/calls",
      "/backend-api/codex/safety/arc",
      "/backend-api/codex/agent-identities/jwks",
      "/backend-api/wham/agent-identities/jwks"
    ]

    for endpoint <- allowed_endpoints do
      Repo.query!(
        """
        INSERT INTO requests (
          pool_id, api_key_id, requested_model, endpoint, transport, status, usage_status, correlation_id
        ) VALUES ($1, $2, 'gpt-example', $3, 'http_json', 'accepted', 'usage_pending', $4)
        """,
        [pool_id, api_key_id, endpoint, "corr-#{endpoint}"]
      )
    end

    assert_db_error(:check_violation, fn ->
      Repo.query!(
        """
        INSERT INTO requests (
          pool_id, api_key_id, requested_model, endpoint, transport, status, usage_status, correlation_id
        ) VALUES ($1, $2, 'gpt-example', '/backend-api/codex/not-added', 'http_json', 'accepted', 'usage_pending', $3)
        """,
        [pool_id, api_key_id, "corr-invalid-endpoint"]
      )
    end)
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
        ["2026-04-#{:erlang.phash2(suffix, 28) + 1}"]
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

  defp create_attempt!(fixture) do
    [[id]] =
      Repo.query!(
        """
        INSERT INTO attempts (
          request_id, attempt_number, pool_upstream_assignment_id, upstream_identity_id,
          pricing_snapshot_id, model_id, upstream_model_id, transport, status,
          retryable, usage_status, response_metadata
        ) VALUES ($1, 1, $2, $3, $4, $5, 'gpt-example', 'http_json', 'succeeded', false, 'usage_known', '{}'::jsonb)
        RETURNING id
        """,
        [
          fixture.request_id,
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

  defp upstream_lifecycle_statuses do
    ~w(active paused refresh_due refreshing refresh_failed reauth_required deleted)
  end
end
