defmodule CodexPoolerWeb.V1.ResponsesSseRolloutDrainTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Gateway.Transports.Streaming.DeferredStreamRegistry
  alias CodexPooler.Gateway.Transports.Websocket.{ActivityRegistry, RolloutDrain}
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  @public_path "/v1/responses"
  @response_id "resp_v1_rollout_drain"

  # The drain polls settled streams every 200 ms, so the drained stream settles
  # far inside this budget; the waits below are failure detection, not timers
  # the behavior depends on.
  @drain_timeout_ms 5_000
  @await_timeout_ms 15_000
  # `RolloutDrain`'s default deadline margin reserves a full owner call budget
  # (tens of seconds) before the poll deadline, which production's 85 s budget
  # absorbs but a test-sized budget does not: left at the default, the whole
  # wait collapses to the deadline floor. Reserve a small margin instead so the
  # drain actually waits for the stream it just signalled.
  @drain_options [deadline_margin_ms: 100, deadline_floor_ms: 50]

  setup do
    stream_registry = :"deferred-stream-registry-#{System.unique_integer([:positive])}"
    activity_registry = :"rollout-drain-activity-#{System.unique_integer([:positive])}"
    drain_name = :"rollout-drain-#{System.unique_integer([:positive])}"

    start_supervised!({DeferredStreamRegistry, name: stream_registry})
    start_supervised!({ActivityRegistry, name: activity_registry})

    start_supervised!(
      Supervisor.child_spec(
        {RolloutDrain,
         [
           name: drain_name,
           activity_registry: activity_registry,
           stream_registry: stream_registry
         ]},
        id: {RolloutDrain, drain_name}
      )
    )

    # Deferred streams register through the configured server name, so this
    # test's streams land in its own registry instead of the global one.
    previous_registry_config = Application.get_env(:codex_pooler, DeferredStreamRegistry)
    Application.put_env(:codex_pooler, DeferredStreamRegistry, server_name: stream_registry)

    on_exit(fn ->
      if previous_registry_config do
        Application.put_env(:codex_pooler, DeferredStreamRegistry, previous_registry_config)
      else
        Application.delete_env(:codex_pooler, DeferredStreamRegistry)
      end
    end)

    {:ok, drain_name: drain_name, stream_registry: stream_registry}
  end

  test "a rollout drain settles an in-flight deferred SSE stream and releases its reservation",
       %{conn: conn, drain_name: drain_name, stream_registry: stream_registry} do
    release_ref = make_ref()

    # provenance: observed findings issue 129 (native Responses SSE
    # created/delta prefix held open across a rollout; payload values invented)
    upstream =
      start_upstream(
        FakeUpstream.barrier_sse_stream([created_event(), delta_event()],
          barrier_after: 2,
          notify: self(),
          release_ref: release_ref,
          done: false
        )
      )

    setup = gateway_setup(upstream)
    parent = self()
    session_key = "v1-rollout-drain-session-#{System.unique_integer([:positive])}"

    # A sessioned turn is the case the drain has to settle correctly: the
    # request carries a CodexSession and CodexTurn, so the drain must leave the
    # turn interrupted rather than failed.
    request_task =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())

        conn
        |> auth(setup)
        |> put_req_header("x-session-id", session_key)
        |> post(@public_path, stream_payload(setup))
      end)

    assert_receive {:fake_upstream_chunk_barrier, 2, upstream_pid, ^release_ref},
                   @await_timeout_ms

    stream_entry = await_registered_stream(stream_registry)

    assert %{
             result: :ok,
             http_streams_seen: 1,
             http_streams_completed: 1,
             http_streams_aborted: 0,
             http_streams_failed: 0
           } = RolloutDrain.start_drain(drain_options(drain_name))

    response = Task.await(request_task, @await_timeout_ms)
    send(upstream_pid, {:fake_upstream_release_chunk, release_ref})

    assert response.status == 200

    # The client keeps the ordinary interrupted-stream contract: the events it
    # already received, then the same sanitized synthetic terminal an ordinary
    # interruption emits.
    assert stream_event_types(response.resp_body) == [
             "response.created",
             "response.output_text.delta",
             "error"
           ]

    request = latest_request(setup.pool.id)
    assert request.status == "failed"
    assert request.transport == "http_sse"
    assert request.response_status_code == 499
    assert request.last_error_code == "owner_drained"
    assert %DateTime{} = request.completed_at

    assert [attempt] = Repo.all(from attempt in Attempt, where: attempt.request_id == ^request.id)
    assert attempt.status == "failed"
    assert attempt.network_error_code == "owner_drained"
    assert %DateTime{} = attempt.completed_at

    # The registry carried the identifiers the drain needs to reason about the
    # stream it signalled.
    assert stream_entry.request_id == request.id
    assert stream_entry.attempt_id == attempt.id

    # A drained turn is interrupted, not failed: the upstream did nothing wrong.
    # Until now this half of the drain contract was asserted only on the
    # bridge/owner path.
    assert %CodexTurn{
             status: "interrupted",
             error_code: "owner_drained",
             final_attempt_id: final_attempt_id,
             completed_at: %DateTime{}
           } = Repo.get_by!(CodexTurn, request_id: request.id)

    assert final_attempt_id == attempt.id

    assert ledger_count(request.id, "reservation") == 1
    assert ledger_count(request.id, "release") == 1
    assert ledger_count(request.id, "settlement") == 1
    assert open_request_count(setup.pool.id) == 0
    assert open_attempt_count(setup.pool.id) == 0

    refute response.resp_body =~ "owner_drained"
  end

  test "a stream that already completed is not finalized again by a later drain", %{
    conn: conn,
    drain_name: drain_name
  } do
    upstream =
      start_upstream(
        # provenance: observed findings issue 129 (ordinary completed public
        # Responses SSE turn; payload values invented)
        FakeUpstream.sse_stream([created_event(), delta_event(), completed_event()])
      )

    setup = gateway_setup(upstream)

    response = conn |> auth(setup) |> post(@public_path, stream_payload(setup))

    assert response.status == 200
    assert response.resp_body =~ "event: response.completed\n"

    request = latest_request(setup.pool.id)
    assert request.status == "succeeded"

    assert %{result: :ok, http_streams_seen: 0} =
             RolloutDrain.start_drain(drain_options(drain_name))

    assert Repo.reload!(request).status == "succeeded"
    assert ledger_count(request.id, "settlement") == 1
    assert open_request_count(setup.pool.id) == 0
  end

  defp drain_options(drain_name) do
    [name: drain_name, timeout_ms: @drain_timeout_ms] ++ @drain_options
  end

  defp stream_payload(setup) do
    %{
      "model" => setup.model.exposed_model_id,
      "input" => "synthetic rollout drain stream request",
      "stream" => true
    }
  end

  defp created_event do
    {"response.created",
     %{
       "type" => "response.created",
       "response" => %{"id" => @response_id, "status" => "in_progress"}
     }}
  end

  defp delta_event do
    {"response.output_text.delta",
     %{
       "type" => "response.output_text.delta",
       "response_id" => @response_id,
       "output_index" => 0,
       "content_index" => 0,
       "delta" => "visible before the rollout drain"
     }}
  end

  defp completed_event do
    {"response.completed",
     %{
       "type" => "response.completed",
       "response" => %{
         "id" => @response_id,
         "status" => "completed",
         "usage" => %{"input_tokens" => 2, "output_tokens" => 3, "total_tokens" => 5}
       }
     }}
  end

  defp await_registered_stream(registry) do
    await_registered_stream(registry, System.monotonic_time(:millisecond) + @await_timeout_ms)
  end

  # Registration happens inside the connection process as the deferred closure
  # starts, and no message announces it, so this reads the registry against a
  # wall-clock budget. Spinning the reads instead would exhaust a fixed attempt
  # count in milliseconds and fail on scheduling order rather than behavior.
  defp await_registered_stream(registry, deadline_ms) do
    case DeferredStreamRegistry.streams(name: registry) do
      [%{} = entry] ->
        entry

      [] ->
        if System.monotonic_time(:millisecond) >= deadline_ms do
          flunk("deferred stream never registered")
        else
          receive do
          after
            5 -> :ok
          end

          await_registered_stream(registry, deadline_ms)
        end
    end
  end

  defp stream_event_types(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn block ->
      case Regex.run(~r/^event: (.+)$/m, block, capture: :all_but_first) do
        [event] -> [event]
        _missing -> []
      end
    end)
  end

  defp latest_request(pool_id) do
    Repo.one!(
      from request in Request,
        where: request.pool_id == ^pool_id,
        order_by: [desc: request.admitted_at],
        limit: 1
    )
  end

  defp ledger_count(request_id, entry_kind) do
    Repo.aggregate(
      from(entry in LedgerEntry,
        where: entry.request_id == ^request_id and entry.entry_kind == ^entry_kind
      ),
      :count
    )
  end

  defp open_request_count(pool_id) do
    Repo.aggregate(
      from(request in Request,
        where: request.pool_id == ^pool_id and request.status in ["accepted", "in_progress"]
      ),
      :count
    )
  end

  defp open_attempt_count(pool_id) do
    Repo.aggregate(
      from(attempt in Attempt,
        join: request in Request,
        on: request.id == attempt.request_id,
        where: request.pool_id == ^pool_id and attempt.status in ["queued", "in_progress"]
      ),
      :count
    )
  end
end
