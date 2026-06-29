defmodule CodexPooler.Gateway.RequestCompression.Strategies.JsonDocumentLosslessTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.RequestCompression.Strategies.JsonDocumentLossless
  alias CodexPooler.Gateway.RequestCompression.TokenCounter

  @model "gpt-4o"

  describe "compress/2" do
    test "losslessly minifies valid top-level JSON objects when token count shrinks" do
      original = """
      {
        "GlobalSettings": {
          "isCrossAccountBackupEnabled": "false",
          "isDelegatedAdministratorEnabled": "false",
          "isMpaEnabled": "false"
        },
        "LastUpdateTime": "2026-05-28T09:52:17.525000+02:00"
      }
      """

      assert {:ok, %{content: compressed, metadata: metadata}} =
               JsonDocumentLossless.compress(original, model: @model)

      assert Jason.decode!(compressed) == Jason.decode!(original)
      assert byte_size(compressed) < byte_size(original)
      assert {:ok, original_tokens, _token_metadata} = TokenCounter.count(@model, original)
      assert {:ok, compressed_tokens, _token_metadata} = TokenCounter.count(@model, compressed)
      assert compressed_tokens < original_tokens

      assert %{
               strategy: :json_document_lossless,
               top_level_key_count: 2,
               original_bytes: original_bytes,
               compressed_bytes: compressed_bytes,
               original_tokens: ^original_tokens,
               compressed_tokens: ^compressed_tokens
             } = metadata

      assert original_bytes == byte_size(original)
      assert compressed_bytes == byte_size(compressed)
    end

    test "preserves duplicate top-level object keys" do
      original = """
      {
        "repeat": "first",
        "repeat": "second",
        "status": "kept"
      }
      """

      assert {:ok, %{content: compressed}} =
               JsonDocumentLossless.compress(original, model: @model)

      assert Jason.decode!(compressed, objects: :ordered_objects) ==
               Jason.decode!(original, objects: :ordered_objects)

      %Jason.OrderedObject{values: values} =
        Jason.decode!(compressed, objects: :ordered_objects)

      assert Enum.count(values, fn {key, _value} -> key == "repeat" end) == 2
    end

    test "preserves synthetic high-entropy values while keeping JSON parseable" do
      synthetic_high_entropy_value =
        "synthetic-high-entropy-placeholder-Zx9Kq3Wm7Pv2Lr8Nt4Bc6Df1Gh5Jy"

      original = """
      {
        "metadata": {
          "kind": "sanitized-fixture",
          "nested": {
            "synthetic_value": "#{synthetic_high_entropy_value}",
            "description": "This verbose synthetic fixture exists to keep token reduction observable."
          }
        },
        "records": [
          {
            "name": "alpha",
            "status": "ok",
            "notes": "Pretty printed whitespace and repeated plain fields should disappear during minification."
          },
          {
            "name": "beta",
            "status": "ok",
            "notes": "The JSON document strategy must preserve values exactly instead of masking content."
          }
        ],
        "summary": {
          "line_count": 2,
          "safe_fixture": true
        }
      }
      """

      assert {:ok, %{content: compressed, metadata: metadata}} =
               JsonDocumentLossless.compress(original, model: @model)

      assert Jason.decode!(compressed) == Jason.decode!(original)
      assert compressed =~ synthetic_high_entropy_value
      assert String.contains?(compressed, "\n...[compressed]...\n") == false
      assert String.contains?(compressed, " ...[compressed]... ") == false
      assert metadata.strategy == :json_document_lossless
      assert metadata.original_tokens > metadata.compressed_tokens
      refute inspect(metadata) =~ synthetic_high_entropy_value
    end

    test "skips arrays, invalid JSON, tiny token-neutral objects, and missing tokenizers" do
      assert :skip = JsonDocumentLossless.compress(~S([{"status":"ok"}]), model: @model)
      assert :skip = JsonDocumentLossless.compress(~S({"status": "open",}), model: @model)
      assert :skip = JsonDocumentLossless.compress(~S({"a":1}), model: @model)
      assert :skip = JsonDocumentLossless.compress(~S({"status": "open"}))
      assert :skip = JsonDocumentLossless.compress(~S({"status": "open"}), model: "unknown-model")
    end

    test "metadata contains only safe sizes and counts" do
      sentinel = "synthetic instruction marker"

      original = """
      {
        "message": "#{sentinel}",
        "values": [1, 2, 3]
      }
      """

      assert {:ok, %{metadata: metadata}} =
               JsonDocumentLossless.compress(original, model: @model)

      refute inspect(metadata) =~ sentinel

      assert metadata
             |> Map.keys()
             |> Enum.sort() == [
               :compressed_bytes,
               :compressed_tokens,
               :original_bytes,
               :original_tokens,
               :strategy,
               :token_count_mode,
               :top_level_key_count
             ]

      assert metadata.token_count_mode in [:exact, :bounded_original]
    end
  end
end
