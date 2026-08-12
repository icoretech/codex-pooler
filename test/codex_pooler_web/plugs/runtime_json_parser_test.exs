defmodule CodexPoolerWeb.Plugs.RuntimeJsonParserTest do
  use ExUnit.Case, async: true

  alias CodexPoolerWeb.Plugs.RuntimeJsonParser

  test "does not consume an exact file-capability PUT body with a JSON content type" do
    conn =
      Plug.Test.conn(
        :put,
        "/file-capabilities/cpfc_opaque",
        Jason.encode!("1234567890")
      )

    opts =
      RuntimeJsonParser.init(
        json_decoder: Jason,
        body_reader: {__MODULE__, :read_body, [self()]}
      )

    assert {:next, ^conn} =
             RuntimeJsonParser.parse(conn, "application", "json", %{}, opts)

    refute_receive :json_body_reader_called
  end

  def read_body(conn, opts, test_pid) do
    send(test_pid, :json_body_reader_called)
    Plug.Conn.read_body(conn, opts)
  end
end
