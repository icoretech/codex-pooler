defmodule CodexPooler.Gateway.OpenAICompatibility.ImageObservation do
  @moduledoc false

  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Websocket.DiagnosticTaxonomy

  @spec from_http(pos_integer(), binary()) :: map()
  def from_http(status, body) do
    case CodexPooler.JSON.decode(body) do
      {:ok, %{"error" => %{} = error}} ->
        %{
          http_status: status,
          body_format: "json",
          error_code: diagnostic_field(error, "code"),
          error_type: diagnostic_field(error, "type"),
          error_param: diagnostic_field(error, "param")
        }

      {:ok, _other} ->
        %{
          http_status: status,
          body_format: "json",
          error_code: nil,
          error_type: nil,
          error_param: nil
        }

      {:error, _invalid} ->
        Map.merge(from_sse(body), %{http_status: status, body_format: "sse_or_unrecognized"})
    end
  end

  defp diagnostic_field(error, key) do
    case Map.get(error, key) do
      value when is_binary(value) -> DiagnosticTaxonomy.identifier(value)
      _value -> nil
    end
  end

  @spec from_sse(binary()) :: map()
  def from_sse(body) do
    initial = %{
      outcome: "no_image_item",
      terminal: "absent",
      image_items: 0,
      messages: 0,
      tool_calls: 0,
      other_items: 0,
      refusals: 0,
      error_code: nil
    }

    body
    |> StreamProtocol.complete_sse_blocks(bounded?: false)
    |> elem(0)
    |> Enum.reduce(initial, fn block, observation ->
      event = block |> StreamProtocol.sse_field("data") |> StreamProtocol.decode_sse_data()
      observation = %{observation | terminal: terminal(event, observation.terminal)}
      Enum.reduce(items(event), observation, &observe_item/2)
    end)
  end

  defp items(%{"type" => "response.output_item.done", "item" => %{} = item}), do: [item]
  defp items(%{"response" => %{"output" => output}}) when is_list(output), do: output
  defp items(%{"output" => output}) when is_list(output), do: output
  defp items(_event), do: []

  defp observe_item(%{"type" => "image_generation_call"} = item, observation) do
    outcome = image_outcome(item)
    prior = observation.outcome

    selected =
      Enum.find(
        ~w(failed_image_item usable_image_result empty_image_result nonstring_image_result),
        &(&1 in [prior, outcome])
      )

    observation
    |> increment(:image_items)
    |> Map.put(:outcome, selected)
    |> Map.put(:error_code, observation.error_code || error_code(item))
  end

  defp observe_item(%{"type" => "message"} = item, observation) do
    content = Map.get(item, "content", [])
    content = if is_list(content), do: content, else: []

    Enum.reduce(content, increment(observation, :messages), fn
      %{"type" => "refusal"}, acc -> increment(acc, :refusals)
      _part, acc -> acc
    end)
  end

  defp observe_item(%{"type" => type}, observation)
       when type in ["function_call", "custom_tool_call"],
       do: increment(observation, :tool_calls)

  defp observe_item(_item, observation), do: increment(observation, :other_items)

  defp image_outcome(%{"status" => "failed"}), do: "failed_image_item"
  defp image_outcome(%{"result" => ""}), do: "empty_image_result"
  defp image_outcome(%{"result" => result}) when is_binary(result), do: "usable_image_result"
  defp image_outcome(_item), do: "nonstring_image_result"

  defp error_code(%{"error" => %{"code" => code}}) when is_binary(code),
    do: DiagnosticTaxonomy.identifier(code)

  defp error_code(_item), do: nil

  defp terminal(%{"type" => "response.completed"}, _prior), do: "completed"
  defp terminal(%{"type" => "response.failed"}, _prior), do: "failed"
  defp terminal(%{"type" => "response.incomplete"}, _prior), do: "incomplete"
  defp terminal(_event, prior), do: prior

  defp increment(observation, key), do: Map.update!(observation, key, &min(&1 + 1, 1000))
end
