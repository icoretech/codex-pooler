defmodule CodexPoolerWeb.Plugs.BackendFilesMultipartGuard do
  @moduledoc false

  import Plug.Conn

  alias CodexPoolerWeb.GatewayControllerHelpers, as: GatewayHelpers

  @files_path ["backend-api", "files"]

  def init(opts), do: opts

  def call(%Plug.Conn{halted: true} = conn, _opts), do: conn

  def call(conn, _opts) do
    if conn.method == "POST" and conn.path_info == @files_path and multipart_content_type?(conn) do
      case GatewayHelpers.authenticate(conn) do
        {:ok, _auth} ->
          conn
          |> GatewayHelpers.send_error(%{
            status: 400,
            code: "unsupported_multipart_file_create",
            message: "multipart file create is not supported on this route"
          })
          |> halt()

        {:error, reason} ->
          conn
          |> GatewayHelpers.send_error(reason)
          |> halt()
      end
    else
      conn
    end
  end

  defp multipart_content_type?(conn) do
    conn
    |> get_req_header("content-type")
    |> List.first()
    |> case do
      nil -> false
      content_type -> String.starts_with?(String.downcase(content_type), "multipart/form-data")
    end
  end
end
