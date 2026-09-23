defmodule CodexPoolerWeb.V1.ResponsesWebsocketBridgeMultilineFrameTest do
  # A `/v1/responses` stream bridged over the upstream websocket turns every
  # upstream text frame into one SSE event (`WebsocketBridgeStream.sse_block`).
  # A frame whose text spans several lines, such as a pretty-printed event
  # object, used to be framed as a single `data:` line, so every line after the
  # first fell outside the event and the client stream carried malformed
  # events; the retained upstream body had the same defect (findings#254 rows
  # 254-60 and 254-53). Each text line now gets its own `data:` line.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Repo

  @visible "synthetic multi-line bridged output"

  setup do
    previous = Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    on_exit(fn ->
      stop_local_owner_sessions()

      case previous do
        nil -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
        value -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
      end
    end)

    :ok
  end

  test "pretty-printed upstream websocket frames reach the bridged SSE client as whole events", %{conn: conn} do
    frames =
      Enum.map(
        [
          %{"type" => "response.created", "response" => %{"id" => "resp_bridge_multiline", "status" => "in_progress", "output" => []}},
          %{"type" => "response.output_text.delta", "item_id" => "msg_bridge_multiline", "output_index" => 0, "content_index" => 0, "delta" => @visible},
          %{"type" => "response.completed", "response" => %{"id" => "resp_bridge_multiline", "status" => "completed", "output" => [], "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}}}
        ],
        &Jason.encode!(&1, pretty: true)
      )

    assert Enum.all?(frames, &(&1 =~ "\n"))

    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            path: "/backend-api/codex/responses",
            websocket_connection_ordinal: 1,
            json: [valid: true, equals: %{"type" => "response.create"}],
            respond: FakeUpstream.websocket_text_frames(frames)
          )
        ])
      )

    setup = gateway_setup(upstream)

    response =
      conn
      |> auth(setup)
      |> put_req_header("x-session-id", "bridge-multiline-#{System.unique_integer([:positive])}")
      |> post("/v1/responses", %{"model" => setup.model.exposed_model_id, "input" => "synthetic multi-line turn", "stream" => true})

    assert FakeUpstream.websocket_connection_count(upstream) == 1
    assert FakeUpstream.http_request_count(upstream) == 0
    assert :ok = FakeUpstream.verify!(upstream)
    assert response.status == 200

    events = sse_events(response.resp_body)
    types = Enum.map(events, & &1["type"])

    assert "response.created" in types
    assert Enum.any?(events, &(&1["type"] == "response.output_text.delta" and &1["delta"] == @visible))
    assert List.last(types) == "response.completed"
    assert %{"response" => %{"id" => "resp_bridge_multiline", "status" => "completed"}} = List.last(events)

    assert [request] = Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
  end

  # Every `data:` line of an event is part of its data; a block whose data does
  # not decode as a JSON object is kept as `:undecodable` so a malformed event
  # fails the test instead of disappearing.
  defp sse_events(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.map(fn block ->
      data =
        block
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "data:"))
        |> Enum.map_join("\n", &String.replace_prefix(String.replace_prefix(&1, "data:", ""), " ", ""))

      data
    end)
    |> Enum.reject(&(&1 in ["", "[DONE]"]))
    |> Enum.map(fn data ->
      case CodexPooler.JSON.decode(data) do
        {:ok, %{} = event} -> event
        _other -> %{"type" => :undecodable}
      end
    end)
  end

  defp stop_local_owner_sessions do
    _logs =
      capture_log(fn ->
        WebsocketOwnerSession.Registry
        |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
        |> Enum.each(fn session_id ->
          try do
            with {:ok, owner_pid} <- WebsocketOwnerSession.lookup(session_id) do
              GenServer.stop(owner_pid, :shutdown, 1_000)
            end
          catch
            :exit, _reason -> :ok
          end
        end)
      end)

    :ok
  end
end
