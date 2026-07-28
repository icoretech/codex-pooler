defmodule CodexPoolerWeb.V1.ResponsesWebsocketBridgeTerminalTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  alias Ecto.Adapters.SQL.Sandbox

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Gateway.Transports.Websocket.RolloutDrain
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Transports.WebsocketRolloutDrainSupport
  alias CodexPooler.Repo

  @terminal_cases [
    {"response.completed",
     %{
       "type" => "response.completed",
       "response" => %{"id" => "resp_terminal_completed", "status" => "completed"}
     }, "response.completed"},
    {"response.done",
     %{
       "type" => "response.done",
       "response" => %{"id" => "resp_terminal_done", "status" => "completed"}
     }, "response.completed"},
    {"response.failed",
     %{
       "type" => "response.failed",
       "headers" => %{
         "authorization" => "Bearer bridge-provider-secret-sentinel",
         "x-provider-debug" => "bridge-provider-header-sentinel"
       },
       "response" => %{
         "id" => "resp_terminal_failed",
         "status" => "failed",
         "error" => %{
           "type" => "bridge_provider_type_must_not_become_public_code",
           "message" => "synthetic terminal failure"
         }
       }
     }, "response.failed"},
    {"response.incomplete",
     %{
       "type" => "response.incomplete",
       "response" => %{
         "id" => "resp_terminal_incomplete",
         "status" => "incomplete",
         "incomplete_details" => %{"reason" => "context_length_exceeded"}
       }
     }, "response.failed"},
    {"error",
     %{
       "type" => "error",
       "status" => 500,
       "error" => %{"code" => "server_error", "message" => "synthetic terminal error"}
     }, "response.failed"}
  ]

  setup do
    previous = Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    on_exit(fn ->
      capture_log(fn ->
        WebsocketOwnerSession.Registry
        |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
        |> Enum.each(fn session_id ->
          with {:ok, owner_pid} <- WebsocketOwnerSession.lookup(session_id) do
            GenServer.stop(owner_pid, :shutdown, 1_000)
          end
        end)
      end)

      case previous do
        nil -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
        value -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
      end
    end)

    :ok
  end

  test "bridge commitment with zero visible output emits one hybrid error without HTTP replay",
       %{conn: conn} do
    release_ref = make_ref()

    replay_event =
      {"response.completed",
       %{
         "type" => "response.completed",
         "response" => %{"id" => "unexpected_http_replay", "status" => "completed"}
       }}

    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.websocket_terminal_then_close_barrier(
             %{
               "type" => "response.completed",
               "response" => %{
                 "id" => "resp_dropped_before_bridge_close",
                 "status" => "in_progress"
               }
             },
             notify: self(),
             release_ref: release_ref
           ),
           FakeUpstream.sse_stream([replay_event])
         ]}
      )

    setup = gateway_setup(upstream)
    session_id = "zero-visible-bridge-#{System.unique_integer([:positive])}"
    parent = self()

    request_task =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())

        conn
        |> auth(setup)
        |> put_req_header("x-session-id", session_id)
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => "synthetic zero-visible bridge turn",
          "stream" => true
        })
      end)

    assert_receive {:fake_upstream_websocket_barrier, :before_terminal, barrier_pid,
                    ^release_ref},
                   1_000

    send(barrier_pid, {:fake_upstream_release_websocket, release_ref})

    assert_receive {:fake_upstream_websocket_barrier, :before_close, close_barrier_pid,
                    ^release_ref},
                   1_000

    send(close_barrier_pid, {:fake_upstream_release_websocket, release_ref})
    response = Task.await(request_task, 1_000)

    assert [content_type] = get_resp_header(response, "content-type")
    assert content_type =~ "text/event-stream"
    assert response.status == 200
    assert stream_event_types(response.resp_body) == ["error"]
    refute response.resp_body =~ "data: [DONE]"

    assert [%{"event" => "error", "data" => error_data}] =
             public_sse_events(response.resp_body)

    assert MapSet.new(Map.keys(error_data)) ==
             MapSet.new(["code", "error", "message", "param", "sequence_number", "type"])

    assert %{
             "code" => "server_error",
             "error" => nested_error,
             "message" =>
               "upstream request failed: stream interrupted before terminal response event",
             "param" => nil,
             "sequence_number" => sequence_number,
             "type" => "error"
           } = error_data

    assert is_integer(sequence_number)
    assert sequence_number >= 0
    refute Map.has_key?(error_data, "response")

    assert nested_error == %{
             "code" => "server_error",
             "message" =>
               "upstream request failed: stream interrupted before terminal response event",
             "param" => nil,
             "type" => "server_error"
           }

    refute response.resp_body =~ "resp_dropped_before_bridge_close"
    refute response.resp_body =~ "unexpected_http_replay"

    assert [upstream_request] = FakeUpstream.requests(upstream)
    assert upstream_request.method == "WEBSOCKET"
    assert FakeUpstream.http_request_count(upstream) == 0

    request = latest_request(setup.pool.id)
    assert request.status == "failed"
    assert request.transport == "http_sse"
    assert request.last_error_code == "upstream_stream_error"

    assert [attempt] = Repo.all(from attempt in Attempt, where: attempt.request_id == ^request.id)
    assert attempt.status == "failed"
    assert attempt.transport == "websocket"
    assert attempt.network_error_code == "upstream_stream_error"
    assert attempt.response_metadata["bridge_committed"] == true
    assert attempt.response_metadata["upstream_transport"] == "websocket"

    assert %{
             "visible_seen" => false,
             "synthetic_terminal_sent" => true
           } = attempt.response_metadata["public_openai_responses_stream"]

    assert settlement_count(request.id) == 1
  end

  for {terminal_type, terminal, public_type} <- @terminal_cases do
    @terminal_type terminal_type
    @terminal terminal
    @public_type public_type

    test "#{terminal_type} survives an immediate websocket peer close exactly once", %{conn: conn} do
      release_ref = make_ref()

      upstream =
        start_upstream(
          {:sequence,
           [
             FakeUpstream.websocket_terminal_then_close_barrier(@terminal,
               notify: self(),
               release_ref: release_ref
             ),
             FakeUpstream.sse_stream([
               {"response.completed",
                %{
                  "type" => "response.completed",
                  "response" => %{"id" => "unexpected_http_replay", "status" => "completed"}
                }}
             ])
           ]}
        )

      setup = gateway_setup(upstream)
      session_id = "terminal-close-#{@terminal_type}-#{System.unique_integer([:positive])}"
      parent = self()

      request_task =
        Task.async(fn ->
          Sandbox.allow(Repo, parent, self())

          conn
          |> auth(setup)
          |> put_req_header("x-session-id", session_id)
          |> post("/v1/responses", %{
            "model" => setup.model.exposed_model_id,
            "input" => "synthetic terminal close turn",
            "stream" => true
          })
        end)

      assert_receive {:fake_upstream_websocket_barrier, :before_terminal, barrier_pid,
                      ^release_ref},
                     1_000

      owner = sole_owner_pid!()
      active_turn = :sys.get_state(owner).active_turn
      task_monitor = Process.monitor(active_turn.task_pid)

      assert :erlang.suspend_process(owner)

      on_exit(fn ->
        if Process.info(owner, :status) == {:status, :suspended} do
          _result = :erlang.resume_process(owner)
        end
      end)

      send(barrier_pid, {:fake_upstream_release_websocket, release_ref})

      assert_receive {:fake_upstream_websocket_barrier, :before_close, close_barrier_pid,
                      ^release_ref},
                     1_000

      assert_receive {:DOWN, ^task_monitor, :process, _task_pid, :normal}, 1_000
      assert Process.info(owner, :status) == {:status, :suspended}
      close_monitor = Process.monitor(close_barrier_pid)
      send(close_barrier_pid, {:fake_upstream_release_websocket, release_ref})

      assert_receive {:DOWN, ^close_monitor, :process, ^close_barrier_pid, _reason}, 1_000
      assert Process.info(request_task.pid, :status) != nil
      assert Process.info(owner, :status) == {:status, :suspended}
      assert :erlang.resume_process(owner)

      response = Task.await(request_task, 1_000)

      assert response.status == 200
      assert Enum.count(stream_event_types(response.resp_body), &(&1 == @public_type)) == 1
      refute response.resp_body =~ "unexpected_http_replay"

      if @terminal_type == "response.failed" do
        failed =
          response.resp_body
          |> public_sse_events()
          |> Enum.find_value(fn
            %{"event" => "response.failed", "data" => data} -> data
            _event -> nil
          end)

        assert failed["response"]["error"]["code"] == "upstream_error"
        refute Map.has_key?(failed, "headers")
        refute response.resp_body =~ "bridge_provider_type_must_not_become_public_code"
        refute response.resp_body =~ "bridge-provider-secret-sentinel"
        refute response.resp_body =~ "bridge-provider-header-sentinel"
        refute response.resp_body =~ "synthetic terminal failure"
      end

      assert [upstream_request] = FakeUpstream.requests(upstream)
      assert upstream_request.method == "WEBSOCKET"
      assert FakeUpstream.http_request_count(upstream) == 0

      request = latest_request(setup.pool.id)
      assert request.status == terminal_request_status(@terminal_type)

      assert Repo.aggregate(
               from(attempt in Attempt, where: attempt.request_id == ^request.id),
               :count
             ) == 1

      assert settlement_count(request.id) == 1
    end
  end

  # Deliberately reversed by the bridged-pre-content-retry work: a peer close
  # without a terminal and without content is retried over plain HTTP on the
  # same attempt with a single settlement.
  test "websocket close without a terminal falls back to plain HTTP exactly once",
       %{conn: conn} do
    release_ref = make_ref()

    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.websocket_close_without_terminal_barrier(
             notify: self(),
             release_ref: release_ref
           ),
           FakeUpstream.sse_stream([
             {"response.completed",
              %{
                "type" => "response.completed",
                "response" => %{"id" => "resp_close_fallback", "status" => "completed"}
              }}
           ])
         ]}
      )

    setup = gateway_setup(upstream)
    session_id = "missing-terminal-close-#{System.unique_integer([:positive])}"
    parent = self()

    request_task =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())

        conn
        |> auth(setup)
        |> put_req_header("x-session-id", session_id)
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => "synthetic missing terminal turn",
          "stream" => true
        })
      end)

    assert_receive {:fake_upstream_websocket_barrier, :before_close, barrier_pid, ^release_ref},
                   1_000

    send(barrier_pid, {:fake_upstream_release_websocket, release_ref})
    response = Task.await(request_task, 1_000)

    assert response.status == 200
    assert stream_event_types(response.resp_body) == ["response.created", "response.completed"]
    assert response.resp_body =~ "resp_close_fallback"
    refute response.resp_body =~ "upstream_stream_error"

    assert [upstream_request | _rest] = FakeUpstream.requests(upstream)
    assert upstream_request.method == "WEBSOCKET"
    assert FakeUpstream.http_request_count(upstream) == 1

    request = latest_request(setup.pool.id)
    assert request.status == "succeeded"

    assert Repo.aggregate(
             from(attempt in Attempt, where: attempt.request_id == ^request.id),
             :count
           ) == 1

    assert settlement_count(request.id) == 1
  end

  @tag :owner_drained_terminal_state
  test "post-budget bridge drain emits one owner_drained terminal without replay", %{conn: conn} do
    release_ref = make_ref()

    upstream =
      start_upstream(
        {:sequence,
         [
           FakeUpstream.delayed_terminal_sse_stream(
             [
               {"response.created",
                %{
                  "type" => "response.created",
                  "response" => %{
                    "id" => "resp_terminal_owner_drained",
                    "status" => "in_progress"
                  }
                }},
               {"response.output_text.delta",
                %{
                  "type" => "response.output_text.delta",
                  "response_id" => "resp_terminal_owner_drained",
                  "output_index" => 0,
                  "content_index" => 0,
                  "delta" => "visible before terminal drain"
                }}
             ],
             {"response.completed",
              %{
                "type" => "response.completed",
                "response" => %{
                  "id" => "resp_terminal_owner_drained",
                  "status" => "completed"
                }
              }},
             notify: self(),
             release_ref: release_ref
           ),
           FakeUpstream.sse_stream([
             {"response.completed",
              %{
                "type" => "response.completed",
                "response" => %{"id" => "unexpected_http_replay", "status" => "completed"}
              }}
           ])
         ]}
      )

    setup = gateway_setup(upstream)
    parent = self()

    request_task =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())

        conn
        |> auth(setup)
        |> put_req_header(
          "x-session-id",
          "terminal-owner-drained-#{System.unique_integer([:positive])}"
        )
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => "synthetic terminal owner drain",
          "stream" => true
        })
      end)

    assert_receive {:fake_upstream_timeout_barrier, :before_terminal, upstream_pid, ^release_ref},
                   1_000

    assert %CodexTurn{first_visible_output_at: %DateTime{}} =
             turn = await_committed_turn(setup.pool.id)

    harness = start_rollout_drain_harness()

    drain_task =
      Task.async(fn ->
        RolloutDrain.start_drain(
          [name: harness.name, timeout_ms: 25, deadline_margin_ms: 20, deadline_floor_ms: 10] ++
            WebsocketRolloutDrainSupport.deadline_options(harness.deadline)
        )
      end)

    assert_receive {:rollout_drain_deadline_wait, deadline, 10}
    assert deadline == harness.deadline
    assert :ok = WebsocketRolloutDrainSupport.VirtualDeadline.advance(deadline, 10)

    response = Task.await(request_task, 2_000)
    send(upstream_pid, {:fake_upstream_release_timeout, release_ref})
    assert %{turns_completed: 0, turns_aborted: 1} = Task.await(drain_task, 2_000)

    assert response.status == 200

    assert stream_event_types(response.resp_body) == [
             "response.created",
             "response.output_text.delta",
             "error"
           ]

    assert response.resp_body =~ "visible before terminal drain"
    refute response.resp_body =~ "unexpected_http_replay"

    data = response_failed_data(response.resp_body)

    assert Map.keys(data) |> Enum.sort() ==
             ~w(code error message param sequence_number type)

    assert Map.keys(data["error"]) |> Enum.sort() == ~w(code message param type)

    assert %{
             "type" => "error",
             "code" => "server_error",
             "message" => message,
             "param" => nil,
             "sequence_number" => sequence_number,
             "error" => %{
               "type" => "server_error",
               "code" => "server_error",
               "message" => message,
               "param" => nil
             }
           } = data

    assert is_integer(sequence_number)

    assert message ==
             "upstream request failed: stream interrupted before terminal response event"

    assert [upstream_request] = FakeUpstream.requests(upstream)
    assert upstream_request.method == "WEBSOCKET"
    assert FakeUpstream.http_request_count(upstream) == 0

    request = latest_request(setup.pool.id)
    assert request.status == "failed"
    assert request.response_status_code == 499
    assert request.last_error_code == "owner_drained"

    assert [attempt] = Repo.all(from attempt in Attempt, where: attempt.request_id == ^request.id)
    assert attempt.status == "failed"
    assert attempt.transport == "websocket"
    assert attempt.network_error_code == "owner_drained"

    assert %CodexTurn{
             status: "interrupted",
             error_code: "owner_drained",
             first_visible_output_at: %DateTime{}
           } = Repo.reload!(turn)

    assert settlement_count(request.id) == 1
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

  defp public_sse_events(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn block ->
      with [event] <- Regex.run(~r/^event: (.+)$/m, block, capture: :all_but_first),
           [data] <- Regex.run(~r/^data: (.+)$/m, block, capture: :all_but_first) do
        [%{"event" => event, "data" => Jason.decode!(data)}]
      else
        _missing -> []
      end
    end)
  end

  defp response_failed_data(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.find_value(fn block ->
      with ["error"] <- Regex.run(~r/^event: (.+)$/m, block, capture: :all_but_first),
           [data] <- Regex.run(~r/^data: (.+)$/m, block, capture: :all_but_first) do
        Jason.decode!(data)
      else
        _missing -> nil
      end
    end)
  end

  defp await_committed_turn(pool_id, attempts_left \\ 1_000)

  defp await_committed_turn(_pool_id, 0), do: flunk("expected committed public bridge turn")

  defp await_committed_turn(pool_id, attempts_left) do
    turn =
      Repo.one(
        from turn in CodexTurn,
          join: request in Request,
          on: request.id == turn.request_id,
          where: request.pool_id == ^pool_id,
          order_by: [desc: turn.started_at],
          limit: 1
      )

    case turn do
      %CodexTurn{first_visible_output_at: %DateTime{}} ->
        turn

      _pending ->
        receive do
        after
          1 -> await_committed_turn(pool_id, attempts_left - 1)
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

  defp settlement_count(request_id) do
    Repo.aggregate(
      from(entry in CodexPooler.Accounting.LedgerEntry,
        where: entry.request_id == ^request_id and entry.entry_kind == "settlement"
      ),
      :count
    )
  end

  defp terminal_request_status(type) when type in ["response.completed", "response.done"],
    do: "succeeded"

  defp terminal_request_status(_type), do: "failed"

  defp sole_owner_pid! do
    assert [owner_pid] =
             Registry.select(WebsocketOwnerSession.Registry, [
               {{:"$1", :"$2", :_}, [], [:"$2"]}
             ])

    owner_pid
  end
end
