defmodule CodexPooler.Gateway.OpenAICompatibility.ChatValidationParamTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.OpenAICompatibility.Chat

  @messages [%{"role" => "user", "content" => "synthetic"}]

  test "maps upstream Responses paths back to the Chat field the client sent" do
    cases = [
      {"reasoning.effort", %{"reasoning_effort" => "high"}, "reasoning_effort"},
      {"max_output_tokens", %{"max_completion_tokens" => 10}, "max_completion_tokens"},
      {"max_output_tokens", %{"max_tokens" => 10}, "max_tokens"},
      {"text.verbosity", %{"verbosity" => "low"}, "verbosity"},
      {"text.format", %{"response_format" => %{"type" => "json_object"}}, "response_format"},
      {"text.format.type", %{"response_format" => %{"type" => "text"}}, "response_format.type"},
      {"text.format.schema.properties.a",
       %{"response_format" => %{"type" => "json_schema", "json_schema" => %{"name" => "x"}}},
       "response_format.json_schema.schema.properties.a"},
      {"tool_choice.name",
       %{"tool_choice" => %{"type" => "function", "function" => %{"name" => "f"}}},
       "tool_choice.function.name"},
      {"tool_choice.name",
       %{"tool_choice" => %{"type" => "custom", "custom" => %{"name" => "c"}}},
       "tool_choice.custom.name"},
      {"tools[1].parameters.properties",
       %{
         "tools" => [
           %{"type" => "web_search_preview"},
           %{"type" => "function", "function" => %{"name" => "f", "parameters" => %{}}}
         ]
       }, "tools[1].function.parameters.properties"},
      {"tools[0].format", %{"tools" => [%{"type" => "custom", "custom" => %{"name" => "c"}}]},
       "tools[0].custom.format"}
    ]

    for {upstream, chat_fields, expected} <- cases do
      payload = Map.put(chat_fields, "messages", @messages)
      assert Chat.public_validation_param(upstream, payload) == expected, upstream
    end
  end

  test "leaves every other path unchanged" do
    cases = [
      {"reasoning.effort", %{}},
      {"max_output_tokens", %{}},
      {"text.verbosity", %{}},
      {"text.format", %{"response_format" => %{"type" => "unknown_format"}}},
      {"text.format.schema", %{"response_format" => %{"type" => "json_object"}}},
      {"tool_choice.name", %{"tool_choice" => %{"type" => "function", "name" => "flat"}}},
      {"tool_choice.name", %{"tool_choice" => "auto"}},
      {"tools[0].name", %{"tools" => [%{"type" => "custom", "name" => "flat"}]}},
      {"tools[0].type", %{"tools" => [%{"type" => "function", "function" => %{}}]}},
      {"tools[5].name", %{"tools" => [%{"type" => "function", "function" => %{}}]}},
      {"tools[0].name", %{"tools" => [%{"type" => "web_search_preview"}]}},
      {"tools[01].name", %{"tools" => [%{"type" => "function", "function" => %{}}]}},
      {"input[0].content", %{"reasoning_effort" => "high"}},
      {"temperature", %{"temperature" => 9}},
      {"model", %{}}
    ]

    for {upstream, chat_fields} <- cases do
      payload = Map.put(chat_fields, "messages", @messages)
      assert Chat.public_validation_param(upstream, payload) == upstream, upstream
    end
  end

  test "fallback-input requests forward Responses fields unchanged" do
    for payload <- [
          %{"input" => "synthetic", "reasoning_effort" => "high"},
          %{"messages" => [], "input" => "synthetic", "reasoning_effort" => "high"},
          %{"reasoning_effort" => "high"}
        ] do
      assert Chat.public_validation_param("reasoning.effort", payload) == "reasoning.effort"
    end
  end
end
