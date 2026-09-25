defmodule CodexPooler.Gateway.OpenAICompatibility.ChatReasoningAliasTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.OpenAICompatibility.Chat
  alias CodexPooler.Gateway.Payloads.{ReasoningEffort, RequestOptions}

  test "string reasoning with messages follows canonical effort normalization and policy extraction" do
    for effort <- ["medium", " HIGH ", "focused", "none", "ultra"] do
      assert {:ok, coerced} = Chat.coerce(chat_payload(%{"reasoning" => effort}))
      expected = effort |> String.trim() |> String.downcase()
      assert coerced.payload["reasoning"]["effort"] == expected
      assert coerced.chat_payload["reasoning_effort"] == expected
      options = RequestOptions.mark_openai_compatibility_origin(coerced.request_options, "/v1/chat/completions", coerced.endpoint)
      assert ReasoningEffort.extract(coerced.payload, options) == expected
      assert ReasoningEffort.parameter(options) == "reasoning"
      assert Chat.public_validation_param("reasoning.effort", coerced.chat_payload) == "reasoning"
    end
  end

  test "equivalent dual effort fields are accepted and conflicting fields fail closed" do
    assert {:ok, coerced} = Chat.coerce(chat_payload(%{"reasoning" => " MEDIUM ", "reasoning_effort" => "medium"}))
    assert coerced.payload["reasoning"]["effort"] == "medium"

    for canonical <- ["high", nil, %{}, 4] do
      assert {:error, %{status: 400, param: "reasoning"}} = Chat.coerce(chat_payload(%{"reasoning" => "medium", "reasoning_effort" => canonical}))
    end
  end

  test "alias uses the existing bounded token validation without reflecting invalid values" do
    for invalid <- ["", " ", "two words", "high__custom", String.duplicate("a", 33), "sensitive.invalid"] do
      assert {:error, error} = Chat.coerce(chat_payload(%{"reasoning" => invalid}))
      assert error == %{status: 400, code: "invalid_request", message: "reasoning effort is not supported", param: "reasoning"}
    end
  end

  test "genuine Responses fields remain ambiguous with nonempty messages" do
    for {field, value} <- [{"reasoning", %{"effort" => "medium"}}, {"reasoning", nil}, {"reasoning", 2}, {"input", []}, {"include", []}, {"text", %{}}] do
      assert {:error, %{status: 400, param: ^field}} = Chat.coerce(chat_payload(%{"reasoning" => "medium", field => value}))
    end
  end

  test "Responses fallback retains object reasoning and rejects string reasoning" do
    for messages <- [%{}, %{"messages" => []}] do
      payload = Map.merge(%{"model" => "sample-model", "input" => "synthetic", "reasoning" => %{"effort" => "medium"}}, messages)
      assert {:ok, coerced} = Chat.coerce(payload)
      assert coerced.payload["reasoning"] == %{"effort" => "medium"}
      assert Chat.public_validation_param("reasoning.effort", coerced.chat_payload) == "reasoning.effort"
      assert {:error, %{status: 400, param: "reasoning"}} = Chat.coerce(Map.put(payload, "reasoning", "medium"))
    end
  end

  defp chat_payload(extra), do: Map.merge(%{"model" => "sample-model", "messages" => [%{"role" => "user", "content" => "synthetic"}]}, extra)
end
