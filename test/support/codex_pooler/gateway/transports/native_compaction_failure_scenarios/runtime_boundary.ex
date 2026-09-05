defmodule CodexPooler.Gateway.Transports.NativeCompactionFailureScenarios.RuntimeBoundary do
  @moduledoc false

  import Ecto.Query
  import ExUnit.Assertions, only: [assert: 1]
  import ExUnit.Callbacks, only: [on_exit: 1, start_supervised!: 1]
  import ExUnit.CaptureLog, only: [with_log: 1]

  alias CodexPooler.Access
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.AccountingTestSupport
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.ResetProbe
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Gateway.Runtime.Dispatch.{AccountingReservation, PreDispatch, RouteState}
  alias CodexPooler.Gateway.Runtime.Finalization.AttemptSettlement
  alias CodexPooler.Gateway.Runtime.Service
  alias CodexPooler.Gateway.Transports.Admission
  alias CodexPooler.Gateway.Transports.NativeCompactionFailureScenarios.AccountingHandle
  alias CodexPooler.Gateway.Transports.NativeCompactionFailureScenarios.AccountingLifecycle
  alias CodexPooler.Gateway.Transports.NativeCompactionFailureScenarios.Observed
  alias CodexPooler.Gateway.Transports.Websocket.ActivityRegistry
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.Binding
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.Topology.Direct
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession

  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.Request,
    as: WebsocketRequest

  alias CodexPooler.Gateway.Websocket
  alias CodexPooler.Gateway.Websocket.ResponseTask
  alias CodexPooler.Repo
  alias CodexPooler.RouteClass
  alias CodexPoolerWeb.Runtime.BackendCodexTestSupport

  @endpoint "/backend-api/codex/responses"
  @detection_timeout_ms 15_000

  @type variant ::
          :validation_admission_overload
          | :routing_denial
          | :saved_reset
          | :accounting_reservation_failure
          | :caller_death_before_accounting

  @spec run(variant(), map()) :: Observed.t()
  def run(:validation_admission_overload, _context) do
    fixture = runtime_fixture(:validation_admission_overload)
    owner = start_owner!()
    correlation_id = correlation_id(:validation_admission_overload)

    malformed_payload =
      Jason.encode!(%{"model" => fixture.model.exposed_model_id, "input" => "invalid"})

    malformed_options = request_options(fixture.auth, correlation_id, %{})

    {:error, %{code: validation_code}} =
      Websocket.prepare_websocket_response(malformed_payload, malformed_options, fn _frame ->
        :ok
      end)

    overload_server = start_admission_server!()
    settings = overload_settings()

    {:ok, held} =
      Admission.acquire(RouteClass.proxy_websocket(), %{request_id: correlation_id}, %{
        server: overload_server,
        settings: settings
      })

    {:error, %{code: "server_is_overloaded", accounting_disposition: :zero_work}} =
      Admission.run(
        RouteClass.proxy_websocket(),
        %{request_id: correlation_id},
        fn -> raise "overloaded admission executed protected work" end,
        server: overload_server,
        settings: settings
      )

    Admission.release(held)

    true = is_binary(validation_code)
    observe_zero_work(owner, fixture.upstream, correlation_id)
  end

  def run(:routing_denial, _context) do
    fixture = runtime_fixture(:routing_denial)
    correlation_id = correlation_id(:routing_denial)
    {owner, payload, request_options} = reserved_admission_input(fixture, correlation_id)

    fixture.assignment
    |> Ecto.Changeset.change(health_status: "degraded")
    |> Repo.update!()

    {:error, %{code: code}} =
      PreDispatch.prepare(fixture.auth, @endpoint, payload, request_options, fixture.model)

    :ok = RequestOptions.clear_native_compaction_admission(request_options)

    true = is_binary(code)
    observe_zero_work(owner, fixture.upstream, correlation_id)
  end

  def run(:saved_reset, _context) do
    fixture = runtime_fixture(:saved_reset)
    correlation_id = correlation_id(:saved_reset)
    {owner, prepared} = prepared_with_reserved_admission(fixture, correlation_id)

    {:ok, probe} =
      ResetProbe.new()
      |> ResetProbe.bind(
        Ecto.UUID.generate(),
        fixture.identity.id,
        fixture.model.exposed_model_id,
        RouteClass.proxy_websocket()
      )

    options = %{
      prepared.request_options
      | routing: %{prepared.request_options.routing | reset_probe: probe}
    }

    route_state = RouteState.put_reset_probe(prepared.route_state, probe)

    {:error, {:reset_probe_scope_mismatch, %{code: code}}} =
      AccountingReservation.validate_reset_probe_scope(
        prepared.candidates,
        options,
        route_state
      )

    :ok = RequestOptions.clear_native_compaction_admission(options)

    true = is_binary(code)
    observe_zero_work(owner, fixture.upstream, correlation_id)
  end

  def run(:accounting_reservation_failure, _context) do
    fixture = runtime_fixture(:accounting_reservation_failure)
    correlation_id = correlation_id(:accounting_reservation_failure)
    {owner, prepared} = prepared_with_reserved_admission(fixture, correlation_id)

    rollback = fn -> Repo.transaction(fn -> Repo.rollback(:rollback) end) end

    {{:error, %{code: code}}, logs} =
      with_log(fn -> execute_session_routable(prepared, fixture, rollback) end)

    assert logs =~ "gateway pre-attempt reservation failed"
    assert logs =~ "operation=reserve_and_start_turn"
    assert logs =~ "failure_code=gateway_reservation_failed"
    assert logs =~ "failure_reason=rollback retryable=true"

    true = is_binary(code)
    observe_zero_work(owner, fixture.upstream, correlation_id)
  end

  def run(:caller_death_before_accounting, _context) do
    fixture = runtime_fixture(:caller_death_before_accounting)
    correlation_id = correlation_id(:caller_death_before_accounting)
    owner = start_owner!()
    registry = start_activity_registry!()
    parent = self()

    {:ok, caller} =
      ResponseTask.start(
        parent,
        :proxy,
        fn _task_pid ->
          send(parent, :runtime_provider_forbidden_dispatch)
          :ok
        end,
        fn task_pid, reason -> send(parent, {:runtime_provider_cancelled, task_pid, reason}) end,
        activity_registry: registry,
        before_cancel_recipient_handoff: fn token ->
          send(parent, {:runtime_provider_before_handoff, self(), token})

          receive do
            :runtime_provider_release_handoff -> :ok
          after
            @detection_timeout_ms -> raise "runtime provider handoff release timed out"
          end
        end
      )

    caller_monitor = Process.monitor(caller)
    token = assert_receive_token!(:runtime_provider_before_handoff, caller)
    {_epoch, [%{token: ^token, pid: ^caller}]} = ActivityRegistry.begin_drain(name: registry)
    :ok = ActivityRegistry.cancel(token, :owner_drained, name: registry)
    send(caller, :runtime_provider_release_handoff)

    receive do
      {:runtime_provider_cancelled, ^caller, :owner_drained} -> :ok
    after
      @detection_timeout_ms -> raise "runtime provider cancellation was not observed"
    end

    receive do
      {:websocket_response_activity, ^caller, ^token} -> :ok
    after
      @detection_timeout_ms -> raise "runtime provider activity handoff was not observed"
    end

    ack_pid =
      receive do
        {:websocket_response_activity_cancelled, ^caller, ^token, pid, :owner_drained} -> pid
      after
        @detection_timeout_ms -> raise "runtime provider cancellation acknowledgement timed out"
      end

    :ok = ResponseTask.acknowledge_delivery(ack_pid, token)

    receive do
      {:codex_response_done, ^caller, {:error, :owner_drained}} -> :ok
    after
      @detection_timeout_ms -> raise "runtime provider caller result timed out"
    end

    receive do
      {:DOWN, ^caller_monitor, :process, ^caller, :normal} -> :ok
    after
      @detection_timeout_ms -> raise "runtime provider caller did not retire"
    end

    receive do
      :runtime_provider_forbidden_dispatch -> raise "caller death reached dispatch"
    after
      0 -> :ok
    end

    observe_zero_work(owner, fixture.upstream, correlation_id)
  end

  @spec open_accounted_lifecycle!(map(), atom()) :: AccountingHandle.t()
  def open_accounted_lifecycle!(context, variant) when is_map(context) and is_atom(variant) do
    fixture =
      AccountingTestSupport.accounting_setup(%{
        account_label: "Compaction provider",
        price_version: pricing_version(context, variant)
      })

    correlation_id = correlation_id(variant)
    baseline = observe_correlation(correlation_id)
    payload = payload(fixture.model.exposed_model_id, Atom.to_string(variant))

    request_options =
      fixture.auth
      |> request_options(correlation_id, payload)
      |> RequestOptions.put_continuity(accepted_turn_state: correlation_id)

    {:ok, session} = Websocket.start_codex_session(fixture.auth, request_options)

    {:ok, %{request: request}} =
      Accounting.reserve(fixture.auth, fixture.model, payload, %{
        endpoint: @endpoint,
        transport: "websocket",
        correlation_id: correlation_id,
        request_metadata: %{"codex_session_id" => session.id}
      })

    {:ok, attempt} = Accounting.create_attempt(request, fixture.assignment)

    {:ok, turn} =
      Websocket.start_codex_turn(session, request, %{
        pool_upstream_assignment_id: fixture.assignment.id
      })

    struct!(AccountingHandle, %{
      correlation_id: correlation_id,
      request_id: request.id,
      attempt_id: attempt.id,
      turn_id: turn.id,
      baseline: baseline,
      resource: %{
        fixture: fixture,
        session: session
      },
      metadata: bounded_context_metadata(context)
    })
  end

  @spec settle_accounted_lifecycle!(AccountingHandle.t(), :success | {:failure, atom()} | atom()) ::
          AccountingLifecycle.t()
  def settle_accounted_lifecycle!(
        %AccountingHandle{request_id: request_id, attempt_id: attempt_id} = handle,
        :success
      )
      when is_binary(request_id) and is_binary(attempt_id) do
    request = Repo.get!(Request, request_id)
    attempt = Repo.get!(Attempt, attempt_id)

    {:ok, _result} =
      AttemptSettlement.finalize_success(
        request,
        attempt,
        %{input_tokens: 1, output_tokens: 1, total_tokens: 2},
        %{status: 200}
      )

    observe_accounting!(handle)
  end

  def settle_accounted_lifecycle!(
        %AccountingHandle{request_id: request_id, attempt_id: attempt_id} = handle,
        {:failure, outcome}
      )
      when is_binary(request_id) and is_binary(attempt_id) and is_atom(outcome) do
    request = Repo.get!(Request, request_id)
    attempt = Repo.get!(Attempt, attempt_id)
    error_code = bounded_error_code(outcome)

    {:ok, _result} =
      AttemptSettlement.finalize_failure(request, attempt, %{
        response_status_code: 503,
        last_error_code: error_code,
        error_message: "runtime provider failure",
        usage_status: "usage_unknown",
        retry_count: 0,
        retryable: false
      })

    observe_accounting!(handle)
  end

  def settle_accounted_lifecycle!(%AccountingHandle{} = handle, outcome) when is_atom(outcome),
    do: settle_accounted_lifecycle!(handle, {:failure, outcome})

  @spec empty_accounting_handle(map(), atom()) :: AccountingHandle.t()
  def empty_accounting_handle(context, variant) when is_map(context) and is_atom(variant) do
    correlation_id = correlation_id(variant)

    %AccountingHandle{
      correlation_id: correlation_id,
      baseline: observe_correlation(correlation_id),
      metadata: bounded_context_metadata(context)
    }
  end

  @spec observe_accounting!(AccountingHandle.t()) :: AccountingLifecycle.t()
  def observe_accounting!(%AccountingHandle{
        correlation_id: correlation_id,
        baseline: baseline
      }) do
    current = observe_correlation(correlation_id)
    subtract_accounting(current, baseline || zero_accounting_lifecycle())
  end

  defp observe_correlation(correlation_id) do
    request_ids =
      Repo.all(
        from request in Request,
          where: request.correlation_id == ^correlation_id,
          select: request.id
      )

    %AccountingLifecycle{
      requests: length(request_ids),
      attempts:
        Repo.aggregate(
          from(attempt in Attempt, where: attempt.request_id in ^request_ids),
          :count
        ),
      turns:
        Repo.aggregate(from(turn in CodexTurn, where: turn.request_id in ^request_ids), :count),
      reservations:
        Repo.aggregate(
          from(entry in LedgerEntry,
            where: entry.request_id in ^request_ids and entry.entry_kind == "reservation"
          ),
          :count
        ),
      settlements:
        Repo.aggregate(
          from(entry in LedgerEntry,
            where: entry.request_id in ^request_ids and entry.entry_kind == "settlement"
          ),
          :count
        )
    }
  end

  defp runtime_fixture(variant) do
    {:ok, upstream} = FakeUpstream.start_link(FakeUpstream.json_response(%{"data" => []}))
    on_exit(fn -> FakeUpstream.stop(upstream) end)
    setup = BackendCodexTestSupport.gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    Map.merge(setup, %{auth: auth, upstream: upstream, variant: variant})
  end

  defp prepared_with_reserved_admission(fixture, correlation_id) do
    {owner, payload, request_options} = reserved_admission_input(fixture, correlation_id)

    {:ok, prepared} =
      PreDispatch.prepare(fixture.auth, @endpoint, payload, request_options, fixture.model)

    {owner, Map.put(prepared, :payload, payload)}
  end

  defp reserved_admission_input(fixture, correlation_id) do
    owner = start_owner!()
    result = connect_owner!(owner)
    lifecycle = UpstreamWebsocketSession.connection_lifecycle_snapshot(owner)

    binding = %{
      direct_binding(lifecycle)
      | previous_response_digest: result.ordinary_success_result.response_digest
    }

    now_ms = System.system_time(:millisecond)

    :ok =
      UpstreamWebsocketSession.arm_compact(
        owner,
        binding,
        now_ms + 30_000,
        result.ordinary_success_result
      )

    {:ok, capability} =
      UpstreamWebsocketSession.reserve_compaction(owner, :compact, binding, make_ref(), now_ms)

    payload = payload(fixture.model.exposed_model_id, "runtime boundary")
    request_options = request_options(fixture.auth, correlation_id, payload)

    request_options =
      RequestOptions.put_native_compaction_admission(
        request_options,
        capability,
        {:direct, owner},
        %{lifecycle_id: binding.lifecycle_id, generation: binding.generation}
      )

    {owner, payload, request_options}
  end

  defp execute_session_routable(prepared, fixture, reserve_callback) do
    reserve_and_start_turn = fn _, _, _, _, _, _, _, _ -> reserve_callback.() end

    Service.execute_session_routable_model(
      %{
        auth: fixture.auth,
        endpoint: @endpoint,
        payload: prepared.payload,
        request_options: prepared.request_options,
        model: fixture.model,
        candidates: prepared.candidates,
        route_state: prepared.route_state,
        turn_claim: nil
      },
      reserve_and_start_turn
    )
  end

  defp observe_zero_work(owner, upstream, correlation_id) do
    admission_phase = UpstreamWebsocketSession.compaction_admission_phase(owner)
    owner_fate = if owner_survived?(owner), do: :survived, else: :retired

    observed = %Observed{
      admission_phase: admission_phase,
      upstream_send_count: FakeUpstream.count(upstream),
      accounting_lifecycle: observe_correlation(correlation_id),
      owner_fate: owner_fate
    }

    cleanup_owner(owner)
    observed
  end

  defp owner_survived?(owner) do
    monitor = Process.monitor(owner)

    result =
      case UpstreamWebsocketSession.connection_lifecycle_snapshot(owner) do
        %{generation: generation} when is_integer(generation) -> :survived
        _other -> :retired
      end

    Process.demonitor(monitor, [:flush])
    result == :survived
  end

  defp cleanup_owner(owner) do
    if Process.alive?(owner) do
      monitor = Process.monitor(owner)
      :ok = UpstreamWebsocketSession.close(owner)

      receive do
        {:DOWN, ^monitor, :process, ^owner, _reason} -> :ok
      after
        @detection_timeout_ms -> raise "runtime provider owner cleanup timed out"
      end
    end
  end

  defp start_owner! do
    {:ok, owner} = UpstreamWebsocketSession.start_link([])
    owner
  end

  defp connect_owner!(owner) do
    {:ok, upstream} =
      FakeUpstream.start_link(
        FakeUpstream.websocket_text_frames([
          Jason.encode!(%{
            "type" => "response.completed",
            "response" => %{"status" => "completed", "id" => "resp_runtime_seed"}
          })
        ])
      )

    on_exit(fn -> FakeUpstream.stop(upstream) end)

    {:ok, result} =
      UpstreamWebsocketSession.request(owner, %WebsocketRequest{
        url: FakeUpstream.url(upstream) <> @endpoint,
        headers: [],
        payload: Jason.encode!(%{"model" => "sample-model"}),
        request_id: Ecto.UUID.generate(),
        attempt_id: Ecto.UUID.generate(),
        effective_serving_mode: "full",
        timeouts: %{connect_timeout_ms: 5_000, receive_timeout_ms: 5_000},
        writer: fn _frame -> :ok end,
        message_mapper: & &1
      })

    result
  end

  defp start_activity_registry! do
    name = {:global, {__MODULE__, :activity_registry, make_ref()}}
    start_supervised!({ActivityRegistry, name: name})
    name
  end

  defp start_admission_server! do
    name = {:global, {__MODULE__, :admission, make_ref()}}
    start_supervised!({Admission, name: name})
    name
  end

  defp overload_settings do
    settings = OperationalSettings.current()
    route_class = RouteClass.proxy_websocket()

    %{
      settings
      | bulkheads:
          Map.put(settings.bulkheads, route_class, %{
            max_concurrency: 1,
            queue_limit: 0,
            queue_timeout_ms: 1_000
          })
    }
  end

  defp request_options(auth, correlation_id, payload) when is_map(payload) do
    {:ok, policy} = Access.normalize_api_key_policy(auth.api_key)

    %{request_id: correlation_id, upstream_endpoint: @endpoint, transport: "websocket"}
    |> RequestOptions.build(@endpoint, payload)
    |> RequestOptions.put_routing(api_key_policy: policy)
  end

  defp payload(model, label) do
    %{
      "model" => model,
      "input" => [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [%{"type" => "input_text", "text" => label}]
        }
      ],
      "stream" => true
    }
  end

  defp direct_binding(%{lifecycle_id: lifecycle_id, generation: generation}) do
    %Binding{
      semantic_turn_key: :crypto.strong_rand_bytes(32),
      window_digest: :crypto.strong_rand_bytes(32),
      context_digest: :crypto.strong_rand_bytes(32),
      window_number: 1,
      previous_response_digest: nil,
      serving_mode: :full,
      topology: %Direct{},
      lifecycle_id: lifecycle_id,
      generation: generation
    }
  end

  defp correlation_id(variant) do
    "native-runtime-#{variant}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp pricing_version(context, variant) do
    namespace =
      case Map.get(context, :scenario_namespace) do
        namespace when is_binary(namespace) -> namespace
        _other -> "runtime"
      end

    unique = System.unique_integer([:positive, :monotonic])
    "native-provider-#{namespace}-#{variant}-#{unique}"
  end

  defp bounded_context_metadata(context) do
    context
    |> Map.take([:provider_run_id])
    |> Map.new(fn {key, value} -> {key, bounded_scalar(value)} end)
  end

  defp bounded_scalar(value) when is_atom(value) or is_boolean(value) or is_integer(value),
    do: value

  defp bounded_scalar(value) when is_binary(value), do: String.slice(value, 0, 80)
  defp bounded_scalar(_value), do: :redacted

  defp bounded_error_code(outcome) do
    outcome
    |> Atom.to_string()
    |> String.slice(0, 80)
  end

  defp zero_accounting_lifecycle do
    %AccountingLifecycle{
      requests: 0,
      attempts: 0,
      turns: 0,
      reservations: 0,
      settlements: 0
    }
  end

  defp subtract_accounting(current, baseline) do
    %AccountingLifecycle{
      requests: current.requests - baseline.requests,
      attempts: current.attempts - baseline.attempts,
      turns: current.turns - baseline.turns,
      reservations: current.reservations - baseline.reservations,
      settlements: current.settlements - baseline.settlements
    }
  end

  defp assert_receive_token!(tag, expected_pid) do
    receive do
      {^tag, ^expected_pid, token} when is_reference(token) -> token
    after
      @detection_timeout_ms -> raise "runtime provider pre-cancellation barrier timed out"
    end
  end
end
