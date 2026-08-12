defmodule CodexPooler.Gateway.OpenAICompatibility.CompletionsTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.OpenAICompatibility.Completions
  alias CodexPooler.Gateway.Payloads.RequestOptions.Persona

  @opts %{
    persona: Persona.fixed(:openai_completions),
    collect_openai_response_stream: true,
    openai_completion_payload: %{}
  }

  describe "coerce/2" do
    test "turns a legacy string prompt into one fixed-target Responses request" do
      assert {:ok, coerced} =
               Completions.coerce(
                 %{
                   "model" => "client-selected-model",
                   "prompt" => "complete this",
                   "max_tokens" => 37,
                   "temperature" => 0.4,
                   "top_p" => 0.8,
                   "stop" => ["END", "STOP"]
                 },
                 @opts
               )

      assert coerced.endpoint == "/backend-api/codex/responses"
      assert coerced.payload["model"] == "gpt-5.6-sol"
      assert coerced.payload["reasoning"] == %{"effort" => "max"}
      assert prompt_text(coerced.payload) == "complete this"
      assert coerced.payload["max_output_tokens"] == 37
      assert coerced.payload["temperature"] == 0.4
      assert coerced.payload["top_p"] == 0.8
      assert coerced.payload["stream"] == true
      assert coerced.payload["store"] == false
      refute Map.has_key?(coerced.payload, "stop")
      refute Jason.encode!(coerced.payload) =~ "client-selected-model"
      assert coerced.completion_payload["stop"] == ["END", "STOP"]
    end

    test "accepts a missing model and rejects ambiguous legacy generation controls" do
      assert {:ok, coerced} = Completions.coerce(%{"prompt" => "hello"}, @opts)
      assert coerced.payload["model"] == "gpt-5.6-sol"

      for {field, value} <- [
            {"best_of", 2},
            {"logprobs", 1},
            {"echo", true},
            {"n", 2}
          ] do
        assert {:error, %{status: 400, param: ^field}} =
                 Completions.coerce(%{"prompt" => "hello", field => value}, @opts)
      end
    end

    test "validates prompt, scalar options, stops, and streamed prompt lists" do
      invalid = [
        {%{}, "prompt"},
        {%{"prompt" => []}, "prompt"},
        {%{"prompt" => ["ok", 1]}, "prompt"},
        {%{"prompt" => "ok", "max_tokens" => 0}, "max_tokens"},
        {%{"prompt" => "ok", "temperature" => -0.1}, "temperature"},
        {%{"prompt" => "ok", "top_p" => 1.1}, "top_p"},
        {%{"prompt" => "ok", "stop" => ""}, "stop"},
        {%{"prompt" => ["one"], "stream" => true}, "prompt"},
        {%{"prompt" => ["one", "two"], "stream" => true}, "prompt"}
      ]

      for {payload, param} <- invalid do
        assert {:error, %{status: 400, param: ^param}} = Completions.coerce_many(payload, @opts)
      end
    end

    test "expands a non-streamed prompt list into ordinary ordered gateway requests" do
      assert {:ok, batch} =
               Completions.coerce_many(
                 %{"model" => "anything", "prompt" => ["first", "second"]},
                 @opts
               )

      assert Enum.map(batch.requests, &prompt_text(&1.payload)) == ["first", "second"]

      assert Enum.all?(batch.requests, fn request ->
               request.payload["model"] == "gpt-5.6-sol" and
                 request.payload["reasoning"] == %{"effort" => "max"}
             end)
    end
  end

  describe "response projection" do
    test "uses local completion identity, gemma3, stop truncation, finish reason, and usage" do
      projected =
        Completions.normalize_response(
          %{
            "id" => "provider-response-id",
            "model" => "hidden-provider-model",
            "status" => "completed",
            "output" => [
              %{
                "type" => "message",
                "content" => [%{"type" => "output_text", "text" => "visible END hidden"}]
              }
            ],
            "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
          },
          %{"prompt" => "hello", "stop" => "END"}
        )

      assert String.starts_with?(projected["id"], "cmpl_")
      assert projected["object"] == "text_completion"
      assert is_integer(projected["created"])
      assert projected["model"] == "gemma3"

      assert projected["choices"] == [
               %{
                 "text" => "visible ",
                 "index" => 0,
                 "logprobs" => nil,
                 "finish_reason" => "stop"
               }
             ]

      assert projected["usage"] == %{
               "prompt_tokens" => 4,
               "completion_tokens" => 3,
               "total_tokens" => 7
             }

      encoded = Jason.encode!(projected)
      refute encoded =~ "provider-response-id"
      refute encoded =~ "hidden-provider-model"
      refute encoded =~ " hidden"
    end

    test "combines prompt-list results in input order and sums usage" do
      projected =
        Completions.normalize_responses(
          [completed_response("first answer", 2, 3), completed_response("second answer", 5, 7)],
          %{"prompt" => ["first", "second"]}
        )

      assert Enum.map(projected["choices"], &{&1["index"], &1["text"]}) == [
               {0, "first answer"},
               {1, "second answer"}
             ]

      assert projected["usage"] == %{
               "prompt_tokens" => 7,
               "completion_tokens" => 10,
               "total_tokens" => 17
             }
    end
  end

  describe "stream projection" do
    test "emits only text_completion chunks with local identity and gemma3" do
      state = Completions.stream_state(%{"prompt" => "hello"})

      upstream =
        [
          sse("response.output_text.delta", %{
            "type" => "response.output_text.delta",
            "delta" => "streamed answer"
          }),
          sse("response.completed", %{
            "type" => "response.completed",
            "response" => %{
              "id" => "provider-stream-id",
              "model" => "hidden-stream-model",
              "status" => "completed",
              "usage" => %{"input_tokens" => 2, "output_tokens" => 3, "total_tokens" => 5}
            }
          }),
          "data: [DONE]\n\n"
        ]
        |> IO.iodata_to_binary()

      assert {output, state} = Completions.normalize_stream_data(upstream, state)
      payloads = stream_payloads(output)

      assert Enum.any?(
               payloads,
               &(get_in(&1, ["choices", Access.at(0), "text"]) == "streamed answer")
             )

      assert Enum.all?(payloads, &(&1["object"] == "text_completion"))
      assert Enum.all?(payloads, &(&1["model"] == "gemma3"))
      assert Enum.uniq(Enum.map(payloads, & &1["id"])) == [state.id]
      assert output =~ "data: [DONE]"
      refute output =~ "provider-stream-id"
      refute output =~ "hidden-stream-model"
    end

    test "recognizes stop sequences split across provider deltas" do
      state = Completions.stream_state(%{"prompt" => "hello", "stop" => "STOP"})

      first =
        sse("response.output_text.delta", %{
          "type" => "response.output_text.delta",
          "delta" => "visible ST"
        })

      second =
        sse("response.output_text.delta", %{
          "type" => "response.output_text.delta",
          "delta" => "OP hidden"
        })

      assert {first_output, state} =
               Completions.normalize_stream_data(IO.iodata_to_binary(first), state)

      assert {second_output, state} =
               Completions.normalize_stream_data(IO.iodata_to_binary(second), state)

      output = first_output <> second_output

      visible_text =
        output
        |> stream_payloads()
        |> Enum.flat_map(&Map.get(&1, "choices", []))
        |> Enum.map_join(&Map.get(&1, "text", ""))

      assert visible_text == "visible "
      assert output =~ "\"finish_reason\":\"stop\""
      assert output =~ "data: [DONE]"
      refute output =~ "STOP"
      refute output =~ "hidden"
      assert Completions.terminal_seen?(state)
    end
  end

  defp completed_response(text, input_tokens, output_tokens) do
    %{
      "status" => "completed",
      "output" => [
        %{"type" => "message", "content" => [%{"type" => "output_text", "text" => text}]}
      ],
      "usage" => %{
        "input_tokens" => input_tokens,
        "output_tokens" => output_tokens,
        "total_tokens" => input_tokens + output_tokens
      }
    }
  end

  defp sse(event, payload),
    do: ["event: ", event, "\n", "data: ", Jason.encode!(payload), "\n\n"]

  defp prompt_text(%{"input" => [%{"content" => [%{"text" => text}]}]}), do: text

  defp stream_payloads(output) do
    output
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn block ->
      case String.split(block, "data: ", parts: 2) do
        [_prefix, "[DONE]"] -> []
        [_prefix, data] -> [Jason.decode!(data)]
        _parts -> []
      end
    end)
  end
end
