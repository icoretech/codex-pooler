defmodule CodexPooler.Gateway.Transports.AISDKResponsesContractTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Runtime.Streaming.DownstreamStream

  @max_safe_integer 9_007_199_254_740_991

  test "writes sequence-valid public POST failure streams for the real AI SDK probe" do
    {probe_dir, cleanup?} = probe_dir()
    File.mkdir_p!(probe_dir)

    if cleanup?, do: on_exit(fn -> File.rm_rf!(probe_dir) end)

    opts = public_responses_stream_opts()

    pre_output_state = DownstreamStream.initial_state(:relay, opts, :websocket_bridge)

    assert {pre_output, pre_output_state} =
             DownstreamStream.synthetic_terminal_failure(
               pre_output_state,
               :upstream_interrupted
             )

    assert [%{"sequence_number" => 0, "type" => "response.failed"}] =
             sse_events(pre_output)

    assert pre_output_state.public_openai_responses.sequence.max_seen == 0

    post_output_prefix =
      sse_event("response.created", %{
        "type" => "response.created",
        "sequence_number" => 0,
        "response" => %{"id" => "resp_post_output", "status" => "in_progress"}
      }) <>
        sse_event("response.output_text.delta", %{
          "type" => "response.output_text.delta",
          "sequence_number" => 2,
          "item_id" => "msg_post_output",
          "output_index" => 0,
          "content_index" => 0,
          "delta" => "synthetic output"
        })

    state = DownstreamStream.initial_state(:relay, opts)

    assert {post_output_prefix, state} =
             DownstreamStream.normalize_data(post_output_prefix, "/v1/responses", opts, state)

    assert {terminal, state} =
             DownstreamStream.synthetic_terminal_failure(state, :upstream_interrupted)

    post_output = post_output_prefix <> terminal
    post_events = sse_events(post_output)
    assert Enum.map(post_events, & &1["sequence_number"]) == [0, 2, 3]
    assert List.last(post_events)["type"] == "response.failed"
    assert state.public_openai_responses.sequence.max_seen == 3

    invalid_sequence =
      update_terminal(post_output, fn event -> Map.delete(event, "sequence_number") end)

    max_safe_prefix =
      sse_event("response.output_text.delta", %{
        "type" => "response.output_text.delta",
        "sequence_number" => @max_safe_integer - 1,
        "delta" => "synthetic output"
      })

    max_safe_state = DownstreamStream.initial_state(:relay, opts)

    assert {^max_safe_prefix, max_safe_state} =
             DownstreamStream.normalize_data(
               max_safe_prefix,
               "/v1/responses",
               opts,
               max_safe_state
             )

    assert {max_safe_terminal, _state} =
             DownstreamStream.synthetic_terminal_failure(max_safe_state, :upstream_interrupted)

    assert [max_safe_event] = sse_events(max_safe_terminal)
    assert max_safe_event["sequence_number"] == @max_safe_integer

    File.write!(Path.join(probe_dir, "pre-output-failure.sse"), pre_output)
    File.write!(Path.join(probe_dir, "post-output-failure.sse"), post_output)
    File.write!(Path.join(probe_dir, "invalid-sequence.sse"), invalid_sequence)
  end

  defp update_terminal(stream, update) do
    events = sse_events(stream)
    terminal = events |> List.last() |> update.()

    events
    |> List.replace_at(-1, terminal)
    |> Enum.map_join(&sse_event(&1["type"], &1))
  end

  defp sse_events(stream) do
    stream
    |> String.split("\n\n", trim: true)
    |> Enum.map(fn block ->
      "data: " <> data = Enum.find(String.split(block, "\n"), &String.starts_with?(&1, "data: "))
      Jason.decode!(data)
    end)
  end

  defp sse_event(type, data) do
    "event: #{type}\ndata: #{Jason.encode!(data)}\n\n"
  end

  defp public_responses_stream_opts do
    RequestOptions.build(
      %{public_openai_responses_stream: true},
      "/v1/responses",
      %{"stream" => true}
    )
  end

  defp probe_dir do
    case System.get_env("AI_SDK_PROBE_DIR") do
      path when is_binary(path) and path != "" ->
        {path, false}

      _path ->
        {Path.join(System.tmp_dir!(), "ai-sdk-probe-#{System.unique_integer([:positive])}"), true}
    end
  end
end
