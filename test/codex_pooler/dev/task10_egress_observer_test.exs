defmodule CodexPooler.Dev.Task10EgressObserverTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias CodexPooler.Dev.Task10EgressObserver
  alias CodexPooler.Dev.Task10EgressObserver.Plug, as: ObserverPlug

  @event [:codex_pooler, :gateway, :upstream, :egress_observation]
  @flag :task10_egress_observation_enabled

  setup do
    on_exit(fn ->
      Task10EgressObserver.disarm()

      case Process.whereis(Task10EgressObserver.Store) do
        nil -> :ok
        pid -> Agent.stop(pid)
      end
    end)

    :ok
  end

  test "arming enables the flag, clears the store, and records sanitized names only" do
    :ok = Task10EgressObserver.arm()
    assert Application.get_env(:codex_pooler, @flag) == true
    assert Task10EgressObserver.captures() == %{}

    :telemetry.execute(@event, %{count: 1}, %{
      transport: :http,
      client_request_id: "smoke-exact-multi_agent_full-abc123",
      header_names: ["Authorization", "content-type", "bad name<with secrets>"],
      websocket_client_metadata: :none
    })

    captures = Task10EgressObserver.captures()
    entry = captures["smoke-exact-multi_agent_full-abc123"]
    assert is_map(entry)
    assert "authorization" in entry["httpHeaderNames"]
    assert "content-type" in entry["httpHeaderNames"]
    refute Enum.any?(entry["httpHeaderNames"], &String.contains?(&1, "secret"))
    assert Enum.any?(entry["httpHeaderNames"], &Regex.match?(~r/^[a-f0-9]{12}$/, &1))
  end

  test "websocket client_metadata keys are recorded and unparseable payloads poison the entry" do
    :ok = Task10EgressObserver.arm()

    :telemetry.execute(@event, %{count: 1}, %{
      transport: :websocket,
      client_request_id: "smoke-ws-correlator",
      header_names: ["authorization"],
      websocket_client_metadata:
        {:keys, ["ws_request_header_x_openai_internal_codex_responses_lite"]}
    })

    entry = Task10EgressObserver.captures()["smoke-ws-correlator"]

    assert entry["websocketClientMetadataKeys"] == [
             "ws_request_header_x_openai_internal_codex_responses_lite"
           ]

    :telemetry.execute(@event, %{count: 1}, %{
      transport: :websocket,
      client_request_id: "smoke-ws-correlator",
      header_names: [],
      websocket_client_metadata: :unparseable
    })

    poisoned = Task10EgressObserver.captures()["smoke-ws-correlator"]
    assert poisoned["websocketClientMetadataKeys"] == nil
  end

  test "the store is bounded and disarm stops recording" do
    :ok = Task10EgressObserver.arm()

    for index <- 1..40 do
      :telemetry.execute(@event, %{count: 1}, %{
        transport: :http,
        client_request_id: "correlator-#{index}",
        header_names: ["authorization"],
        websocket_client_metadata: :none
      })
    end

    assert map_size(Task10EgressObserver.captures()) == 32

    :ok = Task10EgressObserver.disarm()
    assert Application.get_env(:codex_pooler, @flag) == false
    assert Task10EgressObserver.captures() == %{}

    :telemetry.execute(@event, %{count: 1}, %{
      transport: :http,
      client_request_id: "after-disarm",
      header_names: ["authorization"],
      websocket_client_metadata: :none
    })

    assert Task10EgressObserver.captures() == %{}
  end

  test "the loopback plug serves the identity header, captures, and reset lifecycle" do
    reset =
      conn(:post, "/reset")
      |> ObserverPlug.call([])

    assert reset.status == 200
    assert Plug.Conn.get_resp_header(reset, "x-task10-egress-observer") == ["pooler-egress-v1"]
    assert Jason.decode!(reset.resp_body) == %{"status" => "reset"}

    :telemetry.execute(@event, %{count: 1}, %{
      transport: :websocket,
      client_request_id: "plug-correlator",
      header_names: ["authorization"],
      websocket_client_metadata: :unparseable
    })

    served =
      conn(:get, "/")
      |> ObserverPlug.call([])

    assert served.status == 200
    assert Plug.Conn.get_resp_header(served, "x-task10-egress-observer") == ["pooler-egress-v1"]
    body = Jason.decode!(served.resp_body)
    assert body["plug-correlator"]["httpHeaderNames"] == ["authorization"]
    # A poisoned entry omits the websocket keys entirely: downstream validation
    # rejects the malformed entry instead of reading absence as proof.
    refute Map.has_key?(body["plug-correlator"], "websocketClientMetadataKeys")

    missing =
      conn(:get, "/unknown")
      |> ObserverPlug.call([])

    assert missing.status == 404
  end

  test "a hostile correlator key is fingerprinted, never stored or served raw" do
    :ok = Task10EgressObserver.arm()

    :telemetry.execute(@event, %{count: 1}, %{
      transport: :http,
      client_request_id: "bad correlator<looks-like-a-token>",
      header_names: ["authorization"],
      websocket_client_metadata: :none
    })

    captures = Task10EgressObserver.captures()
    refute Map.has_key?(captures, "bad correlator<looks-like-a-token>")
    assert [key] = Map.keys(captures)
    assert Regex.match?(~r/^[a-f0-9]{12}$/, key)

    served =
      conn(:get, "/")
      |> ObserverPlug.call([])

    refute String.contains?(served.resp_body, "looks-like-a-token")
  end

  test "name overflow poisons the field instead of silently truncating" do
    :ok = Task10EgressObserver.arm()

    :telemetry.execute(@event, %{count: 1}, %{
      transport: :http,
      client_request_id: "overflow-correlator",
      header_names: Enum.map(1..70, &"header-#{&1}"),
      websocket_client_metadata: :none
    })

    entry = Task10EgressObserver.captures()["overflow-correlator"]
    assert entry["httpHeaderNames"] == nil

    served =
      conn(:get, "/")
      |> ObserverPlug.call([])

    body = Jason.decode!(served.resp_body)
    refute Map.has_key?(body["overflow-correlator"], "httpHeaderNames")
  end

  test "the loopback disarm endpoint tears the observer down and reports bounded status" do
    :ok = Task10EgressObserver.arm()

    :telemetry.execute(@event, %{count: 1}, %{
      transport: :http,
      client_request_id: "pre-disarm-correlator",
      header_names: ["authorization"],
      websocket_client_metadata: :none
    })

    armed =
      conn(:get, "/status")
      |> ObserverPlug.call([])

    assert armed.status == 200

    assert Jason.decode!(armed.resp_body) == %{
             "armed" => true,
             "telemetryHandlers" => 1,
             "captureEntries" => 1
           }

    disarmed =
      conn(:post, "/disarm")
      |> ObserverPlug.call([])

    assert disarmed.status == 200

    assert Plug.Conn.get_resp_header(disarmed, "x-task10-egress-observer") == [
             "pooler-egress-v1"
           ]

    assert Jason.decode!(disarmed.resp_body) == %{
             "status" => "disarmed",
             "armed" => false,
             "telemetryHandlers" => 0,
             "captureEntries" => 0
           }

    # Nothing is observed or retained after teardown.
    :telemetry.execute(@event, %{count: 1}, %{
      transport: :http,
      client_request_id: "post-disarm-correlator",
      header_names: ["authorization"],
      websocket_client_metadata: :none
    })

    after_disarm =
      conn(:get, "/status")
      |> ObserverPlug.call([])

    assert Jason.decode!(after_disarm.resp_body) == %{
             "armed" => false,
             "telemetryHandlers" => 0,
             "captureEntries" => 0
           }

    assert Task10EgressObserver.captures() == %{}
  end

  test "the gateway flag defaults to disabled so production emits nothing" do
    assert Application.get_env(:codex_pooler, @flag, false) == false
  end
end
