defmodule CodexPooler.JSONTest do
  use ExUnit.Case, async: true

  alias CodexPooler.JSON, as: Codec
  alias CodexPooler.JSON.OrderedObject

  alias CodexPooler.JSONNativeEncoded, as: NativeEncoded

  test "native encoder protocol controls custom struct projection" do
    value = %NativeEncoded{visible: "shown", private: "excluded"}
    assert Codec.encode!(value) == ~s({"visible":"shown"})
    assert Codec.decode!(Codec.encode!([value], pretty: true)) == [%{"visible" => "shown"}]
  end

  test "native decoding preserves JSON values, large integers and first duplicate keys" do
    assert {:ok, %{"a" => 1, "nested" => %{"a" => 3}}} =
             Codec.decode(~s({"a":1,"a":2,"nested":{"a":3,"a":4}}))

    assert [nil, true, false, 123_456_789_012_345_678_901_234_567_890, -0.25, 100.0, "日本語 🦊"] ==
             Codec.decode!(~s([null,true,false,123456789012345678901234567890,-0.25,1e2,"日本語 🦊"]))

    assert {:ok, %{"a" => 1}} = Codec.decode([" {", ~s("a":1}), " \r\n\t"])
  end

  test "ordered objects preserve nested order and duplicate keys through encoding" do
    input = ~s({"z":0,"a":{"x":1,"x":2},"z":3,"empty":{}})
    object = Codec.decode!(input, objects: :ordered_objects)

    assert %OrderedObject{
             values: [
               {"z", 0},
               {"a", %OrderedObject{values: [{"x", 1}, {"x", 2}]}},
               {"z", 3},
               {"empty", %OrderedObject{values: []}}
             ]
           } = object

    assert Codec.encode!(object) == input
    assert Codec.decode!(Codec.encode!(object, pretty: true), objects: :ordered_objects) == object
    assert Codec.encode!(OrderedObject.new([])) == "{}"
  end

  test "invalid UTF-8, escapes, malformed numbers, incomplete and trailing JSON fail" do
    for input <- [
          <<34, 255, 34>>,
          ~S("\uD800"),
          ~S("\uDC00"),
          "[1,]",
          "01",
          "1e",
          "{",
          "true false",
          "null x"
        ] do
      assert {:error, _reason} = Codec.decode(input)
      assert {:error, _reason} = Codec.decode(input, objects: :ordered_objects)
      assert_raise JSON.DecodeError, fn -> Codec.decode!(input) end
    end

    assert {:error, {:invalid_byte, 4, 32}} = Codec.decode("null x")
    assert "🦊" == Codec.decode!(~S("\ud83e\udd8a"))
  end

  test "decode exceptions retain only failure metadata" do
    error = assert_raise JSON.DecodeError, fn -> Codec.decode!(~s({\"sample_marker\":)) end
    assert error.data == nil
    assert is_integer(error.offset)
    refute inspect(error) =~ "sample_marker"
    refute Exception.message(error) =~ "sample_marker"
  end

  test "pretty arrays expand scalar elements for readable operator output" do
    assert Codec.encode!([1, 2, nil], pretty: true) == "[\n  1,\n  2,\n  null\n]"
  end

  test "pretty objects expand even a single scalar property at every nesting level" do
    assert Codec.encode!(%{"a" => [%{"b" => 1}]}, pretty: true) ==
             "{\n  \"a\": [\n    {\n      \"b\": 1\n    }\n  ]\n}"

    assert Codec.encode!(%{"empty" => %{}}, pretty: true) ==
             "{\n  \"empty\": {}\n}"
  end

  test "copied strings do not retain large parser input buffers, including object keys" do
    key = String.duplicate("k", 100)
    value = String.duplicate("v", 100)
    input = Codec.encode!(%{key => value, "padding" => String.duplicate("p", 100_000)})
    decoded = Codec.decode!(input, strings: :copy)
    copied_key = decoded |> Map.keys() |> Enum.find(&(&1 == key))
    assert :binary.referenced_byte_size(copied_key) == byte_size(key)
    assert :binary.referenced_byte_size(decoded[key]) == byte_size(value)
  end

  test "encoding uses native protocol for dates and reports unsupported or invalid values" do
    assert Codec.decode!(Codec.encode!(%{date: ~D[2026-01-02], value: nil})) == %{
             "date" => "2026-01-02",
             "value" => nil
           }

    for value <- [self(), {1, 2}, <<255>>] do
      assert {:error, _error} = Codec.encode(value)
    end

    assert_raise Protocol.UndefinedError, fn -> Codec.encode!({1, 2}) end
  end

  test "decimal encoding retains scale and fixed decimal notation" do
    for {input, output} <- [
          {"1.00", "1.00"},
          {"1E-30", "0.000000000000000000000000000001"},
          {"1E30", "1000000000000000000000000000000"}
        ] do
      decimal = Decimal.new(input)
      assert Codec.encode!(decimal) == ~s("#{output}")

      assert Codec.decode!(Codec.encode!(%{amount: decimal}, pretty: true)) == %{
               "amount" => output
             }
    end
  end

  test "Unicode-safe encoding escapes keys and values, including surrogate pairs" do
    value = %{"日本" => "🦊\n\"\\", "ascii" => "ok"}
    encoded = Codec.encode!(value, escape: :unicode_safe)
    assert String.to_charlist(encoded) |> Enum.all?(&(&1 < 128))
    assert Codec.decode!(encoded) == value
    assert String.downcase(encoded) =~ "\\ud83e\\udd8a"
    pretty = Codec.encode!(value, escape: :unicode_safe, pretty: true)
    assert String.to_charlist(pretty) |> Enum.all?(&(&1 < 128))
    assert Codec.decode!(pretty) == value
  end

  test "pretty output remains valid JSON and iodata matches binary encoding" do
    value = %{"rows" => [%{"text" => "a, b: [c] {d}\n\"quoted\""}], "empty" => []}
    pretty = Codec.encode!(value, pretty: true)
    assert pretty =~ "\n  "
    refute String.ends_with?(pretty, "\n")
    assert Codec.decode!(pretty) == value
    assert IO.iodata_to_binary(Codec.encode_to_iodata!(value)) == Codec.encode!(value)
    assert IO.iodata_to_binary(Codec.encode_to_iodata!(value, pretty: true)) == pretty
  end
end
