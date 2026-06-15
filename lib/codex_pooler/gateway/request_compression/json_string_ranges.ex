defmodule CodexPooler.Gateway.RequestCompression.JsonStringRanges do
  @moduledoc false

  @type path_segment :: String.t() | non_neg_integer()
  @type path :: [path_segment()]
  @type range :: %{
          required(:path) => path(),
          required(:byte_start) => non_neg_integer(),
          required(:byte_end) => non_neg_integer(),
          required(:encoded_byte_size) => pos_integer()
        }
  @type replacement :: %{
          required(:byte_start) => non_neg_integer(),
          required(:byte_end) => non_neg_integer(),
          required(:replacement) => binary()
        }

  @spec scan(binary()) :: {:ok, [range()]} | {:error, :invalid_json}
  def scan(json) when is_binary(json) do
    with true <- String.valid?(json),
         size = byte_size(json),
         offset = skip_whitespace(json, 0, size),
         {:ok, offset, ranges} <- parse_value(json, offset, [], [], size),
         true <- skip_whitespace(json, offset, size) == size do
      {:ok, Enum.reverse(ranges)}
    else
      _error ->
        {:error, :invalid_json}
    end
  end

  def scan(_json), do: {:error, :invalid_json}

  @spec decode_string(binary(), range()) :: {:ok, String.t()} | {:error, :invalid_json}
  def decode_string(json, %{byte_start: byte_start, byte_end: byte_end})
      when is_binary(json) and is_integer(byte_start) and is_integer(byte_end) do
    with {:ok, encoded} <- slice_range(json, byte_start, byte_end),
         {:ok, decoded} when is_binary(decoded) <- Jason.decode(encoded) do
      {:ok, decoded}
    else
      _error -> {:error, :invalid_json}
    end
  rescue
    _error -> {:error, :invalid_json}
  end

  def decode_string(_json, _range), do: {:error, :invalid_json}

  @spec replace_ranges(binary(), [replacement()]) ::
          {:ok, binary()} | {:error, :invalid_range}
  def replace_ranges(json, replacements) when is_binary(json) and is_list(replacements) do
    with {:ok, replacements} <- normalize_replacements(replacements, byte_size(json)) do
      replaced =
        replacements
        |> Enum.sort_by(& &1.byte_start, :desc)
        |> Enum.reduce(json, fn replacement, acc ->
          replace_range(acc, replacement)
        end)

      {:ok, replaced}
    end
  end

  def replace_ranges(_json, _replacements), do: {:error, :invalid_range}

  defp parse_value(json, offset, path, ranges, size) do
    offset = skip_whitespace(json, offset, size)
    parse_value_at(byte_at(json, offset, size), json, offset, path, ranges, size)
  end

  defp parse_value_at(?{, json, offset, path, ranges, size),
    do: parse_object(json, offset + 1, path, ranges, size)

  defp parse_value_at(?[, json, offset, path, ranges, size),
    do: parse_array(json, offset + 1, path, ranges, size)

  defp parse_value_at(?", json, offset, path, ranges, size),
    do: parse_string_value(json, offset, path, ranges, size)

  defp parse_value_at(?t, json, offset, _path, ranges, size),
    do: parse_literal(json, offset, "true", ranges, size)

  defp parse_value_at(?f, json, offset, _path, ranges, size),
    do: parse_literal(json, offset, "false", ranges, size)

  defp parse_value_at(?n, json, offset, _path, ranges, size),
    do: parse_literal(json, offset, "null", ranges, size)

  defp parse_value_at(byte, json, offset, _path, ranges, size)
       when byte == ?- or byte in ?0..?9,
       do: parse_number(json, offset, ranges, size)

  defp parse_value_at(_byte, _json, _offset, _path, _ranges, _size), do: :error

  defp parse_string_value(json, offset, path, ranges, size) do
    with {:ok, byte_start, byte_end} <- parse_string(json, offset, size) do
      range = %{
        path: path,
        byte_start: byte_start,
        byte_end: byte_end,
        encoded_byte_size: byte_end - byte_start
      }

      {:ok, byte_end, [range | ranges]}
    end
  end

  defp parse_object(json, offset, path, ranges, size) do
    offset = skip_whitespace(json, offset, size)

    case byte_at(json, offset, size) do
      ?} -> {:ok, offset + 1, ranges}
      ?" -> parse_object_members(json, offset, path, ranges, size)
      _byte -> :error
    end
  end

  defp parse_object_members(json, offset, path, ranges, size) do
    with {:ok, key_start, key_end} <- parse_string(json, offset, size),
         {:ok, key} <- decode_string_range(json, key_start, key_end) do
      after_key = skip_whitespace(json, key_end, size)

      with ?: <- byte_at(json, after_key, size),
           {:ok, offset, ranges} <-
             parse_value(json, after_key + 1, path ++ [key], ranges, size) do
        parse_object_separator(json, offset, path, ranges, size)
      else
        _error -> :error
      end
    else
      _error -> :error
    end
  end

  defp parse_object_separator(json, offset, path, ranges, size) do
    offset = skip_whitespace(json, offset, size)

    case byte_at(json, offset, size) do
      ?, ->
        next_offset = skip_whitespace(json, offset + 1, size)

        case byte_at(json, next_offset, size) do
          ?" -> parse_object_members(json, next_offset, path, ranges, size)
          _byte -> :error
        end

      ?} ->
        {:ok, offset + 1, ranges}

      _byte ->
        :error
    end
  end

  defp parse_array(json, offset, path, ranges, size) do
    offset = skip_whitespace(json, offset, size)

    case byte_at(json, offset, size) do
      ?] -> {:ok, offset + 1, ranges}
      _byte -> parse_array_values(json, offset, path, ranges, size, 0)
    end
  end

  defp parse_array_values(json, offset, path, ranges, size, index) do
    with {:ok, offset, ranges} <- parse_value(json, offset, path ++ [index], ranges, size) do
      parse_array_separator(json, offset, path, ranges, size, index)
    end
  end

  defp parse_array_separator(json, offset, path, ranges, size, index) do
    offset = skip_whitespace(json, offset, size)

    case byte_at(json, offset, size) do
      ?, -> parse_array_next_value(json, offset + 1, path, ranges, size, index + 1)
      ?] -> {:ok, offset + 1, ranges}
      _byte -> :error
    end
  end

  defp parse_array_next_value(json, offset, path, ranges, size, index) do
    next_offset = skip_whitespace(json, offset, size)

    case byte_at(json, next_offset, size) do
      ?] -> :error
      _byte -> parse_array_values(json, next_offset, path, ranges, size, index)
    end
  end

  defp parse_literal(json, offset, literal, ranges, size) do
    literal_size = byte_size(literal)

    if offset + literal_size <= size and
         binary_part(json, offset, literal_size) == literal do
      {:ok, offset + literal_size, ranges}
    else
      :error
    end
  end

  defp parse_number(json, offset, ranges, size) do
    with {:ok, offset} <- parse_sign(json, offset, size),
         {:ok, offset} <- parse_integer(json, offset, size),
         {:ok, offset} <- parse_fraction(json, offset, size),
         {:ok, offset} <- parse_exponent(json, offset, size) do
      {:ok, offset, ranges}
    end
  end

  defp parse_sign(json, offset, size) do
    case byte_at(json, offset, size) do
      ?- -> {:ok, offset + 1}
      _byte -> {:ok, offset}
    end
  end

  defp parse_integer(json, offset, size) do
    case byte_at(json, offset, size) do
      ?0 -> {:ok, offset + 1}
      byte when byte in ?1..?9 -> consume_digits(json, offset + 1, size)
      _byte -> :error
    end
  end

  defp parse_fraction(json, offset, size) do
    case byte_at(json, offset, size) do
      ?. -> consume_one_or_more_digits(json, offset + 1, size)
      _byte -> {:ok, offset}
    end
  end

  defp parse_exponent(json, offset, size) do
    case byte_at(json, offset, size) do
      byte when byte in [?e, ?E] ->
        offset = offset + 1

        offset =
          case byte_at(json, offset, size) do
            byte when byte in [?+, ?-] -> offset + 1
            _byte -> offset
          end

        consume_one_or_more_digits(json, offset, size)

      _byte ->
        {:ok, offset}
    end
  end

  defp consume_one_or_more_digits(json, offset, size) do
    case byte_at(json, offset, size) do
      byte when byte in ?0..?9 -> consume_digits(json, offset + 1, size)
      _byte -> :error
    end
  end

  defp consume_digits(json, offset, size) do
    case byte_at(json, offset, size) do
      byte when byte in ?0..?9 -> consume_digits(json, offset + 1, size)
      _byte -> {:ok, offset}
    end
  end

  defp parse_string(json, offset, size) do
    case byte_at(json, offset, size) do
      ?" -> parse_string_bytes(json, offset + 1, size, offset)
      _byte -> :error
    end
  end

  defp parse_string_bytes(json, offset, size, byte_start) when offset < size do
    case :binary.at(json, offset) do
      ?" ->
        {:ok, byte_start, offset + 1}

      ?\\ ->
        case parse_escape(json, offset + 1, size) do
          {:ok, offset} -> parse_string_bytes(json, offset, size, byte_start)
          :error -> :error
        end

      byte when byte < 0x20 ->
        :error

      _byte ->
        parse_string_bytes(json, offset + 1, size, byte_start)
    end
  end

  defp parse_string_bytes(_json, _offset, _size, _byte_start), do: :error

  defp parse_escape(json, offset, size) when offset < size do
    case :binary.at(json, offset) do
      byte when byte in [?", ?\\, ?/, ?b, ?f, ?n, ?r, ?t] ->
        {:ok, offset + 1}

      ?u ->
        parse_unicode_escape(json, offset + 1, size)

      _byte ->
        :error
    end
  end

  defp parse_escape(_json, _offset, _size), do: :error

  defp parse_unicode_escape(json, offset, size) when offset + 4 <= size do
    with {:ok, codepoint} <- parse_hex_codepoint(json, offset, size) do
      cond do
        high_surrogate?(codepoint) -> parse_low_surrogate_escape(json, offset + 4, size)
        low_surrogate?(codepoint) -> :error
        true -> {:ok, offset + 4}
      end
    end
  end

  defp parse_unicode_escape(_json, _offset, _size), do: :error

  defp parse_low_surrogate_escape(json, offset, size) when offset + 6 <= size do
    with ?\\ <- byte_at(json, offset, size),
         ?u <- byte_at(json, offset + 1, size),
         {:ok, codepoint} <- parse_hex_codepoint(json, offset + 2, size),
         true <- low_surrogate?(codepoint) do
      {:ok, offset + 6}
    else
      _error -> :error
    end
  end

  defp parse_low_surrogate_escape(_json, _offset, _size), do: :error

  defp parse_hex_codepoint(json, offset, size) do
    with {:ok, first} <- hex_value(byte_at(json, offset, size)),
         {:ok, second} <- hex_value(byte_at(json, offset + 1, size)),
         {:ok, third} <- hex_value(byte_at(json, offset + 2, size)),
         {:ok, fourth} <- hex_value(byte_at(json, offset + 3, size)) do
      {:ok, first * 4096 + second * 256 + third * 16 + fourth}
    else
      :error -> :error
    end
  end

  defp high_surrogate?(codepoint), do: codepoint in 0xD800..0xDBFF
  defp low_surrogate?(codepoint), do: codepoint in 0xDC00..0xDFFF

  defp decode_string_range(json, byte_start, byte_end) do
    with {:ok, encoded} <- slice_range(json, byte_start, byte_end),
         {:ok, decoded} when is_binary(decoded) <- Jason.decode(encoded) do
      {:ok, decoded}
    else
      _error -> :error
    end
  rescue
    _error -> :error
  end

  defp slice_range(json, byte_start, byte_end)
       when is_integer(byte_start) and is_integer(byte_end) do
    size = byte_size(json)

    if byte_start >= 0 and byte_end >= byte_start and byte_end <= size do
      {:ok, binary_part(json, byte_start, byte_end - byte_start)}
    else
      :error
    end
  end

  defp slice_range(_json, _byte_start, _byte_end), do: :error

  defp normalize_replacements(replacements, size) do
    replacements
    |> Enum.reduce_while({:ok, []}, fn replacement, {:ok, acc} ->
      case normalize_replacement(replacement, size) do
        {:ok, replacement} -> {:cont, {:ok, [replacement | acc]}}
        :error -> {:halt, {:error, :invalid_range}}
      end
    end)
    |> case do
      {:ok, replacements} -> reject_overlapping_replacements(replacements)
      {:error, :invalid_range} -> {:error, :invalid_range}
    end
  end

  defp normalize_replacement(
         %{byte_start: byte_start, byte_end: byte_end, replacement: replacement},
         size
       )
       when is_integer(byte_start) and is_integer(byte_end) and is_binary(replacement) do
    if byte_start >= 0 and byte_start < byte_end and byte_end <= size do
      {:ok, %{byte_start: byte_start, byte_end: byte_end, replacement: replacement}}
    else
      :error
    end
  end

  defp normalize_replacement(_replacement, _size), do: :error

  defp reject_overlapping_replacements(replacements) do
    replacements = Enum.sort_by(replacements, & &1.byte_start)

    replacements
    |> Enum.reduce_while({:ok, 0}, fn replacement, {:ok, previous_end} ->
      if replacement.byte_start < previous_end do
        {:halt, {:error, :invalid_range}}
      else
        {:cont, {:ok, replacement.byte_end}}
      end
    end)
    |> case do
      {:ok, _previous_end} -> {:ok, replacements}
      {:error, :invalid_range} -> {:error, :invalid_range}
    end
  end

  defp replace_range(json, %{
         byte_start: byte_start,
         byte_end: byte_end,
         replacement: replacement
       }) do
    [
      binary_part(json, 0, byte_start),
      replacement,
      binary_part(json, byte_end, byte_size(json) - byte_end)
    ]
    |> IO.iodata_to_binary()
  end

  defp skip_whitespace(json, offset, size) when offset < size do
    case :binary.at(json, offset) do
      byte when byte in [?\s, ?\t, ?\n, ?\r] -> skip_whitespace(json, offset + 1, size)
      _byte -> offset
    end
  end

  defp skip_whitespace(_json, offset, _size), do: offset

  defp byte_at(_json, offset, size) when offset >= size, do: :eof
  defp byte_at(json, offset, _size), do: :binary.at(json, offset)

  defp hex_value(byte) when byte in ?0..?9, do: {:ok, byte - ?0}
  defp hex_value(byte) when byte in ?a..?f, do: {:ok, byte - ?a + 10}
  defp hex_value(byte) when byte in ?A..?F, do: {:ok, byte - ?A + 10}
  defp hex_value(_byte), do: :error
end
