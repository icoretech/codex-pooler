defmodule CodexPooler.Gateway.OpenAICompatibility.ImagesProtocolTest do
  use ExUnit.Case, async: true
  alias CodexPooler.Gateway.OpenAICompatibility.{Images, Responses}

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
