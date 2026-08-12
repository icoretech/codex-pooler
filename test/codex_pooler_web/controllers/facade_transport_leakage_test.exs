defmodule CodexPoolerWeb.FacadeTransportLeakageTest do
  use CodexPoolerWeb.ConnCase, async: true

  import CodexPooler.FacadeAssertions

  alias CodexPooler.Gateway.Facade.{PublicProjection}
  alias CodexPooler.Gateway.Transports.Streaming.WebsocketCodec
  alias CodexPoolerWeb.GatewayControllerHelpers
  alias CodexPoolerWeb.PublicGatewayResult

  test "JSON bodies and headers expose only the virtual identity" do
    hidden = facade_sentinels()

    conn =
      Phoenix.ConnTest.build_conn(:post, "/v1/responses")
      |> put_resp_header("x-request-id", "local-request-id")
      |> GatewayControllerHelpers.send_gateway_result(%{
        status: 200,
        headers: private_headers(hidden),
        body: private_response(hidden, "safe public answer")
      })

    body = json_response(conn, 200)

    assert body == %{
             "id" => "local-response-id",
             "object" => "response",
             "model" => "gemma3",
             "output" => [
               %{
                 "type" => "message",
                 "content" => [%{"type" => "output_text", "text" => "safe public answer"}]
               }
             ]
           }

    assert get_resp_header(conn, "x-request-id") == ["local-request-id"]
    assert_cloaked_json(body)
    assert_cloaked_headers(conn)
  end

  test "NDJSON, SSE, and websocket frames reject every private transport sentinel" do
    hidden = facade_sentinels()

    projected =
      hidden
      |> private_response("safe streamed answer")
      |> PublicProjection.gateway_body()

    ndjson = Jason.encode!(projected) <> "\n"

    sse =
      "event: response.completed\n" <>
        "data: " <>
        Jason.encode!(%{
          "type" => "response.completed",
          "provider" => hidden.provider,
          "assignment_id" => hidden.assignment,
          "request_id" => hidden.request_id,
          "response" => private_response(hidden, "safe streamed answer")
        }) <>
        "\n\n"

    projected_sse = PublicProjection.sse_block(sse) |> IO.iodata_to_binary()

    parent = self()

    assert :ok =
             WebsocketCodec.deliver_result(
               %{body: private_response(hidden, "safe streamed answer")},
               fn frame -> send(parent, {:public_frame, frame}) end
             )

    assert_receive {:public_frame, websocket_frame}

    assert_cloaked_ndjson(ndjson)
    assert_cloaked_sse(projected_sse)
    assert_cloaked_websocket([websocket_frame])
  end

  test "projection preserves literal private-looking words only when they are content" do
    hidden = facade_sentinels()

    content =
      Enum.join(
        [
          hidden.target_model,
          hidden.provider,
          hidden.account,
          hidden.assignment,
          hidden.endpoint,
          hidden.request_id,
          hidden.credential,
          hidden.cache
        ],
        " | "
      )

    projected =
      hidden
      |> private_response(content)
      |> PublicProjection.gateway_body()

    assert get_in(projected, ["output", Access.at(0), "content", Access.at(0), "text"]) ==
             content

    assert_cloaked_json(projected, allow_content: [content])
  end

  test "malformed and unknown collected responses become local 502 failures" do
    for result <- [
          %{status: 200, headers: [], raw_body: "{provider-private-not-json"},
          %{status: 200, headers: [], body: %{"unknown" => "provider-private"}}
        ] do
      conn =
        Phoenix.ConnTest.build_conn(:post, "/v1/responses")
        |> GatewayControllerHelpers.send_gateway_result(result)

      assert %{
               "error" => %{
                 "code" => "server_error",
                 "message" => "gemma3 request failed"
               }
             } = json_response(conn, 502)

      refute conn.resp_body =~ "provider-private"
    end

    for raw <- [
          Jason.encode!(%{"unknown" => "private"}),
          "{malformed-provider-private",
          Jason.encode!([%{"provider" => "private"}])
        ] do
      conn =
        Phoenix.ConnTest.build_conn(:post, "/v1/responses")
        |> PublicGatewayResult.send(
          {:ok, %{status: 200, headers: [], raw_body: raw}},
          & &1
        )

      assert json_response(conn, 502)["error"]["code"] == "server_error"
      refute conn.resp_body =~ "private"
    end

    malformed_chat =
      Jason.encode!(%{
        "id" => "chatcmpl-malformed-provider",
        "object" => "chat.completion",
        "created" => 1_723_000_000,
        "model" => "private-provider-model",
        "choices" => %{"provider" => "private-chat-sentinel"}
      })

    conn =
      Phoenix.ConnTest.build_conn(:post, "/v1/chat/completions")
      |> PublicGatewayResult.send(
        {:ok, %{status: 200, headers: [], raw_body: malformed_chat}},
        & &1
      )

    assert json_response(conn, 502)["error"]["code"] == "server_error"
    refute conn.resp_body =~ "private-chat-sentinel"
    refute conn.resp_body =~ "private-provider-model"
  end

  defp private_response(hidden, content) do
    %{
      "id" => "local-response-id",
      "object" => "response",
      "model" => hidden.target_model,
      "provider" => hidden.provider,
      "account_id" => hidden.account,
      "assignment_id" => hidden.assignment,
      "upstream_endpoint" => hidden.endpoint,
      "request_id" => hidden.request_id,
      "output" => [
        %{
          "type" => "message",
          "content" => [%{"type" => "output_text", "text" => content}]
        }
      ]
    }
  end

  defp private_headers(hidden) do
    [
      {"content-type", "application/json"},
      {"x-openai-model", hidden.target_model},
      {"x-provider-name", hidden.provider},
      {"x-account-id", hidden.account},
      {"x-assignment-id", hidden.assignment},
      {"x-upstream-endpoint", hidden.endpoint},
      {"x-request-id", hidden.request_id},
      {"authorization", "Bearer #{hidden.credential}"},
      {"x-prompt-cache-key", hidden.cache}
    ]
  end
end
