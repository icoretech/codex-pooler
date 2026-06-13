defmodule CodexPooler.Gateway.Payloads.TransportEnvelopeTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.TimeoutConfig
  alias CodexPooler.Gateway.Payloads.TransportEnvelope
  alias CodexPooler.Gateway.Transports.UpstreamDispatch
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
               pool_timeout: 20,
               connect_options: [timeout: 10]
             ]
    end
  end

  describe "headers/4" do
    test "uses the configured synthetic upstream user-agent and does not forward downstream user-agent" do
      headers =
        TransportEnvelope.headers(
          identity(),
          " upstream-token ",
          [{"accept", "application/json"}],
          include_user_agent?: true,
          upstream_user_agent: "codex_cli_rs/9.9.9",
          forwarded_headers: [
            {"user-agent", "downstream-harness/1.0"},
            {"x-openai-client-user-agent", "downstream-openai-client"},
            {"x-codex-turn-state", "safe-turn-state"},
            {"authorization", "Bearer downstream"},
            {"content-type", "application/json"}
          ]
        )

      assert headers == [
               {"authorization", "Bearer upstream-token"},
               {"user-agent", "codex_cli_rs/9.9.9"},
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

      headers =
        UpstreamDispatch.regular_runtime_headers(
          identity(),
          " upstream-token ",
          options,
          [{"content-type", "application/json"}, {"accept", "text/event-stream"}],
          upstream_user_agent: "codex_cli_rs/9.9.9"
        )

      assert headers == [
               {"authorization", "Bearer upstream-token"},
               {"user-agent", "codex_cli_rs/9.9.9"},
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
    |> Keyword.put(:forwarded_headers, forwarded_metadata_headers())
    |> Map.new()
    |> RequestOptions.build(endpoint, %{"model" => "example-model"})
  end

  defp forwarded_metadata_headers do
    approved_forwarded_metadata_headers() ++
      [
        {"User-Agent", "downstream-harness/1.0"},
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
end
