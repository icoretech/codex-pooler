defmodule CodexPooler.Upstreams.Reconciliation.UsagePollPauseClearTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Reconciliation.UsagePollCooldown
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @action "upstream_account.usage_poll_pause_clear"
  @multi_day_seconds 3 * 86_400

  setup do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{
      owner: owner,
      owner_scope: Scope.for_user(owner, ["instance_owner"]),
      now: now,
      origin: UsagePollCooldown.origin_key("https://usage.example.test/backend-api/wham/usage"),
      other_origin: UsagePollCooldown.origin_key("https://usage-b.example.test/backend-api/wham/usage")
    }
  end

  test "an operator clears every running pause of the account and the audit event records what was overridden", ctx do
    %{identity: identity, assignment: assignment} = active_upstream_assignment_fixture(pool_fixture(), %{account_label: "Clear Sample"})
    longer = DateTime.add(ctx.now, @multi_day_seconds, :second)

    assert {:ok, _} = UsagePollCooldown.record(identity.id, 1, ctx.origin, 429, DateTime.add(ctx.now, 3_600, :second), ctx.now)
    assert {:ok, _} = UsagePollCooldown.record(identity.id, 1, ctx.other_origin, 503, longer, ctx.now)
    before = Repo.get!(UpstreamIdentity, identity.id)

    assert {:ok, %{status: :usage_poll_pause_cleared, identity: cleared}} =
             Upstreams.clear_usage_poll_pause_for_scope(ctx.owner_scope, identity.id, %{reason: "admin_upstreams_live"})

    # Both origins are free again, and nothing else about the account moved:
    # not its status, not its credential epoch, not its other metadata.
    for origin <- [ctx.origin, ctx.other_origin] do
      assert :ok = UsagePollCooldown.admit_current(identity.id, 1, origin, ctx.now)
    end

    assert cleared.status == before.status
    assert cleared.metadata == Map.delete(before.metadata, UsagePollCooldown.metadata_key())
    assert Upstreams.usage_poll_pauses(cleared, ctx.now) == []

    assert [%AuditEvent{} = event] = audit_events(identity.id)
    assert event.actor_user_id == ctx.owner.id
    assert event.pool_id == assignment.pool_id
    assert event.target_type == "upstream_identity"

    assert %{
             "cleared_pause_count" => 2,
             "cleared_paused_until" => paused_until,
             "cleared_pause_status_codes" => [429, 503],
             "trigger_kind" => "admin_upstreams_live",
             "result_status" => "usage_poll_pause_cleared"
           } = event.details

    assert paused_until == DateTime.to_iso8601(longer)

    # The origin digests identify nothing an auditor needs and stay out.
    encoded = CodexPooler.JSON.encode!(event.details)
    refute encoded =~ ctx.origin
    refute encoded =~ ctx.other_origin
    refute encoded =~ "usage.example.test"
  end

  test "an account with no running pause is refused without a write or an audit event", ctx do
    %{identity: identity} = active_upstream_assignment_fixture(pool_fixture(), %{})
    earlier = DateTime.add(ctx.now, -600, :second)

    # A pause that has already ended is not one the operator can override.
    assert {:ok, _} = UsagePollCooldown.record(identity.id, 1, ctx.origin, 429, DateTime.add(earlier, 60, :second), earlier)
    before = Repo.get!(UpstreamIdentity, identity.id)

    assert {:error, %{code: :no_active_usage_poll_pause}} =
             Upstreams.clear_usage_poll_pause_for_scope(ctx.owner_scope, identity.id, %{reason: "admin_upstreams_live"})

    assert Repo.get!(UpstreamIdentity, identity.id).metadata == before.metadata
    assert audit_events(identity.id) == []
  end

  test "a pool admin who cannot operate every pool of a shared account cannot clear its pause", ctx do
    %{user: admin} = operator_fixture(ctx.owner, %{"email" => unique_user_email()})
    visible_pool = pool_fixture(%{name: "Visible Pause Pool"})
    hidden_pool = pool_fixture(%{name: "Hidden Pause Pool"})
    identity = active_upstream_identity_fixture(%{chatgpt_account_id: "acct_pause_clear_shared_#{System.unique_integer([:positive])}"})

    for pool <- [visible_pool, hidden_pool] do
      assert {:ok, assignment} = PoolAssignments.create_pool_assignment(pool, identity)
      assert {:ok, _assignment} = PoolAssignments.activate_pool_assignment(assignment)
    end

    operator_pool_assignment_fixture(admin, visible_pool, created_by_user_id: ctx.owner.id)
    deadline = DateTime.add(ctx.now, @multi_day_seconds, :second)
    assert {:ok, ^deadline} = UsagePollCooldown.record(identity.id, 1, ctx.origin, 429, deadline, ctx.now)

    assert {:error, %{code: :capability_denied}} =
             Upstreams.clear_usage_poll_pause_for_scope(Scope.for_user(admin), identity.id, %{reason: "admin_upstreams_live"})

    assert {:deferred, ^deadline} = UsagePollCooldown.admit_current(identity.id, 1, ctx.origin, ctx.now)
    assert audit_events(identity.id) == []

    # An admin of every pool the account serves may.
    operator_pool_assignment_fixture(admin, hidden_pool, created_by_user_id: ctx.owner.id)

    assert {:ok, _result} =
             Upstreams.clear_usage_poll_pause_for_scope(Scope.for_user(admin), identity.id, %{reason: "admin_upstreams_live"})

    assert :ok = UsagePollCooldown.admit_current(identity.id, 1, ctx.origin, ctx.now)
    assert length(audit_events(identity.id)) == 2
  end

  test "a clear whose audit event cannot be written does not happen", ctx do
    %{identity: identity} = active_upstream_assignment_fixture(pool_fixture(), %{})
    deadline = DateTime.add(ctx.now, @multi_day_seconds, :second)
    assert {:ok, _} = UsagePollCooldown.record(identity.id, 1, ctx.origin, 429, deadline, ctx.now)

    Repo.query!("""
    CREATE FUNCTION pg_temp.reject_usage_poll_pause_clear_audit() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.action = '#{@action}' THEN
        RAISE EXCEPTION 'forced usage poll pause clear audit failure' USING ERRCODE = '23514';
      END IF;

      RETURN NEW;
    END
    $$
    """)

    Repo.query!("""
    CREATE TRIGGER reject_usage_poll_pause_clear_audit
    BEFORE INSERT ON audit_events
    FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_usage_poll_pause_clear_audit()
    """)

    assert_raise Postgrex.Error, fn ->
      Upstreams.clear_usage_poll_pause_for_scope(ctx.owner_scope, identity.id, %{reason: "admin_upstreams_live"})
    end

    assert {:deferred, ^deadline} = UsagePollCooldown.admit_current(identity.id, 1, ctx.origin, ctx.now)
    assert audit_events(identity.id) == []
  end

  test "a clear is operator-only: there is no path without a user scope", ctx do
    %{identity: identity} = active_upstream_assignment_fixture(pool_fixture(), %{})
    deadline = DateTime.add(ctx.now, @multi_day_seconds, :second)
    assert {:ok, _} = UsagePollCooldown.record(identity.id, 1, ctx.origin, 429, deadline, ctx.now)

    assert {:error, %{code: :invalid_request}} = Upstreams.clear_usage_poll_pause_for_scope(nil, identity.id, %{})
    assert {:deferred, ^deadline} = UsagePollCooldown.admit_current(identity.id, 1, ctx.origin, ctx.now)
  end

  defp audit_events(target_id) do
    Repo.all(
      from(event in AuditEvent,
        where: event.action == @action and event.target_id == ^target_id,
        order_by: [asc: event.occurred_at, asc: event.id]
      )
    )
  end
end
