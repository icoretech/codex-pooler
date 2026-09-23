defmodule CodexPoolerWeb.Runtime.BackendCodexSseWithheldPreambleKeepaliveTest do
  # While the Pooler withholds a candidate's lifecycle preamble (`response.created`,
  # `response.in_progress`, `response.metadata`) for the first-event retry window,
  # the client receives none of the provider's events. The released Codex client
  # resets its stream idle timer only on a parsed SSE event (`eventsource-stream`
  # drops `: keepalive` comments), so a provider that keeps sending preamble events
  # for longer than the 300 s default made Codex time out and resend while the
  # provider was still streaming (findings#225, 225-190). On the native Codex route
  # the next keepalive after a withheld preamble block is a data event, and only
  # that one: silence after it stays comments, so the client's timer still measures
  # the provider. These tests drive a real HTTP listener and read the socket.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 1, native_text_input: 1, start_public_endpoint!: 0, start_upstream: 1]

  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Repo

  @native_path "/backend-api/codex/responses"
  @public_path "/v1/responses"
  @keepalive_comment ": keepalive\n\n"
  @keepalive_event ~s(event: keepalive\ndata: {"type":"keepalive"}\n\n)
  @response_id "resp_withheld_preamble_keepalive"
  @detection_timeout_ms 15_000
  # With a 10 ms interval the preamble is withheld long before this many comment
  # keepalives have been written, so reaching it proves no data event came.
  @comment_budget 25

  setup do
    previous = Application.get_env(:codex_pooler, OperationalSettings)
    Application.put_env(:codex_pooler, OperationalSettings, settings: %OperationalSettings{sse_keepalive_interval_ms: 10})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:codex_pooler, OperationalSettings, previous),
        else: Application.delete_env(:codex_pooler, OperationalSettings)
    end)

    :ok
  end

  test "native Codex SSE announces a withheld preamble with one keepalive data event, then comments" do
    release_ref = make_ref()

    upstream =
      start_upstream(
        # provenance: observed findings issue 225 row 225-190 (S10 PSP arm: preamble events,
        # then a long pre-visible phase; payload values invented)
        FakeUpstream.barrier_sse_stream([created_event(), in_progress_event() | visible_events()],
          barrier_after: 2,
          notify: self(),
          release_ref: release_ref
        )
      )

    setup = gateway_setup(upstream)
    {conn, ref} = post_stream!(setup, @native_path, native_payload(setup))
    assert_receive {:fake_upstream_chunk_barrier, 2, upstream_pid, ^release_ref}, @detection_timeout_ms

    try do
      {conn, held} =
        receive_until(conn, ref, "", fn body ->
          case :binary.split(body, @keepalive_event) do
            [_before, after_event] -> String.contains?(after_event, @keepalive_comment)
            [_no_event] -> comment_budget_spent!(body, "a withheld preamble produced only comment keepalives")
          end
        end)

      refute held =~ "response.created"
      assert count(held, @keepalive_event) == 1

      send(upstream_pid, {:fake_upstream_release_chunk, release_ref})
      {_conn, body} = receive_until_done(conn, ref, held)

      assert event_types(body) == [
               "keepalive",
               "response.created",
               "response.in_progress",
               "response.output_item.added",
               "response.output_text.delta",
               "response.output_item.done",
               "response.completed"
             ]

      assert count(body, @keepalive_event) == 1
      assert_single_succeeded_request!(setup, upstream, "http_sse")
    after
      Mint.HTTP.close(conn)
      send(upstream_pid, {:fake_upstream_release_chunk, release_ref})
    end
  end

  test "native Codex SSE keeps comment keepalives once nothing is withheld" do
    release_ref = make_ref()

    # One upstream chunk carries the preamble and the first output item, so the
    # preamble is flushed in the same write and is never held across a tick.
    committed_chunk = Enum.map_join([created_event(), in_progress_event(), output_item_added_event()], &sse_block/1)

    upstream =
      start_upstream(
        # provenance: observed P30 direct provider probe (created, in_progress and the first
        # output item within one second, then a silent phase; payload values invented)
        FakeUpstream.barrier_sse_stream([committed_chunk, delta_event(), output_item_done_event(), completed_event()],
          barrier_after: 1,
          notify: self(),
          release_ref: release_ref
        )
      )

    setup = gateway_setup(upstream)
    {conn, ref} = post_stream!(setup, @native_path, native_payload(setup))
    assert_receive {:fake_upstream_chunk_barrier, 1, upstream_pid, ^release_ref}, @detection_timeout_ms

    try do
      {conn, held} =
        receive_until(conn, ref, "", fn body ->
          case :binary.split(body, "response.output_item.added") do
            [_before, after_item] -> count(after_item, @keepalive_comment) >= 3
            [_no_item] -> comment_budget_spent!(body, "the committed preamble never reached the client")
          end
        end)

      refute held =~ @keepalive_event

      send(upstream_pid, {:fake_upstream_release_chunk, release_ref})
      {_conn, body} = receive_until_done(conn, ref, held)

      refute body =~ ~s("type":"keepalive")
      assert List.first(event_types(body)) == "response.created"
      assert List.last(event_types(body)) == "response.completed"
      assert_single_succeeded_request!(setup, upstream, "http_sse")
    after
      Mint.HTTP.close(conn)
      send(upstream_pid, {:fake_upstream_release_chunk, release_ref})
    end
  end

  test "native Codex SSE writes no keepalive data event after the terminal" do
    release_ref = make_ref()
    terminal_chunk = Enum.map_join([created_event(), in_progress_event() | visible_events()], &sse_block/1)

    upstream =
      start_upstream(
        # provenance: synthetic_adversarial (a preamble block after the terminal while the
        # upstream EOF is held, the shape the native completion socket test holds)
        FakeUpstream.barrier_sse_stream([terminal_chunk, in_progress_event()],
          barrier_after: 2,
          done: false,
          notify: self(),
          release_ref: release_ref
        )
      )

    setup = gateway_setup(upstream)
    {conn, ref} = post_stream!(setup, @native_path, native_payload(setup))
    assert_receive {:fake_upstream_chunk_barrier, 2, upstream_pid, ^release_ref}, @detection_timeout_ms

    try do
      {conn, held} =
        receive_until(conn, ref, "", fn body ->
          case :binary.split(body, "response.completed") do
            [_before, after_terminal] -> count(after_terminal, @keepalive_comment) >= @comment_budget or after_terminal =~ "keepalive\ndata"
            [_no_terminal] -> false
          end
        end)

      refute held =~ @keepalive_event
      assert List.last(event_types(held)) == "response.completed"

      send(upstream_pid, {:fake_upstream_release_chunk, release_ref})
      {_conn, body} = receive_until_done(conn, ref, held)

      refute body =~ ~s("type":"keepalive")
      assert_single_succeeded_request!(setup, upstream, "http_sse")
    after
      Mint.HTTP.close(conn)
      send(upstream_pid, {:fake_upstream_release_chunk, release_ref})
    end
  end

  test "public /v1/responses SSE keeps comment keepalives while its preamble is withheld" do
    release_ref = make_ref()

    upstream =
      start_upstream(
        # provenance: observed findings issue 225 row 225-190 (same preamble-then-pause shape
        # on the public surface; payload values invented)
        FakeUpstream.barrier_sse_stream([created_event(), in_progress_event() | visible_events()],
          barrier_after: 2,
          notify: self(),
          release_ref: release_ref
        )
      )

    setup = gateway_setup(upstream)

    {conn, ref} =
      post_stream!(setup, @public_path, %{"model" => setup.model.exposed_model_id, "input" => "synthetic public keepalive fixture", "stream" => true})

    assert_receive {:fake_upstream_chunk_barrier, 2, upstream_pid, ^release_ref}, @detection_timeout_ms

    try do
      {conn, held} = receive_until(conn, ref, "", &(count(&1, @keepalive_comment) >= @comment_budget or &1 =~ "keepalive\ndata"))

      refute held =~ "response.created"
      refute held =~ @keepalive_event

      send(upstream_pid, {:fake_upstream_release_chunk, release_ref})
      {_conn, body} = receive_until_done(conn, ref, held)

      refute body =~ ~s("type":"keepalive")
      assert List.first(event_types(body)) == "response.created"
      assert List.last(event_types(body)) == "response.completed"
      assert_single_succeeded_request!(setup, upstream, "http_sse")
    after
      Mint.HTTP.close(conn)
      send(upstream_pid, {:fake_upstream_release_chunk, release_ref})
    end
  end

  defp native_payload(setup) do
    %{
      "model" => setup.model.exposed_model_id,
      "input" => native_text_input("synthetic withheld preamble keepalive fixture"),
      "stream" => true
    }
  end

  defp post_stream!(setup, path, payload) do
    port = start_public_endpoint!()
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, mode: :passive)

    {:ok, conn, ref} =
      Mint.HTTP.request(
        conn,
        "POST",
        path,
        [{"authorization", setup.authorization}, {"content-type", "application/json"}],
        CodexPooler.JSON.encode!(payload)
      )

    {conn, ref}
  end

  defp receive_until(conn, ref, body, done?) do
    if done?.(body) do
      {conn, body}
    else
      assert {:ok, conn, responses} = Mint.HTTP.recv(conn, 0, @detection_timeout_ms)

      body =
        Enum.reduce(responses, body, fn
          {:status, ^ref, status}, body ->
            assert status == 200
            body

          {:headers, ^ref, _headers}, body ->
            body

          {:data, ^ref, data}, body ->
            body <> data

          {:done, ^ref}, _body ->
            flunk("the stream ended while the upstream was still held at its barrier")
        end)

      receive_until(conn, ref, body, done?)
    end
  end

  defp receive_until_done(conn, ref, body) do
    assert {:ok, conn, responses} = Mint.HTTP.recv(conn, 0, @detection_timeout_ms)

    {body, done?} =
      Enum.reduce(responses, {body, false}, fn
        {:data, ^ref, data}, {body, done?} -> {body <> data, done?}
        {:done, ^ref}, {body, _done?} -> {body, true}
        _other, acc -> acc
      end)

    if done?, do: {conn, body}, else: receive_until_done(conn, ref, body)
  end

  defp comment_budget_spent!(body, message) do
    if count(body, @keepalive_comment) >= @comment_budget, do: flunk(message), else: false
  end

  defp count(body, pattern), do: body |> :binary.matches(pattern) |> length()

  # Parse the stream the way the Codex client does: comments dropped, one event
  # per `data:` payload, identified by its JSON `type`.
  defp event_types(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn block ->
      data =
        block
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "data:"))
        |> Enum.map_join("\n", &(&1 |> String.trim_leading("data:") |> String.trim_leading()))

      case CodexPooler.JSON.decode(data) do
        {:ok, %{"type" => type}} -> [type]
        _comment_or_done -> []
      end
    end)
  end

  defp assert_single_succeeded_request!(setup, upstream, transport) do
    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.transport == transport
    assert FakeUpstream.count(upstream) == 1
  end

  defp sse_block({event, payload}), do: "event: #{event}\ndata: #{CodexPooler.JSON.encode!(payload)}\n\n"

  defp created_event,
    do: {"response.created", %{"type" => "response.created", "response" => response("in_progress")}}

  defp in_progress_event,
    do: {"response.in_progress", %{"type" => "response.in_progress", "response" => response("in_progress")}}

  defp visible_events, do: [output_item_added_event(), delta_event(), output_item_done_event(), completed_event()]

  defp output_item_added_event do
    {"response.output_item.added", %{"type" => "response.output_item.added", "output_index" => 0, "item" => %{"type" => "message", "id" => "msg_withheld_preamble", "role" => "assistant", "status" => "in_progress", "content" => []}}}
  end

  defp delta_event do
    {"response.output_text.delta", %{"type" => "response.output_text.delta", "item_id" => "msg_withheld_preamble", "output_index" => 0, "content_index" => 0, "delta" => "ok"}}
  end

  defp output_item_done_event do
    {"response.output_item.done",
     %{
       "type" => "response.output_item.done",
       "output_index" => 0,
       "item" => %{"type" => "message", "id" => "msg_withheld_preamble", "role" => "assistant", "status" => "completed", "content" => [%{"type" => "output_text", "text" => "ok", "annotations" => []}]}
     }}
  end

  defp completed_event do
    {"response.completed",
     %{
       "type" => "response.completed",
       "response" =>
         Map.merge(response("completed"), %{
           "output" => [%{"type" => "message", "id" => "msg_withheld_preamble", "role" => "assistant", "status" => "completed", "content" => [%{"type" => "output_text", "text" => "ok", "annotations" => []}]}],
           "usage" => %{"input_tokens" => 4, "output_tokens" => 1, "total_tokens" => 5}
         })
     }}
  end

  defp response(status), do: %{"id" => @response_id, "object" => "response", "status" => status, "model" => "fixture-model", "output" => []}
end
