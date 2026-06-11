defmodule CodexPoolerWeb.Runtime.GatewayControllerHelpersTest do
  use CodexPoolerWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Gateway.Contracts
  alias CodexPoolerWeb.Runtime.GatewayControllerHelpers

  test "body results do not require a headers key", %{conn: conn} do
    conn =
      GatewayControllerHelpers.send_gateway_result(conn, %{
        status: 200,
        body: %{"ok" => true}
      })

    assert json_response(conn, 200) == %{"ok" => true}
  end

  test "raw body results do not require a headers key", %{conn: conn} do
    conn =
      GatewayControllerHelpers.send_gateway_result(conn, %{
        status: 200,
        raw_body: "raw"
      })

    assert response(conn, 200) == "raw"
  end

  test "send_or_error accepts conn first", %{conn: conn} do
    conn =
      GatewayControllerHelpers.send_or_error(conn, {
        :ok,
        %{status: 200, body: %{"ok" => true}}
      })

    assert json_response(conn, 200) == %{"ok" => true}
  end

  test "authenticate_v1 keeps OpenAI /v1 API-key eligibility separate from backend auth" do
    setup = paused_api_key_fixture()

    conn =
      Phoenix.ConnTest.build_conn(:get, "/v1/models")
      |> put_req_header("authorization", setup.authorization)

    assert {:error, %{status: 401, code: :api_key_paused}} =
             GatewayControllerHelpers.authenticate(conn)

    assert {:error, %{status: 401, code: :api_key_disabled}} =
             GatewayControllerHelpers.authenticate_v1(conn)
  end

  test "request_opts keeps session header provenance bounded by local compatibility header" do
    conn =
      Phoenix.ConnTest.build_conn(:post, "/backend-api/codex/responses")
      |> put_req_header("x-session-affinity", " affinity-local ")

    assert %{session_header: "affinity-local", session_header_source: "x-session-affinity"} =
             GatewayControllerHelpers.request_opts(conn)

    conn =
      Phoenix.ConnTest.build_conn(:post, "/backend-api/codex/responses")
      |> put_req_header("session-id", " local-session ")
      |> put_req_header("x-session-id", "lower-priority-session")
      |> put_req_header("x-session-affinity", "affinity-local")

    assert %{session_header: "local-session", session_header_source: "session-id"} =
             GatewayControllerHelpers.request_opts(conn)

    conn =
      Phoenix.ConnTest.build_conn(:post, "/backend-api/codex/responses")
      |> put_req_header("x-session-id", " local-session ")
      |> put_req_header("x-session-affinity", "affinity-local")

    assert %{session_header: "local-session", session_header_source: "x-session-id"} =
             GatewayControllerHelpers.request_opts(conn)

    conn =
      Phoenix.ConnTest.build_conn(:post, "/backend-api/codex/responses")
      |> put_req_header("x-codex-window-id", " window-session ")
      |> put_req_header("x-codex-session-id", "codex-session")
      |> put_req_header("session-id", "local-session")
      |> put_req_header("x-session-id", "lower-priority-session")

    assert %{session_header: "window-session", session_header_source: "x-codex-window-id"} =
             GatewayControllerHelpers.request_opts(conn)
  end

  test "send_error renders pinned continuation recovery header and body fields", %{conn: conn} do
    conn =
      GatewayControllerHelpers.send_error(
        conn,
        Contracts.pinned_continuation_reauth_required_error()
      )

    assert get_resp_header(conn, "x-codex-recovery-kind") == ["restart_with_full_context"]

    assert %{
             "error" => %{
               "code" => "pinned_continuation_reauth_required",
               "retryable" => false,
               "requires_new_upstream_session" => true,
               "recovery_kind" => "restart_with_full_context",
               "recovery" => recovery
             }
           } = json_response(conn, 503)

    assert recovery["kind"] == "restart_with_full_context"
    assert recovery["anchor_removal"]["body"] == ["previous_response_id"]

    assert recovery["anchor_removal"]["headers"] == [
             "x-codex-previous-response-id",
             "x-codex-turn-state",
             "x-codex-window-id",
             "x-codex-session-id",
             "session-id",
             "x-session-id",
             "x-session-affinity",
             "session_id",
             "x-codex-conversation-id"
           ]
  end

  test "send_error leaves unrelated error shapes without recovery fields" do
    for error <- [
          %{status: 503, code: "session_assignment_unavailable", message: "session unavailable"},
          %{status: 400, code: "unsupported_model_capability", message: "model unsupported"},
          %{status: 400, code: "invalid_request", message: "request invalid"}
        ] do
      conn = GatewayControllerHelpers.send_error(Phoenix.ConnTest.build_conn(), error)
      body = json_response(conn, error.status)

      assert get_resp_header(conn, "x-codex-recovery-kind") == []

      assert body == %{
               "error" => %{
                 "message" => error.message,
                 "type" => "invalid_request_error",
                 "code" => error.code,
                 "param" => nil
               }
             }
    end
  end

  test "late stream errors preserve a safe log reason" do
    conn =
      Phoenix.ConnTest.build_conn(:post, "/backend-api/codex/responses")
      |> put_req_header("x-request-id", "late-stream-regression")

    log =
      capture_log(fn ->
        conn =
          GatewayControllerHelpers.send_gateway_result(conn, %{
            status: 200,
            stream: fn _conn -> {:error, {:chunk, :closed}} end
          })

        assert conn.state == :chunked
      end)

    assert log =~ "late gateway stream failed"
    assert log =~ "path=/backend-api/codex/responses"
    assert log =~ "request_id=late-stream-regression"
    assert log =~ "client disconnected while writing downstream stream"
  end

  test "result_headers normalizes nil or missing headers" do
    assert GatewayControllerHelpers.result_headers(%{}) == []
    assert GatewayControllerHelpers.result_headers(%{headers: nil}) == []

    assert GatewayControllerHelpers.result_headers(%{headers: [{"x-example", "ok"}]}) == [
             {"x-example", "ok"}
           ]
  end
end
