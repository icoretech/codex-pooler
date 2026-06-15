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

  @type opts :: keyword() | map()
  @type plan :: %{
          required(:candidate_count) => non_neg_integer(),
          required(:candidates) => [Candidate.t()]
        }

  @spec plan(binary(), opts()) :: {:ok, plan()} | {:error, :invalid_json}
  def plan(json, opts \\ []) do
    with {:ok, candidates} <- plan_candidates(json, opts) do
      {:ok, %{candidate_count: length(candidates), candidates: candidates}}
    end
  end

  @spec plan_candidates(binary(), opts()) :: {:ok, [Candidate.t()]} | {:error, :invalid_json}
  def plan_candidates(json, opts \\ [])

  def plan_candidates(json, opts) when is_binary(json) do
    min_bytes = min_bytes(opts)

    with {:ok, ranges} <- JsonStringRanges.scan(json),
         {:ok, payload} <- decode_json(json) do
      {:ok, collect_candidates(json, payload, ranges, min_bytes)}
    end
  end

  def plan_candidates(_json, _opts), do: {:error, :invalid_json}

  defp decode_json(json) do
    case Jason.decode(json) do
      {:ok, payload} -> {:ok, payload}
      {:error, _error} -> {:error, :invalid_json}
    end
  end

  defp collect_candidates(json, %{"input" => input}, ranges, min_bytes) when is_list(input) do
    range_by_path = Map.new(ranges, &{&1.path, &1})
    skipped_call_ids = external_retrieval_call_ids(input)

    input
    |> input_items(["input"])
    |> Enum.reduce([], fn {item, path}, candidates ->
      case candidate(json, range_by_path, skipped_call_ids, item, path, min_bytes) do
        {:ok, candidate} -> [candidate | candidates]
        :skip -> candidates
      end
    end)
    |> Enum.sort_by(&{&1.byte_start, &1.byte_end, &1.output_path})
  end

  defp collect_candidates(_json, _payload, _ranges, _min_bytes), do: []

  defp candidate(json, range_by_path, skipped_call_ids, item, path, min_bytes) do
    with item_type when is_binary(item_type) <- Map.get(item, "type"),
         true <- supported_output_item_type?(item_type),
         false <- skipped_call_id?(item, skipped_call_ids),
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

  defp external_retrieval_call_ids(input) do
    input
    |> input_items(["input"])
    |> Enum.reduce(MapSet.new(), fn {item, _path}, call_ids ->
      if external_retrieval_call?(item) do
        MapSet.put(call_ids, item["call_id"])
      else
        call_ids
      end
    end)
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

  defp skipped_call_id?(item, skipped_call_ids) do
    case Map.get(item, "call_id") do
      call_id when is_binary(call_id) -> MapSet.member?(skipped_call_ids, call_id)
      _call_id -> false
    end
  end

  defp supported_output_item_type?(item_type) do
    MapSet.member?(@supported_output_item_types, item_type)
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
end
