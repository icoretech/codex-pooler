defmodule CodexPooler.Upstreams.SavedResets.CapacityFencePostgresTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures, only: [active_upstream_assignment_fixture: 2]
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport, only: [gateway_setup: 1]

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.RoutingCircuitState
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.SavedResetRedemption
  alias CodexPooler.Upstreams.SavedResets.AutoEligibility
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  @detection_budget 15_000

  test "closed to failed-recovery open rereads current C and consumes once" do
    fixture = committed_fixture!("closed", true)
    on_exit(fn -> cleanup_fixture!(fixture) end)

    evidence = race_circuit_transition(fixture, "open", true)

    assert evidence.writer_backend_pid != evidence.claim_backend_pid
    assert evidence.writer_backend_pid in evidence.blocking_pids
    assert evidence.wait_event_type == "Lock"
    assert {:ok, %{status: :succeeded, applied?: true, code: "reset"}} = evidence.claim_result
    assert provider_consume_count(fixture.fake) == 1
  end

  test "open to closed rereads current C and vetoes before provider I/O" do
    fixture = committed_fixture!("open", false)
    on_exit(fn -> cleanup_fixture!(fixture) end)

    evidence = race_circuit_transition(fixture, "closed", false)

    assert evidence.writer_backend_pid != evidence.claim_backend_pid
    assert evidence.writer_backend_pid in evidence.blocking_pids
    assert evidence.wait_event_type == "Lock"

    assert {:ok,
            %{status: :noop, applied?: false, code: "gateway_auto_sibling_transient_exclusion"}} =
             evidence.claim_result

    assert provider_consume_count(fixture.fake) == 0
  end

  test "quota becoming usable while the claim waits is evaluated after locks" do
    fixture = committed_fixture!("closed", false)
    on_exit(fn -> cleanup_fixture!(fixture) end)

    fixture =
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete!(Repo.get!(RoutingCircuitState, fixture.circuit_id))
        identity = Repo.get!(UpstreamIdentity, fixture.sibling_identity_id)
        put_weekly_quota!(identity, "100")
        %{fixture | context: %{fixture.context | transient_circuit_exclusions: []}}
      end)

    started_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    evidence = race_quota_becomes_usable(fixture, started_at)

    assert evidence.writer_backend_pid != evidence.claim_backend_pid
    assert evidence.writer_backend_pid in evidence.blocking_pids
    assert evidence.wait_event_type == "Lock"

    assert {:ok, %{status: :noop, applied?: false, code: "gateway_auto_sibling_usable_capacity"}} =
             evidence.claim_result

    assert provider_consume_count(fixture.fake) == 0
  end

  test "quota reset deadline crossed while waiting uses the post-lock clock" do
    fixture = committed_fixture!("closed", true)
    on_exit(fn -> cleanup_fixture!(fixture) end)
    started_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    fixture =
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete!(Repo.get!(RoutingCircuitState, fixture.circuit_id))
        reset_at = DateTime.add(started_at, 1, :microsecond)

        Repo.one!(
          from window in AccountQuotaWindow,
            where:
              window.upstream_identity_id == ^fixture.sibling_identity_id and
                window.quota_key == "account" and window.window_kind == "secondary"
        )
        |> Ecto.Changeset.change(%{reset_at: reset_at, updated_at: started_at})
        |> Repo.update!()

        %{fixture | context: %{fixture.context | transient_circuit_exclusions: []}}
      end)

    evidence = race_identity_reference_lock(fixture, started_at)

    assert evidence.writer_backend_pid != evidence.claim_backend_pid
    assert evidence.writer_backend_pid in evidence.blocking_pids
    assert evidence.wait_event_type == "Lock"
    assert {:ok, %{status: :succeeded, applied?: true, code: "reset"}} = evidence.claim_result
    assert provider_consume_count(fixture.fake) == 1
  end

  test "latest matching circuit row wins by updated, created, and id order" do
    fixture = committed_fixture!("open", false)
    on_exit(fn -> cleanup_fixture!(fixture) end)

    fixture =
      Sandbox.unboxed_run(Repo, fn ->
        old = Repo.get!(RoutingCircuitState, fixture.circuit_id)
        updated_at = DateTime.add(old.updated_at, 2, :microsecond)
        earlier_created_at = DateTime.add(old.created_at, 1, :microsecond)
        tied_created_at = DateTime.add(old.created_at, 2, :microsecond)

        _updated_winner =
          insert_closed_circuit!(old, Ecto.UUID.generate(), earlier_created_at, updated_at)

        low_id = "00000000-0000-4000-8000-000000000001"
        high_id = "ffffffff-ffff-4fff-bfff-ffffffffffff"
        _created_winner = insert_closed_circuit!(old, low_id, tied_created_at, updated_at)
        newest = insert_closed_circuit!(old, high_id, tied_created_at, updated_at)

        context = %{
          fixture.context
          | transient_circuit_exclusions: [circuit_snapshot(newest)]
        }

        %{fixture | context: context}
      end)

    assert {:ok,
            %{status: :noop, applied?: false, code: "gateway_auto_sibling_transient_exclusion"}} =
             Sandbox.unboxed_run(Repo, fn ->
               SavedResetRedemption.redeem(fixture.target_assignment,
                 trigger_kind: "gateway_auto",
                 gateway_auto_context: fixture.context
               )
             end)

    assert provider_consume_count(fixture.fake) == 0
  end

  test "a circuit inserted before claim is classified from current C" do
    fixture = committed_fixture!("open", false)
    on_exit(fn -> cleanup_fixture!(fixture) end)

    assert {:ok,
            %{status: :noop, applied?: false, code: "gateway_auto_sibling_transient_exclusion"}} =
             Sandbox.unboxed_run(Repo, fn ->
               SavedResetRedemption.redeem(fixture.target_assignment,
                 trigger_kind: "gateway_auto",
                 gateway_auto_context: fixture.context
               )
             end)

    assert provider_consume_count(fixture.fake) == 0
  end

  test "SET LOCAL test settings restore after committed capacity checks" do
    before = Sandbox.unboxed_run(Repo, fn -> show_setting!("lock_timeout") end)

    assert {:ok, "17ms"} =
             Sandbox.unboxed_run(Repo, fn ->
               Repo.transaction(fn ->
                 SQL.query!(Repo, "SET LOCAL lock_timeout = '17ms'", [])
                 show_setting!("lock_timeout")
               end)
             end)

    assert Sandbox.unboxed_run(Repo, fn -> show_setting!("lock_timeout") end) == before
  end

  defp committed_fixture!(initial_status, request_routable_sibling?) do
    {:ok, fake} =
      FakeUpstream.start_link(
        {:path_json,
         %{
           "/api/codex/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}},
           "/api/codex/usage" => {200, usage_payload()}
         }}
      )

    fixture =
      Sandbox.unboxed_run(Repo, fn ->
        setup = gateway_setup(fake)
        sibling = active_upstream_assignment_fixture(setup.pool, %{})
        target_identity = enable_target!(setup.identity, fake)
        put_weekly_quota!(target_identity, "96")
        put_weekly_quota!(sibling.identity, "75")
        now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

        circuit =
          %RoutingCircuitState{}
          |> RoutingCircuitState.changeset(%{
            pool_id: setup.pool.id,
            pool_upstream_assignment_id: sibling.assignment.id,
            upstream_identity_id: sibling.identity.id,
            model_identifier: setup.model.exposed_model_id,
            route_class: "proxy_http",
            status: initial_status,
            reason_code: if(initial_status == "open", do: "synthetic_open", else: nil),
            failure_count: if(initial_status == "open", do: 3, else: 0),
            success_count: 0,
            opened_at: if(initial_status == "open", do: now),
            closed_at: if(initial_status == "closed", do: now),
            next_probe_at: if(initial_status == "open", do: DateTime.add(now, 60, :second)),
            metadata: recovery_metadata(false),
            created_at: now,
            updated_at: now
          })
          |> Repo.insert!()

        capacity_assignment_ids = [setup.assignment.id, sibling.assignment.id]
        capacity_identity_ids = [target_identity.id, sibling.identity.id]

        {routable_assignment_ids, routable_identity_ids, exclusions} =
          if request_routable_sibling? do
            {capacity_assignment_ids, capacity_identity_ids, []}
          else
            {[setup.assignment.id], [target_identity.id], [circuit_snapshot(circuit)]}
          end

        context = %{
          trigger: :threshold_pressure,
          pool_upstream_assignment_id: setup.assignment.id,
          upstream_identity_id: target_identity.id,
          candidate_assignment_ids: [setup.assignment.id],
          candidate_identity_ids: [target_identity.id],
          capacity_assignment_ids: capacity_assignment_ids,
          capacity_identity_ids: capacity_identity_ids,
          cohort_identity_ids: Enum.sort(capacity_identity_ids),
          routable_assignment_ids: routable_assignment_ids,
          routable_identity_ids: routable_identity_ids,
          route_class: "proxy_http",
          quota_scope: %{
            requested_model: setup.model.exposed_model_id,
            catalog_model: setup.model.exposed_model_id,
            exposed_model_id: setup.model.exposed_model_id,
            upstream_model: setup.model.upstream_model_id,
            upstream_model_id: setup.model.upstream_model_id
          },
          transient_circuit_exclusions: exclusions,
          hard_pinned_continuity?: false
        }

        %{
          fake: fake,
          pool_id: setup.pool.id,
          circuit_id: circuit.id,
          sibling_identity_id: sibling.identity.id,
          target_assignment: setup.assignment,
          context: context
        }
      end)

    fixture
  end

  defp race_circuit_transition(fixture, final_status, recovery_attempted?) do
    parent = self()
    barrier = make_ref()

    writer =
      start_writer(
        fn ->
          circuit = lock_circuit!(fixture.circuit_id)
          update_circuit!(circuit, final_status, recovery_attempted?)
        end,
        parent,
        barrier,
        :writer_locked,
        "circuit writer"
      )

    assert_receive {^barrier, :writer_locked, writer_backend_pid, writer_pid}, @detection_budget

    claim =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          backend_pid = backend_pid!()
          send(parent, {barrier, :claim_started, backend_pid})

          result =
            SavedResetRedemption.redeem(fixture.target_assignment,
              trigger_kind: "gateway_auto",
              gateway_auto_context: fixture.context
            )

          {backend_pid, result}
        end)
      end)

    assert_receive {^barrier, :claim_started, claim_backend_pid}, @detection_budget
    blocking = await_blocking!(claim_backend_pid, writer_backend_pid)
    send(writer_pid, {barrier, :release_writer})
    assert {:ok, ^writer_backend_pid} = Task.await(writer, @detection_budget)
    {^claim_backend_pid, claim_result} = Task.await(claim, @detection_budget)

    %{
      blocking_pids: blocking.blocking_pids,
      wait_event_type: blocking.wait_event_type,
      writer_backend_pid: writer_backend_pid,
      claim_backend_pid: claim_backend_pid,
      claim_result: claim_result
    }
  end

  defp race_quota_becomes_usable(fixture, started_at) do
    parent = self()
    barrier = make_ref()

    writer =
      start_writer(
        fn ->
          lock_identity_reference!(fixture.sibling_identity_id)
          update_usable_quota!(fixture)
        end,
        parent,
        barrier,
        :quota_written,
        "quota writer"
      )

    assert_receive {^barrier, :quota_written, writer_backend_pid, writer_pid}, @detection_budget

    claim =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          backend_pid = backend_pid!()
          send(parent, {barrier, :claim_started, backend_pid})

          result =
            SavedResetRedemption.redeem(fixture.target_assignment,
              trigger_kind: "gateway_auto",
              gateway_auto_context: fixture.context,
              started_at: started_at
            )

          {backend_pid, result}
        end)
      end)

    assert_receive {^barrier, :claim_started, claim_backend_pid}, @detection_budget
    blocking = await_blocking!(claim_backend_pid, writer_backend_pid)
    send(writer_pid, {barrier, :release_writer})
    assert {:ok, ^writer_backend_pid} = Task.await(writer, @detection_budget)
    {^claim_backend_pid, claim_result} = Task.await(claim, @detection_budget)

    %{
      blocking_pids: blocking.blocking_pids,
      wait_event_type: blocking.wait_event_type,
      writer_backend_pid: writer_backend_pid,
      claim_backend_pid: claim_backend_pid,
      claim_result: claim_result
    }
  end

  defp race_identity_reference_lock(fixture, started_at) do
    parent = self()
    barrier = make_ref()

    writer =
      start_writer(
        fn -> lock_identity_reference!(fixture.sibling_identity_id) end,
        parent,
        barrier,
        :identity_locked,
        "identity writer"
      )

    assert_receive {^barrier, :identity_locked, writer_backend_pid, writer_pid}, @detection_budget

    claim =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          backend_pid = backend_pid!()
          send(parent, {barrier, :claim_started, backend_pid})

          result =
            SavedResetRedemption.redeem(fixture.target_assignment,
              trigger_kind: "gateway_auto",
              gateway_auto_context: fixture.context,
              started_at: started_at
            )

          {backend_pid, result}
        end)
      end)

    assert_receive {^barrier, :claim_started, claim_backend_pid}, @detection_budget
    blocking = await_blocking!(claim_backend_pid, writer_backend_pid)
    send(writer_pid, {barrier, :release_writer})
    assert {:ok, ^writer_backend_pid} = Task.await(writer, @detection_budget)
    {^claim_backend_pid, claim_result} = Task.await(claim, @detection_budget)

    %{
      blocking_pids: blocking.blocking_pids,
      wait_event_type: blocking.wait_event_type,
      writer_backend_pid: writer_backend_pid,
      claim_backend_pid: claim_backend_pid,
      claim_result: claim_result
    }
  end

  defp await_blocking!(claim_backend_pid, writer_backend_pid) do
    deadline = System.monotonic_time(:millisecond) + @detection_budget
    await_blocking!(claim_backend_pid, writer_backend_pid, deadline)
  end

  defp await_blocking!(claim_backend_pid, writer_backend_pid, deadline) do
    observation =
      Sandbox.unboxed_run(Repo, fn ->
        %{rows: [[blocking_pids, wait_event_type]]} =
          SQL.query!(
            Repo,
            "SELECT pg_blocking_pids($1), wait_event_type FROM pg_stat_activity WHERE pid = $1",
            [claim_backend_pid]
          )

        %{blocking_pids: blocking_pids, wait_event_type: wait_event_type}
      end)

    cond do
      writer_backend_pid in observation.blocking_pids and observation.wait_event_type == "Lock" ->
        observation

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("saved-reset capacity claim never waited on the circuit writer backend")

      true ->
        :erlang.yield()
        await_blocking!(claim_backend_pid, writer_backend_pid, deadline)
    end
  end

  defp start_writer(mutation, parent, barrier, ready_message, label) do
    Task.async(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        run_writer(mutation, parent, barrier, ready_message, label)
      end)
    end)
  end

  defp run_writer(mutation, parent, barrier, ready_message, label) do
    Repo.transaction(fn ->
      backend_pid = backend_pid!()
      mutation.()
      send(parent, {barrier, ready_message, backend_pid, self()})
      await_release!(barrier, backend_pid, label)
    end)
  end

  defp await_release!(barrier, backend_pid, label) do
    receive do
      {^barrier, :release_writer} -> backend_pid
    after
      @detection_budget -> raise "timed out waiting to release #{label}"
    end
  end

  defp lock_circuit!(circuit_id) do
    Repo.one!(
      from circuit in RoutingCircuitState,
        where: circuit.id == ^circuit_id,
        lock: "FOR UPDATE"
    )
  end

  defp update_circuit!(circuit, final_status, recovery_attempted?) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    circuit
    |> RoutingCircuitState.changeset(%{
      status: final_status,
      reason_code: if(final_status == "open", do: "synthetic_failed_recovery", else: nil),
      failure_count: if(final_status == "open", do: 4, else: 0),
      opened_at: if(final_status == "open", do: now),
      closed_at: if(final_status == "closed", do: now),
      next_probe_at: if(final_status == "open", do: DateTime.add(now, 60, :second)),
      metadata: recovery_metadata(recovery_attempted?),
      updated_at: now
    })
    |> Repo.update!()
  end

  defp lock_identity_reference!(identity_id) do
    Repo.one!(
      from identity in UpstreamIdentity,
        where: identity.id == ^identity_id,
        lock: "FOR KEY SHARE"
    )
  end

  defp update_usable_quota!(fixture) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    window =
      Repo.one!(
        from window in AccountQuotaWindow,
          where:
            window.upstream_identity_id == ^fixture.sibling_identity_id and
              window.quota_key == "account" and window.window_kind == "secondary"
      )
      |> Ecto.Changeset.change(%{
        used_percent: Decimal.new("75"),
        observed_at: now,
        last_sync_at: now,
        reset_at: DateTime.add(now, 2, :hour),
        updated_at: now
      })
      |> Repo.update!()

    identity = Repo.get!(UpstreamIdentity, fixture.sibling_identity_id)

    unless AutoEligibility.locked_sibling_usable_capacity?(
             identity,
             fixture.context,
             DateTime.utc_now()
           ) do
      raise "quota writer did not produce usable sibling capacity: #{inspect({window.used_percent, window.observed_at, window.reset_at, window.freshness_state, window.source_precision})}"
    end
  end

  defp enable_target!(identity, fake) do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

    metadata =
      (identity.metadata || %{})
      |> Map.put("usage_base_url", FakeUpstream.url(fake))
      |> Map.put("saved_resets", %{
        "status" => "reported",
        "available_count" => 1,
        "source" => "codex_usage_api",
        "path_style" => "codex_api",
        "observed_at" => observed_at,
        "usage_path" => "/api/codex/usage",
        "reason" => nil
      })

    identity
    |> UpstreamIdentity.changeset(%{
      metadata: metadata,
      saved_reset_auto_redeem_enabled: true,
      saved_reset_auto_redeem_trigger_mode: "threshold",
      saved_reset_auto_redeem_quota_threshold_percent: 95,
      saved_reset_auto_redeem_min_blocked_minutes: 60,
      saved_reset_auto_redeem_keep_credits: 0,
      updated_at: DateTime.utc_now()
    })
    |> Repo.update!()
  end

  defp put_weekly_quota!(identity, used_percent) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, [window]} =
      QuotaWindows.upsert_quota_windows(identity, [
        %{
          quota_key: "account",
          window_kind: "secondary",
          window_minutes: 10_080,
          used_percent: Decimal.new(used_percent),
          reset_at: DateTime.add(now, 2, :hour),
          observed_at: now,
          last_sync_at: now,
          source: "codex_usage_api",
          source_precision: "observed",
          quota_scope: "account",
          quota_family: "account",
          freshness_state: "fresh"
        }
      ])

    window
  end

  defp recovery_metadata(attempted?) do
    %{
      "probe_in_flight_count" => 0,
      "saved_reset_recovery" => %{
        "version" => 1,
        "attempted" => attempted?,
        "since_success_at" => "never"
      }
    }
  end

  defp circuit_snapshot(circuit) do
    %{
      routing_circuit_state_id: circuit.id,
      upstream_identity_id: circuit.upstream_identity_id,
      pool_upstream_assignment_id: circuit.pool_upstream_assignment_id,
      model_identifier: circuit.model_identifier,
      route_class: circuit.route_class
    }
  end

  defp insert_closed_circuit!(template, id, created_at, updated_at) do
    %RoutingCircuitState{id: id}
    |> RoutingCircuitState.changeset(%{
      pool_id: template.pool_id,
      pool_upstream_assignment_id: template.pool_upstream_assignment_id,
      upstream_identity_id: template.upstream_identity_id,
      model_identifier: template.model_identifier,
      route_class: template.route_class,
      status: "closed",
      reason_code: nil,
      failure_count: 0,
      success_count: 1,
      closed_at: updated_at,
      metadata: recovery_metadata(false),
      created_at: created_at,
      updated_at: updated_at
    })
    |> Repo.insert!()
  end

  defp backend_pid! do
    %{rows: [[backend_pid]]} = SQL.query!(Repo, "SELECT pg_backend_pid()", [])
    backend_pid
  end

  defp show_setting!(setting) do
    %{rows: [[value]]} = SQL.query!(Repo, "SHOW #{setting}", [])
    value
  end

  defp provider_consume_count(fake) do
    Enum.count(
      FakeUpstream.requests(fake),
      &(&1.path == "/api/codex/rate-limit-reset-credits/consume")
    )
  end

  defp cleanup_fixture!(fixture) do
    FakeUpstream.stop(fixture.fake)

    Sandbox.unboxed_run(Repo, fn ->
      case Repo.get(Pool, fixture.pool_id) do
        %Pool{} = pool -> Repo.delete!(pool)
        nil -> :ok
      end
    end)
  end

  defp usage_payload do
    %{
      "plan_type" => "plus",
      "rate_limit" => %{
        "primary_window" => %{
          "used_percent" => 0,
          "limit_window_seconds" => 18_000,
          "reset_after_seconds" => 18_000,
          "reset_at" => DateTime.utc_now() |> DateTime.add(18_000, :second) |> DateTime.to_unix()
        },
        "secondary_window" => %{
          "used_percent" => 0,
          "limit_window_seconds" => 604_800,
          "reset_after_seconds" => 604_800,
          "reset_at" => DateTime.utc_now() |> DateTime.add(604_800, :second) |> DateTime.to_unix()
        }
      }
    }
  end
end
