defmodule CodexPooler.Gateway.Payloads.RequestOptionsTest do
  use ExUnit.Case, async: false

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.RouteClass

  setup do
    previous_settings = Application.get_env(:codex_pooler, OperationalSettings)

    on_exit(fn ->
      if previous_settings do
        Application.put_env(:codex_pooler, OperationalSettings, previous_settings)
      else
        Application.delete_env(:codex_pooler, OperationalSettings)
      end
    end)
  end

  describe "boundary constructors" do
    test "from_conn_metadata keeps request metadata and classifies payload routes" do
      options =
        RequestOptions.from_conn_metadata(
          %{
            request_id: "req_conn",
            client_ip: {127, 0, 0, 1},
            forwarded_headers: [{"x-codex-client", "fixture"}]
          },
          "/backend-api/codex/responses",
          %{"model" => "example-model", "stream" => true}
        )

      assert options.request_metadata.request_id == "req_conn"
      assert options.request_metadata.client_ip == {127, 0, 0, 1}
      assert options.transport.route_class == "proxy_stream"
      assert options.transport.forwarded_metadata_headers == [{"x-codex-client", "fixture"}]
      assert options.file_bridge.forwarded_headers == [{"x-codex-client", "fixture"}]
      assert options.extra == %{}
    end

    test "for_websocket retargets typed options without caller-side transport maps" do
      options =
        %{request_id: "req_ws"}
        |> RequestOptions.from_conn_metadata("/v1/responses", %{})
        |> RequestOptions.put_continuity(previous_response_id: "resp_123")
        |> RequestOptions.for_websocket()

      assert options.request_metadata.request_id == "req_ws"
      assert options.continuity.previous_response_id == "resp_123"
      assert options.transport.transport == "websocket"
      assert options.transport.upstream_endpoint == "/backend-api/codex/responses"
      assert options.transport.route_class == "proxy_websocket"
    end

    test "keeps local alias provenance separate from live websocket continuity" do
      options =
        %{
          session_header: "local-session",
          session_header_source: "X-Session-Affinity",
          upstream_websocket_session: self(),
          websocket_owner_forwarding_enabled?: true,
          websocket_owner_session: %{id: "owner-session"},
          websocket_owner_lease_token: "lease-token",
          websocket_owner_downstream: %{pid: self(), correlation_id: "corr"},
          websocket_owner_downstream_epoch: 2
        }
        |> RequestOptions.from_conn_metadata("/backend-api/codex/responses", %{
          "model" => "example-model",
          "stream" => true
        })

      assert options.continuity.session_header == "local-session"
      assert options.continuity.session_header_source == "x-session-affinity"
      assert options.transport.upstream_websocket_session == self()
      assert options.transport.websocket_owner_forwarding_enabled?
      assert options.transport.websocket_owner_session == %{id: "owner-session"}

      assert options.transport.websocket_owner_downstream == %{
               pid: self(),
               correlation_id: "corr"
             }

      assert options.transport.websocket_owner_downstream_epoch == 2
      assert options.extra == %{}
    end

    test "for_file_bridge applies narrow route and bridge updates" do
      options =
        RequestOptions.for_file_bridge(
          %{
            request_id: "req_file",
            forwarded_headers: [
              {"x-codex-client", "fixture"},
              {"x-codex-bad", :invalid}
            ]
          },
          "/v1/files",
          %{},
          route_class: RouteClass.file_upload(),
          operation: :create,
          endpoint: "/backend-api/files",
          route_metadata: %{"routing_strategy" => "affinity"}
        )

      assert options.request_metadata.request_id == "req_file"
      assert options.transport.route_class == "file_upload"
      assert options.transport.forwarded_metadata_headers == [{"x-codex-client", "fixture"}]
      assert options.file_bridge.operation == :create
      assert options.file_bridge.endpoint == "/backend-api/files"
      assert options.file_bridge.route_metadata == %{"routing_strategy" => "affinity"}
      assert options.file_bridge.forwarded_headers == [{"x-codex-client", "fixture"}]
    end
  end

  describe "build/3" do
    test "records inferred JSON request byte counts as numeric metadata" do
      payload = %{"model" => "example-model", "input" => "synthetic prompt"}

      options = RequestOptions.build(%{}, "/backend-api/codex/responses", payload)

      assert options.request_metadata.request_bytes == RequestOptions.json_request_bytes(payload)
      assert is_integer(options.request_metadata.request_bytes)
      refute inspect(options.request_metadata) =~ "synthetic prompt"
    end

    test "keeps explicit request byte counts from the caller" do
      options =
        RequestOptions.build(
          %{request_bytes: 123, upload_bytes: 456},
          "/backend-api/transcribe",
          %{"model" => "example-model"}
        )

      assert options.request_metadata.request_bytes == 123
      assert options.request_metadata.upload_bytes == 456
    end

    test "keeps gateway runtime context in typed fields" do
      writer = fn _frame -> :ok end
      circuit_state = %{id: "state"}
      chat_payload = %{"model" => "example-model", "messages" => []}
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      options =
        RequestOptions.build(
          %{
            now: now,
            reason: "client_disconnected",
            transport: "websocket",
            websocket_writer: writer,
            upstream_websocket_session: self(),
            session_key: "session-key",
            conversation_key: "conversation-key",
            owner_instance_id: "node-a",
            bridge_owner_lease_ttl_seconds: 120,
            reconnect_window_seconds: 30,
            quota_decision: %{"summary" => "allowed"},
            routing_attempt_metadata: %{"rank" => 1},
            routing_circuit_state: circuit_state,
            public_openai_chat_stream: true,
            collect_openai_response_stream: true,
            openai_chat_payload: chat_payload,
            defer_file_create_request: true,
            finalize_retry_timeout_ms: 1000,
            finalize_retry_interval_ms: 0,
            receive_timeout_ms: 25_000
          },
          "/backend-api/codex/responses",
          %{"model" => "example-model"}
        )

      assert options.transport.websocket_writer == writer
      assert options.transport.upstream_websocket_session == self()
      assert options.continuity.session_key == "session-key"
      assert options.continuity.session_header_source == nil
      assert options.continuity.conversation_key == "conversation-key"
      assert options.continuity.owner_instance_id == "node-a"
      assert options.continuity.bridge_owner_lease_ttl_seconds == 120
      assert options.continuity.reconnect_window_seconds == 30
      assert options.routing.quota_decision == %{"summary" => "allowed"}
      assert options.routing.routing_attempt_metadata == %{"rank" => 1}
      assert options.routing.routing_circuit_state == circuit_state
      assert options.openai_compatibility.public_openai_chat_stream
      assert options.openai_compatibility.collect_openai_response_stream
      assert options.openai_compatibility.openai_chat_payload == chat_payload
      assert options.file_bridge.defer_create_request
      assert options.file_bridge.finalize_retry_timeout_ms == 1000
      assert options.file_bridge.finalize_retry_interval_ms == 0
      assert options.runtime.now == now
      assert options.runtime.interrupt_reason == "client_disconnected"
      assert options.timeout_config.receive_timeout_ms == 25_000
      assert options.extra == %{}
    end

    test "normalizes explicit interrupt reason without keeping legacy aliases in extra" do
      options =
        RequestOptions.build(
          %{interrupt_reason: "operator_closed", reason: "client_disconnected"},
          "/backend-api/codex/responses",
          %{"model" => "example-model"}
        )

      assert options.runtime.interrupt_reason == "operator_closed"
      assert options.extra == %{}
    end

    test "keeps usage authentication inputs typed and out of extra opts" do
      options =
        RequestOptions.build(
          %{
            authorization_header: "Bearer secret-token",
            chatgpt_account_id: "acct_usage_boundary"
          },
          "/api/codex/usage",
          %{}
        )

      assert options.usage_authentication.authorization_header == "Bearer secret-token"
      assert options.usage_authentication.chatgpt_account_id == "acct_usage_boundary"
      assert options.extra == %{}
    end

    test "keeps hashed prompt cache routing hints only for the exact routing allowlist" do
      allowed_routes = [
        "/v1/responses",
        "/v1/chat/completions",
        "/backend-api/codex/responses",
        "/backend-api/codex/v1/responses",
        "/backend-api/codex/v1/chat/completions"
      ]

      for endpoint <- allowed_routes do
        raw_prompt_cache_key = "  fixture-cache-key  "

        options =
          RequestOptions.build(
            %{request_method: "POST"},
            endpoint,
            %{"model" => "example-model", "prompt_cache_key" => raw_prompt_cache_key}
          )

        assert options.routing.prompt_cache_key == prompt_cache_key_hash("fixture-cache-key")
        assert options.routing.prompt_cache_key =~ ~r/\A[0-9a-f]{64}\z/
        refute options.routing.prompt_cache_key == raw_prompt_cache_key
        refute inspect(options.routing) =~ raw_prompt_cache_key
        assert options.extra == %{}
      end
    end

    test "canonicalizes prompt cache routing hints before hashing" do
      trimmed =
        RequestOptions.build(
          %{request_method: "POST"},
          "/backend-api/codex/responses",
          %{"model" => "example-model", "prompt_cache_key" => "fixture-cache-key"}
        )

      padded =
        RequestOptions.build(
          %{request_method: "POST"},
          "/backend-api/codex/responses",
          %{"model" => "example-model", "prompt_cache_key" => "  fixture-cache-key\n"}
        )

      assert trimmed.routing.prompt_cache_key == padded.routing.prompt_cache_key
      assert trimmed.routing.prompt_cache_key == prompt_cache_key_hash("fixture-cache-key")
    end

    test "treats blank and non-string prompt cache keys as absent" do
      for value <- ["", "   ", 123, true, nil, %{"unsafe" => "shape"}] do
        options =
          RequestOptions.build(
            %{request_method: "POST"},
            "/backend-api/codex/responses",
            %{"model" => "example-model", "prompt_cache_key" => value}
          )

        assert options.routing.prompt_cache_key == nil
        assert options.extra == %{}
      end
    end

    test "treats oversized prompt cache keys as absent" do
      oversized_key = "oversized-cache-key-" <> String.duplicate("x", 257)

      options =
        RequestOptions.build(
          %{request_method: "POST"},
          "/backend-api/codex/responses",
          %{"model" => "example-model", "prompt_cache_key" => oversized_key}
        )

      assert options.routing.prompt_cache_key == nil
      refute inspect(options.routing) =~ oversized_key
      assert options.extra == %{}
    end

    test "consumes raw prompt cache option keys without using them as routing input" do
      options =
        RequestOptions.build(
          %{
            "prompt_cache_key" => "string-opt-cache-key",
            prompt_cache_key: "atom-opt-cache-key"
          },
          "/backend-api/codex/responses",
          %{"model" => "example-model"}
        )

      assert options.routing.prompt_cache_key == nil
      assert options.extra == %{}
    end

    test "excludes prompt cache routing input from negative route surfaces" do
      negative_routes = [
        {"GET", "/backend-api/codex/responses", %{transport: "websocket"}},
        {"POST", "/backend-api/codex/responses/compact", %{}},
        {"POST", "/backend-api/codex/v1/responses/compact", %{}},
        {"POST", "/v1/responses/compact", %{}},
        {"POST", "/backend-api/files", %{}},
        {"POST", "/backend-api/files/file_fixture/uploaded", %{}},
        {"POST", "/backend-api/transcribe", %{}},
        {"POST", "/v1/audio/transcriptions", %{}},
        {"POST", "/v1/images/generations", %{}},
        {"POST", "/v1/images/edits", %{}},
        {"POST", "/backend-api/codex/images/generations", %{}},
        {"POST", "/backend-api/codex/images/edits", %{}}
      ]

      for {method, endpoint, opts} <- negative_routes do
        options =
          opts
          |> Map.put(:request_method, method)
          |> RequestOptions.build(endpoint, %{
            "model" => "example-model",
            "prompt_cache_key" => "fixture-cache-key"
          })

        assert options.routing.prompt_cache_key == nil
        assert options.extra == %{}
      end
    end

    test "websocket retargeting clears prompt cache routing input" do
      options =
        %{request_method: "POST"}
        |> RequestOptions.build("/backend-api/codex/responses", %{
          "model" => "example-model",
          "prompt_cache_key" => "fixture-cache-key"
        })
        |> RequestOptions.for_websocket(%{
          "model" => "example-model",
          "prompt_cache_key" => "fixture-cache-key"
        })

      assert options.transport.transport == "websocket"
      assert options.transport.route_class == "proxy_websocket"
      assert options.routing.prompt_cache_key == nil
    end

    test "keeps every consumed option key out of extra opts" do
      writer = fn _frame -> :ok end
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      codex_session = %{id: "session-id"}
      codex_turn_id = Ecto.UUID.generate()

      options =
        RequestOptions.build(
          %{
            "authorization_header" => "Bearer string-token",
            "chatgpt_account_id" => "acct_string",
            "prompt_cache_key" => "string-opt-cache-key",
            "transport" => "http_json",
            accepted_turn_state: "turn-state",
            authenticated_owner_attach: true,
            api_key_policy: %{allowed_model_identifiers: ["example-model"]},
            authorization_header: "Bearer atom-token",
            bridge_owner_lease_ttl_seconds: 30,
            chatgpt_account_id: "acct_atom",
            client_ip: "127.0.0.1",
            codex_session: codex_session,
            codex_turn_id: codex_turn_id,
            collect_openai_image_stream: true,
            collect_openai_response_stream: true,
            connect_timeout: 10,
            connect_timeout_ms: 11,
            conversation_key: "conversation-key",
            defer_file_create_request: true,
            effective_model: "example-model",
            file_affinity_assignment_id: Ecto.UUID.generate(),
            file_bridge_endpoint: "/backend-api/files",
            file_bridge_operation: :create,
            file_bridge_route_metadata: %{"route" => "file"},
            finalize_retry_interval_ms: 0,
            finalize_retry_timeout_ms: 500,
            forced_transcription_model: "gpt-4o-transcribe",
            forwarded_headers: [{"x-codex-client", "fixture"}],
            gateway_debug_payload: %{"shape" => "safe"},
            idempotency_key: "idem-key",
            interrupt_reason: "operator_closed",
            media_upload: %{size: 10},
            now: now,
            openai_chat_payload: %{"stream" => false},
            owner_instance_id: "owner-node",
            pool_timeout: 12,
            pool_timeout_ms: 13,
            pool_upstream_assignment_id: Ecto.UUID.generate(),
            previous_response_id: "resp_prev",
            prompt_cache_key: "atom-opt-cache-key",
            public_openai_chat_stream: true,
            public_openai_responses_stream: true,
            quota_decision: %{"summary" => "allowed"},
            reason: "legacy_reason",
            receive_timeout: 14,
            receive_timeout_ms: 15,
            reconnect_window_seconds: 5,
            request_bytes: 123,
            request_content_type: "application/json",
            request_id: "req-known",
            requested_model: "example-model",
            response_id: "resp_current",
            routing_attempt_metadata: %{"rank" => 1},
            routing_circuit_state: %{state: "closed"},
            session_header: "session-header",
            session_header_source: "session-id",
            session_key: "session-key",
            timeout: 16,
            transport: "websocket",
            unknown_fixture: true,
            upload_bytes: 456,
            upstream_endpoint: "/backend-api/codex/responses",
            upstream_identity_id: Ecto.UUID.generate(),
            upstream_websocket_session: self(),
            user_agent: "codex-test",
            websocket_owner_downstream: %{pid: self()},
            websocket_owner_downstream_epoch: 1,
            websocket_owner_forwarder_opts: [timeout: 100],
            websocket_owner_forwarding_enabled?: true,
            websocket_owner_instance_id: "owner-node",
            websocket_owner_lease_token: "lease-token",
            websocket_owner_proxy_instance_id: "proxy-node",
            websocket_owner_session: %{id: "owner-session"},
            websocket_writer: writer
          },
          "/backend-api/codex/responses",
          %{"model" => "example-model"}
        )

      assert options.continuity.authenticated_owner_attach
      assert options.continuity.session_header_source == "session-id"
      assert options.extra == %{unknown_fixture: true}
    end

    test "normalizes session header provenance to the compatibility allowlist" do
      assert %{continuity: %{session_header_source: "x-codex-window-id"}} =
               RequestOptions.build(
                 %{session_header: "window-session", session_header_source: "X-Codex-Window-ID"},
                 "/backend-api/codex/responses",
                 %{"model" => "example-model"}
               )

      assert %{continuity: %{session_header_source: "session-id"}} =
               RequestOptions.build(
                 %{session_header: "local-session", session_header_source: "Session-ID"},
                 "/backend-api/codex/responses",
                 %{"model" => "example-model"}
               )

      assert %{continuity: %{session_header_source: "x-session-affinity"}} =
               RequestOptions.build(
                 %{session_header: "affinity", session_header_source: :"x-session-affinity"},
                 "/backend-api/codex/responses",
                 %{"model" => "example-model"}
               )

      assert %{continuity: %{session_header_source: nil}} =
               RequestOptions.build(
                 %{session_header: "local-session", session_header_source: "x-unsafe-header"},
                 "/backend-api/codex/responses",
                 %{"model" => "example-model"}
               )
    end

    test "uses operational settings for upstream timeout defaults" do
      Application.put_env(:codex_pooler, OperationalSettings,
        settings: %OperationalSettings{
          upstream_connect_timeout_ms: 101,
          upstream_pool_timeout_ms: 202,
          upstream_receive_timeout_ms: 303
        }
      )

      options =
        RequestOptions.build(%{}, "/backend-api/codex/responses", %{"model" => "example-model"})

      assert options.timeout_config.connect_timeout_ms == 101
      assert options.timeout_config.pool_timeout_ms == 202
      assert options.timeout_config.receive_timeout_ms == 303
    end

    test "keeps explicit request timeouts ahead of operational defaults" do
      Application.put_env(:codex_pooler, OperationalSettings,
        settings: %OperationalSettings{
          upstream_connect_timeout_ms: 101,
          upstream_pool_timeout_ms: 202,
          upstream_receive_timeout_ms: 303
        }
      )

      options =
        RequestOptions.build(
          %{timeout: 10, connect_timeout_ms: 20, receive_timeout: 30},
          "/backend-api/codex/responses",
          %{"model" => "example-model"}
        )

      assert options.timeout_config.connect_timeout_ms == 20
      assert options.timeout_config.pool_timeout_ms == 10
      assert options.timeout_config.receive_timeout_ms == 30
    end

    test "ignores invalid legacy timeout values" do
      Application.put_env(:codex_pooler, OperationalSettings,
        settings: %OperationalSettings{
          upstream_connect_timeout_ms: 101,
          upstream_pool_timeout_ms: 202,
          upstream_receive_timeout_ms: 303
        }
      )

      options =
        RequestOptions.build(
          %{
            timeout: "30000",
            connect_timeout: -1,
            connect_timeout_ms: 0,
            pool_timeout: -5,
            receive_timeout: "slow",
            receive_timeout_ms: -30
          },
          "/backend-api/codex/responses",
          %{"model" => "example-model"}
        )

      assert options.timeout_config.connect_timeout_ms == 0
      assert options.timeout_config.pool_timeout_ms == 202
      assert options.timeout_config.receive_timeout_ms == 303
    end

    test "ignores invalid file bridge retry timeout values" do
      options =
        RequestOptions.build(
          %{
            finalize_retry_timeout_ms: "30000",
            finalize_retry_interval_ms: -1
          },
          "/backend-api/files/uploaded",
          %{}
        )

      assert options.file_bridge.finalize_retry_timeout_ms == nil
      assert options.file_bridge.finalize_retry_interval_ms == nil
      assert options.extra == %{}
    end

    test "normalizes legacy continuity fields and forwarded headers" do
      options =
        RequestOptions.build(
          %{
            bridge_owner_lease_ttl_seconds: 0,
            reconnect_window_seconds: -1,
            forwarded_headers: [
              {"user-agent", "codex_cli_rs/0.0.0"},
              {"x-openai-client-user-agent", "synthetic"},
              {"x-codex-client", :not_binary},
              ["x-codex-list", "not-a-tuple"],
              :invalid
            ]
          },
          "/backend-api/files",
          %{}
        )

      assert options.continuity.bridge_owner_lease_ttl_seconds == nil
      assert options.continuity.reconnect_window_seconds == nil

      assert options.transport.forwarded_metadata_headers == [
               {"user-agent", "codex_cli_rs/0.0.0"},
               {"x-openai-client-user-agent", "synthetic"}
             ]

      assert options.file_bridge.forwarded_headers == [
               {"user-agent", "codex_cli_rs/0.0.0"},
               {"x-openai-client-user-agent", "synthetic"}
             ]

      assert options.extra == %{}
    end

    test "normalizes typed continuity and file bridge updates" do
      options =
        %{}
        |> RequestOptions.build("/backend-api/files", %{})
        |> RequestOptions.put_continuity(
          bridge_owner_lease_ttl_seconds: "45",
          reconnect_window_seconds: 0
        )
        |> RequestOptions.put_file_bridge(
          forwarded_headers: [{"x-codex-client", "fixture"}, {"x-codex-client", 123}],
          finalize_retry_timeout_ms: -1,
          finalize_retry_interval_ms: 250
        )

      assert options.continuity.bridge_owner_lease_ttl_seconds == nil
      assert options.continuity.reconnect_window_seconds == 0
      assert options.file_bridge.forwarded_headers == [{"x-codex-client", "fixture"}]
      assert options.file_bridge.finalize_retry_timeout_ms == nil
      assert options.file_bridge.finalize_retry_interval_ms == 250
    end

    test "refreshes payload-sized metadata when reusing connection options" do
      connection_options =
        %{request_id: "ws-connection", transport: "websocket"}
        |> RequestOptions.build("/backend-api/codex/responses", %{})
        |> RequestOptions.put_request_metadata(request_bytes: nil)

      payload = %{"model" => "example-model", "input" => "hello"}

      options =
        RequestOptions.for_payload(
          connection_options,
          "/backend-api/codex/responses",
          payload
        )

      assert options.request_metadata.request_id == "ws-connection"
      assert options.request_metadata.request_bytes == RequestOptions.json_request_bytes(payload)
      assert options.transport.route_class == "proxy_websocket"
    end

    test "retargets typed options without a legacy option map round trip" do
      now = ~U[2026-01-02 03:04:05Z]

      request_options =
        %{request_id: "req_123", now: now, forwarded_headers: [{"x-codex-client", "fixture"}]}
        |> RequestOptions.build("/backend-api/codex/responses", %{"model" => "example-model"})
        |> RequestOptions.put_routing(quota_decision: %{"summary" => "allowed"})
        |> RequestOptions.put_file_bridge(defer_create_request: true)

      payload = %{"file_name" => "sample.txt", "file_size" => 123, "use_case" => "codex"}
      options = RequestOptions.retarget(request_options, "/backend-api/files", payload)

      assert options.request_metadata.request_id == "req_123"
      assert options.request_metadata.request_bytes == RequestOptions.json_request_bytes(payload)
      assert options.transport.transport == "http_json"
      assert options.transport.upstream_endpoint == "/backend-api/files"
      assert options.transport.route_class == "file_upload"
      assert options.transport.forwarded_metadata_headers == [{"x-codex-client", "fixture"}]
      assert options.routing.quota_decision == %{"summary" => "allowed"}
      assert options.file_bridge.defer_create_request
      assert options.file_bridge.forwarded_headers == [{"x-codex-client", "fixture"}]
      assert options.runtime.now == now
      refute Map.has_key?(options.extra, :route_class)
    end

    test "keeps owner forwarding disabled in typed defaults" do
      options =
        RequestOptions.build(%{}, "/backend-api/codex/responses", %{"model" => "example-model"})

      refute options.transport.websocket_owner_forwarding_enabled?
      assert options.transport.upstream_websocket_session == nil
      assert options.transport.websocket_owner_session == nil
      assert options.transport.websocket_owner_lease_token == nil
      assert options.transport.websocket_owner_downstream == nil
      assert options.transport.websocket_owner_downstream_epoch == nil
      assert options.transport.websocket_owner_proxy_instance_id == nil
      assert options.transport.websocket_owner_instance_id == nil
      assert options.continuity.owner_instance_id == nil
      assert options.extra == %{}
    end

    test "keeps owner forwarding handoff metadata typed and out of extra opts" do
      owner_session = %{id: "codex-session-id", owner_instance_id: "owner-node@example"}
      downstream = %{pid: self(), epoch: 3, correlation_id: "corr-owner-safe"}

      options =
        RequestOptions.build(
          %{
            websocket_owner_forwarding_enabled?: true,
            websocket_owner_session: owner_session,
            websocket_owner_lease_token: "lease-token-not-logged",
            websocket_owner_downstream: downstream,
            websocket_owner_downstream_epoch: 3,
            websocket_owner_proxy_instance_id: "proxy-node@example",
            websocket_owner_instance_id: "owner-node@example",
            websocket_owner_forwarder_opts: [timeout: 123]
          },
          "/backend-api/codex/responses",
          %{"model" => "example-model"}
        )

      assert options.transport.websocket_owner_forwarding_enabled?
      assert options.transport.websocket_owner_session == owner_session
      assert options.transport.websocket_owner_lease_token == "lease-token-not-logged"
      assert options.transport.websocket_owner_downstream == downstream
      assert options.transport.websocket_owner_downstream_epoch == 3
      assert options.transport.websocket_owner_proxy_instance_id == "proxy-node@example"
      assert options.transport.websocket_owner_instance_id == "owner-node@example"
      assert options.transport.websocket_owner_forwarder_opts == [timeout: 123]
      assert options.extra == %{}
    end

    test "rebuilds existing typed options without flattening typed updates through legacy opts" do
      connection_options =
        %{request_id: "ws-connection", transport: "websocket"}
        |> RequestOptions.build("/backend-api/codex/responses", %{})
        |> RequestOptions.put_request_metadata(request_bytes: nil)
        |> RequestOptions.put_transport(route_class: "custom_stream")

      payload = %{"model" => "example-model", "input" => "hello"}

      options =
        RequestOptions.build(
          connection_options,
          "/backend-api/codex/responses",
          payload
        )

      assert options.request_metadata.request_id == "ws-connection"
      assert options.request_metadata.request_bytes == RequestOptions.json_request_bytes(payload)
      assert options.transport.route_class == "custom_stream"
      assert options.transport.forwarded_metadata_headers == []
      refute Map.has_key?(options.extra, :route_class)
    end
  end

  describe "route_class/1" do
    test "classifies websocket transport from normalized opts" do
      options =
        RequestOptions.build(
          %{transport: "websocket"},
          "/backend-api/codex/responses",
          %{}
        )

      assert RequestOptions.route_class(options) == "proxy_websocket"
    end

    test "classifies streaming JSON from the payload" do
      options =
        RequestOptions.build(
          %{},
          "/backend-api/codex/responses",
          %{"stream" => true}
        )

      assert RequestOptions.route_class(options) == "proxy_stream"
    end

    test "returns nil when the typed transport has no route class" do
      options =
        %{}
        |> RequestOptions.build("/backend-api/codex/responses", %{"model" => "example-model"})
        |> RequestOptions.put_transport(route_class: nil)

      assert RequestOptions.route_class(options) == nil
    end
  end

  describe "section updaters" do
    test "apply known keyword updates to typed sections" do
      writer = fn _frame -> :ok end

      options =
        %{}
        |> RequestOptions.build("/backend-api/codex/responses", %{"model" => "example-model"})
        |> RequestOptions.put_transport(
          websocket_writer: writer,
          forwarded_metadata_headers: [
            {"x-codex-client", "fixture"},
            {"x-codex-client", :invalid},
            ["x-openai-client-user-agent", "invalid"],
            :invalid
          ]
        )
        |> RequestOptions.put_continuity(previous_response_id: "resp_123")
        |> RequestOptions.put_routing(quota_decision: %{"summary" => "allowed"})
        |> RequestOptions.put_runtime_context(interrupt_reason: "operator_closed")
        |> RequestOptions.put_openai_compatibility(public_openai_responses_stream: true)
        |> RequestOptions.put_file_bridge(pool_upstream_assignment_id: "assignment-id")

      assert options.transport.websocket_writer == writer
      assert options.transport.forwarded_metadata_headers == [{"x-codex-client", "fixture"}]
      assert options.continuity.previous_response_id == "resp_123"
      assert options.routing.quota_decision == %{"summary" => "allowed"}
      assert options.runtime.interrupt_reason == "operator_closed"
      assert options.openai_compatibility.public_openai_responses_stream
      assert options.file_bridge.pool_upstream_assignment_id == "assignment-id"
    end

    test "reject unknown section fields" do
      options =
        RequestOptions.build(%{}, "/backend-api/codex/responses", %{"model" => "example-model"})

      assert_raise KeyError, fn ->
        RequestOptions.put_request_metadata(options, unknown_field: true)
      end

      assert_raise KeyError, fn ->
        RequestOptions.put_transport(options, unknown_field: true)
      end

      assert_raise KeyError, fn ->
        RequestOptions.put_continuity(options, unknown_field: true)
      end

      assert_raise KeyError, fn ->
        RequestOptions.put_routing(options, unknown_field: true)
      end

      assert_raise KeyError, fn ->
        RequestOptions.put_runtime_context(options, unknown_field: true)
      end

      assert_raise KeyError, fn ->
        RequestOptions.put_openai_compatibility(options, unknown_field: true)
      end

      assert_raise KeyError, fn ->
        RequestOptions.put_file_bridge(options, unknown_field: true)
      end
    end
  end

  describe "json_request_bytes/1" do
    test "returns nil for payloads that cannot be encoded as JSON" do
      assert RequestOptions.json_request_bytes(%{"callback" => fn -> :ok end}) == nil
    end
  end

  defp prompt_cache_key_hash(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end
end
