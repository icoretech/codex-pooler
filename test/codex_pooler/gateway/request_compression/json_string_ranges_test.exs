defmodule CodexPooler.Gateway.RequestCompression.JsonStringRangesTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.RequestCompression.JsonStringRanges

  describe "scan/1" do
    test "returns byte ranges for full JSON string literals including quotes" do
      json =
        IO.iodata_to_binary([
          ~S({"input":[{"type":"function_call_output","call_id":"call_range","output":"example \"quoted\" output\nsecond line"},),
          ~S({"type":"local_shell_call_output","output":""},),
          ~S({"type":"function_call_output","output":"multi ),
          <<195, 169>>,
          " ",
          <<240, 159, 152, 128>>,
          ~S( value"}],"unicode":"example \u263A output","nested":[["example nested value"]],"backslash":"C:\\tmp\\example"})
        ])

      assert {:ok, ranges} = JsonStringRanges.scan(json)

      output_range = find_range!(ranges, ["input", 0, "output"])
      empty_range = find_range!(ranges, ["input", 1, "output"])
      multibyte_range = find_range!(ranges, ["input", 2, "output"])
      unicode_range = find_range!(ranges, ["unicode"])
      nested_range = find_range!(ranges, ["nested", 0, 0])
      backslash_range = find_range!(ranges, ["backslash"])

      assert slice(json, output_range) == ~S("example \"quoted\" output\nsecond line")
      assert slice(json, empty_range) == ~S("")

      assert slice(json, multibyte_range) ==
               IO.iodata_to_binary([
                 ~S("multi ),
                 <<195, 169>>,
                 " ",
                 <<240, 159, 152, 128>>,
                 ~S( value")
               ])

      assert slice(json, unicode_range) == ~S("example \u263A output")
      assert slice(json, nested_range) == ~S("example nested value")
      assert slice(json, backslash_range) == ~S("C:\\tmp\\example")

      assert output_range.byte_start ==
               json
               |> :binary.match(~S("example \"quoted\" output\nsecond line"))
               |> elem(0)

      assert output_range.byte_end ==
               output_range.byte_start + byte_size(~S("example \"quoted\" output\nsecond line"))

      assert {:ok, ""} = JsonStringRanges.decode_string(json, empty_range)

      decoded_multibyte =
        IO.iodata_to_binary([
          "multi ",
          <<195, 169>>,
          " ",
          <<240, 159, 152, 128>>,
          " value"
        ])

      assert {:ok, ^decoded_multibyte} = JsonStringRanges.decode_string(json, multibyte_range)
    end

    test "tracks nested object keys and array indexes without corrupting paths" do
      json =
        ~S({"input":[{"items":[{"output":"item zero","value":[{"output":"deep zero"}]}]},[{"output":"nested array"}],{"output":"top level"}],"tail":[{"output":"outside input"}]})

      assert {:ok, ranges} = JsonStringRanges.scan(json)

      assert slice(json, find_range!(ranges, ["input", 0, "items", 0, "output"])) ==
               ~S("item zero")

      assert slice(json, find_range!(ranges, ["input", 0, "items", 0, "value", 0, "output"])) ==
               ~S("deep zero")

      assert slice(json, find_range!(ranges, ["input", 1, 0, "output"])) ==
               ~S("nested array")

      assert slice(json, find_range!(ranges, ["input", 2, "output"])) ==
               ~S("top level")

      assert slice(json, find_range!(ranges, ["tail", 0, "output"])) ==
               ~S("outside input")
    end

    test "rejects malformed JSON without raising" do
      invalid_json_values = [
        ~S({"input":[{"output":"unterminated}]}),
        ~S({"input":[{"output":"bad \q escape"}]}),
        ~S({"input":[{"output":"\uD800"}]}),
        ~S({"input":[{"output":"\uDC00"}]}),
        ~S({"input":[{"output":"\uD800\u0041"}]}),
        ~S({"input":[{"output":"\uD800x"}]}),
        ~S({"input":[{"output":"\uD800\n"}]}),
        ~S({"input":[1,]}),
        ~S({"input":[01]}),
        ~S({"input":[true false]}),
        IO.iodata_to_binary([~S({"input":["), <<10>>, ~S("]})]),
        IO.iodata_to_binary([~S({"input":["), <<255>>, ~S("]})])
      ]

      for invalid_json <- invalid_json_values do
        assert {:error, :invalid_json} = JsonStringRanges.scan(invalid_json)
      end
    end

    test "accepts valid escaped surrogate pairs" do
      json = ~S({"input":[{"output":"\uD83D\uDE00"}],"suffix":"keep"})

      assert {:ok, ranges} = JsonStringRanges.scan(json)

      output_range = find_range!(ranges, ["input", 0, "output"])

      assert slice(json, output_range) == ~S("\uD83D\uDE00")
      assert {:ok, <<240, 159, 152, 128>>} = JsonStringRanges.decode_string(json, output_range)
    end
  end

  describe "replace_ranges/2" do
    test "replaces escaped and unicode string literals without changing surrounding bytes" do
      json =
        ~S({"prefix":"keep","input":[{"type":"function_call_output","output":"example \"quoted\" output\nline"},{"type":"local_shell_call_output","output":"example \u263A output"}],"suffix":{"value":"keep"}})

      assert {:ok, ranges} = JsonStringRanges.scan(json)

      first_range = find_range!(ranges, ["input", 0, "output"])
      second_range = find_range!(ranges, ["input", 1, "output"])

      first_replacement = ~S("compressed \"one\"")
      second_replacement = ~S("compressed \u263A two")

      replacements = [
        %{
          byte_start: second_range.byte_start,
          byte_end: second_range.byte_end,
          replacement: second_replacement
        },
        %{
          byte_start: first_range.byte_start,
          byte_end: first_range.byte_end,
          replacement: first_replacement
        }
      ]

      assert {:ok, replaced} = JsonStringRanges.replace_ranges(json, replacements)

      assert replaced ==
               expected_replacement(json, [first_range, second_range], [
                 first_replacement,
                 second_replacement
               ])

      assert_unchanged_segments(
        json,
        replaced,
        [first_range, second_range],
        [first_replacement, second_replacement]
      )

      assert Jason.decode!(replaced) == %{
               "prefix" => "keep",
               "input" => [
                 %{
                   "type" => "function_call_output",
                   "output" => ~s(compressed "one")
                 },
                 %{
                   "type" => "local_shell_call_output",
                   "output" => IO.iodata_to_binary(["compressed ", <<226, 152, 186>>, " two"])
                 }
               ],
               "suffix" => %{"value" => "keep"}
             }
    end

    test "rejects stale or overlapping replacement ranges" do
      json = ~S({"a":"one","b":"two"})
      assert {:ok, ranges} = JsonStringRanges.scan(json)

      first_range = find_range!(ranges, ["a"])
      second_range = find_range!(ranges, ["b"])

      assert {:error, :invalid_range} =
               JsonStringRanges.replace_ranges(json, [
                 %{
                   byte_start: first_range.byte_start,
                   byte_end: byte_size(json) + 1,
                   replacement: ~S("x")
                 }
               ])

      assert {:error, :invalid_range} =
               JsonStringRanges.replace_ranges(json, [
                 %{
                   byte_start: first_range.byte_start,
                   byte_end: first_range.byte_start,
                   replacement: ~S("x")
                 }
               ])

      assert {:error, :invalid_range} =
               JsonStringRanges.replace_ranges(json, [
                 %{
                   byte_start: first_range.byte_start,
                   byte_end: second_range.byte_start,
                   replacement: ~S("x")
                 },
                 %{
                   byte_start: first_range.byte_end - 1,
                   byte_end: second_range.byte_end,
                   replacement: ~S("y")
                 }
               ])
    end
  end

  defp find_range!(ranges, path) do
    Enum.find(ranges, &(&1.path == path)) ||
      flunk("missing JSON string range for #{inspect(path)}")
  end

  defp slice(json, %{byte_start: byte_start, byte_end: byte_end}) do
    binary_part(json, byte_start, byte_end - byte_start)
  end

  defp expected_replacement(original, ranges, replacements) do
    {iodata, cursor} =
      ranges
      |> Enum.zip(replacements)
      |> Enum.reduce({[], 0}, fn {range, replacement}, {acc, cursor} ->
        unchanged = binary_part(original, cursor, range.byte_start - cursor)
        {[acc, unchanged, replacement], range.byte_end}
      end)

    suffix = binary_part(original, cursor, byte_size(original) - cursor)
    IO.iodata_to_binary([iodata, suffix])
  end

  defp assert_unchanged_segments(original, replaced, ranges, replacements) do
    prefix_size = ranges |> List.first() |> Map.fetch!(:byte_start)
    assert binary_part(replaced, 0, prefix_size) == binary_part(original, 0, prefix_size)

    [first_range, second_range] = ranges
    [first_replacement, second_replacement] = replacements

    between_size = second_range.byte_start - first_range.byte_end
    after_first_replacement = first_range.byte_start + byte_size(first_replacement)

    assert binary_part(replaced, after_first_replacement, between_size) ==
             binary_part(original, first_range.byte_end, between_size)

    suffix =
      binary_part(original, second_range.byte_end, byte_size(original) - second_range.byte_end)

    after_second_replacement =
      after_first_replacement + between_size + byte_size(second_replacement)

    assert binary_part(
             replaced,
             after_second_replacement,
             byte_size(replaced) - after_second_replacement
           ) == suffix
  end
end
