defmodule CodexPooler.Gateway.Payloads.ReasoningEffortTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Payloads.{ReasoningEffort, RequestOptions}

  @backend_endpoint "/backend-api/codex/responses"

  describe "extract/2" do
    test "uses native backend alias precedence without changing custom tokens" do
      cases = [
        {%{
           "reasoning" => %{"effort" => "nested"},
           "reasoning_effort" => "snake",
           "reasoningEffort" => "camel",
           "thinking" => "high",
           "enable_thinking" => true
         }, "nested"},
        {%{"reasoning_effort" => "snake", "reasoningEffort" => "camel"}, "snake"},
        {%{"reasoningEffort" => "camel", "thinking" => "high"}, "camel"},
        {%{"thinking" => %{"effort" => " XHIGH "}, "enable_thinking" => true}, "xhigh"},
        {%{"thinking" => true, "enable_thinking" => false}, "medium"},
        {%{"enable_thinking" => true}, "medium"},
        {%{"reasoning_effort" => " custom-effort "}, "custom-effort"},
        {%{"reasoning_effort" => %{"invalid" => true}}, nil}
      ]

      for {payload, expected} <- cases do
        options = RequestOptions.build(%{}, @backend_endpoint, payload)
        assert ReasoningEffort.extract(payload, options) == expected
      end
    end

    test "does not fall through present malformed native winners" do
      cases = [
        {%{"reasoning" => %{"effort" => 42}, "reasoning_effort" => "high"}, nil},
        {%{"reasoning" => %{"effort" => "  "}, "reasoning_effort" => "high"}, nil},
        {%{"reasoning_effort" => %{"invalid" => true}, "reasoningEffort" => "high"}, nil},
        {%{"reasoning_effort" => "  ", "reasoningEffort" => "high"}, nil},
        {%{"reasoningEffort" => 42, "thinking" => "high"}, nil},
        {%{"reasoningEffort" => " ", "thinking" => "high"}, nil},
        {%{"thinking" => 42, "enable_thinking" => true}, nil},
        {%{"thinking" => " ", "enable_thinking" => true}, nil}
      ]

      for {payload, expected} <- cases do
        options = RequestOptions.build(%{}, @backend_endpoint, payload)
        assert ReasoningEffort.extract(payload, options) == expected
      end
    end

    test "reads only canonical fields from already-coerced public payloads" do
      responses_payload = %{
        "reasoning" => %{"effort" => "high"},
        "reasoning_effort" => "ignored"
      }

      responses_options =
        RequestOptions.build(
          %{openai_source_endpoint: "/v1/responses"},
          @backend_endpoint,
          responses_payload
        )

      assert ReasoningEffort.extract(responses_payload, responses_options) == "high"

      chat_payload = %{"reasoning_effort" => "custom-chat"}

      chat_options =
        RequestOptions.build(
          %{
            openai_source_endpoint: "/v1/chat/completions",
            openai_chat_payload: chat_payload
          },
          @backend_endpoint,
          %{"reasoning" => %{"effort" => "custom-chat"}}
        )

      assert ReasoningEffort.extract(%{"reasoning" => %{"effort" => "ignored"}}, chat_options) ==
               "custom-chat"
    end

    test "returns nil for omitted or malformed surface-specific fields" do
      public_options =
        RequestOptions.build(
          %{openai_source_endpoint: "/v1/responses"},
          @backend_endpoint,
          %{}
        )

      chat_options =
        RequestOptions.build(
          %{openai_source_endpoint: "/v1/chat/completions", openai_chat_payload: %{}},
          @backend_endpoint,
          %{}
        )

      assert ReasoningEffort.extract(%{"reasoning_effort" => "ignored"}, public_options) == nil

      assert ReasoningEffort.extract(%{"reasoning" => %{"effort" => "ignored"}}, chat_options) ==
               nil
    end
  end

  test "normalizes known tokens for comparison without accepting custom tokens" do
    assert ReasoningEffort.normalize_known("  XHIGH ") == "xhigh"
    assert ReasoningEffort.normalize_known("minimal") == "minimal"
    assert ReasoningEffort.normalize_known("custom-effort") == nil
    assert ReasoningEffort.normalize_known(:high) == nil
  end

  test "derives the canonical error parameter from the preserved source endpoint" do
    for endpoint <- ["/v1/chat/completions", "/backend-api/codex/v1/chat/completions"] do
      options =
        RequestOptions.build(%{openai_source_endpoint: endpoint}, @backend_endpoint, %{})

      assert ReasoningEffort.parameter(options) == "reasoning_effort"
    end

    for endpoint <- [
          nil,
          "/v1/responses",
          "/backend-api/codex/responses",
          "/backend-api/codex/v1/responses",
          "/backend-api/codex/responses/compact"
        ] do
      opts = if endpoint, do: %{openai_source_endpoint: endpoint}, else: %{}
      options = RequestOptions.build(opts, @backend_endpoint, %{})
      assert ReasoningEffort.parameter(options) == "reasoning.effort"
    end
  end

  test "keeps compatibility rewrites exact and leaves custom efforts untouched" do
    assert ReasoningEffort.rewrite_client_upstream(" minimal ") == "low"
    assert ReasoningEffort.rewrite_client_upstream("ultra") == "ultra"
    assert ReasoningEffort.rewrite_client_upstream("Custom-Effort") == "Custom-Effort"

    assert ReasoningEffort.rewrite_backend_upstream(" ULTRA ") == "max"
    assert ReasoningEffort.rewrite_backend_upstream("minimal") == "minimal"
    assert ReasoningEffort.rewrite_backend_upstream("Custom-Effort") == "Custom-Effort"
  end

  describe "rewrite_backend_upstream/2" do
    test "keeps max as the ultra alias when catalog levels are unknown or include max" do
      for levels <- [
            nil,
            [],
            ["custom-level"],
            ~w(low medium high xhigh max ultra),
            [" MAX ", "low"]
          ] do
        assert ReasoningEffort.rewrite_backend_upstream("ultra", levels) == "max"
      end
    end

    test "rewrites ultra to the highest listed level when the catalog excludes max" do
      cases = [
        {~w(low medium high xhigh), "xhigh"},
        {~w(xhigh low high), "xhigh"},
        {~w(low medium high ultra), "high"},
        {[" Medium ", "LOW", "custom-level"], "medium"}
      ]

      for {levels, expected} <- cases do
        assert ReasoningEffort.rewrite_backend_upstream(" Ultra ", levels) == expected
      end
    end

    test "never targets none or minimal and leaves every other value unchanged" do
      assert ReasoningEffort.rewrite_backend_upstream("ultra", ~w(none minimal)) == "max"
      assert ReasoningEffort.rewrite_backend_upstream("ultra", ~w(none minimal low)) == "low"

      for effort <- ["none", "minimal", "max", "xhigh", "custom-effort", 42, nil] do
        assert ReasoningEffort.rewrite_backend_upstream(effort, ~w(low medium high xhigh)) ==
                 effort
      end
    end
  end
end
