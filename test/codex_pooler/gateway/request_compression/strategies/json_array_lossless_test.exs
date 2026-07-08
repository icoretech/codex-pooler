defmodule CodexPooler.Gateway.RequestCompression.Strategies.JsonArrayLosslessTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.RequestCompression.Strategies.JsonArrayLossless
  alias CodexPooler.Gateway.RequestCompression.TokenCounter

  @model "gpt-4o"

  describe "compress/2" do
    test "losslessly minifies valid JSON arrays when token count shrinks" do
      original = """
      [
        {
          "id": 1,
          "status": "complete",
          "labels": ["alpha", "beta"],
          "nested": {
            "enabled": true,
            "score": 12.5,
            "items": [
              {"name": "first", "value": null},
              {"name": "second", "value": {"count": 2}}
            ]
          }
        },
        {
          "id": 2,
          "status": "queued",
          "labels": [],
          "nested": {"enabled": false, "score": 0, "items": []}
        }
      ]
      """

      assert {:ok, %{content: compressed, metadata: metadata}} =
               JsonArrayLossless.compress(original, model: @model)

      assert Jason.decode!(compressed) == Jason.decode!(original)
      assert byte_size(compressed) < byte_size(original)
      assert {:ok, original_tokens, _token_metadata} = TokenCounter.count(@model, original)
      assert {:ok, compressed_tokens, _token_metadata} = TokenCounter.count(@model, compressed)
      assert compressed_tokens < original_tokens

      assert %{
               strategy: :json_array_lossless,
               row_count: 2,
               original_bytes: original_bytes,
               compressed_bytes: compressed_bytes,
               original_tokens: ^original_tokens,
               compressed_tokens: ^compressed_tokens
             } = metadata

      assert original_bytes == byte_size(original)
      assert compressed_bytes == byte_size(compressed)
    end

    test "preserves every row, key, value, and nested item" do
      original = """
      [
        {
          "row": 1,
          "keep": "alpha",
          "nested": {
            "object": {"left": "one", "right": "two"},
            "array": [1, 2, 3],
            "flag": true
          }
        },
        {
          "row": 2,
          "keep": "beta",
          "nested": {
            "object": {"left": "three", "right": "four"},
            "array": [{"deep": "value"}, {"deeper": ["x", "y"]}],
            "flag": false
          }
        }
      ]
      """

      assert {:ok, %{content: compressed}} = JsonArrayLossless.compress(original, model: @model)

      decoded_original = Jason.decode!(original)
      decoded_compressed = Jason.decode!(compressed)

      assert decoded_compressed == decoded_original
      assert length(decoded_compressed) == 2
      assert Enum.map(decoded_compressed, &Map.keys/1) == Enum.map(decoded_original, &Map.keys/1)

      assert get_in(decoded_compressed, [Access.at(1), "nested", "array", Access.at(1), "deeper"]) ==
               [
                 "x",
                 "y"
               ]
    end

    test "preserves duplicate object keys" do
      original = """
      [
        {
          "repeat": "first",
          "repeat": "second",
          "status": "kept"
        }
      ]
      """

      assert {:ok, %{content: compressed}} = JsonArrayLossless.compress(original, model: @model)

      assert Jason.decode!(compressed, objects: :ordered_objects) ==
               Jason.decode!(original, objects: :ordered_objects)

      [%Jason.OrderedObject{values: values}] =
        Jason.decode!(compressed, objects: :ordered_objects)

      assert Enum.count(values, fn {key, _value} -> key == "repeat" end) == 2
    end

    test "normalizes whitespace-separated JSON object streams" do
      original = """
      {
        "row": 1,
        "title": "first result",
        "url": "https://example.com/one",
        "metadata": {"score": 10, "labels": ["alpha", "beta"]}
      }
      {
        "row": 2,
        "title": "second result",
        "url": "https://example.com/two",
        "metadata": {"score": 9, "labels": ["gamma"]}
      }
      """

      assert {:ok, %{content: compressed, metadata: metadata}} =
               JsonArrayLossless.compress(original, model: @model)

      assert Jason.decode!(compressed) == [
               %{
                 "row" => 1,
                 "title" => "first result",
                 "url" => "https://example.com/one",
                 "metadata" => %{"score" => 10, "labels" => ["alpha", "beta"]}
               },
               %{
                 "row" => 2,
                 "title" => "second result",
                 "url" => "https://example.com/two",
                 "metadata" => %{"score" => 9, "labels" => ["gamma"]}
               }
             ]

      assert metadata.row_count == 2
      assert metadata.compressed_bytes == byte_size(compressed)
      assert metadata.compressed_bytes < byte_size(original)
    end

    test "preserves duplicate keys in normalized object streams" do
      original = """
      {
        "repeat": "first",
        "repeat": "second",
        "status": "kept",
        "payload": "alpha beta gamma delta epsilon"
      }
      {
        "repeat": "third",
        "repeat": "fourth",
        "status": "kept",
        "payload": "zeta eta theta iota kappa"
      }
      """

      assert {:ok, %{content: compressed}} = JsonArrayLossless.compress(original, model: @model)

      [%Jason.OrderedObject{values: first_values}, %Jason.OrderedObject{values: second_values}] =
        Jason.decode!(compressed, objects: :ordered_objects)

      assert Enum.count(first_values, fn {key, _value} -> key == "repeat" end) == 2
      assert Enum.count(second_values, fn {key, _value} -> key == "repeat" end) == 2
    end

    test "skips single objects and mixed concatenated JSON tokens" do
      assert :skip = JsonArrayLossless.compress(~S({"status":"ok"}), model: @model)
      assert :skip = JsonArrayLossless.compress(~S({"first":1}{"second":2}), model: @model)
      assert :skip = JsonArrayLossless.compress(~S({"first":1} true {"second":2}), model: @model)
    end

    test "skips invalid JSON array-looking text" do
      assert :skip = JsonArrayLossless.compress(~S([{"status": "open",}]), model: @model)
    end

    test "skips valid non-array JSON" do
      assert :skip = JsonArrayLossless.compress(~S({"items":[1,2,3]}), model: @model)
    end

    test "skips when minification reduces bytes but not token count" do
      assert :skip = JsonArrayLossless.compress(~S([1,2,3 ]), model: @model)
    end

    test "skips when tokenizer model is missing or unsupported" do
      assert :skip = JsonArrayLossless.compress(~S([ 1, 2, 3 ]))
      assert :skip = JsonArrayLossless.compress(~S([ 1, 2, 3 ]), model: "unknown-model")
    end

    test "metadata contains only safe sizes and counts" do
      sentinel = "synthetic instruction marker"

      original = """
      [
        {
          "message": "#{sentinel}",
          "values": [1, 2, 3]
        }
      ]
      """

      assert {:ok, %{metadata: metadata}} = JsonArrayLossless.compress(original, model: @model)

      refute inspect(metadata) =~ sentinel

      assert metadata
             |> Map.keys()
             |> Enum.sort() == [
               :compressed_bytes,
               :compressed_tokens,
               :original_bytes,
               :original_tokens,
               :row_count,
               :strategy,
               :token_count_mode
             ]

      assert metadata.token_count_mode in [:exact, :bounded_original]
    end

    test "does not retain state between calls" do
      compressible = """
      [
        {"row": 1, "value": "alpha"},
        {"row": 2, "value": "beta"}
      ]
      """

      assert {:ok, %{content: compressed}} =
               JsonArrayLossless.compress(compressible, model: @model)

      assert Jason.decode!(compressed) == Jason.decode!(compressible)
      assert :skip = JsonArrayLossless.compress("ordinary text", model: @model)
    end
  end
end
