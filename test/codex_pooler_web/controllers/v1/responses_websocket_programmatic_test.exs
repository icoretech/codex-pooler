defmodule CodexPoolerWeb.V1.ResponsesWebsocketProgrammaticTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [
      await_public_websocket_upgrade: 2,
      gateway_setup: 1,
      mint_websocket_new!: 4,
      public_websocket_receive_text!: 3,
      public_websocket_send_text!: 4,
      start_public_endpoint!: 0,
      start_upstream: 1
    ]

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request, RequestLogs}
  alias CodexPooler.Events
  alias CodexPooler.FakeUpstream

  alias CodexPooler.Gateway.Persistence.{
    BridgeOwnerLease,
    BridgeSessionAlias,
    CodexSession,
    CodexTurn,
    IdempotencyKey
  }

  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Runtime.BackendCodexTestSupport

  @websocket_frame_timeout 2_000

  test "public websocket helper preserves every co-decoded Mint text frame in FIFO order" do
    websocket = %Mint.WebSocket{}

    {:ok, _websocket, first_data} = Mint.WebSocket.encode(websocket, {:text, "first"})
    {:ok, _websocket, second_data} = Mint.WebSocket.encode(websocket, {:text, "second"})

    ref = make_ref()

    on_exit(fn ->
      Process.delete({BackendCodexTestSupport, :public_websocket_text_queue, ref})
    end)

    assert {:ok, decoded_websocket, "first"} =
             BackendCodexTestSupport.decode_public_websocket_text(
               websocket,
               ref,
               [{:data, ref, first_data <> second_data}]
             )

    assert {nil, ^decoded_websocket, "second"} =
             public_websocket_receive_text!(nil, decoded_websocket, ref)
  end

  test "GET /v1/responses websocket relays a stateless programmatic replay and finalizes metadata-only" do
    upstream =
      start_upstream(
        FakeUpstream.delayed_sse_stream(programmatic_response_events(),
          done: false,
          interval_ms: 25
        )
      )

    setup = gateway_setup(upstream)
    assert :ok = Events.subscribe_pool(setup.pool)
    port = start_public_endpoint!()

    {conn, websocket, ref} =
      public_v1_websocket_connect!(
        port,
        setup,
        "task-6-programmatic-#{System.unique_integer([:positive])}"
      )

    try do
      {conn, websocket} =
        public_websocket_send_text!(
          conn,
          websocket,
          ref,
          Jason.encode!(programmatic_replay_payload(setup))
        )

      {conn, websocket, frames} = receive_websocket_until_terminal!(conn, websocket, ref, [])

      assert Enum.map(frames, & &1["type"]) == [
               "response.output_item.added",
               "response.output_item.added",
               "response.completed"
             ]

      streamed_item_types =
        frames
        |> Enum.filter(&(&1["type"] == "response.output_item.added"))
        |> Enum.map(&get_in(&1, ["item", "type"]))

      assert streamed_item_types == ["program", "function_call"]

      assert Enum.count(frames, &(&1["type"] == "response.completed")) == 1

      assert %{"response" => %{"output" => completed_output}} =
               Enum.find(frames, &(&1["type"] == "response.completed"))

      assert Enum.map(completed_output, & &1["type"]) == [
               "program",
               "function_call",
               "function_call_output",
               "program_output"
             ]

      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.method == "WEBSOCKET"
      assert captured.path == "/backend-api/codex/responses"
      assert captured.json["type"] == "response.create"
      assert captured.json["stream"] == true
      assert captured.json["store"] == false
      assert captured.json["generate"] == true

      assert Enum.map(captured.json["input"], & &1["type"]) == [
               "program",
               "function_call",
               "function_call_output",
               "program_output"
             ]

      assert get_in(captured.json, ["input", Access.at(1), "caller", "type"]) == "program"
      assert get_in(captured.json, ["input", Access.at(2), "caller", "type"]) == "direct"

      assert captured.json["tools"] |> Enum.map(& &1["type"]) == [
               "programmatic_tool_calling",
               "function"
             ]

      assert captured.json["tool_choice"]["type"] == "programmatic_tool_calling"

      assert get_in(captured.json, ["tools", Access.at(1), "allowed_callers"]) == [
               "direct",
               "programmatic"
             ]

      assert is_map(get_in(captured.json, ["tools", Access.at(1), "output_schema"]))

      assert_receive {Events,
                      %{
                        reason: "request_finalized",
                        payload: %{"status" => "succeeded"}
                      }},
                     @websocket_frame_timeout

      assert [request] =
               Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))

      assert request.endpoint == "/v1/responses"
      assert request.transport == "websocket"
      assert request.status == "succeeded"

      assert [attempt] =
               Repo.all(from(attempt in Attempt, where: attempt.request_id == ^request.id))

      assert attempt.transport == "websocket"
      assert attempt.status == "succeeded"

      assert Repo.aggregate(
               from(entry in LedgerEntry,
                 where: entry.request_id == ^request.id and entry.entry_kind == "settlement"
               ),
               :count
             ) == 1

      persistence_text =
        inspect(
          {request.request_metadata, attempt.response_metadata, RequestLogs.list(setup.pool)}
        )

      for sentinel <- programmatic_sentinels() do
        refute persistence_text =~ sentinel
      end

      {conn, websocket}
    after
      Mint.HTTP.close(conn)
    end
  end

  test "GET /v1/responses websocket forwards exact web search domain filters without external access" do
    tool = %{
      "type" => "web_search",
      "filters" => %{
        "allowed_domains" => [" Example.COM ", "example.com", "Example.COM"],
        "blocked_domains" => [" blocked.example ", "blocked.example", "blocked.example"]
      }
    }

    upstream =
      start_upstream(
        FakeUpstream.sse_stream(
          [
            {"response.completed",
             %{
               "type" => "response.completed",
               "response" => %{
                 "id" => "resp_v1_websocket_web_search_domain_filters",
                 "status" => "completed",
                 "output" => [],
                 "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}
               }
             }}
          ],
          done: false
        )
      )

    setup = gateway_setup(upstream)
    port = start_public_endpoint!()

    {conn, websocket, ref} =
      public_v1_websocket_connect!(
        port,
        setup,
        "web-search-filters-#{System.unique_integer([:positive])}"
      )

    try do
      {conn, websocket} =
        public_websocket_send_text!(
          conn,
          websocket,
          ref,
          Jason.encode!(%{
            "type" => "response.create",
            "model" => setup.model.exposed_model_id,
            "input" => "synthetic websocket filtered web search request",
            "stream" => false,
            "store" => true,
            "generate" => true,
            "tools" => [tool]
          })
        )

      {conn, websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

      assert %{
               "type" => "response.completed",
               "response" => %{"id" => "resp_v1_websocket_web_search_domain_filters"}
             } = Jason.decode!(frame)

      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.method == "WEBSOCKET"
      assert captured.path == "/backend-api/codex/responses"
      assert captured.json["tools"] == [tool]
      assert captured.json["stream"] == true
      assert captured.json["store"] == false
      refute Map.has_key?(hd(captured.json["tools"]), "external_web_access")

      {conn, websocket}
    after
      Mint.HTTP.close(conn)
    end
  end

  test "GET /v1/responses websocket forwards a custom definition and typed named choice exactly" do
    upstream = start_upstream(completed_websocket_response("resp_ws_custom_definition"))
    setup = gateway_setup(upstream)
    assert :ok = Events.subscribe_pool(setup.pool)
    port = start_public_endpoint!()

    custom_tool = %{
      "type" => "custom",
      "name" => "synthetic_custom_tool",
      "description" => "Synthetic grammar tool",
      "defer_loading" => true,
      "allowed_callers" => ["programmatic", "direct", "programmatic"],
      "format" => %{
        "type" => "grammar",
        "definition" => "start: SYNTHETIC\nSYNTHETIC: /synthetic-[0-9]+/",
        "syntax" => "lark"
      }
    }

    tool_choice = %{"type" => "custom", "name" => custom_tool["name"]}

    {conn, websocket, ref} =
      public_v1_websocket_connect!(
        port,
        setup,
        "custom-definition-#{System.unique_integer([:positive])}"
      )

    try do
      {conn, websocket} =
        send_response_create!(conn, websocket, ref, setup, %{
          "input" => "synthetic custom websocket input",
          "tools" => [custom_tool],
          "tool_choice" => tool_choice
        })

      {conn, websocket, frames} = receive_websocket_until_terminal!(conn, websocket, ref, [])
      assert Enum.map(frames, & &1["type"]) == ["response.completed"]

      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.method == "WEBSOCKET"
      assert captured.path == "/backend-api/codex/responses"
      assert captured.json["tools"] == [custom_tool]
      assert captured.json["tool_choice"] == tool_choice

      assert_successful_websocket_lifecycle!(setup)
      {conn, websocket}
    after
      Mint.HTTP.close(conn)
    end
  end

  test "GET /v1/responses websocket forwards repaired nested object and array schema nodes" do
    upstream = start_upstream(completed_websocket_response("resp_ws_nested_repair"))
    setup = gateway_setup(upstream)
    assert :ok = Events.subscribe_pool(setup.pool)
    port = start_public_endpoint!()

    parameters = repairable_nested_parameters()

    {conn, websocket, ref} =
      public_v1_websocket_connect!(
        port,
        setup,
        "nested-repair-#{System.unique_integer([:positive])}"
      )

    try do
      {conn, websocket} =
        send_response_create!(conn, websocket, ref, setup, %{
          "input" => "synthetic nested repair websocket input",
          "tools" => [
            %{
              "type" => "function",
              "name" => "repair_nested_fixture",
              "parameters" => parameters,
              "strict" => true
            }
          ]
        })

      {conn, websocket, frames} = receive_websocket_until_terminal!(conn, websocket, ref, [])
      assert Enum.map(frames, & &1["type"]) == ["response.completed"]

      assert [captured] = FakeUpstream.requests(upstream)
      assert [captured_tool] = captured.json["tools"]
      repaired = captured_tool["parameters"]

      assert get_in(repaired, ["properties", "config", "type"]) == "object"

      assert get_in(repaired, ["properties", "config", "properties", "entries", "type"]) ==
               "array"

      assert get_in(repaired, [
               "properties",
               "config",
               "properties",
               "entries",
               "items",
               "type"
             ]) == "object"

      assert repaired == repaired_nested_parameters()
      refute Map.has_key?(get_in(parameters, ["properties", "config"]), "type")

      assert_successful_websocket_lifecycle!(setup)
      {conn, websocket}
    after
      Mint.HTTP.close(conn)
    end
  end

  test "GET /v1/responses websocket rejects a malformed post-upgrade frame and recovers once" do
    upstream = start_upstream(completed_websocket_response("resp_ws_recovery_valid"))
    setup = gateway_setup(upstream)
    assert :ok = Events.subscribe_pool(setup.pool)
    port = start_public_endpoint!()

    {conn, websocket, ref} =
      public_v1_websocket_connect!(
        port,
        setup,
        "malformed-recovery-#{System.unique_integer([:positive])}"
      )

    try do
      post_upgrade_baseline = lifecycle_counts(upstream)

      {conn, websocket} =
        send_response_create!(conn, websocket, ref, setup, %{
          "input" => "synthetic malformed websocket input",
          "tools" => [
            %{
              "type" => "custom",
              "name" => "invalid_custom_fixture",
              "format" => %{"type" => "text", "unexpected" => true}
            }
          ]
        })

      {conn, websocket, error_frame} = public_websocket_receive_text!(conn, websocket, ref)

      assert %{
               "type" => "error",
               "status" => 400,
               "error" => %{
                 "type" => "invalid_request_error",
                 "code" => "invalid_request",
                 "param" => "tools"
               }
             } = Jason.decode!(error_frame)

      assert lifecycle_counts(upstream) == post_upgrade_baseline
      refute_received {Events, %{reason: "request_finalized"}}

      {conn, websocket} =
        send_response_create!(conn, websocket, ref, setup, %{
          "input" => "synthetic valid recovery websocket input"
        })

      {conn, websocket, frames} = receive_websocket_until_terminal!(conn, websocket, ref, [])
      assert Enum.map(frames, & &1["type"]) == ["response.completed"]

      assert_successful_websocket_lifecycle!(setup)

      assert_lifecycle_delta!(post_upgrade_baseline, lifecycle_counts(upstream), %{
        upstream_requests: 1,
        requests: 1,
        attempts: 1,
        ledger_entries: 3,
        turns: 1,
        reservations: 1,
        settlements: 1,
        idempotency_keys: 0
      })

      {conn, websocket}
    after
      Mint.HTTP.close(conn)
    end
  end

  test "GET /v1/responses websocket rejects malformed caller, tool, and program output before dispatch" do
    upstream =
      start_upstream(FakeUpstream.sse_stream(programmatic_response_events(), done: false))

    setup = gateway_setup(upstream)
    assert :ok = Events.subscribe_pool(setup.pool)
    port = start_public_endpoint!()

    {conn, websocket, ref} =
      public_v1_websocket_connect!(
        port,
        setup,
        "task-6-malformed-#{System.unique_integer([:positive])}"
      )

    try do
      {conn, websocket} =
        Enum.reduce(malformed_programmatic_payloads(setup), {conn, websocket}, fn payload,
                                                                                  {conn,
                                                                                   websocket} ->
          post_upgrade_baseline = lifecycle_counts(upstream)

          {conn, websocket} =
            public_websocket_send_text!(conn, websocket, ref, Jason.encode!(payload))

          {conn, websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

          assert %{"type" => "error", "status" => 400, "error" => error} = Jason.decode!(frame)
          assert error["code"] == "invalid_request"
          assert error["param"] in ["input", "tools"]
          assert lifecycle_counts(upstream) == post_upgrade_baseline
          refute_received {Events, %{reason: "request_finalized"}}
          {conn, websocket}
        end)

      {conn, websocket}
    after
      Mint.HTTP.close(conn)
    end
  end

  test "GET /v1/responses websocket rejects reserved metadata before dispatch" do
    upstream =
      start_upstream(FakeUpstream.sse_stream(programmatic_response_events(), done: false))

    setup = gateway_setup(upstream)
    assert :ok = Events.subscribe_pool(setup.pool)
    port = start_public_endpoint!()

    {conn, websocket, ref} =
      public_v1_websocket_connect!(
        port,
        setup,
        "task-14-reserved-metadata-#{System.unique_integer([:positive])}"
      )

    try do
      post_upgrade_baseline = lifecycle_counts(upstream)

      {conn, websocket} =
        public_websocket_send_text!(
          conn,
          websocket,
          ref,
          Jason.encode!(%{
            "type" => "response.create",
            "model" => setup.model.exposed_model_id,
            "input" => [
              %{
                "type" => "function_call_output",
                "call_id" => "call_task_14_reserved_metadata",
                "output" => "synthetic task 14 output",
                "internal_chat_message_metadata_passthrough" => %{
                  "executed_tool_calls" => "TASK14_RESERVED_METADATA_SENTINEL"
                }
              }
            ],
            "stream" => true
          })
        )

      {conn, websocket, error_frame} = public_websocket_receive_text!(conn, websocket, ref)

      assert %{
               "type" => "error",
               "status" => 400,
               "error" => %{"code" => "invalid_request", "param" => "input"}
             } = Jason.decode!(error_frame)

      assert lifecycle_counts(upstream) == post_upgrade_baseline
      refute_received {Events, %{reason: "request_finalized"}}

      persistence_text = inspect(RequestLogs.list(setup.pool))

      refute error_frame =~ "internal_chat_message_metadata_passthrough"
      refute error_frame =~ "TASK14_RESERVED_METADATA_SENTINEL"
      refute persistence_text =~ "internal_chat_message_metadata_passthrough"
      refute persistence_text =~ "TASK14_RESERVED_METADATA_SENTINEL"

      {conn, websocket}
    after
      Mint.HTTP.close(conn)
    end
  end

  test "direct GET /v1/responses drops malformed and non-object provider frames" do
    assert_invalid_provider_frames_dropped(false)
  end

  test "owner-forwarded GET /v1/responses drops malformed and non-object provider frames" do
    assert_invalid_provider_frames_dropped(true)
  end

  test "owner-forwarded GET /v1/responses emits one safe interruption after visible output" do
    enable_owner_forwarding!()

    visible_event =
      {"response.output_text.delta",
       %{"type" => "response.output_text.delta", "delta" => "synthetic visible output"}}

    upstream =
      start_upstream(
        FakeUpstream.websocket_sse_then_close([visible_event],
          code: 1001,
          reason: "synthetic interrupted stream"
        )
      )

    setup = gateway_setup(upstream)
    assert :ok = Events.subscribe_pool(setup.pool)
    port = start_public_endpoint!()

    {conn, websocket, ref} =
      public_v1_websocket_connect!(
        port,
        setup,
        "w2-interruption-#{System.unique_integer([:positive])}"
      )

    try do
      {conn, websocket} =
        public_websocket_send_text!(
          conn,
          websocket,
          ref,
          Jason.encode!(%{
            "type" => "response.create",
            "model" => setup.model.exposed_model_id,
            "input" => "synthetic interruption input",
            "stream" => true
          })
        )

      {conn, websocket, visible_frame} =
        public_websocket_receive_text!(conn, websocket, ref)

      assert Jason.decode!(visible_frame)["type"] == "response.output_text.delta"

      {conn, websocket, error_frame} =
        public_websocket_receive_text!(conn, websocket, ref)

      assert Jason.decode!(error_frame) == %{
               "type" => "error",
               "status" => 502,
               "error" => %{
                 "type" => "invalid_request_error",
                 "code" => "server_error",
                 "message" =>
                   "upstream request failed: stream interrupted before terminal response event",
                 "param" => nil
               }
             }

      assert_receive {Events,
                      %{
                        reason: "request_finalized",
                        payload: %{"status" => "failed"}
                      }},
                     @websocket_frame_timeout

      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.method == "WEBSOCKET"

      assert [request] =
               Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))

      assert request.endpoint == "/v1/responses"
      assert request.transport == "websocket"
      assert request.status == "failed"
      assert request.last_error_code == "upstream_stream_error"

      assert [attempt] =
               Repo.all(from(attempt in Attempt, where: attempt.request_id == ^request.id))

      assert attempt.transport == "websocket"
      assert attempt.status == "failed"
      assert attempt.network_error_code == "upstream_stream_error"

      {conn, websocket}
    after
      Mint.HTTP.close(conn)
    end
  end

  defp public_v1_websocket_connect!(port, setup, turn_state) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])

    headers = [
      {"authorization", setup.authorization},
      {"x-codex-turn-state", turn_state},
      {"openai-beta", "responses_websockets=2026-02-06"}
    ]

    {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, "/v1/responses", headers)
    {:ok, conn, status, response_headers} = await_public_websocket_upgrade(conn, ref)
    {conn, websocket} = mint_websocket_new!(conn, ref, status, response_headers)
    {conn, websocket, ref}
  end

  defp send_response_create!(conn, websocket, ref, setup, attrs) do
    payload =
      Map.merge(
        %{
          "type" => "response.create",
          "model" => setup.model.exposed_model_id,
          "stream" => false,
          "store" => true,
          "generate" => true
        },
        attrs
      )

    public_websocket_send_text!(conn, websocket, ref, Jason.encode!(payload))
  end

  defp completed_websocket_response(response_id) do
    FakeUpstream.sse_stream(
      [
        {"response.completed",
         %{
           "type" => "response.completed",
           "response" => %{
             "id" => response_id,
             "status" => "completed",
             "output" => [],
             "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}
           }
         }}
      ],
      done: false
    )
  end

  defp assert_successful_websocket_lifecycle!(setup) do
    assert_receive {Events,
                    %{
                      reason: "request_finalized",
                      payload: %{"status" => "succeeded"}
                    }},
                   @websocket_frame_timeout

    assert [request] =
             Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))

    assert request.endpoint == "/v1/responses"
    assert request.transport == "websocket"
    assert request.status == "succeeded"

    assert [attempt] =
             Repo.all(from(attempt in Attempt, where: attempt.request_id == ^request.id))

    assert attempt.transport == "websocket"
    assert attempt.status == "succeeded"

    assert Repo.aggregate(
             from(entry in LedgerEntry,
               where: entry.request_id == ^request.id and entry.entry_kind == "settlement"
             ),
             :count
           ) == 1
  end

  defp lifecycle_counts(upstream) do
    %{
      upstream_requests: FakeUpstream.count(upstream),
      requests: Repo.aggregate(Request, :count),
      attempts: Repo.aggregate(Attempt, :count),
      ledger_entries: Repo.aggregate(LedgerEntry, :count),
      turns: Repo.aggregate(CodexTurn, :count),
      reservations: ledger_entry_count("reservation"),
      settlements: ledger_entry_count("settlement"),
      idempotency_keys: Repo.aggregate(IdempotencyKey, :count),
      sessions: Repo.aggregate(CodexSession, :count),
      owner_leases: Repo.aggregate(BridgeOwnerLease, :count),
      session_aliases: Repo.aggregate(BridgeSessionAlias, :count)
    }
  end

  defp ledger_entry_count(entry_kind) do
    Repo.aggregate(from(entry in LedgerEntry, where: entry.entry_kind == ^entry_kind), :count)
  end

  defp lifecycle_delta(before_counts, after_counts) do
    Map.new(after_counts, fn {key, after_count} ->
      {key, after_count - Map.fetch!(before_counts, key)}
    end)
  end

  defp assert_lifecycle_delta!(before_counts, after_counts, expected_delta) do
    actual_delta = lifecycle_delta(before_counts, after_counts)

    Enum.each(expected_delta, fn {key, expected_count} ->
      actual_count = Map.fetch!(actual_delta, key)

      assert actual_count == expected_count,
             "unexpected lifecycle delta for #{key}: expected #{expected_count}, got #{actual_count}"
    end)
  end

  defp assert_invalid_provider_frames_dropped(owner_forwarding?) do
    if owner_forwarding?, do: enable_owner_forwarding!()

    completion =
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => "resp_after_invalid_frames", "status" => "completed"}
      })

    invalid_frames = ["{", Jason.encode!("string"), Jason.encode!([]), Jason.encode!(42), "null"]
    upstream = start_upstream(FakeUpstream.websocket_text_frames(invalid_frames ++ [completion]))
    setup = gateway_setup(upstream)
    assert :ok = Events.subscribe_pool(setup.pool)
    port = start_public_endpoint!()

    {conn, websocket, ref} =
      public_v1_websocket_connect!(
        port,
        setup,
        "h8-invalid-provider-#{System.unique_integer([:positive])}"
      )

    try do
      {conn, websocket} =
        public_websocket_send_text!(
          conn,
          websocket,
          ref,
          Jason.encode!(%{
            "type" => "response.create",
            "model" => setup.model.exposed_model_id,
            "input" => "synthetic invalid provider frame input",
            "stream" => true
          })
        )

      {conn, websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)

      assert %{
               "type" => "response.completed",
               "sequence_number" => 0,
               "response" => %{"status" => "completed"}
             } = Jason.decode!(frame)

      assert_receive {Events,
                      %{
                        reason: "request_finalized",
                        payload: %{"status" => "succeeded"}
                      }},
                     @websocket_frame_timeout

      assert [request] =
               Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))

      assert request.status == "succeeded"
      assert is_nil(request.last_error_code)

      assert [attempt] =
               Repo.all(from(attempt in Attempt, where: attempt.request_id == ^request.id))

      assert attempt.status == "succeeded"
      assert is_nil(attempt.network_error_code)

      {conn, websocket}
    after
      Mint.HTTP.close(conn)
    end
  end

  defp enable_owner_forwarding! do
    previous = Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    on_exit(fn ->
      stop_registered_websocket_owner_sessions()

      case previous do
        nil -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
        value -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
      end
    end)
  end

  defp stop_registered_websocket_owner_sessions do
    capture_log(fn ->
      WebsocketOwnerSession.Registry
      |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
      |> Enum.each(&stop_registered_websocket_owner_session/1)
    end)
  end

  defp stop_registered_websocket_owner_session(session_id) do
    case WebsocketOwnerSession.lookup(session_id) do
      {:ok, owner_pid} -> GenServer.stop(owner_pid, :shutdown, 1_000)
      _other -> :ok
    end
  end

  defp receive_websocket_until_terminal!(conn, websocket, ref, frames) do
    {conn, websocket, frame} = public_websocket_receive_text!(conn, websocket, ref)
    decoded = Jason.decode!(frame)
    frames = [decoded | frames]

    if decoded["type"] == "response.completed" do
      {conn, websocket, Enum.reverse(frames)}
    else
      receive_websocket_until_terminal!(conn, websocket, ref, frames)
    end
  end

  defp programmatic_replay_payload(setup) do
    %{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "stream" => false,
      "store" => true,
      "generate" => true,
      "input" => programmatic_input_items(),
      "tools" => [
        %{"type" => "programmatic_tool_calling"},
        %{
          "type" => "function",
          "name" => "lookup_fixture",
          "parameters" => %{"type" => "object", "properties" => %{}},
          "allowed_callers" => ["direct", "programmatic"],
          "output_schema" => %{"$id" => "TASK6_SCHEMA_SENTINEL", "type" => "object"}
        }
      ],
      "tool_choice" => %{"type" => "programmatic_tool_calling"}
    }
  end

  defp programmatic_input_items do
    [
      %{
        "type" => "program",
        "id" => "TASK6_PROGRAM_ID_SENTINEL",
        "call_id" => "TASK6_PROGRAM_CALL_ID_SENTINEL",
        "code" => "TASK6_CODE_SENTINEL",
        "fingerprint" => "TASK6_FINGERPRINT_SENTINEL"
      },
      %{
        "type" => "function_call",
        "id" => "TASK6_FUNCTION_ID_SENTINEL",
        "call_id" => "TASK6_FUNCTION_CALL_ID_SENTINEL",
        "name" => "lookup_fixture",
        "arguments" => "{}",
        "caller" => %{"type" => "program", "caller_id" => "TASK6_CALLER_ID_SENTINEL"}
      },
      %{
        "type" => "function_call_output",
        "id" => "TASK6_FUNCTION_OUTPUT_ID_SENTINEL",
        "call_id" => "TASK6_FUNCTION_CALL_ID_SENTINEL",
        "output" => "TASK6_FRAME_SENTINEL",
        "caller" => %{"type" => "direct"}
      },
      %{
        "type" => "program_output",
        "id" => "TASK6_PROGRAM_OUTPUT_ID_SENTINEL",
        "call_id" => "TASK6_PROGRAM_CALL_ID_SENTINEL",
        "result" => "TASK6_RESULT_SENTINEL",
        "status" => "completed"
      }
    ]
  end

  defp programmatic_response_events do
    programmatic_input_items()
    |> Enum.take(2)
    |> Enum.with_index()
    |> Enum.map(fn {item, output_index} ->
      {"response.output_item.added",
       %{
         "type" => "response.output_item.added",
         "output_index" => output_index,
         "item" => item
       }}
    end)
    |> Kernel.++([
      {"response.completed",
       %{
         "type" => "response.completed",
         "response" => %{
           "id" => "TASK6_RESPONSE_ID_SENTINEL",
           "status" => "completed",
           "output" => programmatic_input_items(),
           "usage" => %{"input_tokens" => 4, "output_tokens" => 4, "total_tokens" => 8}
         }
       }}
    ])
  end

  defp malformed_programmatic_payloads(setup) do
    base = programmatic_replay_payload(setup)

    [
      put_in(base, ["input", Access.at(1), "caller"], %{"type" => "program"}),
      put_in(base, ["input", Access.at(3), "status"], "invalid-status"),
      put_in(base, ["tools", Access.at(0)], %{
        "type" => "programmatic_tool_calling",
        "extra" => "TASK6_MALFORMED_TOOL_SENTINEL"
      })
    ]
  end

  defp programmatic_sentinels do
    ~w(
      TASK6_CODE_SENTINEL
      TASK6_RESULT_SENTINEL
      TASK6_FINGERPRINT_SENTINEL
      TASK6_SCHEMA_SENTINEL
      TASK6_PROGRAM_ID_SENTINEL
      TASK6_PROGRAM_CALL_ID_SENTINEL
      TASK6_FUNCTION_ID_SENTINEL
      TASK6_FUNCTION_CALL_ID_SENTINEL
      TASK6_FUNCTION_OUTPUT_ID_SENTINEL
      TASK6_PROGRAM_OUTPUT_ID_SENTINEL
      TASK6_CALLER_ID_SENTINEL
      TASK6_FRAME_SENTINEL
      TASK6_RESPONSE_ID_SENTINEL
    )
  end

  defp repairable_nested_parameters do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "config" => %{
          "additionalProperties" => false,
          "properties" => %{
            "entries" => %{
              "items" => %{
                "additionalProperties" => false,
                "properties" => %{"value" => %{"type" => "string"}},
                "required" => ["value"]
              }
            }
          },
          "required" => ["entries"]
        }
      },
      "required" => ["config"]
    }
  end

  defp repaired_nested_parameters do
    repairable_nested_parameters()
    |> put_in(["properties", "config", "type"], "object")
    |> put_in(["properties", "config", "properties", "entries", "type"], "array")
    |> put_in(
      ["properties", "config", "properties", "entries", "items", "type"],
      "object"
    )
  end
end
