defmodule CodexPooler.Gateway.RequestCompression.EligibilityTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.RequestCompression
  alias CodexPooler.Gateway.Runtime.Dispatch.Context
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState
  alias CodexPooler.Pools.RoutingSettings
  alias CodexPooler.RouteClass

  @responses_endpoint "/backend-api/codex/responses"
  @compact_endpoint "/backend-api/codex/responses/compact"
  @public_responses_endpoint "/v1/responses"
  @public_chat_endpoint "/v1/chat/completions"
  @public_unsupported_compact_endpoint "/v1/responses/compact"
  @supported_model "gpt-4o"

  describe "maybe_compress/3 eligibility" do
    test "disabled pool skips with no body mutation and safe metadata" do
      body = response_body()
      {context, request_options} = request_context(body, enabled?: false)

      assert {^body, compressed_options} =
               RequestCompression.maybe_compress(body, context, request_options)

      assert %{
               "enabled" => false,
               "attempted" => true,
               "status" => "disabled",
               "reason" => "pool_disabled",
               "route_class" => "proxy_http",
               "transport" => "http_json"
             } = compressed_options.runtime.payload_compression
    end

    test "enabled pool attempts eligible HTTP Responses bodies as a safe no-op" do
      body = response_body()
      {context, request_options} = request_context(body)

      assert {^body, compressed_options} =
               RequestCompression.maybe_compress(body, context, request_options)

      assert_attempted_noop_metadata(
        compressed_options.runtime.payload_compression,
        "proxy_http",
        "http_json",
        byte_size(body)
      )
    end

    test "enabled pool attempts eligible SSE Responses bodies as a safe no-op" do
      body = response_body(%{"stream" => true})
      {context, request_options} = request_context(body, route_class: RouteClass.proxy_stream())

      assert {^body, compressed_options} =
               RequestCompression.maybe_compress(body, context, request_options)

      assert_attempted_noop_metadata(
        compressed_options.runtime.payload_compression,
        "proxy_stream",
        "http_sse",
        byte_size(body)
      )
    end

    test "enabled pool attempts eligible compact bodies as a safe no-op" do
      body = response_body()

      {context, request_options} =
        request_context(body,
          endpoint: @compact_endpoint,
          upstream_endpoint: @compact_endpoint,
          route_class: RouteClass.proxy_compact(),
          transport: "http_compact_json"
        )

      assert {^body, compressed_options} =
               RequestCompression.maybe_compress(body, context, request_options)

      assert_attempted_noop_metadata(
        compressed_options.runtime.payload_compression,
        "proxy_compact",
        "http_compact_json",
        byte_size(body)
      )
    end

    test "enabled pool attempts eligible websocket response create bodies as a safe no-op" do
      body = response_body(%{"type" => "response.create"})

      {context, request_options} =
        request_context(body,
          route_class: RouteClass.proxy_websocket(),
          transport: "websocket"
        )

      request_options =
        request_options
        |> RequestOptions.for_websocket(%{
          "type" => "response.create",
          "model" => @supported_model
        })
        |> RequestOptions.put_transport(route_class: RouteClass.proxy_websocket())

      context = %{
        context
        | request_options: request_options,
          route_class: RouteClass.proxy_websocket()
      }

      assert {^body, compressed_options} =
               RequestCompression.maybe_compress(body, context, request_options)

      assert_attempted_noop_metadata(
        compressed_options.runtime.payload_compression,
        "proxy_websocket",
        "websocket",
        byte_size(body)
      )
    end

    test "multipart payloads skip before JSON handling" do
      payload = {:multipart, [{:prompt, "sample"}]}

      {context, request_options} =
        request_context(response_body(),
          route_class: RouteClass.proxy_http(),
          transport: "http_json"
        )

      assert {^payload, compressed_options} =
               RequestCompression.maybe_compress(payload, context, request_options)

      assert %{
               "enabled" => true,
               "attempted" => true,
               "status" => "ineligible",
               "reason" => "payload_kind_ineligible"
             } = compressed_options.runtime.payload_compression
    end

    test "non-responses runtime and operator paths skip without body mutation" do
      body = response_body()

      cases = [
        {"/backend-api/files", RouteClass.file_upload(), "http_json"},
        {"/backend-api/transcribe", RouteClass.audio_transcription(), "http_multipart"},
        {"/backend-api/codex/images/generations", RouteClass.proxy_http(), "http_json"},
        {"/api/codex/usage", RouteClass.proxy_http(), "http_json"},
        {"/backend-api/codex/alpha/search", RouteClass.proxy_control(), "http_json"},
        {"/admin/request-logs", RouteClass.admin_browser(), "http_json"},
        {"/mcp", RouteClass.mcp(), "http_json"}
      ]

      for {endpoint, route_class, transport} <- cases do
        {context, request_options} =
          request_context(body,
            endpoint: endpoint,
            upstream_endpoint: endpoint,
            route_class: route_class,
            transport: transport
          )

        assert {^body, compressed_options} =
                 RequestCompression.maybe_compress(body, context, request_options)

        assert %{
                 "enabled" => true,
                 "attempted" => true,
                 "status" => "ineligible",
                 "reason" => "route_ineligible"
               } = compressed_options.runtime.payload_compression
      end
    end

    test "public responses and chat translations are eligible through their backend upstream endpoint" do
      body = response_body()

      for source_endpoint <- [@public_responses_endpoint, @public_chat_endpoint] do
        {context, request_options} =
          request_context(body,
            endpoint: @responses_endpoint,
            upstream_endpoint: @responses_endpoint,
            source_endpoint: source_endpoint,
            translated_endpoint: @responses_endpoint,
            route_class: RouteClass.proxy_http(),
            transport: "http_json"
          )

        assert {^body, compressed_options} =
                 RequestCompression.maybe_compress(body, context, request_options)

        assert_attempted_noop_metadata(
          compressed_options.runtime.payload_compression,
          "proxy_http",
          "http_json",
          byte_size(body)
        )
      end
    end

    test "public compact remains ineligible because it has no upstream dispatch" do
      body = response_body()

      {context, request_options} =
        request_context(body,
          endpoint: @public_unsupported_compact_endpoint,
          upstream_endpoint: @public_unsupported_compact_endpoint,
          route_class: RouteClass.proxy_http(),
          transport: "http_json"
        )

      assert {^body, compressed_options} =
               RequestCompression.maybe_compress(body, context, request_options)

      assert %{
               "enabled" => true,
               "attempted" => true,
               "status" => "ineligible",
               "reason" => "route_ineligible"
             } = compressed_options.runtime.payload_compression
    end

    test "metadata never echoes body content" do
      sentinel = "sentinel private payload text"
      body = response_body(%{"input" => [%{"type" => "message", "content" => sentinel}]})
      {context, request_options} = request_context(body)

      assert {^body, compressed_options} =
               RequestCompression.maybe_compress(body, context, request_options)

      refute inspect(compressed_options.runtime.payload_compression) =~ sentinel
    end
  end

  defp assert_attempted_noop_metadata(metadata, route_class, transport, bytes) do
    assert %{
             "enabled" => true,
             "attempted" => true,
             "status" => "no_change",
             "reason" => "no_candidates",
             "route_class" => ^route_class,
             "transport" => ^transport,
             "candidate_count" => 0,
             "compressed_count" => 0,
             "skipped_count" => 0,
             "original_bytes" => ^bytes,
             "compressed_bytes" => ^bytes,
             "saved_bytes" => 0
           } = metadata

    assert metadata["byte_savings_ratio"] == 0.0
    assert metadata["byte_savings_percent"] == 0.0
    assert metadata["compression_ratio"] == 1.0
  end

  defp request_context(body, opts \\ []) do
    endpoint = Keyword.get(opts, :endpoint, @responses_endpoint)
    upstream_endpoint = Keyword.get(opts, :upstream_endpoint, @responses_endpoint)
    route_class = Keyword.get(opts, :route_class, RouteClass.proxy_http())
    transport = Keyword.get(opts, :transport, default_transport(route_class))
    payload = Jason.decode!(body)

    request_options =
      %{transport: transport, upstream_endpoint: upstream_endpoint}
      |> RequestOptions.build(endpoint, payload)
      |> RequestOptions.put_transport(
        route_class: route_class,
        upstream_endpoint: upstream_endpoint
      )
      |> maybe_mark_origin(opts)

    context = %Context{
      endpoint: endpoint,
      payload: payload,
      model: model(),
      request_options: request_options,
      route_state: %RouteState{
        visible_model: model(),
        candidates: [],
        routing_settings: routing_settings(Keyword.get(opts, :enabled?, true))
      },
      route_class: route_class
    }

    {context, request_options}
  end

  defp maybe_mark_origin(request_options, opts) do
    source_endpoint = Keyword.get(opts, :source_endpoint)
    translated_endpoint = Keyword.get(opts, :translated_endpoint)

    if is_binary(source_endpoint) and is_binary(translated_endpoint) do
      RequestOptions.mark_openai_compatibility_origin(
        request_options,
        source_endpoint,
        translated_endpoint
      )
    else
      request_options
    end
  end

  defp default_transport(route_class) do
    case route_class do
      "proxy_stream" -> "http_sse"
      "proxy_compact" -> "http_compact_json"
      "proxy_websocket" -> "websocket"
      _route_class -> "http_json"
    end
  end

  defp response_body(overrides \\ %{}) do
    %{
      "model" => @supported_model,
      "input" => []
    }
    |> Map.merge(overrides)
    |> Jason.encode!()
  end

  defp model do
    %Model{
      exposed_model_id: @supported_model,
      upstream_model_id: @supported_model
    }
  end

  defp routing_settings(enabled?) do
    %RoutingSettings{}
    |> Map.put(:request_compression_enabled, enabled?)
  end
end
