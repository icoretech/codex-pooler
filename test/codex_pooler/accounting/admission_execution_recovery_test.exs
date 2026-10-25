defmodule CodexPooler.Accounting.AdmissionExecutionRecoveryTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountingTestSupport
  import Ecto.Query

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, ClientRetry, LedgerEntry, PreAttemptRelease, Request}
  alias CodexPooler.Accounting.RequestLifecycle.AdmissionExecutionRecovery
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn}
  alias CodexPooler.Platform.{ExecutionIdentity, InstancePresence}
  alias CodexPooler.Platform.InstancePresence.Identity
  alias CodexPooler.Repo
  alias CodexPooler.UnboxedFixture
  alias Ecto.Adapters.SQL.Sandbox

  test "a live waiting executor retains its reservation regardless of admission age" do
    setup = accounting_setup()
    admitted_at = DateTime.add(DateTime.utc_now(), -7, :hour)
    {executor, request} = start_executor!(setup, admitted_at)
    identity = execution_identity(request)

    assert ExecutionIdentity.status(identity) == :alive
    assert {:ok, %{admission_only_requests_recovered: 0}} = AdmissionExecutionRecovery.recover(DateTime.utc_now())
    assert {:ok, %{admission_only_requests_recovered: 0}} = AdmissionExecutionRecovery.recover_published(DateTime.utc_now())
    assert Repo.reload!(request).status == "in_progress"
    assert Accounting.reservation_outstanding?(request)
    assert ledger_kinds(request) == ["reservation"]
    assert_no_attempt_or_turn(request)

    stop_executor!(executor)
  end

  test "real executor death needs its exact durable proof and releases once without provider usage" do
    setup = accounting_setup()
    Repo.update_all(from(key in CodexPooler.Access.APIKey, where: key.id == ^setup.api_key.id), set: [max_active_requests: 1])
    {executor, request} = start_executor!(setup)
    identity = execution_identity(request)

    stop_executor!(executor)
    assert ExecutionIdentity.status(identity) == :dead
    assert {:ok, %{admission_only_requests_recovered: 0}} = recover_ids(request)
    assert Accounting.reservation_outstanding?(request)
    CodexPooler.ExecutionProofSupport.publish_terminal!(identity)

    assert {:ok, %{admission_only_requests_recovered: 1}} = recover_ids(request)
    assert %Request{status: "failed", usage_status: "not_applicable", response_status_code: 499, last_error_code: "admission_execution_recovered"} = Repo.reload!(request)
    assert_no_attempt_or_turn(request)
    assert ledger_kinds(request) == ["release", "reservation"]
    assert [%LedgerEntry{attempt_id: nil, usage_status: "not_applicable"} = release] = releases(request)
    assert release.details[PreAttemptRelease.detail_key()] == PreAttemptRelease.turn_interrupted()
    assert release.details["release_reason"] == "admission_execution_recovered"
    assert Decimal.equal?(release.estimated_cost_micros, reservation(request).estimated_cost_micros)
    assert Decimal.equal?(release.settled_cost_micros, 0)
    refute Accounting.reservation_outstanding?(request)

    assert {:ok, %{admission_only_requests_recovered: 0}} = recover_ids(request)
    assert {:ok, %{admission_only_requests_recovered: 0}} = AdmissionExecutionRecovery.recover_published(DateTime.utc_now())
    assert ledger_kinds(request) == ["release", "reservation"]
    assert {:ok, _next_reservation} = reserve!(setup, local_execution())
  end

  for {field, replacement} <- [
        {:admission_execution_id, :uuid},
        {:admission_instance_id, :uuid},
        {:admission_instance_boot_id, :uuid},
        {:admission_process_id, "<0.999999.0>"}
      ] do
    test "a terminal proof with mismatched #{field} cannot release admission work" do
      setup = accounting_setup()
      {executor, request} = start_executor!(setup)
      stop_executor!(executor)
      CodexPooler.ExecutionProofSupport.publish_terminal!(execution_identity(request))
      field = unquote(field)
      replacement = replacement_value(unquote(replacement))
      request = request |> Ecto.Changeset.change(%{field => replacement}) |> Repo.update!()

      assert {:ok, %{admission_only_requests_recovered: 0}} = recover_ids(request)
      assert {:ok, %{admission_only_requests_recovered: 0}} = AdmissionExecutionRecovery.recover_published(DateTime.utc_now())
      assert {:ok, %{admission_only_requests_recovered: 0}} = AdmissionExecutionRecovery.recover(DateTime.utc_now())
      assert Repo.reload!(request).status == "in_progress"
      assert ledger_kinds(request) == ["reservation"]
      assert_no_attempt_or_turn(request)
    end
  end

  test "legacy rows and malformed supplied identities remain unknown rather than borrowing this executor" do
    setup = accounting_setup()

    for identity <- [nil, %{owner_execution_id: Ecto.UUID.generate()}, %{local_execution() | owner_process_id: "not-a-pid"}] do
      {:ok, %{request: request}} = reserve!(setup, identity)
      assert request.admission_execution_id == nil
      assert request.admission_instance_id == nil
      assert request.admission_instance_boot_id == nil
      assert request.admission_process_id == nil
      assert_no_attempt_or_turn(request)
    end

    assert {:ok, %{admission_only_requests_recovered: 0}} = AdmissionExecutionRecovery.recover(DateTime.utc_now())
    assert Repo.aggregate(from(request in Request, where: request.pool_id == ^setup.pool.id and request.status == "in_progress"), :count) == 3
  end

  test "a durable superseding named incarnation authorizes admission recovery but stale presence alone does not" do
    setup = accounting_setup()
    now = InstancePresence.database_now()
    observer = InstancePresence.local_identity()
    assert {:ok, _observer} = InstancePresence.record_heartbeat(observer, now)
    owner = Identity.new("admission-#{Ecto.UUID.generate()}@example.invalid", Ecto.UUID.generate())
    successor = Identity.new(owner.node_name, Ecto.UUID.generate())
    assert {:ok, _old_owner} = InstancePresence.record_heartbeat(owner, DateTime.add(now, -300, :second))
    identity = %{owner_instance_id: owner.node_name, owner_instance_boot_id: owner.boot_id, owner_process_id: "<0.1.0>", owner_execution_id: Ecto.UUID.generate()}
    {:ok, %{request: request}} = reserve!(setup, identity)

    assert {:ok, %{admission_only_requests_recovered: 0}} = AdmissionExecutionRecovery.recover(now)
    assert ledger_kinds(request) == ["reservation"]
    assert {:ok, _successor} = InstancePresence.record_heartbeat(successor, DateTime.add(now, -1, :second))
    assert InstancePresence.superseded?(owner)
    assert {:ok, %{admission_only_requests_recovered: 0}} = AdmissionExecutionRecovery.recover_published(now)
    assert {:ok, %{admission_only_requests_recovered: 1}} = AdmissionExecutionRecovery.recover(now)
    assert Repo.reload!(request).last_error_code == "admission_execution_recovered"
    assert ledger_kinds(request) == ["release", "reservation"]
    assert_no_attempt_or_turn(request)
  end

  test "a shared anonymous node name without exclusive slot is not instance-restart death evidence" do
    setup = accounting_setup()
    now = InstancePresence.database_now()
    assert {:ok, _observer} = InstancePresence.record_heartbeat(InstancePresence.local_identity(), now)
    owner = Identity.new("nonode@nohost", Ecto.UUID.generate())
    successor = Identity.new("nonode@nohost", Ecto.UUID.generate())
    assert {:ok, _old_owner} = InstancePresence.record_heartbeat(owner, DateTime.add(now, -300, :second))
    assert {:ok, _new_owner} = InstancePresence.record_heartbeat(successor, DateTime.add(now, -1, :second))
    identity = %{owner_instance_id: owner.node_name, owner_instance_boot_id: owner.boot_id, owner_process_id: "<0.1.0>", owner_execution_id: Ecto.UUID.generate()}
    {:ok, %{request: request}} = reserve!(setup, identity)

    refute InstancePresence.superseded?(owner)
    assert {:ok, %{admission_only_requests_recovered: 0}} = AdmissionExecutionRecovery.recover(now)
    assert Repo.reload!(request).status == "in_progress"
    assert ledger_kinds(request) == ["reservation"]
  end

  test "an exact ended admission recovers its invisible native HTTP turn without any attempt" do
    setup = accounting_setup()
    {executor, request} = start_executor!(setup)
    request = request |> Ecto.Changeset.change(transport: "http_sse", endpoint: "/backend-api/codex/responses") |> Repo.update!()
    now = DateTime.utc_now()
    session = Repo.insert!(%CodexSession{pool_id: setup.pool.id, api_key_id: setup.api_key.id, session_key: Ecto.UUID.generate(), status: "active"})
    turn = Repo.insert!(%CodexTurn{codex_session_id: session.id, request_id: request.id, turn_sequence: 1, transport_kind: "http_sse", status: "in_progress", started_at: now})

    assert {:ok, %{admission_only_requests_recovered: 0}} = recover_ids(request)
    stop_executor!(executor)
    CodexPooler.ExecutionProofSupport.publish_terminal!(execution_identity(request))
    assert {:ok, %{admission_only_requests_recovered: 1}} = recover_ids(request)
    assert %CodexTurn{status: "interrupted", error_code: "admission_execution_recovered", final_attempt_id: nil, first_visible_output_at: nil, completed_at: %DateTime{}} = Repo.reload!(turn)
    assert %Request{status: "failed", usage_status: "not_applicable", last_error_code: "admission_execution_recovered"} = Repo.reload!(request)
    assert ledger_kinds(request) == ["release", "reservation"]
    refute Repo.exists?(from(attempt in Attempt, where: attempt.request_id == ^request.id))
    assert {:ok, %{admission_only_requests_recovered: 0}} = recover_ids(request)
  end

  for attrs <- [
        %{transport_kind: "websocket"},
        %{first_visible_output_at: :now},
        %{status: "succeeded", completed_at: :now},
        %{final_attempt_id: :attempt}
      ] do
    test "native admission recovery retains turn evidence #{inspect(attrs)}" do
      setup = accounting_setup()
      {executor, request} = start_executor!(setup)
      request = request |> Ecto.Changeset.change(transport: "http_sse", endpoint: "/backend-api/codex/responses") |> Repo.update!()
      stop_executor!(executor)
      CodexPooler.ExecutionProofSupport.publish_terminal!(execution_identity(request))
      now = DateTime.utc_now()
      session = Repo.insert!(%CodexSession{pool_id: setup.pool.id, api_key_id: setup.api_key.id, session_key: Ecto.UUID.generate(), status: "active"})

      attrs =
        Map.new(unquote(Macro.escape(attrs)), fn {key, value} ->
          {key,
           case value do
             :now ->
               now

             :attempt ->
               {:ok, attempt} = Accounting.create_attempt(request, setup.assignment)
               attempt.id

             other ->
               other
           end}
        end)

      turn = Repo.insert!(struct(%CodexTurn{codex_session_id: session.id, request_id: request.id, turn_sequence: 1, transport_kind: "http_sse", status: "in_progress", started_at: now}, attrs))
      assert {:ok, %{admission_only_requests_recovered: 0}} = recover_ids(request)
      assert Repo.reload!(turn).status == turn.status
      assert Repo.reload!(request).status == "in_progress"
      assert ledger_kinds(request) == ["reservation"]
    end
  end

  for changed <- [:pool_id, :api_key_id, :model_id, :codex_session_id, :auth_epoch, :witness, :anchor] do
    test "native admission retry retains #{changed} fence", do: assert_native_scope_fence(unquote(changed))
  end

  defp native_retry_fixture! do
    setup = accounting_setup()
    {executor, request} = start_executor!(setup)
    stop_executor!(executor)
    CodexPooler.ExecutionProofSupport.publish_terminal!(execution_identity(request))
    witness = ClientRetry.original_witness!(:crypto.strong_rand_bytes(32), 0)
    request = request |> Ecto.Changeset.change(Map.merge(ClientRetry.request_attrs(witness), %{transport: "http_sse", endpoint: "/backend-api/codex/responses"})) |> Repo.update!()
    now = DateTime.utc_now()
    session = Repo.insert!(%CodexSession{pool_id: setup.pool.id, api_key_id: setup.api_key.id, session_key: Ecto.UUID.generate(), status: "active"})
    Repo.insert!(%CodexTurn{codex_session_id: session.id, request_id: request.id, turn_sequence: 1, transport_kind: "http_sse", status: "in_progress", started_at: now})
    scope = %{pool_id: request.pool_id, api_key_id: request.api_key_id, model_id: request.model_id, endpoint: request.endpoint, codex_session_id: session.id, auth_epoch: 0, native_client_retry_witness: witness, anchor_present?: false}

    {setup, request, scope}
  end

  defp assert_native_scope_fence(changed) do
    {_setup, request, scope} = native_retry_fixture!()
    now = DateTime.utc_now()

    scope =
      case changed do
        :auth_epoch -> %{scope | auth_epoch: 1}
        :witness -> %{scope | native_client_retry_witness: ClientRetry.original_witness!(:crypto.strong_rand_bytes(32), 0)}
        :anchor -> %{scope | anchor_present?: true}
        key -> Map.put(scope, key, Ecto.UUID.generate())
      end

    assert {:error, :authorization_changed} = AdmissionExecutionRecovery.recover_native_retry(request, scope, now)
    assert Repo.reload!(request).status == "in_progress"
    assert ledger_kinds(request) == ["reservation"]
  end

  for mutation <- [:source_link, :missing_source_link, :linked_noncanonical_reservation, :release_source, :reservation_source, :request_status, :estimated_cost, :settled_cost, :pool_id, :api_key_id, :model_id, :transport, :currency_code, :input_tokens, :cached_input_tokens, :output_tokens, :reasoning_tokens, :total_tokens, :request_count] do
    @tag :native_release_provenance
    test "native retry refuses a corrupted release #{mutation}", do: assert_release_provenance_fence(unquote(mutation))
  end

  defp assert_release_provenance_fence(mutation) do
    {_setup, request, scope} = native_retry_fixture!()
    assert {:ok, %{admission_only_requests_recovered: 1}} = recover_ids(request)
    request = Repo.reload!(request)
    assert {:ok, ^request, []} = AdmissionExecutionRecovery.recover_native_retry(request, scope, DateTime.utc_now())
    [release] = releases(request)
    reservation = reservation(request)

    {target, attrs} = release_corruption(mutation, release, reservation)

    target |> Ecto.Changeset.change(attrs) |> Repo.update!()
    assert {:error, :terminal_predecessor} = AdmissionExecutionRecovery.recover_native_retry(request, scope, DateTime.utc_now())
    assert ledger_kinds(request) == ["release", "reservation"]
    refute Repo.exists?(from(attempt in Attempt, where: attempt.request_id == ^request.id))
  end

  defp release_corruption(:source_link, release, _reservation), do: {release, %{details: Map.put(release.details, "reservation_source_event_id", "synthetic-wrong-reservation")}}
  defp release_corruption(:missing_source_link, release, _reservation), do: {release, %{details: Map.delete(release.details, "reservation_source_event_id")}}

  defp release_corruption(:linked_noncanonical_reservation, release, reservation) do
    source = "synthetic-linked-noncanonical-reservation"
    release |> Ecto.Changeset.change(details: Map.put(release.details, "reservation_source_event_id", source)) |> Repo.update!()
    {reservation, %{source_event_id: source}}
  end

  defp release_corruption(:release_source, release, _reservation), do: {release, %{source_event_id: "synthetic-wrong-release"}}
  defp release_corruption(:reservation_source, _release, reservation), do: {reservation, %{source_event_id: "synthetic-wrong-reservation"}}
  defp release_corruption(:request_status, release, _reservation), do: {release, %{details: Map.put(release.details, "request_status", "in_progress")}}
  defp release_corruption(:estimated_cost, release, _reservation), do: {release, %{estimated_cost_micros: Decimal.add(release.estimated_cost_micros, 1)}}
  defp release_corruption(:settled_cost, release, _reservation), do: {release, %{settled_cost_micros: Decimal.new(1)}}
  defp release_corruption(:transport, release, _reservation), do: {release, %{transport: "websocket"}}
  defp release_corruption(:currency_code, release, _reservation), do: {release, %{currency_code: "EUR"}}

  defp release_corruption(field, release, _reservation) when field in [:pool_id, :api_key_id, :model_id] do
    other = accounting_setup()

    value =
      case field do
        :pool_id -> other.pool.id
        :api_key_id -> other.api_key.id
        :model_id -> other.model.id
      end

    {release, %{field => value}}
  end

  defp release_corruption(field, release, _reservation), do: {release, %{field => (Map.get(release, field) || 0) + 1}}

  @tag :native_release_provenance
  test "scheduled recovery handles an admission after its API key was deleted" do
    {setup, request, scope} = native_retry_fixture!()
    Repo.delete!(setup.api_key)
    request = Repo.reload!(request)
    assert request.api_key_id == nil
    refute Repo.get(CodexSession, scope.codex_session_id)
    refute Repo.exists?(from(turn in CodexTurn, where: turn.request_id == ^request.id))
    assert {:ok, %{admission_only_requests_recovered: 1}} = AdmissionExecutionRecovery.recover(DateTime.utc_now())
    assert Repo.reload!(request).last_error_code == "admission_execution_recovered"
    assert ledger_kinds(request) == ["release", "reservation"]
  end

  test "caller-owned rollback keeps the reservation and defers its release telemetry" do
    setup = accounting_setup()
    {executor, request} = start_executor!(setup)
    stop_executor!(executor)
    CodexPooler.ExecutionProofSupport.publish_terminal!(execution_identity(request))

    assert {:error, :rollback_admission} =
             Repo.transaction(fn ->
               assert {:ok, %{admission_only_requests_recovered: 1, after_commit_markers: [%{kind: :pre_attempt_release, phase: "turn_interrupted", release_reason: "admission_execution_recovered"}]}} = recover_ids(request)
               Repo.rollback(:rollback_admission)
             end)

    assert Repo.reload!(request).status == "in_progress"
    assert ledger_kinds(request) == ["reservation"]
    assert {:ok, %{admission_only_requests_recovered: 1}} = recover_ids(request)
  end

  test "a first-attempt transaction wins before waiting recovery and retains its open reservation" do
    setup = committed_setup!()
    {executor, request} = start_executor!(setup, DateTime.utc_now(), :unboxed)
    stop_executor!(executor)
    {request, native_turn} = committed_native_turn!(request, setup)
    CodexPooler.ExecutionProofSupport.publish_committed_terminal!(execution_identity(request))
    parent = self()

    dispatcher =
      start_supervised!(
        {Task,
         fn ->
           result =
             Sandbox.unboxed_run(Repo, fn ->
               Repo.transaction(fn ->
                 backend = backend_pid!()
                 locked = Repo.one!(from(row in Request, where: row.id == ^request.id, lock: "FOR UPDATE"))
                 send(parent, {:dispatcher_locked, backend})
                 receive do: (:insert_attempt -> :ok)
                 assert {:ok, attempt} = Accounting.create_attempt(locked, setup.assignment)
                 attempt
               end)
             end)

           send(parent, {:dispatch_finished, result})
         end}
      )

    dispatcher_monitor = Process.monitor(dispatcher)
    assert_receive {:dispatcher_locked, dispatcher_backend}, 15_000
    {recovery, recovery_monitor, recovery_backend} = start_recovery!(request)
    assert recovery_backend != dispatcher_backend
    assert_blocked!(recovery_backend, dispatcher_backend)
    send(dispatcher, :insert_attempt)
    assert_receive {:dispatch_finished, {:ok, attempt}}, 15_000
    assert_receive {:admission_recovery_finished, ^recovery, {:ok, %{admission_only_requests_recovered: 0}}}, 15_000
    assert_receive {:DOWN, ^dispatcher_monitor, :process, ^dispatcher, :normal}, 15_000
    assert_receive {:DOWN, ^recovery_monitor, :process, ^recovery, :normal}, 15_000

    UnboxedFixture.run_unboxed(fn ->
      assert Repo.reload!(request).status == "in_progress"
      assert Repo.reload!(attempt).status == "in_progress"
      assert Repo.reload!(native_turn).status == "in_progress"
      assert ledger_kinds(request) == ["reservation"]
      assert Accounting.reservation_outstanding?(request)
    end)
  end

  test "two recoveries waiting on one admission row release the reservation exactly once" do
    setup = committed_setup!()
    {executor, request} = start_executor!(setup, DateTime.utc_now(), :unboxed)
    stop_executor!(executor)
    {request, native_turn} = committed_native_turn!(request, setup)
    CodexPooler.ExecutionProofSupport.publish_committed_terminal!(execution_identity(request))
    parent = self()

    holder =
      start_supervised!(
        {Task,
         fn ->
           Sandbox.unboxed_run(Repo, fn ->
             Repo.transaction(fn ->
               backend = backend_pid!()
               Repo.one!(from(row in Request, where: row.id == ^request.id, lock: "FOR UPDATE"))
               send(parent, {:admission_locked, backend})
               receive do: (:release_lock -> :ok)
             end)
           end)
         end}
      )

    holder_monitor = Process.monitor(holder)
    assert_receive {:admission_locked, holder_backend}, 15_000
    {first, first_monitor, first_backend} = start_recovery!(request)
    assert_blocked!(first_backend, holder_backend)
    {second, second_monitor, second_backend} = start_recovery!(request)
    assert Enum.uniq([holder_backend, first_backend, second_backend]) |> length() == 3
    # PostgreSQL queues the second UPDATE behind the first waiting updater;
    # it need not list the row holder as its direct blocker.
    assert_blocked!(second_backend, first_backend)
    send(holder, :release_lock)
    assert_receive {:admission_recovery_finished, ^first, {:ok, first_summary}}, 15_000
    assert_receive {:admission_recovery_finished, ^second, {:ok, second_summary}}, 15_000
    assert first_summary.admission_only_requests_recovered + second_summary.admission_only_requests_recovered == 1
    assert_receive {:DOWN, ^holder_monitor, :process, ^holder, :normal}, 15_000
    assert_receive {:DOWN, ^first_monitor, :process, ^first, :normal}, 15_000
    assert_receive {:DOWN, ^second_monitor, :process, ^second, :normal}, 15_000

    UnboxedFixture.run_unboxed(fn ->
      assert Repo.reload!(request).last_error_code == "admission_execution_recovered"
      assert ledger_kinds(request) == ["release", "reservation"]
      refute Repo.exists?(from(attempt in Attempt, where: attempt.request_id == ^request.id))
      assert Repo.reload!(native_turn).status == "interrupted"
    end)
  end

  test "a locked proven admission does not starve a later unlocked durable proof" do
    setup = committed_setup!()
    now = DateTime.utc_now()
    {older_executor, older} = start_executor!(setup, DateTime.add(now, -1, :second), :unboxed)
    {later_executor, later} = start_executor!(setup, now, :unboxed)
    stop_executor!(older_executor)
    stop_executor!(later_executor)
    CodexPooler.ExecutionProofSupport.publish_committed_terminal!(execution_identity(older))
    CodexPooler.ExecutionProofSupport.publish_committed_terminal!(execution_identity(later))
    parent = self()

    holder =
      start_supervised!(
        {Task,
         fn ->
           Sandbox.unboxed_run(Repo, fn ->
             Repo.transaction(fn ->
               backend = backend_pid!()
               Repo.one!(from(row in Request, where: row.id == ^older.id, lock: "FOR UPDATE"))
               send(parent, {:older_admission_locked, backend})
               receive do: (:release_lock -> :ok)
             end)
           end)
         end}
      )

    holder_monitor = Process.monitor(holder)
    assert_receive {:older_admission_locked, holder_backend}, 15_000

    {recovery_backend, result} =
      UnboxedFixture.run_unboxed(fn ->
        Repo.checkout(
          fn ->
            backend = backend_pid!()
            {backend, AdmissionExecutionRecovery.recover_published(DateTime.utc_now(), limit: 1, timeout: 500)}
          end,
          timeout: 500,
          deadline: System.monotonic_time(:millisecond) + 500,
          checkout_retries: 0
        )
      end)

    assert recovery_backend != holder_backend
    assert {:ok, %{admission_only_requests_recovered: 1}} = result
    assert Process.alive?(holder)

    UnboxedFixture.run_unboxed(fn ->
      assert Repo.reload!(older).status == "in_progress"
      assert ledger_kinds(older) == ["reservation"]
      assert Repo.reload!(later).last_error_code == "admission_execution_recovered"
      assert ledger_kinds(later) == ["release", "reservation"]
      assert_no_attempt_or_turn(older)
      assert_no_attempt_or_turn(later)
    end)

    send(holder, :release_lock)
    assert_receive {:DOWN, ^holder_monitor, :process, ^holder, :normal}, 15_000

    UnboxedFixture.run_unboxed(fn ->
      assert {:ok, %{admission_only_requests_recovered: 1}} = AdmissionExecutionRecovery.recover_published(DateTime.utc_now(), limit: 2, timeout: 500)
      assert ledger_kinds(older) == ["release", "reservation"]
      assert ledger_kinds(later) == ["release", "reservation"]
    end)
  end

  defp committed_native_turn!(request, setup) do
    UnboxedFixture.run_unboxed(fn ->
      request = request |> Ecto.Changeset.change(transport: "http_sse", endpoint: "/backend-api/codex/responses") |> Repo.update!()
      now = DateTime.utc_now()
      session = Repo.insert!(%CodexSession{pool_id: setup.pool.id, api_key_id: setup.api_key.id, session_key: Ecto.UUID.generate(), status: "active"})
      turn = Repo.insert!(%CodexTurn{codex_session_id: session.id, request_id: request.id, turn_sequence: 1, transport_kind: "http_sse", status: "in_progress", started_at: now})
      {request, turn}
    end)
  end

  defp start_executor!(setup, now \\ DateTime.utc_now(), connection \\ :sandbox) do
    parent = self()
    id = make_ref()

    executor =
      start_supervised!(
        {Task,
         fn ->
           fun = fn ->
             {:ok, %{request: request}} = reserve!(setup, local_execution(), now)
             send(parent, {:admission_waiting, self(), request})
             receive do: (:stop_executor -> :ok)
           end

           if connection == :unboxed, do: Sandbox.unboxed_run(Repo, fun), else: fun.()
         end},
        id: id
      )

    assert_receive {:admission_waiting, ^executor, request}, 15_000
    {executor, request}
  end

  defp stop_executor!(executor) do
    monitor = Process.monitor(executor)
    send(executor, :stop_executor)
    assert_receive {:DOWN, ^monitor, :process, ^executor, :normal}, 15_000
  end

  defp reserve!(setup, identity, now \\ DateTime.utc_now()) do
    Accounting.reserve(setup.auth, setup.model, %{"model" => setup.model.exposed_model_id, "max_output_tokens" => 10, "stream" => true}, %{
      correlation_id: Ecto.UUID.generate(),
      now: now,
      admission_execution: identity,
      request_metadata: %{source_endpoint: "/v1/responses"}
    })
  end

  defp local_execution do
    owner = InstancePresence.local_identity()
    Map.merge(ExecutionIdentity.local(), %{owner_instance_id: owner.node_name, owner_instance_boot_id: owner.boot_id})
  end

  defp execution_identity(request) do
    %{owner_execution_id: request.admission_execution_id, owner_instance_id: request.admission_instance_id, owner_instance_boot_id: request.admission_instance_boot_id, owner_process_id: request.admission_process_id}
  end

  defp recover_ids(request), do: AdmissionExecutionRecovery.recover_execution_ids([request.admission_execution_id], DateTime.utc_now())

  defp ledger_kinds(request), do: Repo.all(from(entry in LedgerEntry, where: entry.request_id == ^request.id, order_by: entry.entry_kind, select: entry.entry_kind))
  defp releases(request), do: Repo.all(from(entry in LedgerEntry, where: entry.request_id == ^request.id and entry.entry_kind == "release"))
  defp reservation(request), do: Repo.one!(from(entry in LedgerEntry, where: entry.request_id == ^request.id and entry.entry_kind == "reservation"))

  defp assert_no_attempt_or_turn(request) do
    refute Repo.exists?(from(attempt in Attempt, where: attempt.request_id == ^request.id))
    refute Repo.exists?(from(turn in CodexTurn, where: turn.request_id == ^request.id))
  end

  defp committed_setup! do
    %{user: owner} = CodexPooler.AccountsFixtures.committed_bootstrap_owner_fixture!()
    pool_id = Ecto.UUID.generate()
    identity_id = Ecto.UUID.generate()

    UnboxedFixture.register_unboxed_cleanup!(fn ->
      CodexPooler.PoolerFixtures.delete_committed_pools!([pool_id], [owner.id])
      Repo.delete_all(from(identity in CodexPooler.Upstreams.Schemas.UpstreamIdentity, where: identity.id == ^identity_id))
    end)

    UnboxedFixture.run_unboxed(fn ->
      now = DateTime.utc_now()
      pool = Repo.insert!(%CodexPooler.Pools.Pool{id: pool_id, slug: "admission-race-#{pool_id}", name: "Admission race", status: "active", created_by_user_id: owner.id, created_at: now, updated_at: now})
      %{api_key: api_key} = CodexPooler.PoolerFixtures.active_api_key_fixture(pool, %{created_by_user_id: owner.id})
      model = CodexPooler.PoolerFixtures.model_fixture(pool)
      Repo.insert!(%CodexPooler.Upstreams.Schemas.UpstreamIdentity{id: identity_id, account_label: "Admission race", status: "active", headers_profile_version: 1, onboarding_method: "import", created_at: now, updated_at: now, metadata: %{}})
      assignment = Repo.insert!(%CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment{pool_id: pool.id, upstream_identity_id: identity_id, assignment_label: "Admission race", status: "active", health_status: "active", eligibility_status: "eligible", created_at: now, updated_at: now, metadata: %{}})
      %{pool: pool, api_key: api_key, auth: %{pool: pool, api_key: api_key}, model: model, assignment: assignment}
    end)
  end

  defp start_recovery!(request) do
    parent = self()

    recovery =
      start_supervised!(
        {Task,
         fn ->
           result =
             Sandbox.unboxed_run(Repo, fn ->
               Repo.checkout(fn ->
                 send(parent, {:admission_recovery_backend, self(), backend_pid!()})
                 recover_ids(request)
               end)
             end)

           send(parent, {:admission_recovery_finished, self(), result})
         end},
        id: make_ref()
      )

    monitor = Process.monitor(recovery)
    assert_receive {:admission_recovery_backend, ^recovery, backend}, 15_000
    {recovery, monitor, backend}
  end

  defp backend_pid!, do: Repo.query!("SELECT pg_backend_pid()", []).rows |> List.first() |> List.first()

  defp replacement_value(:uuid), do: Ecto.UUID.generate()
  defp replacement_value(value), do: value

  defp assert_blocked!(waiter, blocker), do: assert_blocked!(waiter, blocker, System.monotonic_time(:millisecond) + 15_000)

  defp assert_blocked!(waiter, blocker, deadline) do
    blocked = UnboxedFixture.run_unboxed(fn -> Repo.query!("SELECT $2 = ANY(pg_blocking_pids($1))", [waiter, blocker]).rows == [[true]] end)

    unless blocked do
      assert System.monotonic_time(:millisecond) < deadline, "admission recovery never reached its request lock"
      Process.sleep(10)
      assert_blocked!(waiter, blocker, deadline)
    end
  end
end
