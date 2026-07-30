defmodule CodexPooler.Gateway.Payloads.TransportEnvelopeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @detection_timeout_ms 15_000

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.TimeoutConfig
  alias CodexPooler.Gateway.Payloads.TransportEnvelope
  alias CodexPooler.Gateway.Transports.UpstreamDispatch
  alias CodexPooler.Upstreams.CodexClientIdentity
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

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

      assert TransportEnvelope.req_timeout_options(timeouts) == [
               receive_timeout: 30,
               finch: [
                 pool_timeout: 20,
                 conn_opts: [transport_opts: [timeout: 10]]
               ]
             ]
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
               {"x-openai-subagent", "subagent-redacted"}
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

      expected = Map.delete(Jason.decode!(original), "code_mode_tool_names")
      expected_duplicate = Map.delete(Jason.decode!(duplicate), "code_mode_tool_names")

      assert Jason.decode!(projected) == expected
      assert Jason.decode!(projected_duplicate) == expected_duplicate
      assert projected != original
      assert projected_duplicate != duplicate
      assert byte_size(projected) < byte_size(original)
      assert byte_size(projected_duplicate) < byte_size(duplicate)
      assert ascii_only?(projected)
      assert ascii_only?(projected_duplicate)

      assert get_in(Jason.decode!(projected), ["nested", "code_mode_tool_names"]) == %{
               "nested-tool" => "nested sentinel"
             }

      assert Jason.decode!(projected)["non_ascii"] == "cafe \u2615"
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
        metadata = Jason.encode!(%{"code_mode_tool_names" => value})

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

  defp runtime_options(endpoint, opts \\ []) do
    opts
    |> Keyword.put_new(:forwarded_headers, forwarded_metadata_headers())
    |> Map.new()
    |> RequestOptions.build(endpoint, %{"model" => "example-model"})
  end

  defp turn_metadata(label) do
    Jason.encode!(%{
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
        {"x-openai-extra", "extra-redacted"}
      ]
  end

  defp approved_forwarded_metadata_headers do
    [
      {"x-codex-turn-metadata", "metadata-redacted"},
      {"x-codex-window-id", "window-redacted"},
      {"x-codex-parent-thread-id", "thread-redacted"},
      {"x-codex-turn-state", "turn-state-redacted"},
      {"x-openai-subagent", "subagent-redacted"}
    ]
  end

  defp identity do
    %UpstreamIdentity{chatgpt_account_id: "acct_test"}
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
