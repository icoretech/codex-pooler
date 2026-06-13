defmodule CodexPooler.Gateway.Runtime.Streaming.DownstreamStreamTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Runtime.Streaming.DownstreamStream
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol

  describe "endpoint/2" do
    test "selects the typed upstream endpoint from request options" do
      opts = RequestOptions.build(%{}, "/backend-api/codex/responses", %{})

      assert DownstreamStream.endpoint(%{}, opts) == "/backend-api/codex/responses"
    end
  end

  describe "initial_state/2 and normalize_data/4" do
    test "keep public OpenAI chat stream parser state beside the relay target" do
      opts =
        RequestOptions.build(
          %{
            public_openai_chat_stream: true,
            openai_chat_payload: %{"model" => "gpt-example"}
          },
          "/v1/chat/completions",
          %{}
        )

      state = DownstreamStream.initial_state(:websocket, opts)

      assert %{target: :websocket, public_openai_chat: %{buffer: "", model: "gpt-example"}} =
               state

      split_event =
        [
          "event: response.output_text.delta\n",
          "data: ",
          Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "split answer"})
        ]
        |> IO.iodata_to_binary()

      assert {"", state} =
               DownstreamStream.normalize_data(split_event, "/v1/chat/completions", opts, state)

      assert {chunk, _state} =
               DownstreamStream.normalize_data("\n\n", "/v1/chat/completions", opts, state)

      assert chunk =~ "\"object\":\"chat.completion.chunk\""
      assert chunk =~ "\"content\":\"split answer\""
    end

    test "blocks keepalive comments while public OpenAI chat SSE is incomplete" do
      opts =
        RequestOptions.build(
          %{
            public_openai_chat_stream: true,
            openai_chat_payload: %{"model" => "gpt-example"}
          },
          "/v1/chat/completions",
          %{"stream" => true}
        )

      state = DownstreamStream.initial_state(:relay, opts)

      incomplete =
        [
          "event: response.output_text.delta\n",
          "data: ",
          Jason.encode!(%{"type" => "response.output_text.delta", "delta" => "split answer"})
        ]
        |> IO.iodata_to_binary()

      split_at = div(byte_size(incomplete), 2)
      first = binary_part(incomplete, 0, split_at)
      second = binary_part(incomplete, split_at, byte_size(incomplete) - split_at)

      assert {"", state} =
               DownstreamStream.normalize_data(first, "/v1/chat/completions", opts, state)

      refute DownstreamStream.keepalive_allowed?(state)

      assert {chunk, state} =
               DownstreamStream.normalize_data(
                 second <> "\n\n",
                 "/v1/chat/completions",
                 opts,
                 state
               )

      assert chunk =~ "\"object\":\"chat.completion.chunk\""
      assert chunk =~ "\"content\":\"split answer\""
      assert DownstreamStream.keepalive_allowed?(state)
    end

    test "normalizes oversized public OpenAI chat blocks without raw passthrough" do
      opts =
        RequestOptions.build(
          %{
            public_openai_chat_stream: true,
            openai_chat_payload: %{"model" => "gpt-example"}
          },
          "/v1/chat/completions",
          %{"stream" => true}
        )

      state = DownstreamStream.initial_state(:relay, opts)

      oversized =
        [
          "event: response.output_text.delta\n",
          "data: ",
          Jason.encode!(%{
            "type" => "response.output_text.delta",
            "delta" => String.duplicate("synthetic chat delta ", 5_000)
          })
        ]
        |> IO.iodata_to_binary()

      split_at = StreamProtocol.max_incomplete_sse_block_bytes() + 1
      first = binary_part(oversized, 0, split_at)
      second = binary_part(oversized, split_at, byte_size(oversized) - split_at)

      assert {"", state} =
               DownstreamStream.normalize_data(first, "/v1/chat/completions", opts, state)

      refute DownstreamStream.keepalive_allowed?(state)

      assert {"", state} =
               DownstreamStream.normalize_data(second, "/v1/chat/completions", opts, state)

      refute DownstreamStream.keepalive_allowed?(state)

      assert {chunk, state} =
               DownstreamStream.normalize_data("\n\n", "/v1/chat/completions", opts, state)

      assert chunk =~ "\"object\":\"chat.completion.chunk\""
      assert chunk =~ "synthetic chat delta"
      refute chunk =~ "response.output_text.delta"
      assert DownstreamStream.keepalive_allowed?(state)
    end

    test "passes through non-SSE JSON bodies on backend codex responses stream relay" do
      opts = RequestOptions.build(%{}, "/backend-api/codex/responses", %{"stream" => true})
      state = DownstreamStream.initial_state(:relay, opts)

      json_body = Jason.encode!(%{"id" => "resp_sparse_metadata", "object" => "response"})

      assert {^json_body, ^state} =
               DownstreamStream.normalize_data(
                 json_body,
                 "/backend-api/codex/responses",
                 opts,
                 state
               )
    end

    test "passes through oversized incomplete backend codex SSE prefixes without retaining them" do
      attach_stream_buffer_telemetry()
      opts = RequestOptions.build(%{}, "/backend-api/codex/responses", %{"stream" => true})
      state = DownstreamStream.initial_state(:relay, opts)
      oversized = String.duplicate("data: unavailable-upstream-prefix", 12_000)

      assert {^oversized, state} =
               DownstreamStream.normalize_data(
                 oversized,
                 "/backend-api/codex/responses",
                 opts,
                 state
               )

      assert state.codex_responses_sse_buffer == ""

      assert_receive {[:codex_pooler, :gateway, :stream_buffer, :oversized],
                      %{bytes: bytes, count: 1, max_bytes: 65_536},
                      %{
                        buffer: "codex_responses_sse",
                        endpoint: "/backend-api/codex/responses",
                        route_class: route_class
                      }}

      assert bytes > 65_536
      assert is_binary(route_class)
    end

    test "blocks keepalive comments while public OpenAI Responses SSE is incomplete" do
      opts =
        RequestOptions.build(
          %{public_openai_responses_stream: true},
          "/v1/responses",
          %{"stream" => true}
        )

      state = DownstreamStream.initial_state(:relay, opts)

      incomplete =
        [
          "event: response.created\n",
          "data: ",
          Jason.encode!(%{
            "type" => "response.created",
            "response" => %{
              "id" => "resp_public_incomplete_keepalive",
              "tools" => [
                %{
                  "type" => "function",
                  "name" => "synthetic_tool",
                  "description" => String.duplicate("synthetic description ", 4_000)
                }
              ]
            }
          })
        ]
        |> IO.iodata_to_binary()

      split_at = div(byte_size(incomplete), 2)
      first = binary_part(incomplete, 0, split_at)
      second = binary_part(incomplete, split_at, byte_size(incomplete) - split_at)

      assert {"", state} = DownstreamStream.normalize_data(first, "/v1/responses", opts, state)
      refute DownstreamStream.keepalive_allowed?(state)

      assert {_chunk, state} =
               DownstreamStream.normalize_data(second <> "\n\n", "/v1/responses", opts, state)

      assert DownstreamStream.keepalive_allowed?(state)
    end

    test "blocks keepalive comments during oversized public OpenAI Responses passthrough" do
      opts =
        RequestOptions.build(
          %{public_openai_responses_stream: true},
          "/v1/responses",
          %{"stream" => true}
        )

      state = DownstreamStream.initial_state(:relay, opts)

      oversized =
        [
          "event: response.created\n",
          "data: ",
          Jason.encode!(%{
            "type" => "response.created",
            "response" => %{
              "id" => "resp_public_oversized_keepalive",
              "tools" => [
                %{
                  "type" => "function",
                  "name" => "synthetic_tool",
                  "description" => String.duplicate("synthetic description ", 5_000)
                }
              ]
            }
          })
        ]
        |> IO.iodata_to_binary()

      split_at = StreamProtocol.max_incomplete_sse_block_bytes() + 1
      first = binary_part(oversized, 0, split_at)
      second = binary_part(oversized, split_at, byte_size(oversized) - split_at)

      assert {^first, state} =
               DownstreamStream.normalize_data(first, "/v1/responses", opts, state)

      refute DownstreamStream.keepalive_allowed?(state)

      assert {^second, state} =
               DownstreamStream.normalize_data(second, "/v1/responses", opts, state)

      refute DownstreamStream.keepalive_allowed?(state)

      assert {"\n\n", state} =
               DownstreamStream.normalize_data("\n\n", "/v1/responses", opts, state)

      assert DownstreamStream.keepalive_allowed?(state)
    end
  end

  defp attach_stream_buffer_telemetry do
    handler_id = {__MODULE__, self(), System.unique_integer([:positive])}
    parent = self()

    :telemetry.attach(
      handler_id,
      [:codex_pooler, :gateway, :stream_buffer, :oversized],
      fn event, measurements, metadata, _config ->
        send(parent, {event, measurements, metadata})
      end,
      :ok
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
