defmodule CodexPoolerWeb.V1.ResponsesWebsocketBridgeTerminalTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Repo

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
