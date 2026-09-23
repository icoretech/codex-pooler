defmodule CodexPooler.Upstreams.Quota.Windows.IdentityLockOrderTest do
  @moduledoc false

  # Executable oracle for the identity lock order (findings #215).
  #
  # Contract: whenever one transaction needs both, it takes the identity
  # advisory mutex (`pg_advisory_xact_lock(hashtextextended(identity_id, 0))`)
  # before any `upstream_identities` row lock, and fenced writers re-enter that
  # same transaction-scoped mutex. Row-only leaf transactions may lock the row
  # without the mutex, but must never enter an advisory-acquiring path while
  # they hold it.
  #
  # Every scenario runs on independent committed PostgreSQL backends and reads
  # `pg_stat_activity`, `pg_blocking_pids` and `pg_locks` before releasing the
  # holder, so the order is observed rather than inferred from a deadlock
  # timeout. The reversed-order control proves the oracle fails when the order
  # is violated.
  #
  # History (the commits that set the order carry no body): ef04ecf0 chose
  # advisory-first, ae133ac4 flipped to row-first, 08dad3bf/e789de6e restored
  # advisory-first. Row-first deadlocks because a writer owning the mutex waits
  # for `FOR UPDATE` while a runtime header observation holding `FOR KEY SHARE`
  # waits for the mutex. Traced leaf boundary (findings #215): `Redemption`
  # reaches `PoolReconciliation.refresh_quota_from_usage/3` only after its
  # reservation transaction committed and the consume POST returned;
  # `Convergence.converge/3` runs after the usage or runtime evidence upsert
  # committed; `Auth.TokenRefresh` never touches quota evidence or the slot
  # lock; `CredentialFencing.lock_identity/1` is reachable only from the
  # self-contained `allocate_usage_probe/1` transaction.

  use ExUnit.Case, async: false
  use CodexPooler.CommittedWriteGuard

  import CodexPooler.AccountsFixtures, only: [committed_bootstrap_owner_fixture!: 1]
  import CodexPooler.PoolerFixtures
  import CodexPooler.UnboxedFixture, only: [register_unboxed_cleanup!: 1]
  import Ecto.Query

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.RequestOptions.ResetProbe
  alias CodexPooler.Pools
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Lifecycle.{CredentialFencing, IdentitySlotLock}
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Quota.Windows.EvidenceStore
  alias CodexPooler.Upstreams.Reconciliation.{PoolReconciliation, UsagePollCooldown}
  alias CodexPooler.Upstreams.SavedResets.{Convergence, ProbeLease, RedemptionLifecycle}
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias Ecto.Adapters.SQL.Sandbox

  @detection_timeout_ms 15_000
  @probe_generation 3
  @probe_attempt_id "attempt-lock-order"

  describe "advisory-first writers" do
    setup do
      identity = unboxed(fn -> upstream_identity_fixture() end)
      register_unboxed_cleanup!(fn -> Repo.delete!(identity) end)
      %{identity: identity}
    end

    test "quota evidence waits for the identity advisory lock without holding its row", %{
      identity: identity
    } do
      assert {:ok, %AccountQuotaWindow{upstream_identity_id: identity_id}} =
               assert_lock_order(identity, fn -> record_evidence(identity) end)

      assert identity_id == identity.id
    end

    test "lifecycle rows wait for the identity advisory lock before taking FOR UPDATE", %{
      identity: identity
    } do
      assert {:ok, %{identities: [%UpstreamIdentity{id: identity_id}]}} =
               assert_lock_order(identity, fn ->
                 Repo.transaction(fn -> IdentitySlotLock.lock_identity_rows!([identity]) end)
               end)

      assert identity_id == identity.id
    end

    # Causal control: a writer that takes the row reference first and then the
    # advisory mutex is exactly the AB-BA edge the contract forbids. The same
    # oracle must report it: the waiter holds a RowShareLock on
    # `upstream_identities` while it waits for the mutex, and the holder's
    # lock-timed `FOR UPDATE` probe can no longer complete.
    test "a reversed row-then-advisory writer fails the lock-order oracle", %{
      identity: identity
    } do
      outcome = lock_order_outcome(identity, fn -> reversed_order_writer(identity) end)

      assert outcome.wait == :waiting_on_identity_advisory
      assert outcome.row_share_locks == 1

      assert lock_order_violation?(outcome),
             "reversed writer passed the oracle: #{inspect(outcome)}"
    end
  end

  describe "fenced reconciliation and the post-consume usage refresh" do
    test "wait for the identity advisory lock before locking the identity row" do
      %{identity: identity, assignment: assignment, fake: fake} = committed_usage_fixture!()

      # `refresh_quota_from_usage/2` is the reconciliation entry and the exact
      # call `SavedResets.Redemption` makes after a consume POST returned. It
      # allocates the usage probe in a row-only leaf transaction, fetches usage
      # over HTTP, then runs `CredentialFencing.apply_usage_success/3`, whose
      # `lock_identity_rows!/1` takes the advisory mutex first and whose
      # evidence upsert re-enters it.
      assert {:ok, %UpstreamIdentity{id: refreshed_id}} =
               assert_lock_order(identity, fn ->
                 PoolReconciliation.refresh_quota_from_usage(identity, assignment)
               end)

      assert refreshed_id == identity.id
      assert [_usage_request | _rest] = FakeUpstream.requests(fake)

      assert [%AccountQuotaWindow{quota_key: "account", used_percent: used_percent}] =
               unboxed(fn -> Windows.list_evidence(identity) end)

      assert Decimal.compare(used_percent, Decimal.new(12)) == :eq
    end
  end

  describe "trusted account re-import" do
    test "waits for the identity advisory lock before locking the identity row" do
      fixture = committed_import_fixture!()

      assert {:ok, %{identity: %UpstreamIdentity{id: identity_id} = identity}} =
               unboxed(fn ->
                 Upstreams.import_trusted_account(
                   fixture.scope,
                   fixture.pool,
                   fixture.initial_attrs
                 )
               end)

      epoch_before = identity.metadata["credential_epoch"]
      assert is_integer(epoch_before)

      # The re-import prepares a signed witness, takes the slot advisory
      # resources, selects the persisted identity, then reaches
      # `IdentitySlotLock.lock_identity_rows!/1` for the expected identity:
      # advisory mutex first, `FOR UPDATE` second, then credential rotation.
      assert {:ok, %{identity: %UpstreamIdentity{id: ^identity_id} = reimported}} =
               assert_lock_order(identity, fn ->
                 Upstreams.import_trusted_account(
                   fixture.scope,
                   fixture.pool,
                   fixture.newer_attrs
                 )
               end)

      assert reimported.metadata["credential_epoch"] > epoch_before
    end
  end

  describe "saved-reset gateway-auto and post-consume leaf transactions" do
    setup do
      %{identity: identity, assignment: assignment} =
        fixture = committed_pending_redemption_fixture!()

      {:ok, probe} =
        ResetProbe.bind(ResetProbe.new(), assignment.id, identity.id, "gpt-6-sol", "proxy_http")

      Map.put(fixture, :probe, probe)
    end

    test "the gateway-auto probe claim locks only the identity row", %{
      identity: identity,
      probe: probe
    } do
      results =
        assert_row_only_leaf(identity, fn ->
          ProbeLease.claim(identity, @probe_generation, @probe_attempt_id, probe)
        end)

      assert results == %{row: {:ok, :claimed}, advisory: {:ok, :claimed}}
      assert redemption(identity)["probe"]["token"] == probe.token
    end

    test "post-consume convergence locks only the identity row", %{identity: identity} do
      results =
        assert_row_only_leaf(identity, fn ->
          Convergence.converge(identity, DateTime.utc_now(), "runtime_websocket_frame_headers")
        end)

      assert results == %{row: {:ok, :unchanged}, advisory: {:ok, :unchanged}}
      assert redemption(identity)["phase"] == RedemptionLifecycle.consumed_pending_probe()
    end

    # The unchanged leaf above never reaches `apply_transition!/6`; with fresh
    # usable account evidence after `consumed_at` the same leaf writes the
    # confirmed phase, so the writing path's lock order is proven too
    # (findings#215).
    test "post-consume convergence that applies a transition still locks only the identity row",
         %{identity: identity} do
      assert {:ok, _window} = unboxed(fn -> record_evidence(identity) end)
      pending = redemption(identity)

      # Both oracle phases must reach `apply_transition!/6`: the first one
      # confirms the redemption, so the pending redemption is restored before
      # the second (advisory-held) phase, otherwise that phase would only
      # exercise the read-only `:unchanged` branch the previous test covers.
      results =
        assert_row_only_leaf(
          identity,
          fn ->
            Convergence.converge(identity, DateTime.utc_now(), "runtime_websocket_frame_headers")
          end,
          before_each: fn -> restore_redemption!(identity, pending) end
        )

      assert results == %{
               row: {:ok, :confirmed_by_quota},
               advisory: {:ok, :confirmed_by_quota}
             }

      assert redemption(identity)["phase"] == RedemptionLifecycle.confirmed_by_quota()
    end

    test "usage probe allocation locks only the identity row", %{identity: identity} do
      results =
        assert_row_only_leaf(identity, fn ->
          CredentialFencing.allocate_usage_probe(identity)
        end)

      assert %{
               row: {:ok, %UpstreamIdentity{id: row_id}, %{usage_probe_sequence: first}},
               advisory: {:ok, %UpstreamIdentity{id: advisory_id}, %{usage_probe_sequence: second}}
             } = results

      assert row_id == identity.id
      assert advisory_id == identity.id
      assert second == first + 1
    end

    test "post-consume upstream confirmation locks only the identity row", %{
      identity: identity,
      probe: probe
    } do
      assert {:ok, :claimed} =
               unboxed(fn ->
                 ProbeLease.claim(identity, @probe_generation, @probe_attempt_id, probe)
               end)

      results =
        assert_row_only_leaf(identity, fn ->
          ProbeLease.confirm_upstream(identity.id, @probe_generation, @probe_attempt_id, probe)
        end)

      assert results == %{row: {:ok, :confirmed}, advisory: {:ok, :unchanged}}
      assert redemption(identity)["phase"] == RedemptionLifecycle.confirmed_by_upstream()
    end
  end

  describe "usage polling pause leaf transaction" do
    setup do
      identity = unboxed(fn -> upstream_identity_fixture() end)
      register_unboxed_cleanup!(fn -> Repo.delete!(identity) end)
      as_of = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      %{
        identity: identity,
        origin: UsagePollCooldown.origin_key("https://usage.example.test/backend-api/wham/usage"),
        as_of: as_of,
        deadline: DateTime.add(as_of, 3 * 86_400, :second)
      }
    end

    test "recording a provider pause locks only the identity row", ctx do
      results =
        assert_row_only_leaf(ctx.identity, fn ->
          UsagePollCooldown.record(ctx.identity.id, UsagePollCooldown.scope(ctx.identity, 1), ctx.origin, 429, ctx.deadline, ctx.as_of)
        end)

      assert results == %{row: {:ok, ctx.deadline}, advisory: {:ok, ctx.deadline}}
    end
  end

  # -- advisory-first oracle ---------------------------------------------------

  defp assert_lock_order(identity, writer) do
    outcome = lock_order_outcome(identity, writer)

    assert outcome.wait == :waiting_on_identity_advisory
    assert outcome.row_share_locks == 0
    assert {:ok, %{num_rows: 1}} = outcome.row_probe

    CodexPooler.TestDiagnostics.puts(
      "GREEN identity_lock_order holder=#{outcome.holder_pid} waiter=#{outcome.waiter_pid} " <>
        "wait=#{outcome.wait} row_share_locks=#{outcome.row_share_locks} " <>
        "terminal=ok sqlstate_40P01=0"
    )

    outcome.writer
  end

  # Holds the identity advisory mutex on one backend, starts `writer` on
  # another, and records what the writer does while it waits for the mutex:
  # the advisory wait itself, whether it already holds a RowShareLock on
  # `upstream_identities`, and whether the holder can still take the row.
  defp lock_order_outcome(identity, writer) do
    parent = self()
    barrier = make_ref()

    {observation, waiter} =
      unboxed(fn ->
        {:ok, {observation, waiter}} =
          Repo.transaction(fn ->
            Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [identity.id])
            %{rows: [[holder_pid]]} = Repo.query!("SELECT pg_backend_pid()")

            waiter = start_writer(parent, barrier, writer)

            assert_receive {^barrier, :waiter, waiter_pid}, @detection_timeout_ms
            deadline = System.monotonic_time(:millisecond) + @detection_timeout_ms
            wait_result = wait_for_advisory(waiter_pid, holder_pid, barrier, deadline)
            row_share_locks = upstream_identity_row_share_locks(waiter_pid)

            # The timeout only bounds the red path: a row-first writer holds KEY
            # SHARE while waiting for our advisory lock, so our FOR UPDATE cannot
            # finish. It stays far below `deadlock_timeout` so the probe reports
            # `lock_not_available` before either backend is chosen as a victim.
            Repo.query!("SET LOCAL lock_timeout = '250ms'")
            Repo.query!("SAVEPOINT row_lock_probe")

            row_probe =
              Repo.query("SELECT id FROM upstream_identities WHERE id = $1 FOR UPDATE", [
                Ecto.UUID.dump!(identity.id)
              ])

            # Recover the transaction after an expected reversed-order lock failure.
            Repo.query!("ROLLBACK TO SAVEPOINT row_lock_probe")

            {%{
               holder_pid: holder_pid,
               waiter_pid: waiter_pid,
               wait: wait_result,
               row_share_locks: row_share_locks,
               row_probe: row_probe
             }, waiter}
          end)

        {observation, waiter}
      end)

    writer_result = Task.await(waiter, @detection_timeout_ms)

    # `wait_for_advisory/4` already consumed the completion receipt when the
    # writer finished without ever waiting on the mutex; that verdict must reach
    # the caller as the wait result, not as a missing message.
    unless observation.wait == :writer_completed_without_identity_advisory do
      assert_receive {^barrier, :completed}, @detection_timeout_ms
    end

    Map.put(observation, :writer, writer_result)
  end

  defp reversed_order_writer(identity) do
    Repo.transaction(fn ->
      Repo.query!("SELECT id FROM upstream_identities WHERE id = $1 FOR KEY SHARE", [
        Ecto.UUID.dump!(identity.id)
      ])

      Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [identity.id])
      :reversed
    end)
  rescue
    # Only reached when PostgreSQL picks this backend as the deadlock victim
    # before the holder's lock-timed probe fails; both are oracle failures.
    exception in Postgrex.Error -> {:error, exception}
  end

  defp lock_order_violation?(%{row_probe: row_probe, writer: writer}) do
    lock_error?(row_probe) or lock_error?(writer)
  end

  defp lock_error?({:error, %Postgrex.Error{postgres: %{code: code}}}),
    do: code in [:lock_not_available, :deadlock_detected]

  defp lock_error?(_result), do: false

  defp start_writer(parent, barrier, writer) do
    Task.async(fn ->
      unboxed(fn ->
        %{rows: [[waiter_pid]]} = Repo.query!("SELECT pg_backend_pid()")
        send(parent, {barrier, :waiter, waiter_pid})
        result = writer.()
        send(parent, {barrier, :completed})
        result
      end)
    end)
  end

  defp wait_for_advisory(waiter_pid, holder_pid, barrier, deadline) do
    case backend_wait(waiter_pid) do
      {"advisory", [^holder_pid]} ->
        :waiting_on_identity_advisory

      _other ->
        if System.monotonic_time(:millisecond) >= deadline do
          :advisory_wait_not_observed
        else
          receive do
            {^barrier, :completed} -> :writer_completed_without_identity_advisory
          after
            0 -> wait_for_advisory(waiter_pid, holder_pid, barrier, deadline)
          end
        end
    end
  end

  defp backend_wait(backend_pid) do
    %{rows: rows} =
      Repo.query!(
        "SELECT wait_event, pg_blocking_pids(pid) FROM pg_stat_activity WHERE pid = $1",
        [backend_pid]
      )

    case rows do
      [[wait_event, blocking_pids]] -> {wait_event, blocking_pids}
      [] -> {:backend_absent, []}
    end
  end

  # `SELECT ... FOR UPDATE / FOR KEY SHARE` holds ROW SHARE on the table until
  # commit, so a granted RowShareLock on `upstream_identities` is direct
  # evidence that the backend already holds an identity row reference.
  defp upstream_identity_row_share_locks(backend_pid) do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT count(*)
        FROM pg_locks
        WHERE pid = $1
          AND granted
          AND locktype = 'relation'
          AND relation = 'upstream_identities'::regclass
          AND mode = 'RowShareLock'
        """,
        [backend_pid]
      )

    count
  end

  # -- row-only leaf oracle ----------------------------------------------------

  # Runs `leaf` twice on its own backend and returns both results.
  #
  #   * `:row` phase: another backend holds the identity `FOR UPDATE`. The leaf
  #     must wait on that row (proving it really locks the row, so the
  #     `:advisory` phase is not vacuous) while `pg_try_advisory_xact_lock` on
  #     the identity still succeeds from a third backend: the leaf took no
  #     advisory mutex before the row.
  #   * `:advisory` phase: another backend holds the identity advisory mutex.
  #     The leaf must complete while that mutex is still held: it takes no
  #     advisory mutex after the row either.
  defp assert_row_only_leaf(identity, leaf, opts \\ []) do
    before_each = Keyword.get(opts, :before_each, fn -> :ok end)
    before_each.()
    row_result = leaf_waits_on_row_without_advisory(identity, leaf)
    before_each.()
    advisory_result = leaf_completes_under_held_advisory(identity, leaf)
    %{row: row_result, advisory: advisory_result}
  end

  defp restore_redemption!(identity, redemption) do
    unboxed(fn ->
      current = Repo.reload!(identity)

      current
      |> Ecto.Changeset.change(metadata: Map.put(current.metadata || %{}, "saved_reset_redemption", redemption))
      |> Repo.update!()
    end)

    :ok
  end

  defp leaf_waits_on_row_without_advisory(identity, leaf) do
    parent = self()
    barrier = make_ref()

    {observation, waiter} =
      unboxed(fn ->
        {:ok, {observation, waiter}} =
          Repo.transaction(fn ->
            Repo.query!("SELECT id FROM upstream_identities WHERE id = $1 FOR UPDATE", [
              Ecto.UUID.dump!(identity.id)
            ])

            %{rows: [[holder_pid]]} = Repo.query!("SELECT pg_backend_pid()")
            waiter = start_writer(parent, barrier, leaf)
            assert_receive {^barrier, :waiter, waiter_pid}, @detection_timeout_ms

            deadline = System.monotonic_time(:millisecond) + @detection_timeout_ms
            wait_event = wait_for_row(waiter_pid, holder_pid, barrier, deadline)
            advisory_free? = try_identity_advisory_on_fresh_backend(identity)

            {%{
               holder_pid: holder_pid,
               waiter_pid: waiter_pid,
               wait_event: wait_event,
               advisory_free?: advisory_free?
             }, waiter}
          end)

        {observation, waiter}
      end)

    result = Task.await(waiter, @detection_timeout_ms)
    assert_receive {^barrier, :completed}, @detection_timeout_ms

    assert {:row_lock, wait_event} = observation.wait_event
    refute wait_event == "advisory"

    assert observation.advisory_free?,
           "leaf backend #{observation.waiter_pid} held the identity advisory mutex " <>
             "while waiting on the identity row"

    CodexPooler.TestDiagnostics.puts(
      "GREEN row_only_leaf phase=row holder=#{observation.holder_pid} " <>
        "waiter=#{observation.waiter_pid} wait_event=#{wait_event} advisory_free=true " <>
        "terminal=ok sqlstate_40P01=0"
    )

    result
  end

  defp leaf_completes_under_held_advisory(identity, leaf) do
    parent = self()
    barrier = make_ref()

    waiter =
      unboxed(fn ->
        {:ok, waiter} =
          Repo.transaction(fn ->
            Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [identity.id])
            %{rows: [[holder_pid]]} = Repo.query!("SELECT pg_backend_pid()")
            waiter = start_writer(parent, barrier, leaf)
            assert_receive {^barrier, :waiter, waiter_pid}, @detection_timeout_ms

            # The mutex is still held here: a leaf that needed it could not finish.
            assert_receive {^barrier, :completed},
                           @detection_timeout_ms,
                           "leaf backend #{waiter_pid} did not complete while backend " <>
                             "#{holder_pid} held the identity advisory mutex"

            CodexPooler.TestDiagnostics.puts(
              "GREEN row_only_leaf phase=advisory holder=#{holder_pid} waiter=#{waiter_pid} " <>
                "terminal=ok sqlstate_40P01=0"
            )

            waiter
          end)

        waiter
      end)

    Task.await(waiter, @detection_timeout_ms)
  end

  # A third backend in its own transaction: `true` means nobody holds the
  # identity advisory mutex at this instant. The lock is released on commit.
  defp try_identity_advisory_on_fresh_backend(identity) do
    Task.async(fn -> unboxed(fn -> try_identity_advisory_in_transaction(identity) end) end)
    |> Task.await(@detection_timeout_ms)
  end

  defp try_identity_advisory_in_transaction(identity) do
    {:ok, free?} =
      Repo.transaction(fn ->
        %{rows: [[free?]]} =
          Repo.query!("SELECT pg_try_advisory_xact_lock(hashtextextended($1, 0))", [
            identity.id
          ])

        free?
      end)

    free?
  end

  defp wait_for_row(waiter_pid, holder_pid, barrier, deadline) do
    {wait_event, blocking_pids} = observed = backend_wait(waiter_pid)

    cond do
      holder_pid in blocking_pids ->
        {:row_lock, wait_event}

      System.monotonic_time(:millisecond) >= deadline ->
        {:row_wait_not_observed, observed}

      true ->
        receive do
          {^barrier, :completed} -> {:leaf_completed_without_row_lock, observed}
        after
          0 -> wait_for_row(waiter_pid, holder_pid, barrier, deadline)
        end
    end
  end

  # -- drivers and fixtures ----------------------------------------------------

  defp record_evidence(identity) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    EvidenceStore.record_evidence(
      identity,
      CodexPooler.QuotaEvidenceSupport.account_secondary_evidence("22", now),
      now
    )
  end

  defp redemption(identity) do
    unboxed(fn -> Repo.reload!(identity).metadata["saved_reset_redemption"] end)
  end

  # Committed Pool graph whose identity points its usage probes at a local
  # FakeUpstream. Cleanup is registered before any commit and keyed on values
  # derived here, so a fixture that fails partway through is still removed.
  defp committed_usage_fixture! do
    reset_at = DateTime.utc_now() |> DateTime.add(3_600, :second) |> DateTime.to_unix()

    payload = %{
      "rate_limit" => %{
        "primary_window" => %{
          "used_percent" => 12,
          "limit_window_seconds" => 18_000,
          "reset_at" => reset_at
        }
      }
    }

    {:ok, fake} =
      FakeUpstream.start_link(
        {:path_json,
         %{
           "/backend-api/wham/usage" => {200, payload},
           "/backend-api/codex/usage" => {200, payload}
         }}
      )

    on_exit(fn -> FakeUpstream.stop(fake) end)

    graph =
      committed_graph!(fn pool, label ->
        active_upstream_assignment_fixture(pool, %{
          account_label: label,
          metadata: %{"usage_base_url" => FakeUpstream.url(fake)}
        })
      end)

    Map.put(graph, :fake, fake)
  end

  defp committed_pending_redemption_fixture! do
    consumed_at =
      DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)

    phase = RedemptionLifecycle.consumed_pending_probe()
    deadline_at = RedemptionLifecycle.deadline_at(consumed_at)

    redemption = %{
      "status" => RedemptionLifecycle.legacy_status_for(phase),
      "phase" => phase,
      "attempt_id" => @probe_attempt_id,
      "generation" => @probe_generation,
      "trigger_kind" => "gateway_auto",
      "started_at" => DateTime.to_iso8601(consumed_at),
      "consumed_at" => DateTime.to_iso8601(consumed_at),
      "deadline_at" => DateTime.to_iso8601(deadline_at),
      "finished_at" => nil,
      "result" => %{"code" => "reset", "applied" => true}
    }

    committed_graph!(fn pool, label ->
      active_upstream_assignment_fixture(pool, %{
        account_label: label,
        metadata: %{"saved_reset_redemption" => redemption}
      })
    end)
  end

  defp committed_graph!(build) do
    suffix = System.unique_integer([:positive, :monotonic])
    slug = "identity-lock-order-#{suffix}"
    label = "Identity lock order #{suffix}"
    register_unboxed_cleanup!(fn -> delete_graph!(slug, label) end)

    unboxed(fn ->
      pool = pool_fixture(%{slug: slug})
      %{identity: identity, assignment: assignment} = build.(pool, label)
      %{pool: pool, identity: identity, assignment: assignment}
    end)
  end

  defp delete_graph!(slug, label) do
    delete_committed_pool_by_slug!(slug)
    Repo.delete_all(from identity in UpstreamIdentity, where: identity.account_label == ^label)
    :ok
  end

  # Committed operator, Pool and trusted-account attrs for a real import. The
  # owner registers its own graph cleanup first, so it runs after the Pool and
  # identity cleanup registered here.
  defp committed_import_fixture! do
    suffix = System.unique_integer([:positive, :monotonic])
    account_id = "acct_identity_lock_order_#{suffix}"
    slug = "identity-lock-order-import-#{suffix}"

    %{user: user} =
      committed_bootstrap_owner_fixture!(%{
        "email" => "identity-lock-order-owner-#{suffix}@example.com"
      })

    register_unboxed_cleanup!(fn -> delete_import_fixture!(slug, account_id) end)

    unboxed(fn ->
      scope = Scope.for_user(user)

      {:ok, pool} =
        Pools.create_pool(scope, %{slug: slug, name: "Identity lock order import #{suffix}"})

      base = %{
        chatgpt_account_id: account_id,
        chatgpt_user_id: "user_identity_lock_order_#{suffix}",
        account_email: "identity-lock-order-#{suffix}@example.com",
        account_label: "Identity lock order import #{suffix}",
        workspace_id: "workspace_identity_lock_order_#{suffix}",
        workspace_label: "Workspace #{suffix}",
        seat_type: "team",
        credential_provenance: "codex_chatgpt_oauth"
      }

      %{
        scope: scope,
        pool: pool,
        initial_attrs: credential_attrs(base, "initial", suffix),
        newer_attrs: credential_attrs(base, "newer", suffix)
      }
    end)
  end

  defp credential_attrs(base, version, suffix) do
    Map.merge(base, %{
      token: "access-#{version}-#{suffix}",
      refresh_token: "refresh-#{version}-#{suffix}"
    })
  end

  defp delete_import_fixture!(slug, account_id) do
    delete_committed_pool_by_slug!(slug)

    Repo.delete_all(from identity in UpstreamIdentity, where: identity.chatgpt_account_id == ^account_id)

    :ok
  end

  defp delete_committed_pool_by_slug!(slug) do
    case Repo.get_by(Pool, slug: slug) do
      %Pool{id: pool_id} -> delete_committed_pools!([pool_id])
      nil -> :ok
    end
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
