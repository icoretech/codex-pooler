defmodule CodexPoolerWeb.V1.InputImageDetailTest do
  # `input_image.detail` on the two `/v1` routes that build the upstream
  # request themselves. Probed directly on 2026-09-24 (findings#206 rows
  # 206-487, 206-488): the Codex backend accepts `detail: null` and
  # `detail: original` on a message image (`gpt-6-luna`, Full), the public
  # Chat Completions API accepts `image_url.detail` on `gpt-6-luna`, and the
  # Codex backend refuses a detail outside low, high, auto and original
  # (row 206-476). The released Codex client never serializes a null detail
  # and removes every detail for a Responses Lite model.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3]

  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  @vision_metadata %{"input_modalities" => ["text", "image"]}

  @completed %{
    "id" => "resp_image_detail",
    "object" => "response",
    "status" => "completed",
    "output" => [%{"type" => "message", "role" => "assistant", "content" => [%{"type" => "output_text", "text" => "red"}]}],
    "usage" => %{"input_tokens" => 4, "output_tokens" => 1, "total_tokens" => 5}
  }

  for mode <- ["full", "lite"] do
    @tag serving_mode: mode
    test "/v1/responses drops a null message input_image detail and keeps a string one on a #{mode} model", %{conn: conn, serving_mode: mode} do
      upstream = start_upstream(FakeUpstream.json_response(@completed))
      setup = gateway_setup(upstream, model_metadata: @vision_metadata)
      _revision = set_model_serving_mode!(model_serving_scope(), setup, mode)

      conn =
        conn
        |> auth(setup)
        |> post("/v1/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => [
            %{
              "type" => "message",
              "role" => "user",
              "content" => [
                %{"type" => "input_text", "text" => "synthetic image question"},
                %{"type" => "input_image", "image_url" => "https://example.com/null.png", "detail" => nil},
                %{"type" => "input_image", "image_url" => "https://example.com/high.png", "detail" => "high"}
              ]
            }
          ]
        })

      assert %{"id" => "resp_image_detail"} = json_response(conn, 200)
      assert [null_image, high_image] = captured_images(upstream)

      refute Map.has_key?(null_image, "detail")
      assert high_image["detail"] == if(mode == "lite", do: nil, else: "high")
    end

    @tag serving_mode: mode
    test "/v1/chat/completions forwards image_url.detail as the input_image detail on a #{mode} model", %{conn: conn, serving_mode: mode} do
      upstream = start_upstream(FakeUpstream.json_response(@completed))
      setup = gateway_setup(upstream, model_metadata: @vision_metadata)
      _revision = set_model_serving_mode!(model_serving_scope(), setup, mode)

      conn =
        conn
        |> auth(setup)
        |> post("/v1/chat/completions", %{
          "model" => setup.model.exposed_model_id,
          "messages" => [
            %{
              "role" => "user",
              "content" => [
                %{"type" => "text", "text" => "synthetic image question"},
                %{"type" => "image_url", "image_url" => %{"url" => "https://example.com/original.png", "detail" => "original"}},
                %{"type" => "image_url", "image_url" => %{"url" => "https://example.com/null.png", "detail" => nil}}
              ]
            }
          ]
        })

      assert %{"object" => "chat.completion"} = json_response(conn, 200)
      assert [original_image, null_image] = captured_images(upstream)

      # Lite removes the hint, as the released client does for a Responses Lite
      # model; Full forwards it as the Responses adapter does.
      assert original_image["detail"] == if(mode == "lite", do: nil, else: "original")
      assert original_image["image_url"] == "https://example.com/original.png"
      refute Map.has_key?(null_image, "detail")
    end

    @tag serving_mode: mode
    test "/v1/chat/completions refuses an image_url.detail outside the provider enum on a #{mode} model", %{conn: conn, serving_mode: mode} do
      upstream = start_upstream(FakeUpstream.json_response(@completed))
      setup = gateway_setup(upstream, model_metadata: @vision_metadata)
      _revision = set_model_serving_mode!(model_serving_scope(), setup, mode)

      conn =
        conn
        |> auth(setup)
        |> post("/v1/chat/completions", %{
          "model" => setup.model.exposed_model_id,
          "messages" => [
            %{
              "role" => "user",
              "content" => [
                %{"type" => "text", "text" => "synthetic image question"},
                %{"type" => "image_url", "image_url" => %{"url" => "https://example.com/bogus.png", "detail" => "bogus"}}
              ]
            }
          ]
        })

      assert %{"error" => %{"type" => "invalid_request_error", "code" => "invalid_value", "param" => "messages[0].content[1].image_url.detail", "message" => message}} = json_response(conn, 400)
      assert message =~ "low, high, auto, original"
      refute message =~ "bogus"
      assert FakeUpstream.count(upstream) == 0
      assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 0
    end

    # Hermes in its default `chat_completions` mode sends a screenshot tool
    # result as a Chat tool message with `image_url` parts; the rebuild carries
    # them into the `function_call_output`, which the Codex backend accepts.
    @tag serving_mode: mode
    test "/v1/chat/completions carries a tool message image into the function_call_output on a #{mode} model", %{conn: conn, serving_mode: mode} do
      upstream = start_upstream(FakeUpstream.json_response(@completed))
      setup = gateway_setup(upstream, model_metadata: @vision_metadata)
      _revision = set_model_serving_mode!(model_serving_scope(), setup, mode)

      conn =
        conn
        |> auth(setup)
        |> post("/v1/chat/completions", %{
          "model" => setup.model.exposed_model_id,
          "messages" => [
            %{"role" => "user", "content" => "synthetic screenshot request"},
            %{"role" => "assistant", "content" => nil, "tool_calls" => [%{"id" => "call_fixture_screenshot", "type" => "function", "function" => %{"name" => "computer_use", "arguments" => "{}"}}]},
            %{
              "role" => "tool",
              "name" => "computer_use",
              "tool_call_id" => "call_fixture_screenshot",
              "content" => [
                %{"type" => "text", "text" => "synthetic capture summary"},
                %{"type" => "image_url", "image_url" => %{"url" => "https://example.com/screen.png", "detail" => "high"}}
              ]
            }
          ]
        })

      assert %{"object" => "chat.completion"} = json_response(conn, 200)
      assert [%{"type" => "input_text"}, image] = captured_tool_output(upstream, "call_fixture_screenshot")
      assert image["type"] == "input_image"
      assert image["image_url"] == "https://example.com/screen.png"
      assert image["detail"] == if(mode == "lite", do: nil, else: "high")
    end

    # findings#206 row 206-494: the two Pooler extension shapes that carry a
    # Chat-style image inside a tool result keep its detail on Full, lose it on
    # Lite, and are refused before reservation when it is outside the enum.
    @tag serving_mode: mode
    test "/v1/responses forwards a role tool image_url.detail on a #{mode} model", %{conn: conn, serving_mode: mode} do
      upstream = start_upstream(FakeUpstream.json_response(@completed))
      setup = gateway_setup(upstream, model_metadata: @vision_metadata)
      _revision = set_model_serving_mode!(model_serving_scope(), setup, mode)

      conn =
        conn
        |> auth(setup)
        |> post("/v1/responses", %{"model" => setup.model.exposed_model_id, "input" => role_tool_image_input("original")})

      assert %{"id" => "resp_image_detail"} = json_response(conn, 200)
      assert [%{"type" => "input_text"}, image] = captured_tool_output(upstream, "call_fixture_role_tool_image")
      assert image == %{"type" => "input_image", "image_url" => "https://example.com/screen.png"} |> maybe_detail(mode, "original")
    end

    @tag serving_mode: mode
    test "/v1/chat/completions forwards a Cline tool-result image detail on a #{mode} model", %{conn: conn, serving_mode: mode} do
      upstream = start_upstream(FakeUpstream.json_response(@completed))
      setup = gateway_setup(upstream, model_metadata: @vision_metadata)
      _revision = set_model_serving_mode!(model_serving_scope(), setup, mode)

      conn =
        conn
        |> auth(setup)
        |> post("/v1/chat/completions", %{"model" => setup.model.exposed_model_id, "messages" => cline_tool_result_messages("low")})

      assert %{"object" => "chat.completion"} = json_response(conn, 200)
      assert [%{"type" => "input_text"}, image] = captured_tool_output(upstream, "call_fixture_cline_image")
      assert image == %{"type" => "input_image", "image_url" => "https://example.com/screen.png"} |> maybe_detail(mode, "low")
    end

    @tag serving_mode: mode
    test "tool-result image_url.detail outside the provider enum is refused before reservation on a #{mode} model", %{conn: conn, serving_mode: mode} do
      upstream = start_upstream(FakeUpstream.json_response(@completed))
      setup = gateway_setup(upstream, model_metadata: @vision_metadata)
      _revision = set_model_serving_mode!(model_serving_scope(), setup, mode)

      requests = [
        {"/v1/responses", %{"model" => setup.model.exposed_model_id, "input" => role_tool_image_input("bogus")}, "input[1].content[1].image_url.detail"},
        {"/v1/chat/completions", %{"model" => setup.model.exposed_model_id, "messages" => cline_tool_result_messages("bogus")}, "messages[1].content[0].output[1].image_url.detail"}
      ]

      for {path, body, param} <- requests do
        response = conn |> recycle() |> auth(setup) |> post(path, body)

        assert %{"error" => %{"type" => "invalid_request_error", "code" => "invalid_value", "param" => ^param, "message" => message}} = json_response(response, 400)
        refute message =~ "bogus"
      end

      assert FakeUpstream.count(upstream) == 0
      assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 0
    end
  end

  defp role_tool_image_input(detail) do
    [
      %{"type" => "function_call", "call_id" => "call_fixture_role_tool_image", "name" => "computer_use", "arguments" => "{}"},
      %{
        "role" => "tool",
        "tool_call_id" => "call_fixture_role_tool_image",
        "content" => [%{"type" => "text", "text" => "synthetic capture summary"}, %{"type" => "image_url", "image_url" => %{"url" => "https://example.com/screen.png", "detail" => detail}}]
      }
    ]
  end

  defp cline_tool_result_messages(detail) do
    [
      %{"role" => "assistant", "content" => [%{"type" => "tool-call", "toolCallId" => "call_fixture_cline_image", "toolName" => "browser_action", "input" => %{"action" => "screenshot"}}]},
      %{
        "role" => "user",
        "content" => [
          %{
            "type" => "tool-result",
            "toolCallId" => "call_fixture_cline_image",
            "toolName" => "browser_action",
            "output" => [%{"type" => "text", "text" => "synthetic screenshot taken"}, %{"type" => "image_url", "image_url" => %{"url" => "https://example.com/screen.png", "detail" => detail}}]
          }
        ]
      }
    ]
  end

  defp maybe_detail(image, "lite", _detail), do: image
  defp maybe_detail(image, _mode, detail), do: Map.put(image, "detail", detail)

  defp captured_tool_output(upstream, call_id) do
    assert [captured] = FakeUpstream.requests(upstream)
    assert [%{"output" => output}] = for(%{"type" => "function_call_output", "call_id" => ^call_id} = item <- captured.json["input"], do: item)
    output
  end

  defp captured_images(upstream) do
    assert [captured] = FakeUpstream.requests(upstream)

    for item <- captured.json["input"],
        part <- List.wrap(item["content"]),
        is_map(part) and part["type"] == "input_image",
        do: part
  end
end
