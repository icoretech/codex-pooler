defmodule CodexPooler.Gateway.RequestCompression.Strategies do
  @moduledoc false

  alias CodexPooler.Gateway.RequestCompression.TokenCounter

  @type opts :: keyword() | map()
  @type metadata :: %{
          required(:strategy) => atom(),
          required(:original_bytes) => non_neg_integer(),
          required(:compressed_bytes) => non_neg_integer(),
          required(:original_tokens) => non_neg_integer(),
          required(:compressed_tokens) => non_neg_integer(),
          optional(atom()) => non_neg_integer()
        }
  @type skip_reason :: :tokenizer_input_limit
  @type result ::
          {:ok, %{content: binary(), metadata: metadata()}} | :skip | {:skip, skip_reason()}

  @spec finalize(atom(), binary(), binary(), map(), opts()) :: result()
  def finalize(strategy, original, compressed, counts, opts \\ [])

  def finalize(strategy, original, compressed, counts, opts)
      when is_atom(strategy) and is_binary(original) and is_binary(compressed) and is_map(counts) do
    original_bytes = byte_size(original)
    compressed_bytes = byte_size(compressed)

    with {:ok, model} <- model(opts),
         true <- compressed_bytes < original_bytes,
         {:ok, original_tokens} <- count_tokens(model, original),
         {:ok, compressed_tokens} <- count_tokens(model, compressed),
         true <- compressed_tokens < original_tokens do
      metadata =
        counts
        |> safe_counts()
        |> Map.merge(%{
          strategy: strategy,
          original_bytes: original_bytes,
          compressed_bytes: compressed_bytes,
          original_tokens: original_tokens,
          compressed_tokens: compressed_tokens
        })

      {:ok, %{content: compressed, metadata: metadata}}
    else
      {:error, :tokenizer_input_limit} -> {:skip, :tokenizer_input_limit}
      _not_smaller -> :skip
    end
  end

  def finalize(_strategy, _original, _compressed, _counts, _opts), do: :skip

  @spec lines(term()) :: {:ok, [String.t()]} | :error
  def lines(content) when is_binary(content) do
    if String.valid?(content) do
      parts = String.split(content, ["\r\n", "\n", "\r"], trim: false)

      lines =
        if newline_terminated?(content) and List.last(parts) == "" do
          Enum.drop(parts, -1)
        else
          parts
        end

      {:ok, lines}
    else
      :error
    end
  end

  def lines(_content), do: :error

  @spec join_lines([String.t()]) :: binary()
  def join_lines(lines), do: Enum.join(lines, "\n")

  @spec integer_option(opts(), atom(), integer(), integer()) :: integer()
  def integer_option(opts, key, default, minimum \\ 0) do
    opts
    |> option(key, default)
    |> normalize_integer(default, minimum)
  end

  @spec take_first_last([integer()], pos_integer()) :: [integer()]
  def take_first_last(values, limit) when is_list(values) and is_integer(limit) and limit > 0 do
    if length(values) <= limit do
      values
    else
      first_count = div(limit + 1, 2)
      last_count = limit - first_count

      values
      |> Enum.take(first_count)
      |> Kernel.++(Enum.take(values, -last_count))
      |> Enum.uniq()
    end
  end

  @spec collapse_lines([String.t()], [non_neg_integer()], (pos_integer() -> String.t())) ::
          {[String.t()], non_neg_integer()}
  def collapse_lines(lines, selected_indexes, marker_fun)
      when is_list(lines) and is_list(selected_indexes) and is_function(marker_fun, 1) do
    line_count = length(lines)

    selected_indexes =
      selected_indexes
      |> Enum.filter(&valid_index?(&1, line_count))
      |> Enum.uniq()
      |> Enum.sort()

    collapse_selected_lines(lines, selected_indexes, marker_fun, line_count)
  end

  defp collapse_selected_lines([], _selected_indexes, _marker_fun, _line_count), do: {[], 0}

  defp collapse_selected_lines(_lines, [], marker_fun, line_count) do
    {[marker_fun.(line_count)], line_count}
  end

  defp collapse_selected_lines(lines, selected_indexes, marker_fun, line_count) do
    {output, omitted_count, previous_index} =
      Enum.reduce(selected_indexes, {[], 0, -1}, fn index,
                                                    {output, omitted_count, previous_index} ->
        gap = index - previous_index - 1
        {output, omitted_count} = append_omission(output, omitted_count, gap, marker_fun)

        {[Enum.at(lines, index) | output], omitted_count, index}
      end)

    gap = line_count - previous_index - 1
    {output, omitted_count} = append_omission(output, omitted_count, gap, marker_fun)

    {Enum.reverse(output), omitted_count}
  end

  defp append_omission(output, omitted_count, gap, marker_fun) when gap > 0 do
    {[marker_fun.(gap) | output], omitted_count + gap}
  end

  defp append_omission(output, omitted_count, _gap, _marker_fun), do: {output, omitted_count}

  defp model(opts) do
    opts
    |> option(:model, nil)
    |> normalize_model()
  end

  defp option(opts, key, default) when is_list(opts) do
    Keyword.get(opts, key, default)
  end

  defp option(opts, key, default) when is_map(opts) do
    case Map.fetch(opts, key) do
      {:ok, value} -> value
      :error -> Map.get(opts, Atom.to_string(key), default)
    end
  end

  defp option(_opts, _key, default), do: default

  defp normalize_integer(value, _default, minimum) when is_integer(value) and value >= minimum do
    value
  end

  defp normalize_integer(_value, default, _minimum), do: default

  defp normalize_model(model) when is_binary(model) do
    model = String.trim(model)
    if model == "", do: :error, else: {:ok, model}
  end

  defp normalize_model(_model), do: :error

  defp count_tokens(model, content) do
    case TokenCounter.count(model, content) do
      {:ok, count, _metadata} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  defp safe_counts(counts) do
    counts
    |> Enum.filter(fn {key, value} ->
      is_atom(key) and is_integer(value) and value >= 0
    end)
    |> Map.new()
  end

  defp newline_terminated?(content) do
    String.ends_with?(content, "\n") or String.ends_with?(content, "\r")
  end

  defp valid_index?(index, line_count) do
    is_integer(index) and index >= 0 and index < line_count
  end
end
