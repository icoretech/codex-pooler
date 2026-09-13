defmodule CodexPooler.Gateway.Payloads.TransportEnvelopeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @detection_timeout_ms 15_000

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.TimeoutConfig
  alias CodexPooler.Gateway.Payloads.TransportEnvelope
  alias CodexPooler.Gateway.Transports.UpstreamDispatch
  alias CodexPooler.Upstreams.CodexClientIdentity
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @tenant_pool_id "11111111-1111-4111-8111-111111111111"
  @tenant_api_key_id "22222222-2222-4222-8222-222222222222"
  @other_api_key_id "33333333-3333-4333-8333-333333333333"
  @other_pool_id "44444444-4444-4444-8444-444444444444"
  @tenant_scope %{pool_id: @tenant_pool_id, api_key_id: @tenant_api_key_id}
  @tenant_auth %{pool: %{id: @tenant_pool_id}, api_key: %{id: @tenant_api_key_id}}

  describe "timeout_config/2" do
    test "returns the typed timeout config used by Req options" do
      options = request_options(%TimeoutConfig{pool_timeout_ms: 25, receive_timeout_ms: 50})

      defaults = %{connect_timeout_ms: 10, pool_timeout_ms: 20, receive_timeout_ms: 30}

      assert %TimeoutConfig{
               connect_timeout_ms: 10,
               pool_timeout_ms: 25,
               receive_timeout_ms: 50
             } = TransportEnvelope.timeout_config(options, defaults)
    end
  end

  describe "req_timeout_options/1" do
    test "maps timeout config fields to Req option names" do
      timeouts = %TimeoutConfig{
        connect_timeout_ms: 10,
        pool_timeout_ms: 20,
        receive_timeout_ms: 30
      }

      with_operational_settings(%OperationalSettings{}, fn ->
        assert TransportEnvelope.req_timeout_options(timeouts) == [
                 receive_timeout: 30,
                 finch: [
                   pool_timeout: 20,
                   conn_opts: [transport_opts: [timeout: 10]],
                   conn_max_idle_time: 45_000
                 ]
               ]
      end)
    end

    test "carries the instance-settings upstream connection idle bound as a Finch pool option" do
      timeouts = %TimeoutConfig{
        connect_timeout_ms: 10,
        pool_timeout_ms: 20,
        receive_timeout_ms: 30
      }

      for idle_ms <- [1_000, 1_234, 3_600_000] do
        settings = %OperationalSettings{
          upstream_connect_timeout_ms: 99,
          upstream_conn_max_idle_time_ms: idle_ms
        }

        with_operational_settings(settings, fn ->
          options = TransportEnvelope.req_timeout_options(timeouts)

          assert options[:finch][:conn_max_idle_time] == idle_ms
          assert options[:finch][:conn_opts] == [transport_opts: [timeout: 10]]
        end)
      end
    end

    test "executes the configured Req transport without deprecation warnings" do
      url = start_http_server!()

      timeouts = %TimeoutConfig{
        connect_timeout_ms: @detection_timeout_ms,
        pool_timeout_ms: @detection_timeout_ms,
        receive_timeout_ms: @detection_timeout_ms
      }

      {result, warnings} =
        with_io(:stderr, fn ->
          result =
            Req.get(
              url,
              [decode_body: false, retry: false] ++
                TransportEnvelope.req_timeout_options(timeouts)
            )

          result
        end)

      assert {:ok, %Req.Response{status: 204}} = result
      assert warnings == ""
    end
  end

  describe "headers/4" do
    test "preserves header order, server account identity, and allowed forwarded metadata" do
      headers =
        TransportEnvelope.headers(
          identity(),
          " upstream-token ",
          [{"accept", "application/json"}],
          forwarded_headers: [
            {"chatgpt-account-id", "acct_downstream"},
            {"x-openai-client-user-agent", "downstream-openai-client"},
            {"x-codex-turn-state", "safe-turn-state"}
          ]
        )

      assert headers == [
               {"authorization", "Bearer upstream-token"},
               {"chatgpt-account-id", "acct_test"},
               {"accept", "application/json"},
               {"x-openai-client-user-agent", "downstream-openai-client"},
               {"x-codex-turn-state", "safe-turn-state"}
             ]
    end

    test "synthesizes trusted identity and ignores downstream identity headers" do
      version = CodexClientIdentity.version()

      headers =
        TransportEnvelope.headers(
          identity(),
          " upstream-token ",
          [{"accept", "application/json"}],
          include_codex_identity?: true,
          forwarded_headers: [
            {"user-agent", "downstream-harness/1.0"},
            {"originator", "downstream-originator"},
            {"version", "0.0.1"},
            {"chatgpt-account-id", "acct_downstream"},
            {"x-openai-client-user-agent", "downstream-openai-client"},
            {"x-codex-turn-state", "safe-turn-state"},
            {"authorization", "Bearer downstream"},
            {"content-type", "application/json"}
          ]
        )

      assert headers == [
               {"authorization", "Bearer upstream-token"},
               {"user-agent", "codex_cli_rs/#{version}"},
               {"originator", "codex_cli_rs"},
               {"version", version},
               {"chatgpt-account-id", "acct_test"},
               {"accept", "application/json"},
               {"x-openai-client-user-agent", "downstream-openai-client"},
               {"x-codex-turn-state", "safe-turn-state"}
             ]
    end

    test "appends one residency header from namespaced or root access-token claims" do
      for claims <- [
            %{
              "https://api.openai.com/auth" => %{
                "chatgpt_compute_residency" => "region-alpha"
              }
            },
            %{"chatgpt_compute_residency" => "region-beta"}
          ] do
        headers =
          TransportEnvelope.headers(
            identity(),
            access_token(claims),
            [{"accept", "application/json"}],
            forwarded_headers: [{"x-codex-turn-state", "safe-turn-state"}]
          )

        assert List.last(headers) ==
                 {"x-openai-internal-codex-residency", claims_residency(claims)}

        assert length(residency_headers(headers)) == 1
      end
    end

    test "normalizes the selected token once for authorization and residency extraction" do
      token = access_token(%{"chatgpt_compute_residency" => "region-trimmed"})

      headers =
        TransportEnvelope.headers(identity(), " \t#{token}\n", [],
          forwarded_headers: [{"x-openai-unrelated", "preserved"}]
        )

      assert {"authorization", "Bearer #{token}"} in headers
      assert {"x-openai-unrelated", "preserved"} in headers

      assert List.last(headers) ==
               {"x-openai-internal-codex-residency", "region-trimmed"}
    end

    test "omits residency for absent, invalid, and no-constraint access-token claims" do
      tokens = [
        access_token(%{}),
        "invalid-access-token",
        access_token(%{"chatgpt_compute_residency" => "no_constraint"}),
        access_token(%{
          "https://api.openai.com/auth" => %{
            "chatgpt_compute_residency" => "invalid\r\nvalue"
          }
        })
      ]

      for token <- tokens do
        headers = TransportEnvelope.headers(identity(), token, [])
        assert residency_headers(headers) == []
      end
    end

    test "drops mixed-case forwarded residency spoofing and preserves server-owned identity" do
      token = access_token(%{"chatgpt_compute_residency" => "region-server"})

      headers =
        TransportEnvelope.headers(identity(), token, [{"accept", "application/json"}],
          forwarded_headers: [
            {"X-OpenAI-Internal-Codex-Residency", "region-client-one"},
            {"x-OPENAI-internal-codex-residency", "region-client-two"},
            {"chatgpt-account-id", "acct_downstream"},
            {"x-openai-client-user-agent", "downstream-openai-client"}
          ]
        )

      assert headers == [
               {"authorization", "Bearer #{token}"},
               {"chatgpt-account-id", "acct_test"},
               {"accept", "application/json"},
               {"x-openai-client-user-agent", "downstream-openai-client"},
               {"x-openai-internal-codex-residency", "region-server"}
             ]
    end

    test "derives each envelope independently from its selected access token" do
      first_headers =
        TransportEnvelope.headers(
          identity(),
          access_token(%{"chatgpt_compute_residency" => "region-first"}),
          []
        )

      second_headers =
        TransportEnvelope.headers(
          identity(),
          access_token(%{"chatgpt_compute_residency" => "region-second"}),
          []
        )

      assert residency_headers(first_headers) == [
               {"x-openai-internal-codex-residency", "region-first"}
             ]

      assert residency_headers(second_headers) == [
               {"x-openai-internal-codex-residency", "region-second"}
             ]
    end
  end

  describe "UpstreamDispatch regular runtime headers" do
    test "keeps forwarded metadata broad at construction and narrows only at runtime output" do
      options = runtime_options("/backend-api/codex/responses")

      assert options.transport.forwarded_metadata_headers == forwarded_metadata_headers()

      assert UpstreamDispatch.regular_runtime_forwarded_metadata_headers(options) ==
               approved_forwarded_metadata_headers()
    end

    test "builds regular runtime headers with only approved forwarded metadata" do
      options = runtime_options("/backend-api/codex/responses")
      version = CodexClientIdentity.version()

      headers =
        UpstreamDispatch.regular_runtime_headers(
          identity(),
          " upstream-token ",
          options,
          [{"content-type", "application/json"}, {"accept", "text/event-stream"}]
        )

      assert headers == [
               {"authorization", "Bearer upstream-token"},
               {"user-agent", "codex_cli_rs/#{version}"},
               {"originator", "codex_cli_rs"},
               {"version", version},
               {"chatgpt-account-id", "acct_test"},
               {"content-type", "application/json"},
               {"accept", "text/event-stream"},
               {"x-codex-turn-metadata", "metadata-redacted"},
               {"x-codex-window-id", "window-redacted"},
               {"x-codex-parent-thread-id", "thread-redacted"},
               {"x-codex-turn-state", "turn-state-redacted"},
               {"x-openai-subagent", "subagent-redacted"},
               {"session-id", "019a0c74-e494-7162-b789-1ba499fad58e"},
               {"thread-id", "019a0c74-e494-7162-b789-1ba499fad58e"},
               {"x-client-request-id", "019a0c74-e494-7162-b789-1ba499fad58e"}
             ]
    end

    test "forwards provider session headers only as bounded identifiers on native routes" do
      overlong = String.duplicate("a", 129)

      input_headers = [
        {"session-id", "019a0c74-e494-7162-b789-1ba499fad58e"},
        {"Thread-Id", "thread_01.a:b"},
        {"x-client-request-id", overlong},
        {"session-id", "spaced value"},
        {"session-id", ""},
        {"x-session-id", "local-only"},
        {"x-session-affinity", "local-only"},
        {"session_id", "local-only"}
      ]

      options = runtime_options("/backend-api/codex/responses", forwarded_headers: input_headers)

      assert UpstreamDispatch.regular_runtime_forwarded_metadata_headers(options) == [
               {"session-id", "019a0c74-e494-7162-b789-1ba499fad58e"},
               {"thread-id", "thread_01.a:b"}
             ]

      assert UpstreamDispatch.regular_runtime_forwarded_metadata_headers(
               runtime_options("/v1/responses", forwarded_headers: input_headers)
             ) == []

      # The envelope narrows the same way when a caller bypasses the runtime filter.
      envelope_headers =
        TransportEnvelope.headers(identity(), "upstream-token", [],
          forwarded_headers: input_headers
        )

      assert Enum.filter(envelope_headers, fn {name, _value} ->
               name in ["session-id", "thread-id", "x-client-request-id", "x-session-id"]
             end) == [
               {"session-id", "019a0c74-e494-7162-b789-1ba499fad58e"},
               {"thread-id", "thread_01.a:b"}
             ]
    end

    test "synthesizes the provider session-id from prompt_cache_key on public /v1 origins only" do
      client_headers = [
        {"session-id", "019a0c74-e494-7162-b789-1ba499fad58e"},
        {"thread-id", "thread_01.a:b"},
        {"x-session-id", "local-only"}
      ]

      payload = %{"model" => "example-model", "prompt_cache_key" => "fixture-cache-key"}
      expected = TransportEnvelope.prompt_cache_session_id(@tenant_scope, "fixture-cache-key")
      assert is_binary(expected)

      for source_endpoint <- ["/v1/responses", "/v1/chat/completions"] do
        options =
          source_endpoint
          |> public_v1_options(payload, forwarded_headers: client_headers)
          |> RequestOptions.capture_tenant_scope(@tenant_auth)

        # The client's own continuity headers stay local on /v1; only the
        # Pooler-derived session-id goes upstream.
        assert UpstreamDispatch.regular_runtime_forwarded_metadata_headers(options, payload) ==
                 [{"session-id", expected}]

        headers =
          UpstreamDispatch.regular_runtime_headers(
            identity(),
            "upstream-token",
            options,
            [{"content-type", "application/json"}],
            payload: payload
          )

        assert Enum.filter(headers, fn {name, _value} ->
                 name in ["session-id", "thread-id", "x-session-id"]
               end) == [{"session-id", expected}]
      end

      options =
        "/v1/responses"
        |> public_v1_options(payload, forwarded_headers: client_headers)
        |> RequestOptions.capture_tenant_scope(@tenant_auth)

      # Another API key in the same Pool gets its own provider session-id.
      other_tenant_options =
        RequestOptions.capture_tenant_scope(options, %{
          pool: %{id: @tenant_pool_id},
          api_key: %{id: @other_api_key_id}
        })

      assert [{"session-id", other_tenant_value}] =
               UpstreamDispatch.regular_runtime_forwarded_metadata_headers(
                 other_tenant_options,
                 payload
               )

      assert other_tenant_value != expected

      # Without a usable key nothing is synthesized and the client headers are
      # still not forwarded.
      for absent_payload <- [
            %{"model" => "example-model"},
            %{"model" => "example-model", "prompt_cache_key" => ""},
            %{"model" => "example-model", "prompt_cache_key" => String.duplicate("k", 513)},
            %{"model" => "example-model", "prompt_cache_key" => %{"nested" => "key"}},
            nil
          ] do
        assert UpstreamDispatch.regular_runtime_forwarded_metadata_headers(
                 options,
                 absent_payload
               ) == []
      end

      assert UpstreamDispatch.regular_runtime_forwarded_metadata_headers(options) == []

      # Fail closed without a trusted tenant scope: there is no unscoped
      # derivation, controller opts and runtime updates cannot supply the
      # scope, and an auth context missing either id clears a captured one.
      unscoped = public_v1_options("/v1/responses", payload, forwarded_headers: client_headers)

      for unscoped_options <- [
            unscoped,
            public_v1_options("/v1/responses", payload,
              forwarded_headers: client_headers,
              tenant_scope: @tenant_scope
            ),
            RequestOptions.put_runtime_context(unscoped, tenant_scope: @tenant_scope),
            RequestOptions.capture_tenant_scope(options, %{
              pool: %{id: nil},
              api_key: %{id: @tenant_api_key_id}
            }),
            RequestOptions.capture_tenant_scope(options, %{pool: %{id: @tenant_pool_id}})
          ] do
        assert unscoped_options.runtime.tenant_scope == nil
        refute Map.has_key?(unscoped_options.extra, :tenant_scope)

        assert UpstreamDispatch.regular_runtime_forwarded_metadata_headers(
                 unscoped_options,
                 payload
               ) == []
      end

      # Native routes keep forwarding the client's headers verbatim and never
      # synthesize from the body.
      native_options =
        runtime_options("/backend-api/codex/responses", forwarded_headers: client_headers)

      assert UpstreamDispatch.regular_runtime_forwarded_metadata_headers(
               native_options,
               payload
             ) == [
               {"session-id", "019a0c74-e494-7162-b789-1ba499fad58e"},
               {"thread-id", "thread_01.a:b"}
             ]
    end

    test "gates forwarded metadata to backend responses and compact transport only" do
      assert UpstreamDispatch.regular_runtime_forwarded_metadata_headers(
               runtime_options("/backend-api/codex/responses")
             ) == approved_forwarded_metadata_headers()

      assert UpstreamDispatch.regular_runtime_forwarded_metadata_headers(
               runtime_options("/backend-api/codex/responses/compact")
             ) == approved_forwarded_metadata_headers()

      assert UpstreamDispatch.regular_runtime_forwarded_metadata_headers(
               runtime_options("/v1/responses")
             ) == []

      assert UpstreamDispatch.regular_runtime_forwarded_metadata_headers(
               runtime_options("/backend-api/codex/responses",
                 openai_source_endpoint: "/v1/responses"
               )
             ) == []

      assert UpstreamDispatch.regular_runtime_forwarded_metadata_headers(
               runtime_options("/backend-api/codex/responses",
                 openai_chat_payload: %{"model" => "example-model", "messages" => []}
               )
             ) == []
    end

    @tag :code_mode_turn_metadata_projection
    test "projects only top-level code mode tools from direct native metadata headers" do
      original = turn_metadata("first")
      duplicate = turn_metadata("second")

      input_headers = [
        {"X-Codex-Turn-Metadata", original},
        {"x-codex-window-id", "window-redacted"},
        {"x-codex-turn-metadata", duplicate},
        {"x-codex-parent-thread-id", "thread-redacted"},
        {"x-codex-installation-id", "installation-redacted"},
        {"x-codex-turn-state", "turn-state-redacted"},
        {"x-openai-subagent", "subagent-redacted"}
      ]

      options =
        runtime_options("/backend-api/codex/responses", forwarded_headers: input_headers)

      forwarded_headers = UpstreamDispatch.regular_runtime_forwarded_metadata_headers(options)

      assert [
               {"x-codex-turn-metadata", projected},
               {"x-codex-window-id", "window-redacted"},
               {"x-codex-turn-metadata", projected_duplicate},
               {"x-codex-parent-thread-id", "thread-redacted"},
               {"x-codex-installation-id", "installation-redacted"},
               {"x-codex-turn-state", "turn-state-redacted"},
               {"x-openai-subagent", "subagent-redacted"}
             ] = forwarded_headers

      expected = Map.delete(CodexPooler.JSON.decode!(original), "code_mode_tool_names")
      expected_duplicate = Map.delete(CodexPooler.JSON.decode!(duplicate), "code_mode_tool_names")

      assert CodexPooler.JSON.decode!(projected) == expected
      assert CodexPooler.JSON.decode!(projected_duplicate) == expected_duplicate
      assert projected != original
      assert projected_duplicate != duplicate
      assert byte_size(projected) < byte_size(original)
      assert byte_size(projected_duplicate) < byte_size(duplicate)
      assert ascii_only?(projected)
      assert ascii_only?(projected_duplicate)

      assert get_in(CodexPooler.JSON.decode!(projected), ["nested", "code_mode_tool_names"]) == %{
               "nested-tool" => "nested sentinel"
             }

      assert CodexPooler.JSON.decode!(projected)["non_ascii"] == "cafe \u2615"
      assert options.transport.forwarded_metadata_headers == input_headers

      regular_headers =
        UpstreamDispatch.regular_runtime_headers(
          identity(),
          "upstream-token",
          options,
          [{"accept", "application/json"}]
        )

      assert turn_metadata_headers(regular_headers) == [
               {"x-codex-turn-metadata", projected},
               {"x-codex-turn-metadata", projected_duplicate}
             ]

      compact_options =
        runtime_options("/backend-api/codex/responses/compact", forwarded_headers: input_headers)

      assert turn_metadata_headers(
               UpstreamDispatch.regular_runtime_headers(
                 identity(),
                 "upstream-token",
                 compact_options,
                 [{"accept", "application/json"}]
               )
             ) == [
               {"x-codex-turn-metadata", projected},
               {"x-codex-turn-metadata", projected_duplicate}
             ]
    end

    @tag :code_mode_turn_metadata_projection
    test "removes every JSON top-level code mode tool-name value" do
      for value <- [%{}, [], "scalar", 42, true, nil] do
        metadata = CodexPooler.JSON.encode!(%{"code_mode_tool_names" => value})

        assert UpstreamDispatch.regular_runtime_forwarded_metadata_headers(
                 runtime_options("/backend-api/codex/responses",
                   forwarded_headers: [{"x-codex-turn-metadata", metadata}]
                 )
               ) == [{"x-codex-turn-metadata", "{}"}]
      end
    end

    @tag :code_mode_turn_metadata_projection
    test "preserves no-target, malformed, non-object, blank, and opaque metadata bytes" do
      large_opaque = String.duplicate("opaque-turn-metadata/", 2_048)

      passthrough_values = [
        ~s({ "unrelated" : "unchanged", "nested" : {"code_mode_tool_names" : ["preserve"]} }),
        "{malformed-json",
        ~s("json string"),
        "[]",
        "42",
        "true",
        "false",
        "null",
        "",
        " \t\n ",
        large_opaque
      ]

      for value <- passthrough_values do
        assert UpstreamDispatch.regular_runtime_forwarded_metadata_headers(
                 runtime_options("/backend-api/codex/responses",
                   forwarded_headers: [{"x-codex-turn-metadata", value}]
                 )
               ) == [{"x-codex-turn-metadata", value}]
      end
    end

    @tag :code_mode_turn_metadata_projection
    test "keeps non-target approved headers and excludes v1 and OpenAI-origin requests" do
      metadata = turn_metadata("excluded")

      assert UpstreamDispatch.regular_runtime_forwarded_metadata_headers(
               runtime_options("/v1/responses",
                 forwarded_headers: [{"x-codex-turn-metadata", metadata}]
               )
             ) == []

      assert UpstreamDispatch.regular_runtime_forwarded_metadata_headers(
               runtime_options("/backend-api/codex/responses",
                 openai_source_endpoint: "/v1/responses",
                 forwarded_headers: [{"x-codex-turn-metadata", metadata}]
               )
             ) == []

      assert UpstreamDispatch.regular_runtime_forwarded_metadata_headers(
               runtime_options("/backend-api/codex/responses",
                 openai_chat_payload: %{"model" => "example-model", "messages" => []},
                 forwarded_headers: [{"x-codex-turn-metadata", metadata}]
               )
             ) == []
    end
  end

  defp request_options(%TimeoutConfig{} = timeout_config) do
    %RequestOptions{
      request_metadata: nil,
      transport: nil,
      continuity: nil,
      routing: nil,
      timeout_config: timeout_config,
      payload_context: nil,
      runtime: nil,
      openai_compatibility: nil,
      usage_authentication: nil,
      file_bridge: nil
    }
  end

  describe "prompt_cache_session_id/2" do
    # RFC 4122 version 5: version nibble `5`, variant bits `10xx`.
    @uuid_v5 ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

    test "uses the fixed Pooler namespace and RFC 4122 v5 over the netstring tenant name" do
      # The namespace is itself UUID v5 of the RFC 4122 URL namespace over the
      # project URL. Every value below was cross-checked with Python's
      # `uuid.uuid5(uuid.UUID("0aac30b0-0311-52bd-8fb7-258f9c6f0278"), name)`
      # where `name` is the UTF-8 bytes of
      # `f"{len(pool_id)}:{pool_id},{len(api_key_id)}:{api_key_id},{key}"`
      # (lengths in bytes).
      assert TransportEnvelope.prompt_cache_session_namespace() ==
               "0aac30b0-0311-52bd-8fb7-258f9c6f0278"

      assert TransportEnvelope.prompt_cache_session_id(@tenant_scope, "fixture-cache-key") ==
               "f228c884-887f-5139-9116-d0d12a32b2a4"

      assert TransportEnvelope.prompt_cache_session_id(@tenant_scope, "other-cache-key") ==
               "5f4379e8-576a-5b98-9e51-76eae22095d9"

      assert TransportEnvelope.prompt_cache_session_id(@tenant_scope, String.duplicate("a", 512)) ==
               "1b022668-2e28-5cd7-95d7-7a37ce6fa1f6"

      assert TransportEnvelope.prompt_cache_session_id(
               %{pool_id: @tenant_pool_id, api_key_id: @other_api_key_id},
               "fixture-cache-key"
             ) == "64dd4d61-404c-5b01-a009-c2e97f90cbc7"

      assert TransportEnvelope.prompt_cache_session_id(
               %{pool_id: @other_pool_id, api_key_id: @tenant_api_key_id},
               "fixture-cache-key"
             ) == "fb4ebc53-19a1-5fb9-aac2-498e7ea5e124"
    end

    test "is deterministic, v5-shaped, and bounded by the raw key" do
      for key <- ["fixture-cache-key", "conv:01/𝔘nicode key", String.duplicate("z", 512)] do
        value = TransportEnvelope.prompt_cache_session_id(@tenant_scope, key)

        assert value =~ @uuid_v5
        assert TransportEnvelope.provider_session_header_value?(value)
        assert TransportEnvelope.prompt_cache_session_id(@tenant_scope, key) == value
      end

      assert TransportEnvelope.prompt_cache_session_id(@tenant_scope, "fixture-cache-key") !=
               TransportEnvelope.prompt_cache_session_id(@tenant_scope, "fixture-cache-key ")

      for ignored <- ["", String.duplicate("z", 513), nil, 42, %{}, ["fixture-cache-key"]] do
        assert TransportEnvelope.prompt_cache_session_id(@tenant_scope, ignored) == nil
      end
    end

    test "separates tenants: the same key under another API key or Pool gets another id" do
      key = "default"
      tenant = TransportEnvelope.prompt_cache_session_id(@tenant_scope, key)

      assert TransportEnvelope.prompt_cache_session_id(
               %{pool_id: @tenant_pool_id, api_key_id: @tenant_api_key_id},
               key
             ) == tenant

      other_values =
        Enum.map(
          [
            %{pool_id: @tenant_pool_id, api_key_id: @other_api_key_id},
            %{pool_id: @other_pool_id, api_key_id: @tenant_api_key_id},
            %{pool_id: @other_pool_id, api_key_id: @other_api_key_id},
            # Swapping the two ids is a different tenant name.
            %{pool_id: @tenant_api_key_id, api_key_id: @tenant_pool_id}
          ],
          &TransportEnvelope.prompt_cache_session_id(&1, key)
        )

      assert Enum.all?(other_values, &(&1 =~ @uuid_v5))
      assert Enum.uniq([tenant | other_values]) == [tenant | other_values]
    end

    test "is injective over (pool id, api key id, key) even when values contain separators" do
      # A plain `:`-joined name would collapse both triples to "a:b:c:d".
      assert Enum.join(["a:b", "c", "d"], ":") == Enum.join(["a", "b:c", "d"], ":")

      assert TransportEnvelope.prompt_cache_session_id(%{pool_id: "a:b", api_key_id: "c"}, "d") ==
               "3d589036-54f8-57d8-9b56-f5e5c9e1b239"

      assert TransportEnvelope.prompt_cache_session_id(%{pool_id: "a", api_key_id: "b:c"}, "d") ==
               "e27cde86-c9b7-54aa-bae6-74143ea50a11"

      # A pool id that itself looks like a netstring prefix stays distinct.
      assert TransportEnvelope.prompt_cache_session_id(%{pool_id: "1:a,", api_key_id: "b"}, "c") ==
               "e1bbbf29-e1d3-5b30-a99d-d9408dce3c8d"

      # Moving the separator byte across the api key id / key boundary changes
      # the name, because the api key id is length-prefixed.
      assert TransportEnvelope.prompt_cache_session_id(%{pool_id: "a", api_key_id: "b,"}, "c") !=
               TransportEnvelope.prompt_cache_session_id(%{pool_id: "a", api_key_id: "b"}, ",c")
    end

    test "returns nil without a complete trusted tenant scope" do
      for scope <- [
            nil,
            %{},
            %{pool_id: @tenant_pool_id},
            %{api_key_id: @tenant_api_key_id},
            %{pool_id: "", api_key_id: @tenant_api_key_id},
            %{pool_id: @tenant_pool_id, api_key_id: ""},
            %{pool_id: nil, api_key_id: @tenant_api_key_id},
            %{pool_id: @tenant_pool_id, api_key_id: 42},
            {@tenant_pool_id, @tenant_api_key_id},
            "fixture-cache-key"
          ] do
        assert TransportEnvelope.prompt_cache_session_id(scope, "fixture-cache-key") == nil
      end
    end
  end

  defp public_v1_options(source_endpoint, payload, opts) do
    opts
    |> Map.new()
    |> Map.put(:openai_source_endpoint, source_endpoint)
    |> Map.put(:openai_translated_endpoint, "/backend-api/codex/responses")
    |> RequestOptions.build("/backend-api/codex/responses", payload || %{})
  end

  defp runtime_options(endpoint, opts \\ []) do
    opts
    |> Keyword.put_new(:forwarded_headers, forwarded_metadata_headers())
    |> Map.new()
    |> RequestOptions.build(endpoint, %{"model" => "example-model"})
  end

  defp turn_metadata(label) do
    CodexPooler.JSON.encode!(%{
      "code_mode_tool_names" =>
        Map.new(1..256, fn index -> {"tool_#{index}", "#{label}-handler-#{index}"} end),
      "nested" => %{"code_mode_tool_names" => %{"nested-tool" => "nested sentinel"}},
      "non_ascii" => "cafe \u2615",
      "unrelated" => "#{label}-unrelated"
    })
  end

  defp turn_metadata_headers(headers) do
    Enum.filter(headers, fn {name, _value} -> name == "x-codex-turn-metadata" end)
  end

  defp ascii_only?(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.all?(&(&1 < 128))
  end

  defp access_token(claims) do
    header = Base.url_encode64(CodexPooler.JSON.encode!(%{"alg" => "none"}), padding: false)
    payload = Base.url_encode64(CodexPooler.JSON.encode!(claims), padding: false)
    "#{header}.#{payload}.signature"
  end

  defp claims_residency(%{"https://api.openai.com/auth" => auth_claims}) do
    auth_claims["chatgpt_compute_residency"]
  end

  defp claims_residency(claims), do: claims["chatgpt_compute_residency"]

  defp residency_headers(headers) do
    Enum.filter(headers, fn {name, _value} ->
      name == "x-openai-internal-codex-residency"
    end)
  end

  defp forwarded_metadata_headers do
    approved_forwarded_metadata_headers() ++
      [
        {"User-Agent", "downstream-harness/1.0"},
        {"originator", "downstream-originator"},
        {"version", "0.0.1"},
        {"chatgpt-account-id", "acct_downstream"},
        {"authorization", "Bearer downstream"},
        {"cookie", "downstream-cookie"},
        {"idempotency-key", "downstream-idempotency"},
        {"accept", "application/json"},
        {"content-type", "application/json"},
        {"x-codex-extra", "extra-redacted"},
        {"x-openai-extra", "extra-redacted"},
        {"x-session-id", "local-only"},
        {"x-session-affinity", "local-only"}
      ]
  end

  defp approved_forwarded_metadata_headers do
    [
      {"x-codex-turn-metadata", "metadata-redacted"},
      {"x-codex-window-id", "window-redacted"},
      {"x-codex-parent-thread-id", "thread-redacted"},
      {"x-codex-turn-state", "turn-state-redacted"},
      {"x-openai-subagent", "subagent-redacted"},
      {"session-id", "019a0c74-e494-7162-b789-1ba499fad58e"},
      {"thread-id", "019a0c74-e494-7162-b789-1ba499fad58e"},
      {"x-client-request-id", "019a0c74-e494-7162-b789-1ba499fad58e"}
    ]
  end

  defp identity do
    %UpstreamIdentity{chatgpt_account_id: "acct_test"}
  end

  defp with_operational_settings(%OperationalSettings{} = settings, fun) do
    previous = Application.fetch_env(:codex_pooler, OperationalSettings)

    restore = fn ->
      case previous do
        {:ok, value} -> Application.put_env(:codex_pooler, OperationalSettings, value)
        :error -> Application.delete_env(:codex_pooler, OperationalSettings)
      end
    end

    # Also on_exit: the ExUnit timeout or a linked crash kills the test before `after` runs.
    on_exit(restore)
    Application.put_env(:codex_pooler, OperationalSettings, settings: settings)

    try do
      fun.()
    after
      restore.()
    end
  end

  defp start_http_server! do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, port} = :inet.port(listen_socket)

    server_pid =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen_socket)
        {:ok, _request} = :gen_tcp.recv(socket, 0, @detection_timeout_ms)

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 204 No Content\r\n",
            "content-length: 0\r\n",
            "connection: close\r\n\r\n"
          ])

        :gen_tcp.close(socket)
        :gen_tcp.close(listen_socket)
      end)

    on_exit(fn ->
      if Process.alive?(server_pid), do: Process.exit(server_pid, :kill)
      :gen_tcp.close(listen_socket)
    end)

    "http://127.0.0.1:#{port}/"
  end
end
