defmodule CodexPoolerWeb.BrowserSecurity do
  @moduledoc false

  @codex_desktop_browser_script_sources ["'unsafe-eval'", "blob:"]
  @local_browser_hosts ["localhost", "127.0.0.1", "::1"]

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
    secure_headers(nil)
  end

  @spec secure_headers(Plug.Conn.t() | nil) :: %{String.t() => String.t()}
  def secure_headers(conn) do
    %{"content-security-policy" => content_security_policy(conn)}
  end

  @spec codex_desktop_browser?(Plug.Conn.t()) :: boolean()
  def codex_desktop_browser?(conn) do
    conn
    |> Plug.Conn.get_req_header("user-agent")
    |> Enum.any?(&(String.contains?(&1, " Codex/") and String.contains?(&1, " Electron/")))
  end

  @spec local_browser_annotation_client?(Plug.Conn.t()) :: boolean()
  def local_browser_annotation_client?(%Plug.Conn{} = conn) do
    local_browser_request?(conn) and (codex_desktop_browser?(conn) or chromium_browser?(conn))
  end

  defp content_security_policy(conn) do
    extra_sources =
      :codex_pooler
      |> Application.get_env(:browser_csp_extra_sources, [])
      |> Keyword.merge(CodexPoolerWeb.DevFeatures.browser_csp_extra_sources(), fn _directive,
                                                                                  left,
                                                                                  right ->
        List.wrap(left) ++ List.wrap(right)
      end)
      |> Keyword.merge(browser_annotation_csp_extra_sources(conn), fn _directive, left, right ->
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

  defp browser_annotation_csp_extra_sources(%Plug.Conn{} = conn) do
    if local_browser_annotation_client?(conn) do
      [script_src: @codex_desktop_browser_script_sources]
    else
      []
    end
  end

  defp browser_annotation_csp_extra_sources(_conn), do: []

  defp local_browser_request?(%Plug.Conn{} = conn) do
    local_browser_host?(conn) and local_remote_ip?(conn)
  end

  defp local_browser_host?(%Plug.Conn{host: host}) when is_binary(host) do
    host in @local_browser_hosts or String.ends_with?(host, ".localhost")
  end

  defp local_remote_ip?(%Plug.Conn{remote_ip: {127, 0, 0, 1}}), do: true
  defp local_remote_ip?(%Plug.Conn{remote_ip: {0, 0, 0, 0, 0, 0, 0, 1}}), do: true
  defp local_remote_ip?(%Plug.Conn{}), do: false

  defp chromium_browser?(%Plug.Conn{} = conn) do
    conn
    |> Plug.Conn.get_req_header("user-agent")
    |> Enum.any?(
      &(String.contains?(&1, [" Chrome/", " Chromium/"]) and String.contains?(&1, " Safari/"))
    )
  end
end
