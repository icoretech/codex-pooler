defmodule CodexPooler.Gateway.OpenAICompatibility.ImagesProtocolTest do
  use ExUnit.Case, async: true
  alias CodexPooler.Gateway.OpenAICompatibility.{Images, Responses}

  @image_25_models ~w(gpt-image-2.5-flare gpt-image-2.5-sunburst gpt-image-2.5-flare-2026-09-08 gpt-image-2.5-sunburst-2026-09-08)

  test "GPT Image 2.5 preserves extended qualities and custom size boundaries" do
    for model <- @image_25_models,
        quality <- ~w(auto low medium high xhigh max),
        size <- ~w(auto 1536x864 864x1536 1024x640 640x1024 3840x2160 2160x3840 1536x512) do
      assert {:ok, response} =
               Images.coerce_generation(%{
                 "model" => model,
                 "prompt" => "synthetic",
                 "quality" => quality,
                 "size" => size,
                 "background" => "transparent"
               })

      assert response.endpoint == "/backend-api/codex/images/generations"
      assert response.payload["model"] == model
      assert response.payload["quality"] == quality
      assert response.payload["size"] == size
      assert response.payload["background"] == "transparent"
    end
  end

  test "GPT Image 2.5 rejects malformed and out-of-range options" do
    for model <- @image_25_models,
        {key, value} <- [
          {"quality", "ultra"},
          {"quality", 1},
          {"quality", %{}},
          {"size", 1024},
          {"size", %{}},
          {"size", "1536X864"},
          {"size", "1536x864suffix"},
          {"size", "1537x864"},
          {"size", "1536x865"},
          {"size", "0x1024"},
          {"size", "-1024x1024"},
          {"size", "3856x2048"},
          {"size", "2048x3856"},
          {"size", "1024x624"},
          {"size", "3840x2176"},
          {"size", "1552x512"},
          {"size", "512x1552"}
        ] do
      assert {:error, %{status: 400, param: ^key}} =
               Images.coerce_generation(%{
                 "model" => model,
                 "prompt" => "synthetic",
                 key => value
               })
    end
  end

  test "older image models retain their quality boundary" do
    for model <- ~w(gpt-image-1 gpt-image-1-mini gpt-image-1.5 gpt-image-2),
        quality <- ~w(xhigh max) do
      assert {:error, %{status: 400, param: "quality"}} =
               Images.coerce_generation(%{
                 "model" => model,
                 "prompt" => "synthetic",
                 "quality" => quality
               })
    end
  end

  test "generation rejects edit-only fields and unsupported response formats" do
    for {key, value} <- [
          {"mask", nil},
          {"input_fidelity", "high"},
          {"response_format", "url"},
          {"response_format", %{}},
          {"user", 12}
        ] do
      assert {:error, %{status: 400, param: ^key}} =
               Images.validate_generation(Map.put(payload(), key, value))
    end
  end

  test "base64 response format is accepted and user identifiers are discarded" do
    for user <- [nil, "synthetic-user"] do
      assert {:ok, normalized} =
               Images.validate_generation(
                 Map.merge(payload(), %{"response_format" => "b64_json", "user" => user})
               )

      refute Map.has_key?(normalized, "user")
    end
  end

  test "completed output does not duplicate the output-item event" do
    for id <- [nil, "ig_fixture"] do
      item = %{
        "type" => "image_generation_call",
        "status" => "completed",
        "result" => "SYNTHETIC"
      }

      item = if id, do: Map.put(item, "id", id), else: item

      body =
        stream([
          %{"type" => "response.output_item.done", "item" => item},
          %{"type" => "response.completed", "response" => %{"output" => [item]}}
        ])

      assert {:ok, %{"data" => [_one]}} = Images.image_response_from_sse(body)
    end
  end

  test "failed item errors are fixed public errors" do
    body =
      stream([
        %{
          "type" => "response.output_item.done",
          "item" => %{
            "type" => "image_generation_call",
            "status" => "failed",
            "error" => %{
              "type" => "invalid_request_error",
              "code" => "synthetic-private-code",
              "message" => "synthetic-private-message",
              "param" => "synthetic-private-param"
            }
          }
        }
      ])

    assert {:error,
            %{
              status: 400,
              code: "image_generation_failed",
              message: "upstream image generation failed",
              param: nil
            }} = Images.image_response_from_sse(body)
  end

  test "edit mask is carried by the image tool without modifying prompt" do
    path = Path.join(System.tmp_dir!(), "image-protocol-#{System.unique_integer([:positive])}")
    File.write!(path, <<0, 1, 2>>)
    on_exit(fn -> File.rm(path) end)
    upload = %Plug.Upload{path: path, filename: "sample.png", content_type: "image/png"}

    assert {:ok, response} =
             Images.coerce_edit(Map.merge(payload(), %{"image" => upload, "mask" => upload}))

    assert [%{"content" => [%{"text" => "synthetic"}, %{"type" => "input_image"}]}] =
             response.payload["input"]

    assert [%{"input_image_mask" => %{"image_url" => url}}] = response.payload["tools"]
    assert String.starts_with?(url, "data:image/png;base64,")
    assert response.payload["tool_choice"] == %{"type" => "image_generation"}
  end

  test "GPT Image 2.5 masked edits preserve extended options in Responses translation" do
    path =
      Path.join(System.tmp_dir!(), "image-mask-options-#{System.unique_integer([:positive])}")

    File.write!(path, <<0, 1, 2>>)
    on_exit(fn -> File.rm(path) end)
    upload = %Plug.Upload{path: path, filename: "sample.png", content_type: "image/png"}

    for model <- @image_25_models, quality <- ~w(xhigh max) do
      assert {:ok, response} =
               Images.coerce_edit(%{
                 "model" => model,
                 "prompt" => "synthetic",
                 "image" => upload,
                 "mask" => upload,
                 "quality" => quality,
                 "size" => "1536x864"
               })

      assert response.endpoint == "/backend-api/codex/responses"
      assert response.payload["tool_choice"] == %{"type" => "image_generation"}

      assert [
               %{
                 "model" => ^model,
                 "quality" => ^quality,
                 "size" => "1536x864",
                 "input_image_mask" => %{"image_url" => _}
               }
             ] = response.payload["tools"]
    end
  end

  test "terminal output supersedes earlier same-id items and ignores created snapshots" do
    item = %{"id" => "ig_fixture", "type" => "image_generation_call", "status" => "in_progress"}
    final = Map.merge(item, %{"status" => "completed", "result" => "FINAL"})

    body =
      stream([
        %{"type" => "response.created", "response" => %{"output" => [item]}},
        %{"type" => "response.output_item.done", "item" => item},
        %{"type" => "response.completed", "response" => %{"output" => [final]}}
      ])

    assert {:ok, %{"data" => [%{"b64_json" => "FINAL"}]}} = Images.image_response_from_sse(body)
  end

  test "null item ids do not collapse distinct results and failed final items remain errors" do
    one = %{
      "id" => nil,
      "type" => "image_generation_call",
      "status" => "completed",
      "result" => "ONE"
    }

    two = Map.put(one, "result", "TWO")

    assert {:ok, %{"data" => [_, _]}} =
             Images.image_response_from_sse(
               stream([
                 %{"type" => "response.completed", "response" => %{"output" => [one, two]}}
               ])
             )

    failed = Map.put(one, "status", "failed")

    assert {:error, %{code: "image_generation_failed"}} =
             Images.image_response_from_sse(
               stream([
                 %{"type" => "response.output_item.done", "item" => one},
                 %{"type" => "response.completed", "response" => %{"output" => [failed]}}
               ])
             )
  end

  test "Responses mask admission rejects malformed mask shapes" do
    for mask <- [
          nil,
          "invalid",
          %{},
          %{"image_url" => 12},
          %{"image_url" => ""},
          %{"image_url" => "data:image/png;base64,AAEC", "extra" => true}
        ] do
      tool = %{
        "type" => "image_generation",
        "model" => "gpt-image-1",
        "size" => "auto",
        "quality" => "auto",
        "input_image_mask" => mask
      }

      assert {:error, %{param: "tools"}} =
               Responses.validate(%{
                 "model" => "gpt-image-1",
                 "input" => "synthetic",
                 "tools" => [tool]
               })
    end
  end

  test "failed terminal cannot expose an earlier successful image" do
    item = %{"type" => "image_generation_call", "status" => "completed", "result" => "SYNTHETIC"}

    for type <- ["response.failed", "response.incomplete", "error"] do
      assert {:error, %{code: "image_generation_failed"}} =
               Images.image_response_from_sse(
                 stream([
                   %{"type" => "response.output_item.done", "item" => item},
                   %{"type" => type}
                 ])
               )
    end
  end

  test "native generation preserves all supported quality values and sizes" do
    for quality <- ~w(auto low medium high), size <- ~w(auto 1024x1024 1024x1536 1536x1024) do
      assert {:ok,
              %{
                endpoint: "/backend-api/codex/images/generations",
                payload: %{
                  "quality" => ^quality,
                  "size" => ^size,
                  "background" => "opaque",
                  "n" => 1
                }
              }} =
               Images.coerce_generation(%{
                 "model" => "gpt-image-2",
                 "prompt" => "synthetic",
                 "quality" => quality,
                 "size" => size,
                 "background" => "opaque",
                 "n" => 1
               })
    end
  end

  defp payload, do: %{"model" => "gpt-image-1", "prompt" => "synthetic"}

  defp stream(events),
    do: Enum.map_join(events, "", &("data: " <> CodexPooler.JSON.encode!(&1) <> "\n\n"))
end
