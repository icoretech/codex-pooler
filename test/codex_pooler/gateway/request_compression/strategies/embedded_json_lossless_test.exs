defmodule CodexPooler.Gateway.RequestCompression.Strategies.EmbeddedJsonLosslessTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.RequestCompression.Strategies.EmbeddedJsonLossless
  alias CodexPooler.Gateway.RequestCompression.TokenCounter

  @model "gpt-4o"

  describe "compress/2" do
    test "losslessly minifies embedded JSON objects and arrays while preserving surrounding bytes" do
      object = pretty_object("object")
      array = pretty_array()
      prefix = "synthetic prefix\n"
      middle = "\nsynthetic middle\n"
      suffix = "\nsynthetic suffix"
      original = prefix <> object <> middle <> array <> suffix

      assert {:ok, %{content: compressed, metadata: metadata}} =
               EmbeddedJsonLossless.compress(original, model: @model)

      expected = prefix <> compact_json(object) <> middle <> compact_json(array) <> suffix

      assert compressed == expected
      assert byte_size(compressed) < byte_size(original)
      assert {:ok, original_tokens, _token_metadata} = TokenCounter.count(@model, original)
      assert {:ok, compressed_tokens, _token_metadata} = TokenCounter.count(@model, compressed)
      assert compressed_tokens < original_tokens

      assert %{
               strategy: :embedded_json_lossless,
               span_count: 2,
               object_span_count: 1,
               array_span_count: 1,
               original_tokens: ^original_tokens,
               compressed_tokens: ^compressed_tokens
             } = metadata
    end

    test "does not rewrite JSON-looking containers inside a JSON string literal" do
      quoted_json_literal = Jason.encode!(pretty_object("quoted"))
      object = pretty_object("actual")
      prefix = "synthetic quoted value: " <> quoted_json_literal <> "\nactual value:\n"
      suffix = "\nsynthetic suffix"
      original = prefix <> object <> suffix

      assert {:ok, %{content: compressed}} =
               EmbeddedJsonLossless.compress(original, model: @model)

      assert compressed == prefix <> compact_json(object) <> suffix
      assert compressed =~ quoted_json_literal
    end

    test "fails open for malformed, unbalanced, or unterminated container text" do
      valid_object = pretty_object("later")

      malformed = [
        "synthetic prefix {\n  \"broken\": [1, 2, 3]\n" <> valid_object,
        "synthetic prefix {\"broken\": nope}\n" <> valid_object,
        "synthetic prefix [}\n" <> valid_object,
        "synthetic prefix \"unterminated JSON-looking text\n" <> valid_object
      ]

      for original <- malformed do
        assert :skip = EmbeddedJsonLossless.compress(original, model: @model)
      end
    end

    test "skips whole JSON values, token-neutral spans, and over-limit span sets" do
      assert :skip = EmbeddedJsonLossless.compress(pretty_object("whole"), model: @model)
      assert :skip = EmbeddedJsonLossless.compress("prefix {\"a\":1} suffix", model: @model)

      over_limit =
        1..51
        |> Enum.map_join("\n", fn index ->
          """
          {
            "index": #{index},
            "label": "synthetic span #{index}"
          }
          """
        end)
        |> then(&("synthetic prefix\n" <> &1 <> "\nsynthetic suffix"))

      assert :skip = EmbeddedJsonLossless.compress(over_limit, model: @model)
    end

    test "preserves duplicate object keys and keeps metadata content-free" do
      sentinel = "synthetic embedded JSON sentinel"

      object = """
      {
        "repeat": "first",
        "repeat": "second",
        "sentinel": "#{sentinel}"
      }
      """

      original = "synthetic prefix\n" <> object <> "synthetic suffix"

      assert {:ok, %{content: compressed, metadata: metadata}} =
               EmbeddedJsonLossless.compress(original, model: @model)

      compact_object =
        compressed
        |> String.trim_leading("synthetic prefix\n")
        |> String.trim_trailing("synthetic suffix")

      %Jason.OrderedObject{values: values} =
        Jason.decode!(compact_object, objects: :ordered_objects)

      assert Enum.count(values, fn {key, _value} -> key == "repeat" end) == 2
      refute inspect(metadata) =~ sentinel
    end
  end

  defp pretty_object(label) do
    %{
      "label" => label,
      "records" =>
        Enum.map(1..8, fn index ->
          %{
            "index" => index,
            "nested" => %{"active" => true, "values" => [index, index + 1, index + 2]}
          }
        end)
    }
    |> Jason.encode!(pretty: true)
  end

  defp pretty_array do
    1..8
    |> Enum.map(fn index ->
      %{"index" => index, "label" => "synthetic row #{index}", "active" => true}
    end)
    |> Jason.encode!(pretty: true)
  end

  defp compact_json(json) do
    json
    |> Jason.decode!(objects: :ordered_objects)
    |> Jason.encode!()
  end
end
