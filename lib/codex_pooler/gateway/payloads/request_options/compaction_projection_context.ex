defmodule CodexPooler.Gateway.Payloads.RequestOptions.CompactionProjectionContext do
  @moduledoc false

  alias CodexPooler.Gateway.Payloads.RequestOptions

  @count_cap 1_000_000
  @fingerprint_chars 16
  @classes ~w(compaction_trigger tool_call tool_output message reasoning other)

  defmodule Stage do
    @moduledoc false

    @enforce_keys [:state, :anchor_digest, :item_count, :count_capped, :item_classes]
    defstruct [:state, :anchor_digest, :item_count, :count_capped, :item_classes]

    @type state :: :absent | :valid | :invalid
    @type t :: %__MODULE__{
            state: state(),
            anchor_digest: <<_::256>> | nil,
            item_count: non_neg_integer(),
            count_capped: boolean(),
            item_classes: %{optional(String.t()) => non_neg_integer()}
          }
  end

  @enforce_keys [:downstream_frame, :compact_projection]
  defstruct [:downstream_frame, :compact_projection]

  @type safe_stage :: %{
          required(String.t()) => String.t() | non_neg_integer() | boolean() | map()
        }
  @type safe_projection :: %{required(String.t()) => String.t() | safe_stage()}
  @type t :: %__MODULE__{
          downstream_frame: Stage.t(),
          compact_projection: Stage.t()
        }

  @spec new(term(), term()) :: t()
  def new(downstream_frame, compact_projection) do
    %__MODULE__{
      downstream_frame: stage(downstream_frame),
      compact_projection: stage(compact_projection)
    }
  end

  @spec finalize(t(), term()) :: safe_projection()
  def finalize(%__MODULE__{} = context, upstream_payload) do
    upstream_stage = stage(upstream_payload)

    %{
      "action" => action(context.downstream_frame, context.compact_projection, upstream_stage),
      "downstream_frame" => safe_stage(context.downstream_frame),
      "compact_projection" => safe_stage(context.compact_projection),
      "upstream_payload" => safe_stage(upstream_stage)
    }
  end

  @spec finalize(RequestOptions.t(), term()) :: {safe_projection() | nil, RequestOptions.t()}
  def finalize(%RequestOptions{} = request_options, upstream_payload) do
    case request_options.payload_context.compaction_projection_context do
      %__MODULE__{} = context ->
        safe_projection = finalize(context, upstream_payload)

        {safe_projection,
         RequestOptions.put_payload_context(request_options,
           compaction_projection_context: nil,
           compaction_projection: safe_projection
         )}

      nil ->
        {nil, request_options}
    end
  end

  defp stage(payload) when is_map(payload) do
    {state, digest} = anchor(payload)
    {item_count, count_capped, item_classes} = item_counts(Map.get(payload, "input"))

    %Stage{
      state: state,
      anchor_digest: digest,
      item_count: item_count,
      count_capped: count_capped,
      item_classes: item_classes
    }
  end

  defp stage(_payload) do
    %Stage{
      state: :invalid,
      anchor_digest: nil,
      item_count: 0,
      count_capped: false,
      item_classes: %{}
    }
  end

  defp anchor(payload) do
    case Map.fetch(payload, "previous_response_id") do
      :error -> {:absent, nil}
      {:ok, value} when is_binary(value) -> valid_anchor(value)
      {:ok, _value} -> {:invalid, nil}
    end
  end

  defp valid_anchor(value) do
    if String.trim(value) == "",
      do: {:invalid, nil},
      else: {:valid, :crypto.hash(:sha256, value)}
  end

  defp item_counts(items) when is_list(items) do
    {count, classes} =
      Enum.reduce(items, {0, %{}}, fn item, {count, classes} ->
        class = item_class(item)
        {count + 1, Map.update(classes, class, 1, &(&1 + 1))}
      end)

    {min(count, @count_cap), count > @count_cap,
     Map.new(classes, fn {class, class_count} -> {class, min(class_count, @count_cap)} end)}
  end

  defp item_counts(nil), do: {0, false, %{}}
  defp item_counts(_invalid), do: {0, false, %{}}

  defp item_class(%{"type" => type}) when is_binary(type) do
    cond do
      type == "compaction_trigger" ->
        "compaction_trigger"

      type == "message" ->
        "message"

      type == "reasoning" or String.starts_with?(type, "reasoning_") ->
        "reasoning"

      String.contains?(type, "output") ->
        "tool_output"

      String.contains?(type, "tool_call") or String.ends_with?(type, "function_call") ->
        "tool_call"

      true ->
        "other"
    end
  end

  defp item_class(_item), do: "other"

  defp action(%Stage{state: :invalid}, _compact, _upstream), do: "invalid"
  defp action(_downstream, %Stage{state: :invalid}, _upstream), do: "invalid"
  defp action(_downstream, _compact, %Stage{state: :invalid}), do: "invalid"

  defp action(%Stage{state: :absent}, %Stage{state: :absent}, %Stage{state: :absent}),
    do: "absent"

  defp action(%Stage{state: :absent}, _compact, _upstream), do: "introduced"
  defp action(%Stage{state: :valid}, %Stage{state: :absent}, _upstream), do: "dropped"
  defp action(%Stage{state: :valid}, _compact, %Stage{state: :absent}), do: "dropped"

  defp action(
         %Stage{state: :valid, anchor_digest: digest},
         %Stage{state: :valid, anchor_digest: digest},
         %Stage{state: :valid, anchor_digest: digest}
       ),
       do: "preserved"

  defp action(%Stage{state: :valid}, %Stage{state: :valid}, %Stage{state: :valid}),
    do: "changed"

  defp safe_stage(%Stage{} = stage) do
    %{
      "state" => Atom.to_string(stage.state),
      "item_count" => stage.item_count,
      "count_capped" => stage.count_capped,
      "item_classes" => Map.take(stage.item_classes, @classes)
    }
    |> maybe_put_fingerprint(stage.anchor_digest)
  end

  defp maybe_put_fingerprint(safe, digest) when is_binary(digest) do
    fingerprint =
      :crypto.hash(:sha256, "compaction_projection_anchor\0" <> digest)
      |> Base.encode16(case: :lower)
      |> binary_part(0, @fingerprint_chars)

    Map.put(safe, "anchor_fingerprint", fingerprint)
  end

  defp maybe_put_fingerprint(safe, nil), do: safe
end

defimpl Inspect,
  for: CodexPooler.Gateway.Payloads.RequestOptions.CompactionProjectionContext do
  def inspect(_context, _opts), do: "#CompactionProjectionContext<redacted>"
end

defimpl Inspect,
  for: CodexPooler.Gateway.Payloads.RequestOptions.CompactionProjectionContext.Stage do
  def inspect(_stage, _opts), do: "#CompactionProjectionContext.Stage<redacted>"
end
