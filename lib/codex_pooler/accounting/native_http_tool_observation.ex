defmodule CodexPooler.Accounting.NativeHttpToolObservation do
  @moduledoc false

  # Only a single incomplete client-side tool is admitted. Completed items,
  # provider-side tools and unrecognised events all destroy this authority.
  # The item id is transient matching state and never enters metadata.
  defstruct item_id: nil, call_type: nil, input_done?: false, poisoned?: false

  @type t :: %__MODULE__{
          item_id: String.t() | nil,
          call_type: String.t() | nil,
          input_done?: boolean(),
          poisoned?: boolean()
        }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec poison(t()) :: t()
  def poison(%__MODULE__{} = observation), do: %{observation | poisoned?: true}

  @spec observe(t(), String.t() | nil, term()) :: t()
  def observe(%__MODULE__{poisoned?: true} = observation, _label, _decoded), do: observation

  def observe(observation, label, %{"type" => type} = decoded) when label == type,
    do: observe_event(observation, type, decoded)

  def observe(observation, _label, _decoded), do: poison(observation)

  @spec metadata(t(), boolean()) :: map()
  def metadata(%__MODULE__{} = observation, parser_complete?) do
    %{
      "version" => 1,
      "parser_complete" => parser_complete?,
      "poisoned" => observation.poisoned?,
      "partial_tool" => observation.call_type,
      "input_done" => observation.input_done?
    }
  end

  @spec eligible_metadata?(term()) :: boolean()
  def eligible_metadata?(%{"version" => 1, "parser_complete" => true, "poisoned" => false, "partial_tool" => type}),
    do: type in ["custom_tool_call", "function_call"]

  def eligible_metadata?(_metadata), do: false

  defp observe_event(observation, type, %{"response" => %{} = response})
       when type in ["response.created", "response.in_progress", "response.queued"] do
    if Map.get(response, "output", []) == [] and Map.get(response, "status") in [nil, "queued", "in_progress"],
      do: observation,
      else: poison(observation)
  end

  defp observe_event(%__MODULE__{item_id: nil} = observation, "response.output_item.added", %{
         "output_index" => 0,
         "item" => %{"id" => id, "type" => type, "call_id" => call_id, "name" => name} = item
       })
       when type in ["custom_tool_call", "function_call"] and is_binary(id) and byte_size(id) in 1..1024 and
              is_binary(call_id) and byte_size(call_id) > 0 and is_binary(name) and byte_size(name) > 0 do
    if Map.get(item, "status") in [nil, "in_progress"],
      do: %{observation | item_id: id, call_type: type},
      else: poison(observation)
  end

  defp observe_event(%__MODULE__{item_id: id, call_type: call_type, input_done?: false} = observation, type, %{
         "item_id" => id,
         "output_index" => 0,
         "delta" => delta
       })
       when is_binary(id) and is_binary(delta) do
    if {call_type, type} in [
         {"custom_tool_call", "response.custom_tool_call_input.delta"},
         {"function_call", "response.function_call_arguments.delta"}
       ],
       do: observation,
       else: poison(observation)
  end

  defp observe_event(%__MODULE__{item_id: id, call_type: "custom_tool_call", input_done?: false} = observation, "response.custom_tool_call_input.done", %{"item_id" => id, "output_index" => 0, "input" => input})
       when is_binary(id) and is_binary(input),
       do: %{observation | input_done?: true}

  defp observe_event(%__MODULE__{item_id: id, call_type: "function_call", input_done?: false} = observation, "response.function_call_arguments.done", %{"item_id" => id, "output_index" => 0, "arguments" => arguments})
       when is_binary(id) and is_binary(arguments),
       do: %{observation | input_done?: true}

  defp observe_event(observation, _type, _decoded), do: poison(observation)
end
