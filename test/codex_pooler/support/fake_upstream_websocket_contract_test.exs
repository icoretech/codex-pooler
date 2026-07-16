defmodule CodexPooler.FakeUpstreamWebsocketContractTest do
  use ExUnit.Case, async: false

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.Request

  @timeouts %{connect_timeout_ms: 1_000, receive_timeout_ms: 1_000}

  test "real upstream websocket session upgrades and counts one fake connection" do
    event =
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => "resp_contract"}
      })

    {:ok, upstream} = FakeUpstream.start_link(FakeUpstream.websocket_text_frames([event]))
    {:ok, session} = UpstreamWebsocketSession.start_link([])

    on_exit(fn ->
      UpstreamWebsocketSession.close(session)
      FakeUpstream.stop(upstream)
    end)

    request = %Request{
      url: FakeUpstream.url(upstream) <> "/backend-api/codex/responses",
      headers: [],
      payload: "{}",
      timeouts: @timeouts,
      writer: fn _text -> :ok end,
      message_mapper: nil
    }

    assert {:ok, %{terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(session, request)

    assert FakeUpstream.websocket_connection_count(upstream) == 1
    assert [connection_id] = FakeUpstream.websocket_connection_ids(upstream)
    assert is_reference(connection_id)
  end

  test "keeps one opaque connection ID across warm request reuse" do
    {upstream, session} = start_resources(FakeUpstream.websocket_text_frames([completed_event()]))
    request = websocket_request(upstream)

    assert {:ok, %{terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(session, request)

    assert [connection_id] = FakeUpstream.websocket_connection_ids(upstream)
    assert FakeUpstream.websocket_connection_count(upstream) == 1

    assert {:ok, %{terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(session, request)

    assert FakeUpstream.websocket_connection_count(upstream) == 1
    assert [^connection_id] = FakeUpstream.websocket_connection_ids(upstream)
  end

  test "observes a new ID after a forced pre-visible close and transparent reconnect" do
    {upstream, session} =
      start_resources(FakeUpstream.websocket_text_frames([completed_event("first")]))

    request = websocket_request(upstream)

    assert {:ok, %{terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(session, request)

    assert [first_connection_id] = FakeUpstream.websocket_connection_ids(upstream)

    FakeUpstream.set_mode(
      upstream,
      {:sequence,
       [
         FakeUpstream.websocket_sse_then_close([], code: 1001, reason: "synthetic close"),
         FakeUpstream.websocket_text_frames([completed_event("reconnected")])
       ]}
    )

    assert {:ok, %{terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(session, request)

    assert FakeUpstream.websocket_connection_count(upstream) == 2

    assert [^first_connection_id, second_connection_id] =
             FakeUpstream.websocket_connection_ids(upstream)

    assert is_reference(second_connection_id)
    refute first_connection_id == second_connection_id
  end

  test "does not invent an ID when a transparent reconnect fails its upgrade" do
    {upstream, session} =
      start_resources(FakeUpstream.websocket_text_frames([completed_event("first")]))

    request = websocket_request(upstream)

    assert {:ok, %{terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(session, request)

    assert [connection_id] = FakeUpstream.websocket_connection_ids(upstream)

    FakeUpstream.set_mode(
      upstream,
      {:sequence,
       [
         FakeUpstream.websocket_sse_then_close([], code: 1001, reason: "synthetic close"),
         FakeUpstream.websocket_upgrade_error(%{"error" => %{"code" => "upgrade_rejected"}},
           status: 503
         )
       ]}
    )

    assert {:error, %{body: "", reason: {:websocket_upgrade_failed, 503, _}}} =
             UpstreamWebsocketSession.request(session, request)

    assert FakeUpstream.websocket_connection_count(upstream) == 1
    assert [^connection_id] = FakeUpstream.websocket_connection_ids(upstream)
  end

  test "observes a new ID when a request key changes its headers" do
    {upstream, session} =
      start_resources(
        {:sequence,
         [
           FakeUpstream.websocket_text_frames([completed_event("old-key")]),
           FakeUpstream.websocket_text_frames([completed_event("new-key")])
         ]}
      )

    old_request = websocket_request(upstream, [{"x-test-key", "old"}])
    new_request = websocket_request(upstream, [{"x-test-key", "new"}])

    assert {:ok, %{terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(session, old_request)

    assert [first_connection_id] = FakeUpstream.websocket_connection_ids(upstream)

    assert {:ok, %{terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(session, new_request)

    assert FakeUpstream.websocket_connection_count(upstream) == 2

    assert [^first_connection_id, second_connection_id] =
             FakeUpstream.websocket_connection_ids(upstream)

    assert is_reference(second_connection_id)
    refute first_connection_id == second_connection_id
  end

  test "records no ID for a rejected initial websocket upgrade" do
    {upstream, _session} =
      start_resources(
        FakeUpstream.websocket_upgrade_error(%{"error" => %{"code" => "upgrade_rejected"}},
          status: 401
        )
      )

    request = websocket_request(upstream)

    assert {:error, %{reason: {:websocket_upgrade_failed, 401, _}}} =
             UpstreamWebsocketSession.request_once(request)

    assert FakeUpstream.websocket_connection_count(upstream) == 0
    assert [] = FakeUpstream.websocket_connection_ids(upstream)
  end

  test "keeps malformed upgrade failure output bounded" do
    {upstream, _session} =
      start_resources(
        FakeUpstream.websocket_upgrade_error(%{"error" => "malformed"}, status: 502)
      )

    assert {:error, %{body: "", reason: {:websocket_upgrade_failed, 502, _}}} =
             UpstreamWebsocketSession.request_once(websocket_request(upstream))

    assert FakeUpstream.websocket_connection_count(upstream) == 0
    assert [] = FakeUpstream.websocket_connection_ids(upstream)
  end

  test "repeated close requests remain bounded and do not add IDs" do
    {upstream, session} = start_resources(FakeUpstream.websocket_text_frames([completed_event()]))
    request = websocket_request(upstream)

    assert {:ok, %{terminal: "response.completed", status: 200}} =
             UpstreamWebsocketSession.request(session, request)

    assert [connection_id] = FakeUpstream.websocket_connection_ids(upstream)
    assert :ok = FakeUpstream.close_websocket_connections(upstream)
    assert :ok = FakeUpstream.close_websocket_connections(upstream)
    assert FakeUpstream.websocket_connection_count(upstream) == 1
    assert [^connection_id] = FakeUpstream.websocket_connection_ids(upstream)
  end

  defp start_resources(mode) do
    {:ok, upstream} = FakeUpstream.start_link(mode)
    {:ok, session} = UpstreamWebsocketSession.start_link([])

    on_exit(fn ->
      UpstreamWebsocketSession.close(session)
      FakeUpstream.stop(upstream)
    end)

    {upstream, session}
  end

  defp websocket_request(upstream, headers \\ []) do
    %Request{
      url: FakeUpstream.url(upstream) <> "/backend-api/codex/responses",
      headers: headers,
      payload: "{}",
      timeouts: @timeouts,
      writer: fn _text -> :ok end,
      message_mapper: nil
    }
  end

  defp completed_event(id \\ "resp_contract") do
    Jason.encode!(%{
      "type" => "response.completed",
      "response" => %{"id" => id}
    })
  end
end
