defmodule CodexPooler.Accounting.ImageProjectionTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Accounting.PricingResolution.{ImageProjection, InputEstimate}
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.OpenAICompatibility.{Chat, Images, Responses}
  alias CodexPooler.Gateway.Payloads.{PayloadNormalizer, RequestOptions}

  @url "https://example.com/sample.png"
  @endpoint "/backend-api/codex/responses"

  test "message occurrences retain structure, detail and ordinary fields without mutating input" do
    image = image() |> Map.put("detail", "high") |> Map.put("metadata", %{"image_url" => @url})
    payload = %{"input" => [message([image, image, %{"type" => "input_text", "text" => @url}])], "instructions" => @url}
    before = :erlang.term_to_binary(payload)

    assert {projected, 2} = ImageProjection.project(payload, %{})
    assert projected == put_in(payload, ["input"], [message([%{image | "image_url" => ""}, %{image | "image_url" => ""}, %{"type" => "input_text", "text" => @url}])])
    assert :erlang.term_to_binary(payload) == before
  end

  test "alternate locators on one image count once and only locator strings are neutralized" do
    part = image() |> Map.merge(%{"file_id" => "file-synthetic", "data" => "ordinary", "url" => "ordinary", "width" => 8})
    assert {projected, 1} = ImageProjection.project(%{"input" => [message([part])]}, %{})
    assert projected["input"] == [message([%{part | "image_url" => "", "file_id" => ""}])]

    file = %{"type" => "input_image", "file_id" => "file-synthetic"}
    assert {_, 1} = ImageProjection.project(%{"input" => [message([file])]}, %{})
  end

  test "all tool-result semantic types support direct arrays and one content wrapper" do
    for type <- ["function_call_output", "custom_tool_call_output", "future_tool_output", "future_result"],
        field <- ["output", "result"],
        wrap? <- [false, true] do
      output = if wrap?, do: %{"content" => [image()], "other" => image()}, else: [image()]
      item = %{"type" => type, "call_id" => "call_synthetic", field => output}
      assert {projected, 1} = ImageProjection.project(%{"input" => [item]}, %{})
      neutral = %{image() | "image_url" => ""}
      expected = if wrap?, do: %{output | "content" => [neutral]}, else: [neutral]
      assert projected == %{"input" => [Map.put(item, field, expected)]}
    end

    standalone = %{"type" => "function_call_output", "name" => "sample_tool", "output" => [image()]}
    assert {_, 1} = ImageProjection.project(%{"input" => [standalone]}, %{})
  end

  test "atom and string keys preserve their original spelling and agree" do
    payload = %{input: [%{type: "message", role: "user", content: [%{type: "input_image", image_url: @url, detail: "original"}]}, %{type: "custom_tool_call_output", call_id: "call_synthetic", output: %{content: [%{type: "input_image", file_id: "file-synthetic"}]}}]}
    assert {projected, 2} = ImageProjection.project(payload, %{})
    assert projected == %{input: [%{type: "message", role: "user", content: [%{type: "input_image", image_url: "", detail: "original"}]}, %{type: "custom_tool_call_output", call_id: "call_synthetic", output: %{content: [%{type: "input_image", file_id: ""}]}}]}
  end

  test "real Chat adapter normalizes user and tool images before projection" do
    original = %{"model" => "sample-model", "messages" => [%{"role" => "user", "content" => [%{"type" => "image_url", "image_url" => %{"url" => @url, "detail" => "high"}}]}, %{"role" => "tool", "tool_call_id" => "call_synthetic", "content" => [%{"type" => "image_url", "image_url" => @url}]}]}
    assert {:ok, response} = Chat.coerce(original)
    before = :erlang.term_to_binary(response)
    assert {projected, 2} = ImageProjection.project(response.payload, %{})
    assert [user, tool] = projected["input"]
    assert [%{"image_url" => ""}] = user["content"]
    assert [%{"image_url" => ""}] = tool["output"]
    assert :erlang.term_to_binary(response) == before
  end

  test "real Responses adapter preserves supported tool-output content wrappers" do
    for type <- ["function_call_output", "custom_tool_call_output"] do
      raw = %{"model" => "sample-model", "input" => [%{"type" => type, "call_id" => "call_synthetic", "output" => %{"content" => [image()], "other" => image()}}]}
      assert {:ok, response} = Responses.coerce(raw)
      assert {projected, 1} = ImageProjection.project(response.payload, %{})
      assert [%{"output" => %{"content" => [%{"image_url" => ""}], "other" => untouched}}] = projected["input"]
      assert untouched == image()
    end
  end

  @tag :tmp_dir
  test "real native image edit arrays require the trusted native endpoint", %{tmp_dir: tmp_dir} do
    upload = upload(tmp_dir)
    assert {:ok, response} = Images.coerce_edit(%{"model" => "gpt-image-2", "prompt" => "synthetic", "image" => [upload, upload]})
    before = :erlang.term_to_binary(response)
    assert response.endpoint == "/backend-api/codex/images/edits"
    assert {projected, 2} = ImageProjection.project(response.payload, %{source_endpoint: response.endpoint})
    assert projected == %{response.payload | "images" => [%{"image_url" => ""}, %{"image_url" => ""}]}
    assert {same, 0} = ImageProjection.project(response.payload, %{})
    assert same == response.payload
    assert :erlang.term_to_binary(response) == before
  end

  @tag :tmp_dir
  test "real masked image edit counts message image and exact image-generation mask", %{tmp_dir: tmp_dir} do
    upload = upload(tmp_dir)
    assert {:ok, response} = Images.coerce_edit(%{"model" => "gpt-image-2", "prompt" => "synthetic", "image" => upload, "mask" => upload})
    before = :erlang.term_to_binary(response)
    assert response.endpoint == @endpoint
    assert {projected, 2} = ImageProjection.project(response.payload, %{source_endpoint: response.endpoint})
    assert [%{"content" => [_, %{"image_url" => ""}]}] = projected["input"]
    assert [%{"input_image_mask" => %{"image_url" => ""}}] = projected["tools"]
    assert :erlang.term_to_binary(response) == before
  end

  test "Full and Lite have the same image count while ordinary detail fields are preserved" do
    payload = %{"model" => "sample-model", "input" => [message([Map.put(image(), "detail", "original")])]}

    for mode <- [:full, :lite] do
      value = Atom.to_string(mode)
      options = RequestOptions.build(%{model_serving_mode_configured: value, model_serving_mode: value, model_serving_mode_source: "override"}, @endpoint, payload)
      assert {:ok, encoded} = PayloadNormalizer.upstream_payload(payload, %Model{upstream_model_id: "sample-model"}, @endpoint, options)
      upstream = CodexPooler.JSON.decode!(encoded)
      wire_message = Enum.find(upstream["input"], &(&1["type"] == "message"))
      [wire_image] = wire_message["content"]
      assert {projected, 1} = ImageProjection.project(payload, %{})
      assert {wire_projection, 1} = ImageProjection.project(upstream, %{})
      projected_message = Enum.find(wire_projection["input"], &(&1["type"] == "message"))
      assert hd(projected_message["content"])["detail"] == wire_image["detail"]
      assert wire_image["detail"] == if(mode == :lite, do: nil, else: "original")
      assert wire_image["image_url"] == @url
      assert [%{"content" => [%{"detail" => "original"}]}] = projected["input"]
    end
  end

  test "arbitrary nested JSON, schemas, instructions and strings remain exactly unchanged" do
    ordinary = %{"nested" => image(), "content" => %{"content" => [image()]}, "images" => [image()]}
    payload = %{"instructions" => ordinary, "input" => [%{"type" => "function_call_output", "call_id" => "call_synthetic", "output" => ordinary}, %{"type" => "function_call_output", "call_id" => "call_text", "output" => CodexPooler.JSON.encode!(image())}, message([%{"type" => "input_text", "text" => CodexPooler.JSON.encode!(image())}, ordinary])], "tools" => [%{"type" => "function", "parameters" => ordinary, "input_image_mask" => %{"image_url" => @url}}], "metadata" => ordinary}
    assert ImageProjection.project(payload, %{}) == {payload, 0}
  end

  test "invalid and unrecognized content envelopes cannot exempt arbitrary bytes" do
    items = [image(), %{"type" => "arbitrary", "content" => [image()]}, %{"type" => "function_call_output", "output" => [image()]}, %{"type" => "function_call_output", "call_id" => " ", "output" => [image()]}, %{"type" => "function_call_output", "call_id" => "call_synthetic", "output" => image()}, %{"type" => "function_call_output", "call_id" => "call_wrapped", "output" => %{"result" => %{"content" => [image()]}}}, message([%{"type" => "input_image", "image_url" => %{"url" => @url}}, %{"type" => "input_image", "file_id" => nil}, %{"type" => "image_url", "image_url" => @url}])]
    payload = %{"input" => items}
    assert ImageProjection.project(payload, %{}) == {payload, 0}
  end

  test "payload endpoint claims and similar endpoint strings cannot authorize native arrays" do
    payload = %{"source_endpoint" => "/backend-api/codex/images/edits", "endpoint" => "/backend-api/codex/images/edits", "images" => [%{"image_url" => @url}]}

    for context <- [%{}, %{source_endpoint: "/v1/images/edits"}, %{source_endpoint: @endpoint}, %{source_endpoint: "/backend-api/codex/images/edits/extra"}] do
      assert ImageProjection.project(payload, context) == {payload, 0}
    end
  end

  test "only the exact image-generation mask locator is projected" do
    tool = %{"type" => "image_generation", "input_image_mask" => %{"image_url" => @url, "file_id" => "ordinary", "data" => "ordinary"}, "other" => image(), "mask" => %{"image_url" => @url}}
    assert {projected, 1} = ImageProjection.project(%{"tools" => [tool]}, %{})
    assert projected == %{"tools" => [put_in(tool, ["input_image_mask", "image_url"], "")]}
  end

  test "locator length cannot change the projection and later images are never dropped" do
    payload = fn url -> %{"input" => [message(List.duplicate(%{image() | "image_url" => url}, 513))]} end
    assert {short, 513} = ImageProjection.project(payload.(@url), %{})
    assert {long, 513} = ImageProjection.project(payload.(@url <> String.duplicate("x", 10_000)), %{})
    assert short == long
    assert ImageProjection.project(payload.(@url), %{}) == {short, 513}
  end

  test "text-only and malformed containers keep their exact JSON representation" do
    for payload <- [%{"input" => "synthetic", "tools" => []}, %{"input" => [message([%{"type" => "input_text", "text" => "synthetic"}])]}, %{"input" => message([image()]), "tools" => %{"type" => "image_generation", "input_image_mask" => %{"image_url" => @url}}, "images" => %{"image_url" => @url}}] do
      assert {projected, 0} = ImageProjection.project(payload, %{source_endpoint: "/backend-api/codex/images/edits"})
      assert CodexPooler.JSON.encode!(projected) == CodexPooler.JSON.encode!(payload)
    end
  end

  test "blank and nonbinary locators remain ordinary fields and inline image locators are neutralized" do
    invalid = [%{"type" => "input_image", "image_url" => ""}, %{"type" => "input_image", "image_url" => nil}, %{"type" => "input_image", "file_id" => "  "}]
    payload = %{"input" => [message(invalid)]}
    assert ImageProjection.project(payload, %{}) == {payload, 0}

    data_url = "data:image/png;base64," <> Base.encode64(<<0, 1, 2>>)
    part = %{image() | "image_url" => data_url}
    assert {projected, 1} = ImageProjection.project(%{"input" => [message([part])]}, %{})
    assert projected == %{"input" => [message([%{part | "image_url" => ""}])]}
  end

  # A client replays a hosted image generation with the image as base64 in `result`; the estimate counts it as one
  # semantic image with the fixed allowance instead of reading the bytes as JSON text.
  test "a replayed image generation counts one image allowance instead of its base64 bytes" do
    bytes = Base.encode64(:binary.copy(<<137, 80, 78, 71>>, 300_000))
    call = %{"type" => "image_generation_call", "id" => "ig_synthetic", "status" => "completed", "revised_prompt" => "synthetic prompt", "result" => bytes}
    payload = %{"input" => [message([%{"type" => "input_text", "text" => "synthetic"}]), call]}
    before = :erlang.term_to_binary(payload)

    assert {projected, 1} = ImageProjection.project(payload, %{})
    assert Enum.at(projected["input"], 1) == %{call | "result" => ""}
    assert :erlang.term_to_binary(payload) == before

    estimate = InputEstimate.estimate(payload, %{})
    blank = InputEstimate.estimate(%{"input" => [hd(payload["input"]), %{call | "result" => ""}]}, %{})
    assert estimate.input_tokens == blank.input_tokens + 1_600
    assert estimate.image_estimate.image_count == 1

    assert {atom_projected, 1} = ImageProjection.project(%{input: [%{type: "image_generation_call", result: bytes}]}, %{})
    assert atom_projected == %{input: [%{type: "image_generation_call", result: ""}]}

    for odd <- [nil, 7, "", "  ", %{"data" => bytes}] do
      odd_payload = %{"input" => [%{call | "result" => odd}]}
      assert ImageProjection.project(odd_payload, %{}) == {odd_payload, 0}
    end
  end

  test "atom native image and mask keys obey the same exact field boundaries" do
    payload = %{images: [%{image_url: @url, data: "ordinary"}], tools: [%{type: "image_generation", input_image_mask: %{image_url: @url, file_id: "ordinary"}}]}
    assert {projected, 2} = ImageProjection.project(payload, %{source_endpoint: "/backend-api/codex/images/edits"})
    assert projected == %{images: [%{image_url: "", data: "ordinary"}], tools: [%{type: "image_generation", input_image_mask: %{image_url: "", file_id: "ordinary"}}]}
  end

  defp image, do: %{"type" => "input_image", "image_url" => @url}
  defp message(content), do: %{"type" => "message", "role" => "user", "content" => content}

  defp upload(tmp_dir) do
    path = Path.join(tmp_dir, "sample.png")
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    File.write!(path, <<0, 1, 2>>)
    %Plug.Upload{path: path, filename: "sample.png", content_type: "image/png"}
  end
end
