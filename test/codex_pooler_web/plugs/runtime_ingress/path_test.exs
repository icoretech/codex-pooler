defmodule CodexPoolerWeb.Plugs.RuntimeIngress.PathTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias CodexPoolerWeb.Plugs.RuntimeIngress
  alias CodexPoolerWeb.Plugs.RuntimeIngress.Path

  @runtime_paths [
    "/backend-api/codex/models",
    "/backend-api/files",
    "/backend-api/transcribe",
    "/api/codex/usage",
    "/wham/usage",
    "/backend-api/wham/usage",
    "/v1/models"
  ]

  test "existing unencoded families are classified without changing path_info" do
    for request_path <- @runtime_paths do
      conn = Plug.Test.conn(:get, request_path)
      original_path_info = conn.path_info

      classified_conn = RuntimeIngress.call(conn, [])

      assert classified_conn.private[:codex_pooler_runtime_ingress_settings]
      assert classified_conn.path_info === original_path_info
    end

    conn = Plug.Test.conn(:get, "/mcp")
    original_path_info = conn.path_info

    classified_conn = RuntimeIngress.call(conn, [])

    assert classified_conn.private[:codex_pooler_json_parse_error_scope] == :mcp
    assert classified_conn.path_info === original_path_info

    send_resp(classified_conn, 204, "")
  end

  test "encoded spellings classify as their decoded runtime and MCP families" do
    for {request_path, expected_scope, expected_segments} <- [
          {"/%76%31/responses", :runtime, ["v1", "responses"]},
          {"/%62ackend-api/codex/responses", :runtime, ["backend-api", "codex", "responses"]},
          {"/backend-api/%66iles", :runtime, ["backend-api", "files"]},
          {"/api/%63odex/usage", :runtime, ["api", "codex", "usage"]},
          {"/wham/%75sage", :runtime, ["wham", "usage"]},
          {"/backend-api/wham/%75sage", :runtime, ["backend-api", "wham", "usage"]},
          {"/%6dcp", :mcp, ["mcp"]}
        ] do
      path = request_path |> then(&Plug.Test.conn(:get, &1)) |> Path.fetch()

      assert path.scope == expected_scope
      assert Path.decoded_segments(path) == expected_segments
      refute path.unsafe_segment?
    end
  end

  test "classification-only virtual segments identify unsafe runtime and MCP candidates" do
    for {request_path, expected_scope, expected_candidates} <- [
          {"/v1%2Fresponses", :runtime, ["v1", "responses"]},
          {"/backend-api%5Cfiles", :runtime, ["backend-api", "files"]},
          {"/mcp%00suffix", :mcp, ["mcp"]}
        ] do
      path = request_path |> then(&Plug.Test.conn(:get, &1)) |> Path.fetch()

      assert path.scope == expected_scope
      assert path.candidate_segments == expected_candidates
      assert path.unsafe_segment?
    end
  end

  test "segments are decoded once and invalid percent sequences stay literal" do
    single_decode = "/v1/value%252Ftail" |> then(&Plug.Test.conn(:get, &1)) |> Path.fetch()
    invalid_percent = "/v1/value%ZZtail" |> then(&Plug.Test.conn(:get, &1)) |> Path.fetch()

    assert Path.decoded_segments(single_decode) == ["v1", "value%2Ftail"]
    assert single_decode.candidate_segments == ["v1", "value%2Ftail"]
    refute single_decode.unsafe_segment?

    assert Path.decoded_segments(invalid_percent) == ["v1", "value%ZZtail"]
    assert invalid_percent.candidate_segments == ["v1", "value%ZZtail"]
    refute invalid_percent.unsafe_segment?
  end

  test "unsafe unrelated paths remain passthrough candidates" do
    for request_path <- ["/admin%2Fusers", "/login%00suffix", "/healthz%2Fextra"] do
      path = request_path |> then(&Plug.Test.conn(:get, &1)) |> Path.fetch()

      assert path.scope == :passthrough
      assert path.unsafe_segment?
    end
  end

  test "pruned runtime helper paths are included in the runtime candidate scope" do
    for request_path <- [
          "/api/codex/rate-limit-reset-credits/consume",
          "/wham/rate-limit-reset-credits/consume",
          "/backend-api/wham/agent-identities/jwks"
        ] do
      path = request_path |> then(&Plug.Test.conn(:get, &1)) |> Path.fetch()

      assert path.scope == :runtime
    end
  end

  test "populate stores one immutable path view without mutating connection path data" do
    conn = Plug.Test.conn(:get, "/%76%31/responses?mode=sample")

    populated_conn = Path.populate(conn)
    first_path = Path.fetch(populated_conn)
    second_path = Path.fetch(populated_conn)

    assert populated_conn.private[:codex_pooler_runtime_ingress_path] === first_path
    assert second_path === first_path
    assert Path.populate(populated_conn) === populated_conn
    assert populated_conn.path_info === conn.path_info
    assert populated_conn.request_path === conn.request_path
    assert populated_conn.query_string === conn.query_string
    assert populated_conn.path_params === conn.path_params
    assert populated_conn.params === conn.params
  end
end
