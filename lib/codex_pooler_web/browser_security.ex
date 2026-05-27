defmodule CodexPoolerWeb.BrowserSecurity do
  @moduledoc false

  @base_directives [
    default_src: ["'self'"],
    base_uri: ["'self'"],
    frame_ancestors: ["'self'"],
    connect_src: ["'self'", "ws:", "wss:"],
    img_src: ["'self'", "data:", "https://www.gravatar.com"],
    script_src: ["'self'", "'unsafe-inline'"],
    style_src: ["'self'", "'unsafe-inline'"]
  ]

  @spec secure_headers() :: %{String.t() => String.t()}
  def secure_headers do
    %{"content-security-policy" => content_security_policy()}
  end

  defp content_security_policy do
    extra_sources =
      :codex_pooler
      |> Application.get_env(:browser_csp_extra_sources, [])
      |> Keyword.merge(CodexPoolerWeb.DevFeatures.browser_csp_extra_sources(), fn _directive,
                                                                                  left,
                                                                                  right ->
        List.wrap(left) ++ List.wrap(right)
      end)
      |> Keyword.take([:connect_src, :img_src, :script_src, :style_src])

    @base_directives
    |> Keyword.merge(extra_sources, fn _directive, base, extra ->
      Enum.uniq(base ++ List.wrap(extra))
    end)
    |> Enum.map_join("; ", fn {directive, sources} ->
      "#{directive_name(directive)} #{Enum.join(sources, " ")}"
    end)
  end

  defp directive_name(directive) do
    directive
    |> Atom.to_string()
    |> String.replace("_", "-")
  end
end
