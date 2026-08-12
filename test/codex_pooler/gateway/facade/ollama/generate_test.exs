defmodule CodexPooler.Gateway.Facade.Ollama.GenerateTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Facade.Ollama.Generate
  alias CodexPooler.Gateway.Payloads.RequestOptions.Persona

  @jpeg Base.encode64(<<255, 216, 255, 224, 0, 16, 74, 70, 73, 70, 0, 1>>)

  test "coerces prefix/suffix generation, image, format, and exact runtime options" do
    schema = %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{"insert" => %{"type" => "string"}},
      "required" => ["insert"]
    }

    payload = %{
      "model" => "arbitrary-model",
      "prompt" => "def answer():\n    ",
      "suffix" => "\n    return result",
      "system" => "Use valid Python.",
      "images" => [@jpeg],
      "format" => schema,
      "stream" => false,
      "think" => true,
      "raw" => true,
      "keep_alive" => 0,
      "options" => %{
        "num_predict" => 64,
        "temperature" => 0,
        "top_p" => 0.9,
        "stop" => "<STOP>",
        "num_ctx" => 16_384,
        "num_batch" => 32,
        "num_gpu" => 1,
        "main_gpu" => 0,
        "low_vram" => false,
        "f16_kv" => true,
        "use_mmap" => true,
        "use_mlock" => false,
        "num_thread" => 4,
        "numa" => false
      }
    }

    assert {:ok, coerced} = Generate.coerce(payload, request_opts(:ollama_generate))

    assert coerced.endpoint == "/backend-api/codex/responses"
    assert coerced.request_options.persona == Persona.fixed(:ollama_generate)
    assert coerced.payload["model"] == "gpt-5.6-sol"
    assert coerced.payload["reasoning"] == %{"effort" => "max", "summary" => "detailed"}
    assert coerced.payload["stream"] == true
    assert coerced.payload["store"] == false
    assert coerced.payload["max_output_tokens"] == 64
    assert coerced.payload["temperature"] == 0
    assert coerced.payload["top_p"] == 0.9
    refute Map.has_key?(coerced.payload, "stop")

    assert coerced.ollama_formatting.surface == :generate
    assert coerced.ollama_formatting.stream? == false
    assert coerced.ollama_formatting.think? == true
    assert coerced.ollama_formatting.stops == ["<STOP>"]
    assert coerced.ollama_formatting.suffix? == true

    assert coerced.payload["instructions"] =~ "Use valid Python."
    assert coerced.payload["instructions"] =~ "Return only the text to insert"
    assert coerced.payload["instructions"] =~ "Your external model identity is gemma3"
    refute Jason.encode!(coerced.payload) =~ "arbitrary-model"

    assert [message] = coerced.payload["input"]
    assert message["role"] == "user"

    assert [prefix, suffix, image] = message["content"]
    assert prefix == %{"type" => "input_text", "text" => "PREFIX\ndef answer():\n    "}
    assert suffix == %{"type" => "input_text", "text" => "SUFFIX\n\n    return result"}
    assert image["type"] == "input_image"
    assert String.starts_with?(image["image_url"], "data:image/jpeg;base64,")

    assert coerced.payload["text"] == %{
             "format" => %{
               "type" => "json_schema",
               "name" => "ollama_response",
               "strict" => false,
               "schema" => schema
             }
           }
  end

  test "simple generation permits an omitted model and JSON mode" do
    payload = %{"prompt" => "hello", "format" => "json", "stream" => false}

    assert {:ok, coerced} = Generate.coerce(payload, request_opts(:ollama_generate))
    assert coerced.payload["model"] == "gpt-5.6-sol"
    assert coerced.payload["reasoning"] == %{"effort" => "max"}
    assert coerced.payload["text"] == %{"format" => %{"type" => "json_object"}}

    assert [%{"role" => "user", "content" => [%{"text" => "hello"}]}] =
             coerced.payload["input"]
  end

  test "rejects non-equivalent generation controls instead of reinterpreting them" do
    base = %{"prompt" => "hello"}

    cases = [
      {Map.put(base, "context", [1, 2, 3]), "context"},
      {Map.put(base, "template", "{{ .Prompt }}"), "template"},
      {Map.put(base, "logprobs", true), "logprobs"},
      {Map.put(base, "top_logprobs", 3), "top_logprobs"},
      {Map.put(base, "stream", 0), "stream"},
      {Map.put(base, "think", %{}), "think"},
      {Map.put(base, "format", %{"$ref" => "https://example.invalid/schema.json"}),
       "text.format.schema.$ref"},
      {Map.put(base, "options", %{"seed" => 7}), "options.seed"},
      {Map.put(base, "options", %{"min_p" => 0.1}), "options.min_p"},
      {Map.put(base, "options", %{"repeat_penalty" => 1.1}), "options.repeat_penalty"},
      {Map.put(base, "options", %{"num_predict" => -1}), "options.num_predict"},
      {Map.put(base, "options", %{"temperature" => "cold"}), "options.temperature"},
      {Map.put(base, "options", %{"top_p" => -0.1}), "options.top_p"},
      {Map.put(base, "options", %{"stop" => [""]}), "options.stop"},
      {Map.put(base, "images", ["not-base64"]), "images[0]"}
    ]

    for {payload, param} <- cases do
      assert {:error, %{status: 400, param: ^param}} =
               Generate.coerce(payload, request_opts(:ollama_generate))
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
