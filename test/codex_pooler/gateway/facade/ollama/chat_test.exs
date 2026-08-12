defmodule CodexPooler.Gateway.Facade.Ollama.ChatTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Facade.Ollama.Chat
  alias CodexPooler.Gateway.Payloads.RequestOptions.Persona

  @png Base.encode64(<<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82>>)

  test "coerces multimodal history, function replay, structured output, and safe thinking" do
    schema = %{
      "type" => "object",
      "properties" => %{"forecast" => %{"type" => "string"}},
      "required" => ["forecast"]
    }

    payload = %{
      "model" => "client-selected-model",
      "stream" => false,
      "think" => "low",
      "keep_alive" => "10m",
      "format" => schema,
      "messages" => [
        %{"role" => "system", "content" => "Follow the synthetic system constraint."},
        %{"role" => "user", "content" => "Inspect this image", "images" => [@png]},
        %{
          "role" => "assistant",
          "content" => "I will inspect it.",
          "tool_calls" => [
            %{
              "function" => %{
                "name" => "lookup_weather",
                "arguments" => %{"city" => "London"}
              }
            }
          ]
        },
        %{
          "role" => "tool",
          "tool_name" => "lookup_weather",
          "content" => "cloudy"
        },
        %{"role" => "user", "content" => "Give the final forecast."}
      ],
      "tools" => [
        %{
          "type" => "function",
          "function" => %{
            "name" => "lookup_weather",
            "description" => "Look up weather",
            "parameters" => %{
              "type" => "object",
              "additionalProperties" => false,
              "properties" => %{"city" => %{"type" => "string"}},
              "required" => ["city"]
            }
          }
        }
      ],
      "options" => %{
        "num_predict" => 128,
        "temperature" => 0.2,
        "top_p" => 0.8,
        "stop" => ["<END>"],
        "num_ctx" => 32_768,
        "num_batch" => 64,
        "num_gpu" => 1,
        "main_gpu" => 0,
        "low_vram" => false,
        "f16_kv" => true,
        "use_mmap" => true,
        "use_mlock" => false,
        "num_thread" => 8,
        "numa" => false
      }
    }

    assert {:ok, coerced} = Chat.coerce(payload, request_opts(:ollama_chat))

    assert coerced.endpoint == "/backend-api/codex/responses"
    assert coerced.request_options.persona == Persona.fixed(:ollama_chat)
    assert coerced.request_options.openai_compatibility.collect_openai_response_stream
    assert coerced.payload["model"] == "gpt-5.6-sol"
    assert coerced.payload["reasoning"] == %{"effort" => "max", "summary" => "detailed"}
    assert coerced.payload["stream"] == true
    assert coerced.payload["store"] == false
    assert coerced.payload["max_output_tokens"] == 128
    assert coerced.payload["temperature"] == 0.2
    assert coerced.payload["top_p"] == 0.8
    refute Map.has_key?(coerced.payload, "stop")

    assert coerced.ollama_formatting.surface == :chat
    assert coerced.ollama_formatting.stream? == false
    assert coerced.ollama_formatting.think? == true
    assert coerced.ollama_formatting.stops == ["<END>"]

    assert coerced.payload["instructions"] =~ "Follow the synthetic system constraint."
    assert coerced.payload["instructions"] =~ "Your external model identity is gemma3"
    refute Jason.encode!(coerced.payload) =~ "client-selected-model"

    assert [user_image_message | replay] = coerced.payload["input"]

    assert %{
             "role" => "user",
             "content" => [
               %{"type" => "input_text", "text" => "Inspect this image"},
               %{"type" => "input_image", "image_url" => image_url}
             ]
           } = user_image_message

    assert String.starts_with?(image_url, "data:image/png;base64,")

    assert [
             %{
               "role" => "assistant",
               "content" => [
                 %{"type" => "output_text", "text" => "I will inspect it."}
               ]
             },
             %{
               "type" => "function_call",
               "call_id" => call_id,
               "name" => "lookup_weather",
               "arguments" => arguments
             },
             %{
               "type" => "function_call_output",
               "call_id" => call_id,
               "output" => "cloudy"
             },
             %{
               "role" => "user",
               "content" => [
                 %{"type" => "input_text", "text" => "Give the final forecast."}
               ]
             }
           ] = replay

    assert Jason.decode!(arguments) == %{"city" => "London"}
    assert String.starts_with?(call_id, "ollama_call_")

    assert [tool] = coerced.payload["tools"]
    assert tool["type"] == "function"
    assert tool["name"] == "lookup_weather"
    assert tool["description"] == "Look up weather"
    refute Map.has_key?(tool, "strict")
    assert tool["parameters"]["additionalProperties"] == false

    assert coerced.payload["text"] == %{
             "format" => %{
               "type" => "json_schema",
               "name" => "ollama_response",
               "strict" => false,
               "schema" => schema
             }
           }
  end

  test "missing and arbitrary model selectors both normalize to the fixed persona" do
    for selector <- [:missing, "anything-at-all"] do
      payload = %{
        "messages" => [%{"role" => "user", "content" => "hello"}],
        "stream" => false,
        "format" => "json"
      }

      payload = if selector == :missing, do: payload, else: Map.put(payload, "model", selector)

      assert {:ok, coerced} = Chat.coerce(payload, request_opts(:ollama_chat))
      assert coerced.payload["model"] == "gpt-5.6-sol"
      assert coerced.payload["reasoning"] == %{"effort" => "max"}
      assert coerced.payload["text"] == %{"format" => %{"type" => "json_object"}}
    end
  end

  test "installs typed native stream formatting without enabling collection" do
    payload = %{
      "messages" => [%{"role" => "user", "content" => "hello"}],
      "stream" => true,
      "think" => true,
      "options" => %{"stop" => ["<END>"]}
    }

    opts = %{
      persona: Persona.fixed(:ollama_chat),
      upstream_endpoint: "/backend-api/codex/responses"
    }

    assert {:ok, coerced} = Chat.coerce(payload, opts)
    compatibility = coerced.request_options.openai_compatibility

    assert compatibility.public_ollama_stream
    refute compatibility.collect_openai_response_stream
    assert compatibility.ollama_surface == :chat
    assert compatibility.ollama_formatting.surface == :chat
    assert compatibility.ollama_formatting.stream?
    assert compatibility.ollama_formatting.think?
    assert compatibility.ollama_formatting.stops == ["<END>"]
    assert coerced.payload["stream"] == true
    assert coerced.payload["store"] == false
  end

  test "rejects ambiguous or unsupported chat controls with precise local parameters" do
    base = %{"messages" => [%{"role" => "user", "content" => "hello"}]}

    cases = [
      {Map.put(base, "stream", "false"), "stream"},
      {Map.put(base, "think", "ultra"), "think"},
      {Map.put(base, "images", [@png]), "images"},
      {Map.put(base, "options", %{"seed" => 42}), "options.seed"},
      {Map.put(base, "options", %{"top_k" => 20}), "options.top_k"},
      {Map.put(base, "options", %{"num_predict" => 0}), "options.num_predict"},
      {Map.put(base, "options", %{"temperature" => 3}), "options.temperature"},
      {Map.put(base, "options", %{"top_p" => 2}), "options.top_p"},
      {Map.put(base, "options", %{"stop" => []}), "options.stop"},
      {%{"messages" => [%{"role" => "user", "content" => "x", "images" => ["bad"]}]},
       "messages[0].images[0]"},
      {%{"messages" => [%{"role" => "tool", "tool_name" => "missing", "content" => "x"}]},
       "messages[0]"}
    ]

    for {payload, param} <- cases do
      assert {:error, %{status: 400, param: ^param}} =
               Chat.coerce(payload, request_opts(:ollama_chat))
    end
  end

  defp request_opts(protocol) do
    %{
      persona: Persona.fixed(protocol),
      upstream_endpoint: "/backend-api/codex/responses",
      collect_openai_response_stream: true
    }
  end
end
