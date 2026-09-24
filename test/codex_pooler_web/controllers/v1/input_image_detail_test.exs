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
  end

  defp captured_images(upstream) do
    assert [captured] = FakeUpstream.requests(upstream)

    for item <- captured.json["input"],
        part <- List.wrap(item["content"]),
        is_map(part) and part["type"] == "input_image",
        do: part
  end
end
