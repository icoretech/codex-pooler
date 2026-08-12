defmodule CodexPooler.Gateway.Facade.Ollama.Response do
  @moduledoc """
  Projects a collected canonical Responses result into native Ollama JSON.
  """

  alias CodexPooler.Gateway.Facade

  @spec chat(map(), map()) :: map()
  def chat(decoded, formatting) when is_map(decoded) and is_map(formatting) do
    {content, stopped?} = visible_text(decoded, formatting)

    message =
      %{"role" => "assistant", "content" => content}
      |> maybe_put("thinking", visible_summary(decoded, formatting))
      |> maybe_put("tool_calls", tool_calls(decoded))

    base_response(decoded, formatting, stopped?)
    |> Map.put("message", message)
  end

  @spec generate(map(), map()) :: map()
  def generate(decoded, formatting) when is_map(decoded) and is_map(formatting) do
    {content, stopped?} = visible_text(decoded, formatting)

    base_response(decoded, formatting, stopped?)
    |> Map.put("response", content)
    |> maybe_put("thinking", visible_summary(decoded, formatting))
  end

  defp base_response(decoded, formatting, stopped?) do
    usage = usage(decoded)

    %{
      "model" => Facade.public_model(),
      "created_at" =>
        DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601(),
      "done" => true,
      "done_reason" => done_reason(decoded, stopped?),
      "total_duration" => elapsed_nanoseconds(formatting),
      "load_duration" => 0,
      "prompt_eval_count" => usage.input_tokens,
      "prompt_eval_duration" => 0,
      "eval_count" => usage.output_tokens,
      "eval_duration" => 0
    }
  end

  defp visible_text(decoded, formatting) do
    text =
      decoded
      |> output_items()
      |> Enum.flat_map(fn
        %{"type" => "message", "content" => content} when is_list(content) ->
          Enum.flat_map(content, fn
            %{"type" => "output_text", "text" => text} when is_binary(text) -> [text]
            _part -> []
          end)

        _item ->
          []
      end)
      |> Enum.join()

    truncate_at_stop(text, Map.get(formatting, :stops, []))
  end

  defp visible_summary(_decoded, %{think?: false}), do: nil

  defp visible_summary(decoded, _formatting) do
    decoded
    |> output_items()
    |> Enum.flat_map(fn
      %{"type" => "reasoning", "summary" => summary} when is_list(summary) ->
        Enum.flat_map(summary, fn
          %{"type" => "summary_text", "text" => text} when is_binary(text) -> [text]
          _part -> []
        end)

      _item ->
        []
    end)
    |> Enum.join("\n")
    |> blank_to_nil()
  end

  defp tool_calls(decoded) do
    calls =
      decoded
      |> output_items()
      |> Enum.flat_map(fn
        %{"type" => "function_call", "name" => name, "arguments" => arguments}
        when is_binary(name) and is_binary(arguments) ->
          [
            %{
              "id" => local_call_id(),
              "function" => %{
                "name" => name,
                "arguments" => safe_arguments(arguments)
              }
            }
          ]

        _item ->
          []
      end)

    if calls == [], do: nil, else: calls
  end

  defp safe_arguments(arguments) do
    case Jason.decode(arguments) do
      {:ok, %{} = decoded} -> decoded
      _invalid -> %{}
    end
  end

  defp usage(decoded) do
    usage = Map.get(decoded, "usage", %{})

    %{
      input_tokens: nonnegative_integer(Map.get(usage, "input_tokens")),
      output_tokens: nonnegative_integer(Map.get(usage, "output_tokens"))
    }
  end

  defp output_items(%{"output" => output}) when is_list(output), do: output
  defp output_items(_decoded), do: []

  defp done_reason(_decoded, true), do: "stop"

  defp done_reason(%{"incomplete_details" => %{"reason" => "max_output_tokens"}}, false),
    do: "length"

  defp done_reason(%{"status" => "incomplete"}, false), do: "length"
  defp done_reason(_decoded, false), do: "stop"

  defp elapsed_nanoseconds(%{started_at: started_at}) when is_integer(started_at) do
    elapsed = max(System.monotonic_time() - started_at, 0)
    System.convert_time_unit(elapsed, :native, :nanosecond)
  end

  defp elapsed_nanoseconds(_formatting), do: 0

  defp truncate_at_stop(text, stops) when is_binary(text) and is_list(stops) do
    stops
    |> Enum.flat_map(fn
      stop when is_binary(stop) and stop != "" ->
        case :binary.match(text, stop) do
          {index, _length} -> [{index, stop}]
          :nomatch -> []
        end

      _stop ->
        []
    end)
    |> Enum.min_by(fn {index, stop} -> {index, -byte_size(stop)} end, fn -> nil end)
    |> case do
      {index, _stop} -> {binary_part(text, 0, index), true}
      nil -> {text, false}
    end
  end

  defp local_call_id do
    "call_" <> (Ecto.UUID.generate() |> String.replace("-", ""))
  end

  defp nonnegative_integer(value) when is_integer(value) and value >= 0, do: value
  defp nonnegative_integer(_value), do: 0

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(_value), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
