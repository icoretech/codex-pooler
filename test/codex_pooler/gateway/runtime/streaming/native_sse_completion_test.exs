defmodule CodexPooler.Gateway.Runtime.Streaming.NativeSSECompletionTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.SessionContinuity.OwnerWitness
  alias CodexPooler.Gateway.Websocket

  alias CodexPooler.Gateway.Persistence.{
    BridgeDemotion,
    BridgeOwnerLease,
    CodexSession,
    RoutingCircuitState
  }

  alias CodexPooler.Repo

  @endpoint_path "/backend-api/codex/responses"
  @detection_timeout_ms 15_000

  defmodule ClosingAdapter do
    @moduledoc false

    def chunk(%{closed?: true}, _data), do: {:error, :closed}

    def chunk(%{adapter: adapter, payload: payload} = state, data) do
      {:ok, body, payload} = adapter.chunk(payload, data)
      closed? = body == state.close_after
      {:ok, body, %{state | payload: payload, closed?: closed?}}
    end
  end

  setup do
    previous = Application.get_env(:codex_pooler, OperationalSettings)

    Application.put_env(:codex_pooler, OperationalSettings,
      settings: %OperationalSettings{
        bridge_owner_lease_renewal_seconds: 1,
        sse_keepalive_interval_ms: 20
      }
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:codex_pooler, OperationalSettings, previous),
        else: Application.delete_env(:codex_pooler, OperationalSettings)
    end)
  end

  test "native completion remains successful when the client closes before upstream EOF" do
    completed = completed_event()
    {request, attempt, body} = close_after_delivery([completed])

    assert body == completed
    assert request.status == "succeeded"
    assert attempt.status == "succeeded"
    assert request.usage_status == "usage_known"
    assert attempt.usage_status == "usage_known"
    assert is_nil(request.last_error_code)
    assert is_nil(attempt.network_error_code)

    refute inspect({request.request_metadata, attempt.response_metadata}) =~
             "resp_native_complete"
  end

  test "native completion split across chunks keeps its original bytes and successful settlement" do
    completed = completed_event()
    split = div(byte_size(completed), 2)
    <<prefix::binary-size(^split), suffix::binary>> = completed
    {request, attempt, body} = close_after_delivery([prefix, suffix])

    assert body == completed
    assert request.status == "succeeded"
    assert attempt.status == "succeeded"
    assert attempt.usage_status == "usage_known"
  end

  test "client close after a tool item without response completion remains health neutral failure" do
    item =
      event("response.output_item.done", %{
        "type" => "response.output_item.done",
        "item" => %{
          "type" => "function_call",
          "name" => "sample_tool",
          "call_id" => "sample_call"
        }
      })

    {request, attempt, body} = close_after_delivery([item])

    assert body == item
    assert request.status == "failed"
    assert attempt.status == "failed"
    assert request.last_error_code == "client_disconnected"
    assert attempt.network_error_code == "client_disconnected"
    assert Repo.all(BridgeDemotion) == []
    assert Repo.all(RoutingCircuitState) == []
  end

  test "a completion label with failed response status cannot turn a client close into success" do
    malformed =
      event("response.completed", %{
        "type" => "response.completed",
        "response" => %{"status" => "failed"}
      })

    {request, attempt, body} = close_after_delivery([malformed])

    assert body == malformed
    assert request.status == "failed"
    assert attempt.network_error_code == "client_disconnected"
  end

  test "client close while writing completion is not treated as a delivered completion" do
    {request, attempt, body} = close_after_delivery([completed_event()], closed?: true)

    assert body == ""
    assert request.status == "failed"
    assert attempt.network_error_code == "client_disconnected"
    assert Repo.all(BridgeDemotion) == []
    assert Repo.all(RoutingCircuitState) == []
  end

  test "sessioned HTTP streaming keeps the owner lease live until deferred completion" do
    Application.put_env(:codex_pooler, OperationalSettings,
      settings: %{OperationalSettings.current() | sse_keepalive_interval_ms: 60_000}
    )

    release_ref = make_ref()
    created = created_event()
    completed = completed_event()

    upstream =
      start_upstream(
        FakeUpstream.barrier_sse_stream([created, completed],
          barrier_after: 1,
          notify: self(),
          release_ref: release_ref
        )
      )

    fixture = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(fixture.authorization)

    payload = %{
      "model" => fixture.model.exposed_model_id,
      "input" => native_text_input("sessioned HTTP owner heartbeat"),
      "stream" => true
    }

    parent = self()

    task =
      Task.async(fn ->
        request_options =
          RequestOptions.build(
            %{
              accepted_turn_state: "native-sse-owner-#{System.unique_integer([:positive])}",
              bridge_owner_lease_ttl_seconds: 3
            },
            @endpoint_path,
            payload
          )

        assert {:ok, %{stream: stream}} =
                 Gateway.execute(auth, @endpoint_path, payload, request_options)

        send(parent, {:native_sse_stream_ready, self()})

        receive do
          :consume_native_sse_stream -> :ok
        end

        conn = build_conn() |> put_resp_content_type("text/event-stream") |> send_chunked(200)
        stream.(conn)
      end)

    assert_receive {:native_sse_stream_ready, task_pid}, @detection_timeout_ms
    assert task.pid == task_pid

    session = Repo.one!(from(session in CodexSession, where: session.pool_id == ^fixture.pool.id))
    lease = active_lease!(session.id)
    assert session.owner_lease_expires_at == lease.expires_at

    send(task.pid, :consume_native_sse_stream)

    assert_receive {:fake_upstream_chunk_barrier, 1, upstream_pid, ^release_ref},
                   @detection_timeout_ms

    assert_owner_deadline_advances!(session.id, session.owner_lease_expires_at)

    send(upstream_pid, {:fake_upstream_release_chunk, release_ref})
    assert {:ok, conn} = Task.await(task, @detection_timeout_ms)
    assert conn.resp_body == created <> completed <> "data: [DONE]\n\n"

    stopped_session = Repo.get!(CodexSession, session.id)
    stopped_lease = active_lease!(session.id)
    assert stopped_session.owner_lease_expires_at == stopped_lease.expires_at
    assert_owner_heartbeat_stops!(session.id, stopped_session.owner_lease_expires_at)
  end

  test "returned but uninvoked sessioned HTTP stream stops its service heartbeat at handoff ttl" do
    upstream = start_upstream(FakeUpstream.sse_stream([]))
    fixture = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(fixture.authorization)

    payload = %{
      "model" => fixture.model.exposed_model_id,
      "input" => native_text_input("uninvoked HTTP stream heartbeat handoff"),
      "stream" => true
    }

    request_options =
      RequestOptions.build(
        %{
          accepted_turn_state: "native-sse-uninvoked-#{System.unique_integer([:positive])}",
          bridge_owner_lease_ttl_seconds: 1,
          session_lease_heartbeat_test_observer: self()
        },
        @endpoint_path,
        payload
      )

    assert {:ok, %{stream: stream}} =
             Gateway.execute(auth, @endpoint_path, payload, request_options)

    assert is_function(stream, 1)
    assert_receive {:session_lease_heartbeat, :started, heartbeat}, @detection_timeout_ms
    monitor = Process.monitor(heartbeat)

    assert_receive {:session_lease_heartbeat, :stopped, ^heartbeat}, @detection_timeout_ms
    assert_receive {:DOWN, ^monitor, :process, ^heartbeat, :normal}, @detection_timeout_ms
  end

  test "a first-event HTTP retry reuses one service heartbeat through terminal completion" do
    first_upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"response.failed",
             %{"type" => "response.failed", "error" => %{"code" => "server_error"}}}
          ],
          done: false
        )
      )

    second_upstream = start_upstream(stream_success_sse())
    fixture = gateway_setup(first_upstream)

    second =
      gateway_upstream(fixture.pool, second_upstream, "retry-heartbeat-upstream", compact?: false)

    prime_routing_quota!(second.identity)

    fixture = %{
      fixture
      | model:
          put_model_source_assignments!(fixture.model, [fixture.assignment, second.assignment])
    }

    {:ok, auth} = Access.authenticate_authorization_header(fixture.authorization)

    assert {:ok, session} =
             Websocket.start_codex_session(auth,
               accepted_turn_state:
                 "native-sse-retry-owner-#{System.unique_integer([:positive])}",
               owner_instance_id: "native-sse-retry-owner"
             )

    session =
      session
      |> Ecto.Changeset.change(pool_upstream_assignment_id: fixture.assignment.id)
      |> Repo.update!()

    {:ok, witness} = OwnerWitness.new(session)

    payload = %{
      "model" => fixture.model.exposed_model_id,
      "input" => native_text_input("first-event retry owns one heartbeat"),
      "stream" => true
    }

    request_options =
      RequestOptions.build(
        %{
          codex_session: session,
          session_lease_heartbeat_test_observer: self()
        },
        @endpoint_path,
        payload
      )
      |> RequestOptions.put_session_owner_witness(witness)

    assert {:ok, %{stream: stream}} =
             Gateway.execute(auth, @endpoint_path, payload, request_options)

    assert_receive {:session_lease_heartbeat, :started, heartbeat}, @detection_timeout_ms

    conn = build_conn() |> put_resp_content_type("text/event-stream") |> send_chunked(200)
    assert {:ok, _conn} = stream.(conn)

    assert_receive {:session_lease_heartbeat, :stopped, ^heartbeat}, @detection_timeout_ms
    refute_received {:session_lease_heartbeat, :started, _other_heartbeat}
    assert_stream_retry_success!(fixture, "server_error")
    assert FakeUpstream.count(first_upstream) == 1
    assert FakeUpstream.count(second_upstream) == 1
  end

  defp close_after_delivery(chunks, opts \\ []) do
    release_ref = make_ref()

    upstream =
      start_upstream(
        FakeUpstream.barrier_sse_stream(chunks,
          done: false,
          barrier_after: length(chunks),
          notify: self(),
          release_ref: release_ref
        )
      )

    fixture = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(fixture.authorization)

    payload = %{
      "model" => fixture.model.exposed_model_id,
      "input" => native_text_input("synthetic native stream"),
      "stream" => true
    }

    task =
      Task.async(fn ->
        request_options = RequestOptions.build(%{}, @endpoint_path, payload)

        {:ok, %{stream: stream}} =
          Gateway.execute(auth, @endpoint_path, payload, request_options)

        conn = build_conn() |> put_resp_content_type("text/event-stream") |> send_chunked(200)
        {adapter, adapter_payload} = conn.adapter

        adapter_state = %{
          adapter: adapter,
          payload: adapter_payload,
          close_after: IO.iodata_to_binary(chunks),
          closed?: Keyword.get(opts, :closed?, false)
        }

        stream.(%{conn | adapter: {ClosingAdapter, adapter_state}})
      end)

    assert_receive {:fake_upstream_chunk_barrier, _index, upstream_pid, ^release_ref},
                   @detection_timeout_ms

    try do
      assert {:ok, conn} = Task.await(task, @detection_timeout_ms)
      assert FakeUpstream.count(upstream) == 1
      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^fixture.pool.id))
      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
      {request, attempt, conn.resp_body}
    after
      send(upstream_pid, {:fake_upstream_release_chunk, release_ref})
    end
  end

  defp completed_event do
    event("response.completed", %{
      "type" => "response.completed",
      "response" => %{
        "id" => "resp_native_complete",
        "status" => "completed",
        "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
      }
    })
  end

  defp created_event do
    event("response.created", %{
      "type" => "response.created",
      "response" => %{"id" => "resp_native_created", "status" => "in_progress"}
    })
  end

  defp active_lease!(session_id) do
    Repo.one!(
      from lease in BridgeOwnerLease,
        where: lease.codex_session_id == ^session_id and lease.status == "active",
        limit: 1
    )
  end

  defp assert_owner_deadline_advances!(session_id, initial_expiry, attempts \\ 30)

  defp assert_owner_deadline_advances!(_session_id, _initial_expiry, 0),
    do: flunk("owner deadline did not advance while the deferred stream was live")

  defp assert_owner_deadline_advances!(session_id, initial_expiry, attempts) do
    session = Repo.get!(CodexSession, session_id)

    if DateTime.compare(session.owner_lease_expires_at, initial_expiry) == :gt do
      lease = active_lease!(session_id)
      assert session.owner_lease_expires_at == lease.expires_at
    else
      Process.send_after(self(), :observe_owner_deadline, 100)
      assert_receive :observe_owner_deadline, @detection_timeout_ms
      assert_owner_deadline_advances!(session_id, initial_expiry, attempts - 1)
    end
  end

  defp assert_owner_heartbeat_stops!(session_id, stopped_expiry) do
    Process.send_after(self(), :observe_stopped_owner_heartbeat, 1_200)
    assert_receive :observe_stopped_owner_heartbeat, @detection_timeout_ms

    session = Repo.get!(CodexSession, session_id)
    lease = active_lease!(session_id)

    assert session.owner_lease_expires_at == stopped_expiry
    assert lease.expires_at == stopped_expiry
  end

  defp event(type, payload), do: "event: #{type}\ndata: #{CodexPooler.JSON.encode!(payload)}\n\n"
end
