defmodule CodexPoolerWeb.Plugs.RuntimeJsonParser do
  @moduledoc false

  @behaviour Plug.Parsers

  alias Plug.Parsers.JSON

  @parse_error_scope_private_key :codex_pooler_json_parse_error_scope

  @impl true
  def init(opts), do: JSON.init(opts)

  @impl true
  def parse(
        %Plug.Conn{method: "PUT", path_info: ["file-capabilities", _opaque_capability]} = conn,
        _type,
        _subtype,
        _headers,
        _opts
      ) do
    {:next, conn}
  end

  def parse(conn, type, subtype, headers, opts) do
    JSON.parse(conn, type, subtype, headers, opts)
  rescue
    error in Plug.Parsers.ParseError ->
      case conn.private[@parse_error_scope_private_key] do
        :protected_backend ->
          {:ok, %{"_invalid_json" => true},
           Plug.Conn.put_private(conn, :runtime_json_parse_error, true)}

        :mcp ->
          {:ok, %{"_invalid_json" => true},
           Plug.Conn.put_private(conn, :mcp_json_parse_error, true)}

        _other ->
          reraise error, __STACKTRACE__
      end
  end
end
