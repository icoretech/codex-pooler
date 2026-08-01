defmodule CodexPooler.Gateway.RequestCompression.EmbeddedJson do
  @moduledoc false

  @max_span_count 50

  @type span_kind :: :array | :object
  @type span :: %{
          required(:byte_start) => non_neg_integer(),
          required(:byte_end) => pos_integer(),
          required(:kind) => span_kind()
        }

  @spec embedded?(term()) :: boolean()
  def embedded?(content) when is_binary(content) do
    match?({:ok, [_first | _rest]}, plan(content))
  end

  def embedded?(_content), do: false

  @spec plan(term()) :: {:ok, [span()]} | :skip
  def plan(content) when is_binary(content) do
    if String.valid?(content) do
      case scan(content, 0, [], 0) do
        {:ok, spans} -> finalize_plan(content, Enum.reverse(spans))
        :error -> :skip
      end
    else
      :skip
    end
  end

  def plan(_content), do: :skip

  defp scan(content, offset, spans, _seen_count) when offset >= byte_size(content) do
    {:ok, spans}
  end

  defp scan(content, offset, spans, seen_count) do
    case :binary.at(content, offset) do
      ?" ->
        case string_end(content, offset + 1) do
          {:ok, next_offset} -> scan(content, next_offset, spans, seen_count)
          :error -> :error
        end

      opener when opener in [?{, ?[] ->
        scan_container(content, offset, opener, spans, seen_count)

      _byte ->
        scan(content, offset + 1, spans, seen_count)
    end
  end

  defp scan_container(content, offset, opener, spans, seen_count) do
    if plausible_container_start?(content, offset + 1, opener) do
      with true <- seen_count < @max_span_count,
           {:ok, byte_end} <- container_end(content, offset + 1, [opener]),
           span_content = binary_part(content, offset, byte_end - offset),
           {:ok, kind} <- container_kind(span_content) do
        span = %{byte_start: offset, byte_end: byte_end, kind: kind}
        scan(content, byte_end, [span | spans], seen_count + 1)
      else
        _invalid_or_over_limit -> :error
      end
    else
      scan(content, offset + 1, spans, seen_count)
    end
  end

  defp plausible_container_start?(content, offset, opener) do
    case next_non_whitespace_byte(content, offset) do
      :eof -> true
      byte when opener == ?{ -> byte in [?", ?}, ?]]
      byte when opener == ?[ -> json_value_start?(byte) or byte in [?], ?}]
    end
  end

  defp next_non_whitespace_byte(content, offset) when offset >= byte_size(content), do: :eof

  defp next_non_whitespace_byte(content, offset) do
    case :binary.at(content, offset) do
      byte when byte in [?\s, ?\n, ?\r, ?\t] -> next_non_whitespace_byte(content, offset + 1)
      byte -> byte
    end
  end

  defp json_value_start?(byte) do
    byte in [?", ?{, ?[, ?-, ?t, ?f, ?n] or byte in ?0..?9
  end

  defp container_end(content, offset, _stack) when offset >= byte_size(content), do: :error

  defp container_end(content, offset, stack) do
    case :binary.at(content, offset) do
      ?" ->
        with {:ok, next_offset} <- string_end(content, offset + 1) do
          container_end(content, next_offset, stack)
        end

      ?{ ->
        container_end(content, offset + 1, [?{ | stack])

      ?[ ->
        container_end(content, offset + 1, [?[ | stack])

      ?} ->
        close_container(content, offset, stack, ?{)

      ?] ->
        close_container(content, offset, stack, ?[)

      _byte ->
        container_end(content, offset + 1, stack)
    end
  end

  defp close_container(_content, offset, [expected], expected), do: {:ok, offset + 1}

  defp close_container(content, offset, [expected | rest], expected),
    do: container_end(content, offset + 1, rest)

  defp close_container(_content, _offset, _stack, _expected), do: :error

  defp string_end(content, offset) when offset >= byte_size(content), do: :error

  defp string_end(content, offset) do
    case :binary.at(content, offset) do
      ?\\ when offset + 1 < byte_size(content) -> string_end(content, offset + 2)
      ?\\ -> :error
      ?" -> {:ok, offset + 1}
      _byte -> string_end(content, offset + 1)
    end
  end

  defp container_kind(content) do
    case Jason.decode(content, objects: :ordered_objects) do
      {:ok, value} -> decoded_container_kind(value)
      _invalid_json -> :error
    end
  end

  defp decoded_container_kind(%Jason.OrderedObject{}), do: {:ok, :object}
  defp decoded_container_kind(value) when is_list(value), do: {:ok, :array}
  defp decoded_container_kind(_value), do: :error

  defp finalize_plan(_content, []), do: :skip

  defp finalize_plan(content, [span] = spans) do
    if whole_content_span?(content, span), do: :skip, else: {:ok, spans}
  end

  defp finalize_plan(_content, spans), do: {:ok, spans}

  defp whole_content_span?(content, span) do
    {byte_start, byte_end} = trimmed_bounds(content)
    span.byte_start == byte_start and span.byte_end == byte_end
  end

  defp trimmed_bounds(content) do
    {leading_whitespace_bytes(content, 0), trailing_whitespace_end(content, byte_size(content))}
  end

  defp leading_whitespace_bytes(content, offset) when offset >= byte_size(content), do: offset

  defp leading_whitespace_bytes(content, offset) do
    if :binary.at(content, offset) in [?\s, ?\n, ?\r, ?\t] do
      leading_whitespace_bytes(content, offset + 1)
    else
      offset
    end
  end

  defp trailing_whitespace_end(_content, 0), do: 0

  defp trailing_whitespace_end(content, byte_end) do
    if :binary.at(content, byte_end - 1) in [?\s, ?\n, ?\r, ?\t] do
      trailing_whitespace_end(content, byte_end - 1)
    else
      byte_end
    end
  end
end
