defmodule CodexPooler.Dev.GatewayPerfFakeUpstreamTest do
  use ExUnit.Case, async: false

  alias CodexPooler.Dev.GatewayPerfFakeUpstream

  # Detection budget for a loopback socket round trip. The websocket helpers
  # below only ever drive "short-ok", whose paced delays are two orders of
  # magnitude smaller, so this bounds a stalled run rather than the scenario.
  @detection_timeout_ms 5_000

  @manifest_keys [
    "name",
    "first_event_delay_ms",
    "inter_event_delay_ms",
    "event_count",
    "chunk_bytes",
    "http_status",
    "failure_phase",
    "close_mode",
    "expected_outcome",
    "allowed_statuses"
  ]

  @expected_profiles %{
    "short-ok" => [50, 25, 20, 512, 200, "before_none", "clean_close", "success", [200]],
    "long-ok" => [100, 1000, 300, 512, 200, "before_none", "clean_close", "success", [200]],
    "large-chunk" => [50, 100, 50, 65_536, 200, "before_none", "clean_close", "success", [200]],
    "slow-first-event" => [
      15_000,
      25,
      20,
      512,
      200,
      "before_none",
      "clean_close",
      "timeout_or_classified_failure",
      [504, 502]
    ],
    "disconnect-midstream" => [
      50,
      25,
      20,
      512,
      200,
      "after_event_5",
      "client_disconnect",
      "classified_disconnect",
      [499, 502]
    ],
    "partial-failure" => [
      50,
      25,
      20,
      512,
      200,
      "after_event_5",
      "upstream_error",
      "classified_failure",
      [502]
    ],
    "timeout" => [999_999, 25, 20, 512, 200, "before_first_event", "timeout", "timeout", [504]],
    "quota-429" => [0, 0, 0, 0, 429, "before_stream", "http_error", "rate_limited", [429]],
    "opencode-text-ok" => [0, 0, 8, 2, 200, "before_none", "clean_close", "success", [200]],
    "native-compaction-v2-success" => [
      0,
      0,
      2,
      0,
      200,
      "before_none",
      "clean_close",
      "success",
      [200]
    ],
    "native-compaction-terminal-failure" => [
      0,
      0,
      1,
      0,
      200,
      "before_none",
      "upstream_error",
      "classified_failure",
      [502]
    ]
  }
  @profile_order [
    "short-ok",
    "long-ok",
    "large-chunk",
    "slow-first-event",
    "disconnect-midstream",
    "partial-failure",
    "timeout",
    "quota-429",
    "opencode-text-ok",
    "native-compaction-v2-success",
    "native-compaction-terminal-failure"
  ]

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:bandit)
    :ok
  end

  test "manifest entries use the fixed schema and profile values" do
    assert {:ok, profiles} = GatewayPerfFakeUpstream.profiles_from_selector("all")
    manifest = GatewayPerfFakeUpstream.manifest_entries(profiles)

    assert Enum.map(manifest, & &1["name"]) == @profile_order

    for entry <- manifest do
      assert MapSet.new(Map.keys(entry)) == MapSet.new(@manifest_keys)

      assert profile_tuple(entry) == Map.fetch!(@expected_profiles, entry["name"])
    end
  end

  test "unknown CLI profiles are rejected with a clear error" do
    assert {:error, message} =
             GatewayPerfFakeUpstream.parse_args([
               "--run-id",
               "profile-reject-test",
               "--profiles",
               "short-ok,missing-profile"
             ])

    assert message == "unknown profiles: missing-profile"
  end

  test "health route responds on the configured server" do
    server = start_server!("short-ok")

    response = Req.get!(server.url <> "/healthz")

    assert response.status == 200
    assert response.body == "ok"
  end

  test "Full catalog entry is canonical-source eligible and explicitly non-Lite" do
    model = GatewayPerfFakeUpstream.full_catalog_model()

    assert model["slug"] == model["id"]
    assert model["use_responses_lite"] == false
    assert model["capabilities"]["responses"] == true
  end

  test "backend and v1 routes emit equivalent successful SSE streams" do
    server = start_server!("short-ok")

    backend = post_stream!(server.url <> "/backend-api/codex/responses")
    responses = post_stream!(server.url <> "/v1/responses")
    chat = post_stream!(server.url <> "/v1/chat/completions")

    assert backend.status == 200
    assert responses.status == 200
    assert chat.status == 200

    assert stream_event_count(backend.body, "response.output_text.delta") == 19
    assert stream_event_count(responses.body, "response.output_text.delta") == 19
    assert stream_event_count(chat.body, "response.output_text.delta") == 19

    assert backend.body =~ "event: response.completed\n"
    assert responses.body =~ "event: response.completed\n"
    assert chat.body =~ "event: response.completed\n"

    assert backend.body =~ "data: [DONE]\n\n"
    assert responses.body =~ "data: [DONE]\n\n"
    assert chat.body =~ "data: [DONE]\n\n"
  end

  test "profile selection prefers query, then gateway header, then codex pooler header" do
    server = start_server!("short-ok,quota-429")
    url = server.url <> "/backend-api/codex/responses"

    codex_header =
      post_stream!(url, [{"x-codex-pooler-perf-profile", "quota-429"}])

    assert codex_header.status == 429
    assert codex_header.body["error"]["code"] == "rate_limit_exceeded"

    gateway_header =
      post_stream!(url, [
        {"x-gateway-perf-profile", "quota-429"},
        {"x-codex-pooler-perf-profile", "short-ok"}
      ])

    assert gateway_header.status == 429
    assert gateway_header.body["error"]["code"] == "rate_limit_exceeded"

    query =
      post_stream!(url <> "?profile=short-ok", [
        {"x-gateway-perf-profile", "quota-429"},
        {"x-codex-pooler-perf-profile", "quota-429"}
      ])

    assert query.status == 200
    assert query.body =~ "profile short-ok complete"
  end

  test "deterministic failure profiles expose distinct HTTP and stream behavior" do
    server = start_server!("quota-429,partial-failure,disconnect-midstream,timeout")

    quota = post_stream!(server.url <> "/backend-api/codex/responses?profile=quota-429")
    assert quota.status == 429
    assert quota.body["error"]["code"] == "rate_limit_exceeded"

    partial = post_stream!(server.url <> "/backend-api/codex/responses?profile=partial-failure")
    assert partial.status == 200
    assert stream_event_count(partial.body, "response.output_text.delta") == 5
    assert partial.body =~ "event: response.failed\n"
    refute partial.body =~ "data: [DONE]"

    disconnected =
      post_stream!(server.url <> "/backend-api/codex/responses?profile=disconnect-midstream")

    assert disconnected.status == 200
    assert stream_event_count(disconnected.body, "response.output_text.delta") == 5
    refute disconnected.body =~ "data: [DONE]"

    assert {:error, error} =
             Req.post(server.url <> "/backend-api/codex/responses?profile=timeout",
               json: %{"model" => "gpt-example"},
               receive_timeout: 100,
               retry: false
             )

    assert transport_timeout?(error)
  end

  test "websocket routes convert stream events into JSON text frames" do
    server = start_server!("short-ok")
    {conn, websocket, ref} = websocket_connect!(server.url, "/backend-api/codex/responses")

    {conn, websocket} =
      websocket_send_text!(conn, websocket, ref, Jason.encode!(%{"model" => "gpt-example"}))

    {_conn, _websocket, text} = websocket_receive_text!(conn, websocket, ref)

    assert %{"type" => "response.output_text.delta", "profile" => "short-ok"} =
             Jason.decode!(text)
  end

  test "opencode text profile emits one internally consistent AI SDK response" do
    assert {:ok, [profile]} =
             GatewayPerfFakeUpstream.profiles_from_selector("opencode-text-ok")

    events = GatewayPerfFakeUpstream.stream_event_payloads(profile)

    assert Enum.map(events, & &1["type"]) == [
             "response.created",
             "response.output_item.added",
             "response.content_part.added",
             "response.output_text.delta",
             "response.output_text.done",
             "response.content_part.done",
             "response.output_item.done",
             "response.completed"
           ]

    assert Enum.map(events, & &1["sequence_number"]) == Enum.to_list(0..7)

    [created, item_added, part_added, delta, text_done, part_done, item_done, completed] =
      events

    response_id = created["response"]["id"]
    item_id = item_added["item"]["id"]

    assert created["response"]["status"] == "in_progress"
    assert created["response"]["output"] == []
    assert item_added["output_index"] == 0
    assert item_added["item"]["status"] == "in_progress"
    assert item_added["item"]["content"] == []

    for event <- [part_added, delta, text_done, part_done] do
      assert event["item_id"] == item_id
      assert event["output_index"] == 0
      assert event["content_index"] == 0
    end

    assert part_added["part"] == output_text("")
    assert delta["delta"] == "ok"
    assert text_done["text"] == "ok"
    assert part_done["part"] == output_text("ok")
    assert item_done["output_index"] == 0
    assert item_done["item"]["id"] == item_id
    assert item_done["item"]["status"] == "completed"
    assert item_done["item"]["content"] == [output_text("ok")]

    response = completed["response"]
    assert response["id"] == response_id
    assert response["status"] == "completed"
    assert response["output"] == [item_done["item"]]

    assert response["usage"] == %{
             "input_tokens" => 1,
             "input_tokens_details" => %{"cached_tokens" => 0},
             "output_tokens" => 1,
             "output_tokens_details" => %{"reasoning_tokens" => 0},
             "total_tokens" => 2
           }
  end

  test "native compaction profiles emit exact success and terminal event families" do
    assert {:ok, [success]} =
             GatewayPerfFakeUpstream.profiles_from_selector("native-compaction-v2-success")

    assert {:ok, [failure]} =
             GatewayPerfFakeUpstream.profiles_from_selector("native-compaction-terminal-failure")

    trigger = %{"input" => [%{"type" => "compaction_trigger"}]}

    assert Enum.map(GatewayPerfFakeUpstream.stream_event_payloads(success, trigger), & &1["type"]) ==
             [
               "response.output_item.done",
               "response.completed"
             ]

    [compact_done, _completed] =
      GatewayPerfFakeUpstream.stream_event_payloads(success, trigger)

    assert compact_done["item"] == %{
             "id" => "cmp_synthetic_native_local",
             "type" => "compaction",
             "encrypted_content" => "synthetic-encrypted-compaction"
           }

    assert Enum.map(GatewayPerfFakeUpstream.stream_event_payloads(failure, trigger), & &1["type"]) ==
             [
               "response.failed"
             ]

    assert Enum.map(
             GatewayPerfFakeUpstream.stream_event_payloads(success, %{"input" => []}),
             & &1["type"]
           ) == [
             "response.created",
             "response.output_item.added",
             "response.content_part.added",
             "response.output_text.delta",
             "response.output_text.done",
             "response.content_part.done",
             "response.output_item.done",
             "response.completed"
           ]
  end

  test "HTTP compaction observations are bounded, closed, and shape-only" do
    server = start_server!("native-compaction-v2-success")

    response =
      Req.post!(server.url <> "/backend-api/codex/responses",
        json: %{
          "model" => "gateway-perf-full",
          "store" => false,
          "stream" => true,
          "input" => [%{"type" => "compaction_trigger"}]
        },
        retry: false
      )

    assert response.status == 200

    assert %{"observations" => [observation]} =
             Req.get!(server.url <> "/__smoke/request-observations").body

    assert observation == %{
             "requestClass" => "http",
             "connectionId" => nil,
             "connectionOrdinal" => nil,
             "frameOrdinal" => nil,
             "inputTypes" => ["compaction_trigger"],
             "inputCount" => 1,
             "anchorPresent" => false,
             "terminalCompactionTrigger" => true,
             "store" => false,
             "stream" => true,
             "compactPhase" => "compact",
             "requestKind" => "unknown",
             "windowId" => "metadata_missing",
             "contextWindowId" => "metadata_missing",
             "compactionMetadata" => "metadata_missing",
             "toolResultContinuation" => false,
             "logicalTurnFingerprint" => nil
           }

    encoded = Jason.encode!(observation)
    refute encoded =~ "encrypted_content"
    refute encoded =~ "authorization"
    refute encoded =~ "client_metadata"
    refute encoded =~ "RAW_NESTED_SENTINEL"
  end

  test "simultaneous websocket connections receive opaque ordered metadata-only observations" do
    server = start_server!("quota-429")

    {connection_a, websocket_a, ref_a} =
      websocket_connect!(server.url, "/backend-api/codex/responses")

    {connection_b, websocket_b, ref_b} =
      websocket_connect!(server.url, "/backend-api/codex/responses")

    {connection_a, websocket_a} =
      websocket_send_text!(
        connection_a,
        websocket_a,
        ref_a,
        Jason.encode!(%{
          "input" => [%{"type" => "message", "content" => "RAW_NESTED_SENTINEL"}],
          "store" => false,
          "stream" => true
        })
      )

    {_connection_a, _websocket_a, _text_a} =
      websocket_receive_text!(connection_a, websocket_a, ref_a)

    {connection_b, websocket_b} =
      websocket_send_text!(
        connection_b,
        websocket_b,
        ref_b,
        Jason.encode!(%{
          "input" => [
            %{"type" => "function_call_output", "output" => "RAW_NESTED_SENTINEL"},
            %{"type" => "compaction_trigger"}
          ],
          "previous_response_id" => "resp_synthetic_anchor",
          "store" => false,
          "stream" => true
        })
      )

    {_connection_b, _websocket_b, _text_b} =
      websocket_receive_text!(connection_b, websocket_b, ref_b)

    {connection_a, websocket_a} =
      websocket_send_text!(
        connection_a,
        websocket_a,
        ref_a,
        Jason.encode!(%{
          "input" => [%{"type" => "compaction"}],
          "store" => false,
          "stream" => true
        })
      )

    {_connection_a, _websocket_a, _text_a} =
      websocket_receive_text!(connection_a, websocket_a, ref_a)

    assert %{"observations" => observations} =
             Req.get!(server.url <> "/__smoke/request-observations").body

    assert not Enum.any?(observations, &(&1["requestClass"] == "http"))

    assert Enum.map(
             observations,
             &Map.take(&1, [
               "connectionOrdinal",
               "frameOrdinal",
               "inputTypes",
               "anchorPresent",
               "compactPhase"
             ])
           ) == [
             %{
               "connectionOrdinal" => 1,
               "frameOrdinal" => 1,
               "inputTypes" => ["message"],
               "anchorPresent" => false,
               "compactPhase" => "lineage"
             },
             %{
               "connectionOrdinal" => 2,
               "frameOrdinal" => 1,
               "inputTypes" => ["function_call_output", "compaction_trigger"],
               "anchorPresent" => true,
               "compactPhase" => "compact"
             },
             %{
               "connectionOrdinal" => 1,
               "frameOrdinal" => 2,
               "inputTypes" => ["compaction"],
               "anchorPresent" => false,
               "compactPhase" => "final"
             }
           ]

    connection_ids = observations |> Enum.map(& &1["connectionId"]) |> Enum.uniq()
    assert Enum.all?(connection_ids, &is_binary/1)
    assert Enum.all?(connection_ids, &Regex.match?(~r/\Aws_[a-f0-9]{12}\z/, &1))
    assert length(connection_ids) == 2

    encoded = Jason.encode!(observations)
    refute encoded =~ "RAW_NESTED_SENTINEL"
    refute encoded =~ "resp_synthetic_anchor"
    refute encoded =~ "function_call_output\",\"output"
  end

  test "write_manifest! persists metadata-only manifest JSON" do
    manifest_path =
      Path.join(
        System.tmp_dir!(),
        "gateway-perf-manifest-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(manifest_path) end)

    assert {:ok, [profile]} = GatewayPerfFakeUpstream.profiles_from_selector("short-ok")

    GatewayPerfFakeUpstream.write_manifest!(manifest_path, [profile])

    assert [decoded] = manifest_path |> File.read!() |> Jason.decode!()
    assert MapSet.new(Map.keys(decoded)) == MapSet.new(@manifest_keys)
    assert decoded["name"] == "short-ok"
    refute File.read!(manifest_path) =~ "authorization"
  end

  defp start_server!(selector) do
    assert {:ok, profiles} = GatewayPerfFakeUpstream.profiles_from_selector(selector)

    assert {:ok, server} =
             GatewayPerfFakeUpstream.start_link(
               host: "127.0.0.1",
               port: 0,
               profiles: profiles,
               run_id: "test-run"
             )

    on_exit(fn -> GatewayPerfFakeUpstream.stop(server) end)
    server
  end

  defp post_stream!(url, headers \\ []) do
    Req.post!(url, headers: headers, json: %{"model" => "gpt-example"}, retry: false)
  end

  defp output_text(text) do
    %{"type" => "output_text", "annotations" => [], "logprobs" => [], "text" => text}
  end

  defp profile_tuple(profile) do
    [
      profile["first_event_delay_ms"],
      profile["inter_event_delay_ms"],
      profile["event_count"],
      profile["chunk_bytes"],
      profile["http_status"],
      profile["failure_phase"],
      profile["close_mode"],
      profile["expected_outcome"],
      profile["allowed_statuses"]
    ]
  end

  defp stream_event_count(body, event) do
    body
    |> String.split("\n")
    |> Enum.count(&(&1 == "event: #{event}"))
  end

  defp transport_timeout?(%Finch.TransportError{reason: :timeout}), do: true
  defp transport_timeout?(%Req.TransportError{reason: :timeout}), do: true
  defp transport_timeout?(%Mint.TransportError{reason: :timeout}), do: true
  defp transport_timeout?(_error), do: false

  defp websocket_connect!(base_url, path) do
    %URI{host: host, port: port} = URI.parse(base_url)
    {:ok, conn} = Mint.HTTP.connect(:http, host, port, protocols: [:http1])
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, path, [])
    {:ok, conn, status, headers} = await_websocket_upgrade(conn, ref)
    {:ok, conn, websocket} = Mint.WebSocket.new(conn, ref, status, headers)
    {conn, websocket, ref}
  end

  defp await_websocket_upgrade(conn, ref, status \\ nil, headers \\ nil) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            status = websocket_status(responses, ref) || status
            headers = websocket_headers(responses, ref) || headers

            if Enum.any?(responses, &match?({:done, ^ref}, &1)) do
              {:ok, conn, status, headers}
            else
              await_websocket_upgrade(conn, ref, status, headers)
            end

          {:error, conn, reason, _responses} ->
            Mint.HTTP.close(conn)
            flunk("websocket upgrade failed: #{inspect(reason)}")

          :unknown ->
            await_websocket_upgrade(conn, ref, status, headers)
        end
    after
      @detection_timeout_ms -> flunk("timed out waiting for websocket upgrade")
    end
  end

  defp websocket_status(responses, ref) do
    Enum.find_value(responses, fn
      {:status, ^ref, status} -> status
      _response -> nil
    end)
  end

  defp websocket_headers(responses, ref) do
    Enum.find_value(responses, fn
      {:headers, ^ref, headers} -> headers
      _response -> nil
    end)
  end

  defp websocket_send_text!(conn, websocket, ref, text) do
    {:ok, websocket, data} = Mint.WebSocket.encode(websocket, {:text, text})
    {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)
    {conn, websocket}
  end

  defp websocket_receive_text!(conn, websocket, ref) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            case decode_websocket_text(websocket, ref, responses) do
              {:ok, websocket, text} -> {conn, websocket, text}
              {:cont, websocket} -> websocket_receive_text!(conn, websocket, ref)
            end

          {:error, conn, reason, _responses} ->
            Mint.HTTP.close(conn)
            flunk("websocket receive failed: #{inspect(reason)}")

          :unknown ->
            websocket_receive_text!(conn, websocket, ref)
        end
    after
      @detection_timeout_ms -> flunk("timed out waiting for websocket frame")
    end
  end

  defp decode_websocket_text(websocket, ref, responses) do
    Enum.reduce_while(responses, {:cont, websocket}, fn
      {:data, ^ref, data}, {:cont, websocket} ->
        websocket
        |> decode_frames!(data)
        |> reduce_decoded_text()

      _response, acc ->
        {:cont, acc}
    end)
  end

  defp decode_frames!(websocket, data) do
    case Mint.WebSocket.decode(websocket, data) do
      {:ok, websocket, frames} -> {websocket, frames}
      {:error, _websocket, reason} -> flunk("websocket decode failed: #{inspect(reason)}")
    end
  end

  defp reduce_decoded_text({websocket, frames}) do
    case decoded_text(websocket, frames) do
      {:ok, websocket, text} -> {:halt, {:ok, websocket, text}}
      {:cont, websocket} -> {:cont, {:cont, websocket}}
    end
  end

  defp decoded_text(websocket, frames) do
    Enum.reduce_while(frames, {:cont, websocket}, fn
      {:text, text}, _acc -> {:halt, {:ok, websocket, text}}
      _frame, acc -> {:cont, acc}
    end)
  end
end
