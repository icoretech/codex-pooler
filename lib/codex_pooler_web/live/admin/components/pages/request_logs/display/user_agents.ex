defmodule CodexPoolerWeb.Admin.RequestLogsDisplay.UserAgents do
  @moduledoc false

  @type classification :: %{
          kind: String.t(),
          label: String.t(),
          icon: String.t(),
          icon_class: String.t()
        }

  @patterns [
    {:prefix, "codex desktop/", "codex_desktop", "Codex Desktop", "hero-computer-desktop", :info},
    {:custom, :codex_cli, "codex", "Codex", "hero-command-line", :info},
    {:contains, ["opencode"], "opencode", "opencode", "hero-code-bracket-square", :primary},
    {:contains, ["openclaw"], "openclaw", "OpenClaw", "hero-bolt", :primary},
    {:contains, ["hermes"], "hermes", "Hermes Agent", "hero-paper-airplane", :primary},
    {:contains, ["aider"], "aider", "Aider", "hero-pencil-square", :primary},
    {:contains, ["continue"], "continue", "Continue", "hero-arrow-path-rounded-square", :primary},
    {:contains, ["cline"], "cline", "Cline", "hero-command-line", :primary},
    {:contains, ["roo-code", "roocode", "roo code"], "roo_code", "Roo Code",
     "hero-wrench-screwdriver", :primary},
    {:contains, ["goose"], "goose", "Goose", "hero-sparkles", :primary},
    {:prefix, "openai/python", "openai_python", "OpenAI Python SDK", "hero-code-bracket",
     :success},
    {:prefix, "openai/js", "openai_node", "OpenAI Node SDK", "hero-cube", :success},
    {:custom, :vercel_ai_sdk, "vercel_ai_sdk", "Vercel AI SDK", "hero-sparkles", :success},
    {:custom, :python_runtime, "python", "Python", "hero-code-bracket", :warning},
    {:custom, :node_runtime, "node", "Node.js", "hero-cube", :warning},
    {:prefix, "curl/", "curl", "curl", "hero-command-line", :neutral},
    {:custom, :elixir_http, "elixir_http", "Elixir HTTP", "hero-beaker", :neutral},
    {:prefix, "codex-pooler-", "codex_pooler", "Codex Pooler", "hero-server-stack", :neutral}
  ]

  @spec display(map()) :: map() | nil
  def display(%{user_agent: user_agent}) when is_binary(user_agent) do
    user_agent = String.trim(user_agent)

    if user_agent == "" do
      nil
    else
      classification = classify(user_agent)

      %{
        text: compact(user_agent),
        title: "#{classification.label} user agent",
        kind: classification.kind,
        label: classification.label,
        icon: classification.icon,
        icon_class: classification.icon_class
      }
    end
  end

  def display(_request_log), do: nil

  @spec format(map()) :: String.t() | nil
  def format(%{user_agent: user_agent}) when is_binary(user_agent) and user_agent != "",
    do: compact(user_agent)

  def format(_request_log), do: nil

  @spec classify(String.t()) :: classification()
  def classify(user_agent) when is_binary(user_agent) do
    normalized = user_agent |> String.trim() |> String.downcase()

    Enum.find_value(@patterns, client("unknown", "Client", "hero-window", :neutral), fn pattern ->
      classify_pattern(pattern, normalized)
    end)
  end

  defp classify_pattern({:prefix, prefix, kind, label, icon, tone}, user_agent) do
    if String.starts_with?(user_agent, prefix), do: client(kind, label, icon, tone)
  end

  defp classify_pattern({:contains, needles, kind, label, icon, tone}, user_agent) do
    if Enum.any?(needles, &String.contains?(user_agent, &1)), do: client(kind, label, icon, tone)
  end

  defp classify_pattern({:custom, name, kind, label, icon, tone}, user_agent) do
    if custom_match?(name, user_agent), do: client(kind, label, icon, tone)
  end

  defp client(kind, label, icon, tone) do
    %{
      kind: kind,
      label: label,
      icon: icon,
      icon_class: ["size-3.5 shrink-0", icon_tone_class(tone)]
    }
  end

  defp custom_match?(:codex_cli, user_agent) do
    String.starts_with?(user_agent, "codex cli/") or
      String.starts_with?(user_agent, "codex-tui/") or
      String.starts_with?(user_agent, "codex_exec/")
  end

  defp custom_match?(:vercel_ai_sdk, user_agent) do
    String.starts_with?(user_agent, "ai/") and
      (String.contains?(user_agent, "ai-sdk") or String.contains?(user_agent, "runtime/node.js"))
  end

  defp custom_match?(:python_runtime, user_agent) do
    String.starts_with?(user_agent, "python-requests/") or
      String.starts_with?(user_agent, "python-urllib/")
  end

  defp custom_match?(:node_runtime, user_agent),
    do: user_agent == "node" or String.starts_with?(user_agent, "node/")

  defp custom_match?(:elixir_http, user_agent),
    do: String.starts_with?(user_agent, "mint/") or String.starts_with?(user_agent, "req/")

  defp icon_tone_class(:info), do: "text-info"
  defp icon_tone_class(:primary), do: "text-primary"
  defp icon_tone_class(:success), do: "text-success"
  defp icon_tone_class(:warning), do: "text-warning"
  defp icon_tone_class(_tone), do: "text-base-content/45"

  defp compact(user_agent) do
    user_agent = String.trim(user_agent)

    case Regex.run(~r/^([^\/\(]+)\/([^\s\(]+)(?:\s+\(([^)]*)\))?/, user_agent) do
      [_match, product, version | _ignored] ->
        product
        |> compact_product(version)
        |> truncate()

      _no_match ->
        truncate(user_agent)
    end
  end

  defp compact_product(product, version) do
    [String.trim(product), String.trim(version)]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
  end

  defp truncate(user_agent) do
    if String.length(user_agent) > 72 do
      String.slice(user_agent, 0, 69) <> "..."
    else
      user_agent
    end
  end

  defp blank?(value), do: String.trim(to_string(value)) == ""
end
