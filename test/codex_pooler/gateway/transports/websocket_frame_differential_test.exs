defmodule CodexPooler.Gateway.Transports.WebsocketFrameDifferentialTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.PublicResponses
  alias CodexPooler.Gateway.Transports.Streaming.WebsocketBridgeStream

  @moduletag :websocket_frame_differential
  @seed {20_260_730, 41, 97}

  defmodule Reference do
    @moduledoc false

    alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
    alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.PublicResponses

    def normalize_json_message(data) do
      case Jason.decode(data) do
        {:ok, %{"type" => "response.failed"} = decoded} ->
          "response.failed"
          |> PublicResponses.normalize_terminal_errors(decoded)
          |> Jason.encode!()

        {:ok, %{} = decoded} ->
          prepared = suppress_incomplete_provider_error_types(decoded)
          canonical_input = if prepared == decoded, do: data, else: Jason.encode!(prepared)
          normalize_canonical_message(canonical_input, data)

        _invalid ->
          data
      end
    end

    def sse_block(text) do
      case Jason.decode(text) do
        {:ok, %{"type" => type}} when is_binary(type) and type != "" ->
          "event: " <> type <> "\ndata: " <> text <> "\n\n"

        _other ->
          "data: " <> text <> "\n\n"
      end
    end

    defp normalize_canonical_message(canonical_input, original_data) do
      canonical_data = StreamProtocol.canonicalize_codex_responses_json_message(canonical_input)

      case Jason.decode(canonical_data) do
        {:ok, %{} = canonical} ->
          type = clean_string(Map.get(canonical, "type"))
          normalized = PublicResponses.normalize_terminal_errors(type, canonical)
          if normalized == canonical, do: canonical_data, else: Jason.encode!(normalized)

        _invalid ->
          original_data
      end
    end

    defp suppress_incomplete_provider_error_types(%{"type" => "response.incomplete"} = decoded) do
      decoded
      |> drop_type_without_code(["error"])
      |> drop_type_without_code(["response", "error"])
    end

    defp suppress_incomplete_provider_error_types(decoded), do: decoded

    defp drop_type_without_code(decoded, path) do
      case get_in(decoded, path) do
        %{"type" => _type, "code" => code} when is_binary(code) -> decoded
        %{"type" => _type} = error -> put_in(decoded, path, Map.delete(error, "type"))
        _error -> decoded
      end
    end

    defp clean_string(value) when is_binary(value) do
      value = String.trim(value)
      if value == "", do: nil, else: value
    end

    defp clean_string(_value), do: nil
  end

  test "source-anchored public mapper is byte-identical across the websocket corpus" do
    Enum.each(frame_corpus(), fn {label, frame} ->
      assert_same_bytes(
        label,
        Reference.normalize_json_message(frame),
        PublicResponses.normalize_json_message(frame)
      )
    end)
  end

  test "source-anchored bridge wrapper is byte-identical across the websocket corpus" do
    Enum.each(frame_corpus(), fn {label, frame} ->
      assert_same_bytes(label, Reference.sse_block(frame), WebsocketBridgeStream.sse_block(frame))
    end)
  end

  test "seeded frame mutations preserve exact mapper and bridge bytes" do
    rng = :rand.seed_s(:exsss, @seed)
    corpus = frame_corpus()

    Enum.reduce(1..160, rng, fn iteration, rng ->
      {index, rng} = :rand.uniform_s(length(corpus), rng)
      {label, frame} = Enum.at(corpus, index - 1)
      {mutation, rng} = random_mutation(frame, rng)

      assert_same_bytes(
        {label, iteration, byte_size(mutation)},
        Reference.normalize_json_message(mutation),
        PublicResponses.normalize_json_message(mutation)
      )

      assert_same_bytes(
        {label, iteration, byte_size(mutation)},
        Reference.sse_block(mutation),
        WebsocketBridgeStream.sse_block(mutation)
      )

      rng
    end)
  end

  test "bridge relay sequences preserve exact SSE blocks and terminal state" do
    rng = :rand.seed_s(:exsss, @seed)
    corpus = frame_corpus()

    Enum.reduce(1..80, rng, fn iteration, rng ->
      {sequence, rng} = random_sequence(corpus, rng)

      expected = reference_relay(sequence)
      actual = current_relay(sequence)

      assert expected == actual,
             "relay differential mismatch iteration=#{iteration} frame_count=#{length(sequence)}"

      rng
    end)
  end

  test "large item.done and delta fixtures do not retain their parent after normalization" do
    parent = large_frame_parent()

    Enum.each([large_delta(parent), large_item_done(parent)], fn frame ->
      normalized = PublicResponses.normalize_json_message(frame)
      assert byte_size(normalized) == byte_size(frame)
      assert :binary.referenced_byte_size(normalized) == byte_size(normalized)
    end)
  end

  defp frame_corpus do
    parent = large_frame_parent()

    [
      {:delta, ~s({"type":"response.output_text.delta","delta":"sample"})},
      {:delta_whitespace, ~s( { "delta" : "sample", "type" : "response.output_text.delta" } )},
      {:large_delta, large_delta(parent)},
      {:item_done,
       ~s({"type":"response.output_item.done","item":{"type":"message","id":"item_sample"}})},
      {:large_item_done, large_item_done(parent)},
      {:rate_limit, ~s({"type":"codex.rate_limits","rate_limits":{}})},
      {:completed,
       ~s({"type":"response.completed","response":{"id":"resp_sample","status":"completed"}})},
      {:done, ~s({"type":"response.done","response":{"id":"resp_sample","status":"completed"}})},
      {:failed,
       ~s({"type":"response.failed","response":{"id":"resp_sample","status":"failed","error":{"code":"server_error"}}})},
      {:incomplete,
       ~s({"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"}}})},
      {:incomplete_provider_types,
       ~s({"type":"response.incomplete","error":{"type":"provider_error"},"response":{"status":"incomplete","error":{"type":"provider_error"}}})},
      {:error, ~s({"type":"error","error":{"code":"server_error"}})},
      {:legacy_terminal, ~s({"id":"resp_legacy_sample"})},
      {:malformed_terminal,
       ~s({"type":"response.completed","response":{"id":"resp_sample","status":"failed"}})},
      {:typeless_detail, ~s({"detail":{"kind":"sample"}})},
      {:malformed_json, ~s({"type":"response.output_text.delta")},
      {:truncated_json, ~s({"type":"response.failed","response":)},
      {:json_array, ~s([{"type":"response.completed"}])},
      {:json_scalar, ~s("response.completed")},
      {:json_null, "null"}
    ]
  end

  defp large_frame_parent, do: :binary.copy("x", 1_000_000)

  defp large_delta(parent) do
    ~s({"type":"response.output_text.delta","delta":"#{parent}","sequence_number":7})
  end

  defp large_item_done(parent) do
    ~s({"type":"response.output_item.done","item":{"type":"message","id":"item_large","content":"#{parent}"}})
  end

  defp random_mutation(frame, rng) do
    {choice, rng} = :rand.uniform_s(4, rng)

    mutation =
      case choice do
        1 -> frame
        2 -> " " <> frame <> "\n"
        3 -> binary_part(frame, 0, max(byte_size(frame) - 1, 0))
        4 -> frame <> "!"
      end

    {mutation, rng}
  end

  defp random_sequence(corpus, rng) do
    {count, rng} = :rand.uniform_s(8, rng)

    Enum.reduce(1..count, {[], rng}, fn _index, {frames, rng} ->
      {index, rng} = :rand.uniform_s(length(corpus), rng)
      {_label, frame} = Enum.at(corpus, index - 1)
      {[frame | frames], rng}
    end)
    |> then(fn {frames, rng} -> {Enum.reverse(frames), rng} end)
  end

  defp reference_relay(frames) do
    Enum.reduce_while(frames, {[], false}, fn frame, {blocks, false} ->
      terminal? = terminal_frame?(frame)
      state = {[Reference.sse_block(frame) | blocks], terminal?}
      if terminal?, do: {:halt, state}, else: {:cont, state}
    end)
    |> then(fn {blocks, terminal?} -> {Enum.reverse(blocks), terminal?} end)
  end

  defp current_relay(frames) do
    Enum.reduce_while(frames, {[], false}, fn frame, {blocks, false} ->
      terminal? = terminal_frame?(frame)
      state = {[WebsocketBridgeStream.sse_block(frame) | blocks], terminal?}
      if terminal?, do: {:halt, state}, else: {:cont, state}
    end)
    |> then(fn {blocks, terminal?} -> {Enum.reverse(blocks), terminal?} end)
  end

  defp terminal_frame?(frame) do
    match?({:ok, _outcome}, StreamProtocol.terminal_outcome(frame))
  end

  defp assert_same_bytes(label, expected, actual) do
    assert byte_size(actual) == byte_size(expected), failure(label, expected, actual)

    assert :crypto.hash(:sha256, actual) == :crypto.hash(:sha256, expected),
           failure(label, expected, actual)
  end

  defp failure(label, expected, actual) do
    "frame differential mismatch label=#{inspect(label)} expected_bytes=#{byte_size(expected)} actual_bytes=#{byte_size(actual)}"
  end
end
