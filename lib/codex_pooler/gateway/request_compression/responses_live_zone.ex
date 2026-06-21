defmodule CodexPooler.Gateway.RequestCompression.ResponsesLiveZone do
  @moduledoc false

  alias CodexPooler.Gateway.RequestCompression.ContentDetector
  alias CodexPooler.Gateway.RequestCompression.JsonStringRanges

  defmodule Candidate do
    @moduledoc false

    alias CodexPooler.Gateway.RequestCompression.ContentDetector
    alias CodexPooler.Gateway.RequestCompression.JsonStringRanges

    @enforce_keys [
      :item_type,
      :output_path,
      :byte_start,
      :byte_end,
      :encoded_byte_size,
      :output_byte_size,
      :content_kind,
      :content_confidence,
      :compressible,
      :strategy
    ]
    defstruct [
      :item_type,
      :output_path,
      :byte_start,
      :byte_end,
      :encoded_byte_size,
      :output_byte_size,
      :content_kind,
      :content_confidence,
      :compressible,
      :strategy
    ]

    @type t :: %__MODULE__{
            item_type: String.t(),
            output_path: JsonStringRanges.path(),
            byte_start: non_neg_integer(),
            byte_end: non_neg_integer(),
            encoded_byte_size: pos_integer(),
            output_byte_size: non_neg_integer(),
            content_kind: ContentDetector.kind(),
            content_confidence: float(),
            compressible: boolean(),
            strategy: ContentDetector.strategy() | nil
          }
  end

  @default_min_bytes 512
  @supported_output_item_types MapSet.new([
                                 "function_call_output",
                                 "local_shell_call_output",
                                 "apply_patch_call_output"
                               ])
  @external_retrieval_name <<104, 101, 97, 100, 114, 111, 111, 109, 95, 114, 101, 116, 114, 105,
                             101, 118, 101>>
  @external_retrieval_suffix <<95, 95>> <> @external_retrieval_name
  @default_excluded_function_tool_name_list ~w(Read Glob Grep Write Edit read glob grep write edit)

  @type opts :: keyword() | map()
  @type plan :: %{
          required(:candidate_count) => non_neg_integer(),
          required(:candidates) => [Candidate.t()],
          required(:protected_tool_output_skipped_count) => non_neg_integer()
        }

  @spec plan(binary(), opts()) :: {:ok, plan()} | {:error, :invalid_json}
  def plan(json, opts \\ []) do
    with {:ok, details} <- plan_details(json, opts) do
      {:ok,
       %{
         candidate_count: length(details.candidates),
         candidates: details.candidates,
         protected_tool_output_skipped_count: details.protected_tool_output_skipped_count
       }}
    end
  end

  @spec plan_candidates(binary(), opts()) :: {:ok, [Candidate.t()]} | {:error, :invalid_json}
  def plan_candidates(json, opts \\ [])

  def plan_candidates(json, opts) when is_binary(json) do
    with {:ok, details} <- plan_details(json, opts) do
      {:ok, details.candidates}
    end
  end

  def plan_candidates(_json, _opts), do: {:error, :invalid_json}

  defp plan_details(json, opts) when is_binary(json) do
    min_bytes = min_bytes(opts)
    excluded_function_tool_names = excluded_function_tool_names(opts)

    with {:ok, ranges} <- JsonStringRanges.scan(json),
         {:ok, payload} <- decode_json(json) do
      {:ok, collect_candidates(json, payload, ranges, min_bytes, excluded_function_tool_names)}
    end
  end

  defp plan_details(_json, _opts), do: {:error, :invalid_json}

  defp decode_json(json) do
    case Jason.decode(json) do
      {:ok, payload} -> {:ok, payload}
      {:error, _error} -> {:error, :invalid_json}
    end
  end

  defp collect_candidates(
         json,
         %{"input" => input},
         ranges,
         min_bytes,
         excluded_function_tool_names
       )
       when is_list(input) do
    range_by_path = Map.new(ranges, &{&1.path, &1})
    items = input_items(input, ["input"])

    {skipped_call_ids, known_function_call_ids} =
      call_id_sets(items, excluded_function_tool_names)

    candidates =
      items
      |> Enum.reduce([], fn {item, path}, candidates ->
        case candidate(
               json,
               range_by_path,
               skipped_call_ids,
               known_function_call_ids,
               item,
               path,
               min_bytes
             ) do
          {:ok, candidate} -> [candidate | candidates]
          :skip -> candidates
        end
      end)
      |> Enum.sort_by(&{&1.byte_start, &1.byte_end, &1.output_path})

    %{
      candidates: candidates,
      protected_tool_output_skipped_count:
        protected_tool_output_skipped_count(
          json,
          range_by_path,
          items,
          skipped_call_ids,
          known_function_call_ids,
          min_bytes
        )
    }
  end

  defp collect_candidates(_json, _payload, _ranges, _min_bytes, _excluded_function_tool_names),
    do: %{candidates: [], protected_tool_output_skipped_count: 0}

  defp candidate(
         json,
         range_by_path,
         skipped_call_ids,
         known_function_call_ids,
         item,
         path,
         min_bytes
       ) do
    with item_type when is_binary(item_type) <- Map.get(item, "type"),
         true <- supported_output_item_type?(item_type),
         false <- protected_tool_output?(item, skipped_call_ids, known_function_call_ids),
         output_path <- path ++ ["output"],
         %{byte_start: byte_start, byte_end: byte_end, encoded_byte_size: encoded_byte_size} =
           range <- Map.get(range_by_path, output_path),
         {:ok, output} <- JsonStringRanges.decode_string(json, range),
         true <- byte_size(output) >= min_bytes do
      decision = ContentDetector.detect(output)

      {:ok,
       %Candidate{
         item_type: item_type,
         output_path: output_path,
         byte_start: byte_start,
         byte_end: byte_end,
         encoded_byte_size: encoded_byte_size,
         output_byte_size: byte_size(output),
         content_kind: decision.kind,
         content_confidence: decision.confidence,
         compressible: decision.compressible,
         strategy: decision.strategy
       }}
    else
      _not_candidate -> :skip
    end
  end

  defp call_id_sets(items, excluded_function_tool_names) do
    Enum.reduce(items, {MapSet.new(), MapSet.new()}, fn {item, _path},
                                                        {skipped_call_ids, known_call_ids} ->
      known_call_ids = put_known_function_call_id(known_call_ids, item)

      skipped_call_ids =
        case skipped_function_call_id(item, excluded_function_tool_names) do
          call_id when is_binary(call_id) and call_id != "" ->
            MapSet.put(skipped_call_ids, call_id)

          _call_id ->
            skipped_call_ids
        end

      {skipped_call_ids, known_call_ids}
    end)
  end

  defp put_known_function_call_id(call_ids, %{"type" => "function_call", "call_id" => call_id})
       when is_binary(call_id) and call_id != "" do
    MapSet.put(call_ids, call_id)
  end

  defp put_known_function_call_id(call_ids, _item), do: call_ids

  defp skipped_function_call_id(item, excluded_function_tool_names) do
    cond do
      external_retrieval_call?(item) -> item["call_id"]
      excluded_function_tool_call?(item, excluded_function_tool_names) -> item["call_id"]
      true -> nil
    end
  end

  defp external_retrieval_call?(%{
         "type" => "function_call",
         "call_id" => call_id,
         "name" => name
       })
       when is_binary(call_id) and is_binary(name) do
    name == @external_retrieval_name or String.ends_with?(name, @external_retrieval_suffix)
  end

  defp external_retrieval_call?(_item), do: false

  defp excluded_function_tool_call?(
         %{"type" => "function_call", "call_id" => call_id, "name" => name},
         excluded_function_tool_names
       )
       when is_binary(call_id) and is_binary(name) do
    name in excluded_function_tool_names or String.downcase(name) in excluded_function_tool_names
  end

  defp excluded_function_tool_call?(_item, _excluded_function_tool_names), do: false

  defp protected_tool_output?(
         %{"type" => "function_call_output"} = item,
         skipped_call_ids,
         known_function_call_ids
       ) do
    skipped_call_id?(item, skipped_call_ids) or
      unknown_function_tool_output?(item, known_function_call_ids)
  end

  defp protected_tool_output?(item, skipped_call_ids, _known_function_call_ids) do
    skipped_call_id?(item, skipped_call_ids)
  end

  defp unknown_function_tool_output?(%{"call_id" => call_id}, known_function_call_ids)
       when is_binary(call_id) and call_id != "" do
    not MapSet.member?(known_function_call_ids, call_id)
  end

  defp unknown_function_tool_output?(_item, _known_function_call_ids), do: true

  defp skipped_call_id?(item, skipped_call_ids) do
    case Map.get(item, "call_id") do
      call_id when is_binary(call_id) -> MapSet.member?(skipped_call_ids, call_id)
      _call_id -> false
    end
  end

  defp supported_output_item_type?(item_type) do
    MapSet.member?(@supported_output_item_types, item_type)
  end

  defp protected_tool_output_skipped_count(
         json,
         range_by_path,
         items,
         skipped_call_ids,
         known_function_call_ids,
         min_bytes
       ) do
    Enum.count(items, fn {item, path} ->
      protected_tool_output_skipped?(
        json,
        range_by_path,
        item,
        path,
        skipped_call_ids,
        known_function_call_ids,
        min_bytes
      )
    end)
  end

  defp protected_tool_output_skipped?(
         json,
         range_by_path,
         item,
         path,
         skipped_call_ids,
         known_function_call_ids,
         min_bytes
       ) do
    with item_type when is_binary(item_type) <- Map.get(item, "type"),
         true <- supported_output_item_type?(item_type),
         true <- protected_tool_output?(item, skipped_call_ids, known_function_call_ids),
         output_path <- path ++ ["output"],
         range when is_map(range) <- Map.get(range_by_path, output_path),
         {:ok, output} <- JsonStringRanges.decode_string(json, range) do
      byte_size(output) >= min_bytes
    else
      _not_protected -> false
    end
  end

  @spec input_items(term(), JsonStringRanges.path()) :: [{map(), JsonStringRanges.path()}]
  defp input_items(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} -> input_items(item, path ++ [index]) end)
  end

  defp input_items(value, path) when is_map(value), do: [{value, path}]

  defp input_items(_value, _path), do: []

  defp min_bytes(opts) when is_list(opts) do
    opts
    |> Keyword.get(:min_bytes, @default_min_bytes)
    |> normalize_min_bytes()
  end

  defp min_bytes(opts) when is_map(opts) do
    opts
    |> Map.get(:min_bytes, Map.get(opts, "min_bytes", @default_min_bytes))
    |> normalize_min_bytes()
  end

  defp min_bytes(_opts), do: @default_min_bytes

  defp normalize_min_bytes(value) when is_integer(value) and value >= 0, do: value
  defp normalize_min_bytes(_value), do: @default_min_bytes

  defp excluded_function_tool_names(opts) when is_list(opts) do
    opts
    |> Keyword.get(:excluded_function_tool_names, Keyword.get(opts, :excluded_tools))
    |> normalize_excluded_function_tool_names()
  end

  defp excluded_function_tool_names(opts) when is_map(opts) do
    opts
    |> Map.get(
      :excluded_function_tool_names,
      Map.get(
        opts,
        "excluded_function_tool_names",
        Map.get(opts, :excluded_tools, Map.get(opts, "excluded_tools"))
      )
    )
    |> normalize_excluded_function_tool_names()
  end

  defp excluded_function_tool_names(_opts), do: @default_excluded_function_tool_name_list

  defp normalize_excluded_function_tool_names(nil), do: @default_excluded_function_tool_name_list

  defp normalize_excluded_function_tool_names(names) when is_list(names) do
    names
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(&[&1, String.downcase(&1)])
    |> Kernel.++(@default_excluded_function_tool_name_list)
    |> Enum.uniq()
  end

  defp normalize_excluded_function_tool_names(_names),
    do: @default_excluded_function_tool_name_list
end
