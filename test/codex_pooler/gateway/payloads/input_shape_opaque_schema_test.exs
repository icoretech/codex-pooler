defmodule CodexPooler.Gateway.Payloads.InputShapeOpaqueSchemaTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.OpenAICompatibility.Responses
  alias CodexPooler.Gateway.Payloads.InputShape

  @literal %{"type" => "input_image", "image_url" => "http://example.com/reference.png"}
  @file_literal %{"type" => "input_file", "file_data" => "not-a-data-url"}
  @tool %{"type" => "function", "name" => "synthetic_tool", "strict" => false, "parameters" => %{"type" => "object", "properties" => %{}}}

  test "a media-shaped literal inside an opaque function output_schema is not an attachment" do
    schema = %{"x-opaque-keyword" => [@literal, @file_literal]}
    payload = request([Map.put(@tool, "output_schema", schema)])

    assert :ok = InputShape.validate(payload)
    assert {:ok, coerced} = Responses.coerce(payload)
    assert hd(coerced.payload["tools"])["output_schema"] == schema
  end

  test "media-shaped literals in parameter and structured-output schemas stay opaque" do
    parameters = %{"type" => "object", "properties" => %{"part" => %{"type" => "object", "examples" => [@literal]}}}
    assert :ok = InputShape.validate(request([Map.put(@tool, "parameters", parameters)]))

    format = %{"format" => %{"type" => "json_schema", "name" => "synthetic", "schema" => %{"type" => "object", "examples" => [@file_literal]}}}
    assert :ok = InputShape.validate(Map.put(request([@tool]), "text", format))
  end

  test "control: the same literals as real content parts are still refused" do
    message = fn part -> %{"input" => [%{"type" => "message", "role" => "user", "content" => [part]}], "tools" => [Map.put(@tool, "output_schema", %{"x-opaque-keyword" => []})]} end

    assert {:error, %{status: 400, code: "unsupported_input_image_format"}} = InputShape.validate(message.(@literal))
    assert {:error, %{status: 400, code: "unsupported_input_file_format"}} = InputShape.validate(message.(@file_literal))
    assert {:error, %{code: "unsupported_input_image_format"}} = Responses.coerce(Map.put(message.(@literal), "model", "synthetic-model"))
  end

  test "control: a content part beside a schema-named key is still validated" do
    part = Map.put(@literal, "schema", %{"note" => "ignored"})
    assert {:error, %{code: "unsupported_input_image_format"}} = InputShape.validate(%{"input" => [%{"type" => "message", "role" => "user", "content" => [part]}]})
  end

  defp request(tools), do: %{"model" => "synthetic-model", "input" => "synthetic request", "tools" => tools}
end
