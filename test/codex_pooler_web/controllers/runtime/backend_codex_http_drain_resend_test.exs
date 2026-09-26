defmodule CodexPoolerWeb.Runtime.BackendCodexHttpDrainResendTest do
  # The cohort findings#212 actually measures: a native Codex SSE turn still
  # relaying when a rollout drain starts is cut at once, and the client resends
  # the turn on another pod, so the provider is paid twice.
  #
  # The retry body is NOT the request body. The released client records each
  # completed output item into history as it arrives and rebuilds the retry
  # prompt from `clone_history()` with no rollback
  # (`stream_events_utils.rs:300-380`, `session/turn.rs:1578-1583`,
  # `responses_retry.rs`), so a cut that already delivered an item retries with
  # a LONGER body. Every request below uses a grown body for the resend, which
  # is what a payload-scoped claim cannot survive and what the bare turn claim
  # exists for.
  #
  # Nothing here is hand-stamped: the predecessor's `owner_drained` row is
  # written by a real `RolloutDrain.start_drain/1` against a real in-flight
  # stream, exactly as `responses_sse_rollout_drain_test.exs` drives it.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, start_upstream: 1, native_text_input: 1]

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Gateway.Transports.Streaming.DeferredStreamRegistry
  alias CodexPooler.Gateway.Transports.Websocket.{ActivityRegistry, RolloutDrain}
  alias CodexPooler.Gateway.Transports.WebsocketRolloutDrainSupport
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag capture_log: true

  @path "/backend-api/codex/responses"
  @response_id "resp_native_http_drain_resend"
  @turn_id "turn_212_drain_cut"
  @drain_timeout_ms 5_000
  @await_timeout_ms 15_000
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

    previous = Application.get_env(:codex_pooler, DeferredStreamRegistry)
    Application.put_env(:codex_pooler, DeferredStreamRegistry, server_name: stream_registry)

    restore = fn ->
      if previous,
        do: Application.put_env(:codex_pooler, DeferredStreamRegistry, previous),
        else: Application.delete_env(:codex_pooler, DeferredStreamRegistry)
    end

    on_exit(restore)

    {:ok, drain_name: drain_name, stream_registry: stream_registry, leave_drained_pod: restore}
  end

  test "a drain-cut native turn resent with a grown body is refused and dispatches once", %{
    conn: conn,
    drain_name: drain_name,
    stream_registry: stream_registry,
    leave_drained_pod: leave_drained_pod
  } do
    release_ref = make_ref()

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
    session = "codex-session-drain-#{System.unique_integer([:positive])}"
    parent = self()

    request_task =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())
        post_turn(conn, setup, session, turn_body(setup, :initial))
      end)

    assert_receive {:fake_upstream_chunk_barrier, 2, upstream_pid, ^release_ref},
                   @await_timeout_ms

    stream_entry = await_registered_stream(stream_registry)
    :ok = WebsocketRolloutDrainSupport.await_visible_http_turn!(stream_entry, @await_timeout_ms)

    {cut, summary} =
      WebsocketRolloutDrainSupport.drain_http_request(
        request_task,
        [name: drain_name, timeout_ms: @drain_timeout_ms] ++ @drain_options,
        @await_timeout_ms
      )

    assert %{result: :ok, http_streams_seen: 1} = summary
    send(upstream_pid, {:fake_upstream_release_chunk, release_ref})
    assert cut.status == 200
    assert cut.resp_body =~ "visible before the rollout drain"

    # The predecessor is the row's exact shape: cut mid-relay, after output the
    # client has already recorded into its history.
    predecessor = latest_request(setup.pool.id)
    assert predecessor.transport == "http_sse"
    assert predecessor.status == "failed"
    assert predecessor.last_error_code == "owner_drained"
    assert predecessor.response_status_code == 499
    assert %DateTime{} = predecessor.completed_at

    turn = Repo.one!(from t in CodexTurn, where: t.request_id == ^predecessor.id)
    assert %DateTime{} = turn.first_visible_output_at

    dispatched = FakeUpstream.count(upstream)

    # Production semantics: the client reconnects and re-dispatches on ANOTHER
    # pod, which is not draining. Restoring the registry redirect is how a
    # single-node test leaves the drained pod -- without it the resend is
    # refused 503 `owner_drained` by this pod's own admission gate and the fence
    # is never reached, which would prove nothing about duplicate spend.
    leave_drained_pod.()

    # The resend the released client actually sends: same turn, LONGER body.
    resend = post_turn(conn, setup, session, turn_body(setup, :grown))

    assert %{"error" => %{"code" => "duplicate_turn"}} = json_response(resend, 409)
    assert FakeUpstream.count(upstream) == dispatched
    assert [^predecessor] = Repo.all(from r in Request, where: r.pool_id == ^setup.pool.id)

    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^predecessor.id), :count) == 1
  end

  defp post_turn(conn, setup, session, body) do
    conn
    |> Phoenix.ConnTest.recycle()
    |> auth(setup)
    |> put_req_header("session-id", session)
    |> post(@path, body)
  end

  # The real client shape: the canonical turn metadata travels in the request
  # body's `client_metadata` (`codex-rs/core/src/client.rs:893`), not only as a
  # header. The grown body carries the delivered item the client recorded as it
  # arrived, so it is not byte-identical to the request that was cut.
  defp turn_body(setup, shape) do
    %{
      "model" => setup.model.exposed_model_id,
      "input" => input_for(shape),
      "stream" => true,
      "client_metadata" => %{
        "session_id" => "client-metadata-session",
        "x-codex-turn-metadata" => CodexPooler.JSON.encode!(%{"turn_id" => @turn_id, "request_kind" => "turn"})
      }
    }
  end

  defp input_for(:initial), do: native_text_input("drain cut turn")

  defp input_for(:grown) do
    native_text_input("drain cut turn") ++
      [
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => "visible before the rollout drain"}]
        }
      ]
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

  defp await_registered_stream(registry),
    do: await_registered_stream(registry, System.monotonic_time(:millisecond) + @await_timeout_ms)

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

  defp latest_request(pool_id) do
    Repo.one!(
      from request in Request,
        where: request.pool_id == ^pool_id,
        order_by: [desc: request.admitted_at],
        limit: 1
    )
  end
end
