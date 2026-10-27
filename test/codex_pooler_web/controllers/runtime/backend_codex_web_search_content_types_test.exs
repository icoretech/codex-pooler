defmodule CodexPoolerWeb.Runtime.BackendCodexWebSearchContentTypesTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 2, start_upstream: 1]

  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport,
    only: [
      collect_native_turn_frames!: 1,
      completed_response_events: 4,
      completed_response_frames: 4,
      model_serving_scope: 0,
      set_model_serving_mode!: 3
    ]

  alias CodexPooler.Access
  alias CodexPooler.FakeUpstream
  alias CodexPoolerWeb.CodexResponsesSocket

  @path "/backend-api/codex/responses"
  @inline_image_url "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

  for mode <- ["full", "lite"] do
    test "native HTTP #{mode} preserves hosted search content types with image input", %{conn: conn} do
      upstream = start_upstream(FakeUpstream.sse_stream(completed_response_events("resp_web_search_http", [], 5, 2)))
      setup = serving_setup(upstream, unquote(mode))

      response =
        conn
        |> auth(setup)
        |> maybe_lite_header(unquote(mode))
        |> post(@path, request_payload(setup.model.exposed_model_id))

      assert response.status == 200
      assert response.resp_body =~ "response.completed"
      assert [%{method: "POST", json: forwarded}] = FakeUpstream.requests(upstream)
      assert_forwarded_search!(forwarded, unquote(mode))
      assert forwarded_image_urls(forwarded) == [@inline_image_url, @inline_image_url]
      assert :ok = FakeUpstream.verify!(upstream)
    end

    test "native websocket #{mode} preserves hosted search content types with image input" do
      upstream = start_upstream(completed_response_frames("resp_web_search_ws", [], 5, 2))
      setup = serving_setup(upstream, unquote(mode))
      {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
      {:ok, state} = CodexResponsesSocket.init(%{auth: auth, opts: %{request_id: "web-search-#{unquote(mode)}", accepted_turn_state: Ecto.UUID.generate(), client_ip: "127.0.0.1"}})

      payload =
        request_payload(setup.model.exposed_model_id)
        |> Map.put("type", "response.create")
        |> Map.put("stream", true)

      try do
        assert {:ok, state} = CodexResponsesSocket.handle_in({CodexPooler.JSON.encode!(payload), [opcode: :text]}, state)
        {state, frames} = collect_native_turn_frames!(state)
        assert Enum.any?(frames, &(&1["type"] == "response.completed"))
        assert [%{method: "WEBSOCKET", json: forwarded}] = FakeUpstream.requests(upstream)
        assert_forwarded_search!(forwarded, unquote(mode))
        assert forwarded_image_urls(forwarded) == [@inline_image_url, @inline_image_url]
        assert :ok = CodexResponsesSocket.terminate(:closed, state)
      after
        CodexResponsesSocket.terminate(:closed, state)
      end

      assert :ok = FakeUpstream.verify!(upstream)
    end
  end

  defp serving_setup(upstream, mode) do
    setup =
      gateway_setup(upstream,
        model_metadata: %{
          "input_modalities" => ["text", "image"],
          "web_search_tool_type" => "text_and_image"
        }
      )

    set_model_serving_mode!(model_serving_scope(), setup, mode)
    setup
  end

  defp maybe_lite_header(conn, "lite"), do: Plug.Conn.put_req_header(conn, "x-openai-internal-codex-responses-lite", "true")
  defp maybe_lite_header(conn, _mode), do: conn

  defp request_payload(model) do
    %{
      "model" => model,
      "input" => [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [
            %{"type" => "input_text", "text" => "synthetic web search request"},
            %{"type" => "input_image", "image_url" => @inline_image_url},
            %{"type" => "input_image", "image_url" => @inline_image_url}
          ]
        }
      ],
      "tools" => [
        %{
          "type" => "web_search",
          "external_web_access" => true,
          "indexed_web_access" => true,
          "filters" => %{"allowed_domains" => ["example.com"]},
          "search_content_types" => ["text", "image"]
        }
      ],
      "stream" => true
    }
  end

  defp assert_forwarded_search!(%{"tools" => [tool]}, "full") do
    assert tool["type"] == "web_search"
    assert tool["external_web_access"] == true
    assert tool["indexed_web_access"] == true
    assert tool["filters"] == %{"allowed_domains" => ["example.com"]}
    assert tool["search_content_types"] == ["text", "image"]
  end

  defp assert_forwarded_search!(%{"input" => input} = forwarded, "lite") do
    refute Map.has_key?(forwarded, "tools")
    assert [%{"type" => "additional_tools", "tools" => [tool]} | _] = input
    assert tool["type"] == "web_search"
    assert tool["external_web_access"] == true
    assert tool["indexed_web_access"] == true
    assert tool["filters"] == %{"allowed_domains" => ["example.com"]}
    assert tool["search_content_types"] == ["text", "image"]
  end

  defp forwarded_image_urls(%{"input" => input}) do
    for %{"content" => content} <- input,
        %{"type" => "input_image", "image_url" => image_url} <- content,
        do: image_url
  end
end
