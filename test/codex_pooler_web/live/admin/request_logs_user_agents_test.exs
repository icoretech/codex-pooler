defmodule CodexPoolerWeb.Admin.RequestLogsUserAgentsTest do
  use CodexPoolerWeb.ConnCase, async: false

  alias CodexPoolerWeb.Admin.RequestLogsDisplay.UserAgents

  describe "classify/1" do
    test "recognizes observed production and local request user agents" do
      assert %{kind: "codex_desktop", label: "Codex Desktop"} =
               UserAgents.classify(
                 "Codex Desktop/0.133.0-alpha.1 (Mac OS 26.5.0; arm64) unknown (Codex Desktop; 26.519.41501)"
               )

      assert %{kind: "codex", label: "Codex"} =
               UserAgents.classify("codex-tui/0.133.0 (Mac OS 26.5.0; arm64)")

      assert %{kind: "codex", label: "Codex"} =
               UserAgents.classify("codex_exec/0.133.0 (Alpine Linux 3.23.3; aarch64)")

      assert %{kind: "openai_python", label: "OpenAI Python SDK"} =
               UserAgents.classify("OpenAI/Python 2.38.0")

      assert %{kind: "openai_python", label: "OpenAI Python SDK"} =
               UserAgents.classify("AsyncOpenAI/Python 2.36.0")

      assert %{kind: "openai_node", label: "OpenAI Node SDK"} =
               UserAgents.classify("OpenAI/JS 6.39.0")

      assert %{kind: "vercel_ai_sdk", label: "Vercel AI SDK"} =
               UserAgents.classify("ai/6.0.191 ai-sdk/provider-utils/4.0.27 runtime/node.js/26")

      assert %{kind: "vercel_ai_sdk", label: "Vercel AI SDK"} =
               UserAgents.classify(
                 "ai/7.0.0-beta.12 @ai-sdk/openai/4.0.0-beta.12 runtime/node.js/24"
               )

      assert %{kind: "python", label: "Python"} = UserAgents.classify("python-requests/2.33.0")
      assert %{kind: "python", label: "Python"} = UserAgents.classify("Python-urllib/3.14")
      assert %{kind: "node", label: "Node.js"} = UserAgents.classify("node")
      assert %{kind: "curl", label: "curl"} = UserAgents.classify("curl/8.20.0")
      assert %{kind: "elixir_http", label: "Elixir HTTP"} = UserAgents.classify("req/0.5.17")
      assert %{kind: "elixir_http", label: "Elixir HTTP"} = UserAgents.classify("mint/1.8.0")
    end

    test "recognizes documented harness names when they appear in user agents" do
      assert %{kind: "opencode", label: "opencode"} = UserAgents.classify("opencode/0.15.0")
      assert %{kind: "openclaw", label: "OpenClaw"} = UserAgents.classify("OpenClaw/1.0")
      assert %{kind: "hermes", label: "Hermes Agent"} = UserAgents.classify("Hermes-Agent/0.9")
      assert %{kind: "windmill", label: "Windmill"} = UserAgents.classify("windmill/beta")
      assert %{kind: "aider", label: "Aider"} = UserAgents.classify("aider/0.86.2")
      assert %{kind: "continue", label: "Continue"} = UserAgents.classify("Continue/1.5.45")
      assert %{kind: "cline", label: "Cline"} = UserAgents.classify("Cline/3.16.0")
      assert %{kind: "goose", label: "Goose"} = UserAgents.classify("goose/1.35.0")
    end
  end

  test "display/1 keeps compact sanitized text separate from classification" do
    assert %{
             kind: "codex_desktop",
             label: "Codex Desktop",
             title: "Codex Desktop user agent",
             text: "Codex Desktop 0.133.0-alpha.1"
           } =
             UserAgents.display(%{
               user_agent:
                 "Codex Desktop/0.133.0-alpha.1 (Mac OS 26.5.0; arm64) unknown (Codex Desktop; 26.519.41501)"
             })
  end
end
