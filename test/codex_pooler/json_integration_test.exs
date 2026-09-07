defmodule CodexPooler.JSONIntegrationTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.FakeUpstream
  alias CodexPooler.JSON, as: Codec

  test "frameworks load the native application codec" do
    assert Phoenix.json_library() == Codec
    assert Application.fetch_env!(:postgrex, :json_library) == Codec
    assert Swoosh.json_library() == Codec
    assert Keyword.fetch!(Req.default_options(), :decoders)[:json] == (&Codec.decode/1)
  end

  test "Postgrex JSON and JSONB preserve nested values and decimal strings" do
    value = %{
      "nested" => [%{"enabled" => true, "missing" => nil, "label" => "雪"}],
      "precise" => Decimal.new("1.00"),
      "small" => Decimal.new("1E-30"),
      "large" => Decimal.new("1E30")
    }

    expected = %{
      "nested" => [%{"enabled" => true, "missing" => nil, "label" => "雪"}],
      "precise" => "1.00",
      "small" => "0.000000000000000000000000000001",
      "large" => "1000000000000000000000000000000"
    }

    assert %{rows: [[^expected, ^expected]]} =
             Repo.query!("SELECT $1::json, $2::jsonb", [value, value])
  end

  test "Phoenix response and Plug parser use the configured codec" do
    conn = Phoenix.Controller.json(Plug.Test.conn(:get, "/"), %{label: "雪", active: true})

    assert conn.status == 200
    assert Plug.Conn.get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
    assert JSON.decode!(conn.resp_body) == %{"label" => "雪", "active" => true}

    parsed =
      Plug.Test.conn(:post, "/", ~s({"label":"first","label":"last","nested":[null,true]}))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Parsers.call(parser_options())

    assert parsed.body_params == %{"label" => "first", "nested" => [nil, true]}

    assert_raise Plug.Parsers.ParseError, fn ->
      Plug.Test.conn(:post, "/", ~s({"broken":))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Parsers.call(parser_options())
    end
  end

  test "Req sends native encoded JSON and decodes duplicate keys through the configured codec" do
    {:ok, upstream} =
      FakeUpstream.start_link(
        FakeUpstream.raw_response(~s({"result":"first","result":"last","nested":[true,null]}),
          headers: [{"content-type", "application/json"}]
        )
      )

    on_exit(fn -> FakeUpstream.stop(upstream) end)
    body = Codec.encode_to_iodata!(%{"label" => "雪", "nested" => [true, nil]})

    assert {:ok, %{status: 200, body: %{"result" => "first", "nested" => [true, nil]}}} =
             Req.post(FakeUpstream.url(upstream),
               body: body,
               headers: [{"content-type", "application/json"}],
               retry: false
             )

    assert [request] = FakeUpstream.requests(upstream)
    assert request.body == IO.iodata_to_binary(body)
    assert {"content-type", "application/json"} in request.headers
    assert JSON.decode!(request.body) == %{"label" => "雪", "nested" => [true, nil]}
  end

  defp parser_options do
    Plug.Parsers.init(parsers: [:json], pass: ["*/*"], json_decoder: Phoenix.json_library())
  end
end
