defmodule CodexPoolerWeb.V1.ResponsesWebsocketBridgeTerminalTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  alias Ecto.Adapters.SQL.Sandbox

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
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
       "response" => %{"id" => "resp_terminal_failed", "status" => "failed"},
       "error" => %{"code" => "server_error", "message" => "synthetic terminal failure"}
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

  test "hidden websocket bridge commitment emits one public synthetic failure and never replays HTTP",
       %{conn: conn} do
    set_upstream_receive_timeout!(1_000)

    hidden_event =
      Jason.encode!(%{"type" => "codex.future_event", "detail" => %{"count" => 1}})

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
           FakeUpstream.websocket_text_frames([hidden_event]),
           FakeUpstream.sse_stream([replay_event])
         ]}
      )

    setup = gateway_setup(upstream)
    session_id = "hidden-bridge-#{System.unique_integer([:positive])}"

    response =
      conn
      |> auth(setup)
      |> put_req_header("x-session-id", session_id)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic hidden bridge turn",
        "stream" => true
      })

    assert response.status == 200
    assert stream_event_types(response.resp_body) == ["response.failed"]

    assert [upstream_request] = FakeUpstream.requests(upstream)
    assert upstream_request.method == "WEBSOCKET"

    request =
      Repo.one!(
        from request in Request,
          where: request.pool_id == ^setup.pool.id,
          order_by: [desc: request.admitted_at],
          limit: 1
      )

    assert request.status == "failed"
    assert [attempt] = Repo.all(from attempt in Attempt, where: attempt.request_id == ^request.id)
    assert attempt.transport == "websocket"
    assert attempt.response_metadata["bridge_committed"] == true
    refute inspect(attempt.response_metadata) =~ "codex.future_event"
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
      assert :erlang.resume_process(owner)

      response = Task.await(request_task, 1_000)
      send(close_barrier_pid, {:fake_upstream_release_websocket, release_ref})

      assert response.status == 200
      assert Enum.count(stream_event_types(response.resp_body), &(&1 == @public_type)) == 1
      refute response.resp_body =~ "unexpected_http_replay"

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

  test "websocket close without a terminal emits one truthful synthetic failure without replay",
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
                "response" => %{"id" => "unexpected_http_replay", "status" => "completed"}
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
    assert stream_event_types(response.resp_body) == ["response.failed"]
    assert response.resp_body =~ "upstream_stream_error"
    refute response.resp_body =~ "unexpected_http_replay"

    assert [upstream_request] = FakeUpstream.requests(upstream)
    assert upstream_request.method == "WEBSOCKET"
    assert FakeUpstream.http_request_count(upstream) == 0

    request = latest_request(setup.pool.id)
    assert request.status == "failed"

    assert Repo.aggregate(
             from(attempt in Attempt, where: attempt.request_id == ^request.id),
             :count
           ) == 1

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

  defp set_upstream_receive_timeout!(timeout_ms) do
    previous = Application.get_env(:codex_pooler, OperationalSettings, [])
    settings = %{OperationalSettings.current() | upstream_receive_timeout_ms: timeout_ms}

    Application.put_env(:codex_pooler, OperationalSettings,
      settings: settings,
      use_instance_settings?: false
    )

    on_exit(fn -> Application.put_env(:codex_pooler, OperationalSettings, previous) end)
  end
end
