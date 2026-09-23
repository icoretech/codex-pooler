defmodule CodexPoolerWeb.V1.ResponsesWebsocketBridgeRejectionTest do
  # A provider validation refusal reaches the public `/v1/responses` stream the
  # same way whichever upstream transport carried the turn (findings#225,
  # 225-98). Over HTTP the Codex backend answers the refused request with a
  # 4xx JSON error before any stream; over its websocket transport it sends
  # one `{"type": "error", "status": 4xx, "error": {...}}` frame instead. The
  # bridged turn must answer the public client with the same HTTP status and
  # OpenAI error body as the HTTP path, and record the same rejection fields
  # on the attempt, instead of HTTP 200 plus a `response.failed` that turns
  # the 4xx into a stream interruption.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  @provider_sentinel "private-bridge-rejection-sentinel"
  @prompt_sentinel "private-bridge-rejection-prompt-sentinel"
  @param "input[1].id"

  setup do
    previous = Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
        value -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
      end
    end)

    :ok
  end

  test "a bridged provider 400 frame answers the same public status, body and rejection fields as the HTTP path", %{conn: conn} do
    http_upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(method: "POST", path: "/backend-api/codex/responses", respond: {:json_error, 400, %{"error" => provider_error()}})
        ])
      )

    http_setup = gateway_setup(http_upstream)
    http_response = conn |> auth(http_setup) |> post("/v1/responses", payload(http_setup))

    assert FakeUpstream.websocket_connection_count(http_upstream) == 0
    assert http_response.status == 400
    {http_request, http_attempt} = sole_rows!(http_setup)

    bridge_upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "WEBSOCKET",
            path: "/backend-api/codex/responses",
            websocket_connection_ordinal: 1,
            json: [valid: true, equals: %{"type" => "response.create"}],
            respond: FakeUpstream.websocket_text_frames([CodexPooler.JSON.encode!(%{"type" => "error", "status" => 400, "error" => provider_error()})])
          )
        ])
      )

    bridge_setup = gateway_setup(bridge_upstream)

    bridge_response =
      conn
      |> recycle()
      |> auth(bridge_setup)
      |> put_req_header("x-session-id", "bridge-rejection-#{System.unique_integer([:positive])}")
      |> post("/v1/responses", payload(bridge_setup))

    # The turn went over the upstream websocket and was not resubmitted over HTTP.
    assert FakeUpstream.websocket_connection_count(bridge_upstream) == 1
    assert FakeUpstream.http_request_count(bridge_upstream) == 0
    assert :ok = FakeUpstream.verify!(bridge_upstream)

    assert bridge_response.status == 400
    assert json_response(bridge_response, 400) == json_response(http_response, 400)

    assert json_response(bridge_response, 400) == %{
             "error" => %{
               "message" => "upstream rejected parameter #{@param} (invalid_value)",
               "type" => "invalid_request_error",
               "code" => "invalid_value",
               "param" => @param
             }
           }

    {bridge_request, bridge_attempt} = sole_rows!(bridge_setup)

    for field <- [:status, :last_error_code, :response_status_code] do
      assert Map.fetch!(bridge_request, field) == Map.fetch!(http_request, field), "request #{field}"
    end

    assert bridge_request.transport == "http_sse"
    assert bridge_attempt.upstream_status_code == 400
    assert bridge_attempt.network_error_code == http_attempt.network_error_code

    rejection_fields = fn attempt -> Map.filter(attempt.response_metadata, fn {key, _value} -> String.starts_with?(key, "rejection_") end) end

    assert rejection_fields.(bridge_attempt) == rejection_fields.(http_attempt)
    assert bridge_attempt.response_metadata["rejection_error_param"] == @param
    assert bridge_attempt.response_metadata["error_kind"] == "upstream_status"
    assert bridge_attempt.response_metadata["upstream_transport"] == "websocket"
    assert %{"generation" => 1} = bridge_attempt.response_metadata["upstream_websocket_connection"]
    assert settlement_count(bridge_request.id) == 1

    for response <- [bridge_response, http_response], row <- [bridge_request, bridge_attempt] do
      refute response.resp_body =~ @provider_sentinel
      refute response.resp_body =~ @prompt_sentinel
      refute inspect(row) =~ @provider_sentinel
      refute inspect(row) =~ @prompt_sentinel
    end
  end

  # The Codex client's own websocket fixture for a provider 400 carries only
  # the error type and message; the bridged answer still matches HTTP.
  test "a bridged provider 400 frame without code or param matches the HTTP answer", %{conn: conn} do
    error = %{"type" => "invalid_request_error", "message" => "Model '#{@provider_sentinel}' does not support image inputs."}

    http_upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(method: "POST", path: "/backend-api/codex/responses", respond: {:json_error, 400, %{"error" => error}})
        ])
      )

    http_setup = gateway_setup(http_upstream)
    http_response = conn |> auth(http_setup) |> post("/v1/responses", payload(http_setup))
    {_http_request, http_attempt} = sole_rows!(http_setup)

    bridge_upstream = start_upstream(FakeUpstream.websocket_text_frames([CodexPooler.JSON.encode!(%{"type" => "error", "status" => 400, "error" => error})]))
    bridge_setup = gateway_setup(bridge_upstream)

    bridge_response =
      conn
      |> recycle()
      |> auth(bridge_setup)
      |> put_req_header("x-session-id", "bridge-codeless-rejection-#{System.unique_integer([:positive])}")
      |> post("/v1/responses", payload(bridge_setup))

    assert FakeUpstream.websocket_connection_count(bridge_upstream) == 1
    assert FakeUpstream.http_request_count(bridge_upstream) == 0
    assert bridge_response.status == 400
    assert json_response(bridge_response, 400) == json_response(http_response, 400)
    refute bridge_response.resp_body =~ @provider_sentinel

    {_bridge_request, bridge_attempt} = sole_rows!(bridge_setup)
    rejection_fields = fn attempt -> Map.filter(attempt.response_metadata, fn {key, _value} -> String.starts_with?(key, "rejection_") end) end
    assert rejection_fields.(bridge_attempt) == rejection_fields.(http_attempt)
    assert bridge_attempt.response_metadata["rejection_error_type"] == "invalid_request_error"
  end

  test "a bridged provider 5xx error frame keeps its committed stream failure", %{conn: conn} do
    upstream =
      start_upstream(
        FakeUpstream.websocket_text_frames([
          CodexPooler.JSON.encode!(%{"type" => "error", "status" => 500, "error" => %{"type" => "server_error", "code" => "server_error", "message" => "synthetic provider failure"}})
        ])
      )

    setup = gateway_setup(upstream)

    response =
      conn
      |> auth(setup)
      |> put_req_header("x-session-id", "bridge-server-error-#{System.unique_integer([:positive])}")
      |> post("/v1/responses", payload(setup))

    assert FakeUpstream.websocket_connection_count(upstream) == 1
    assert FakeUpstream.http_request_count(upstream) == 0
    assert response.status == 200
    assert response.resp_body =~ "event: response.failed"

    {request, attempt} = sole_rows!(setup)
    assert request.status == "failed"
    assert attempt.upstream_status_code == 200
    refute Map.has_key?(attempt.response_metadata, "rejection_error_code")
  end

  defp provider_error do
    %{
      "type" => "invalid_request_error",
      "code" => "invalid_value",
      "message" => "Invalid 'input[1].id': '#{@provider_sentinel}'.",
      "param" => @param
    }
  end

  defp payload(setup), do: %{"model" => setup.model.exposed_model_id, "input" => @prompt_sentinel, "stream" => true}

  defp sole_rows!(setup) do
    assert [request] = Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))
    assert [attempt] = Repo.all(from(attempt in Attempt, where: attempt.request_id == ^request.id))
    {request, attempt}
  end

  defp settlement_count(request_id) do
    Repo.aggregate(from(entry in LedgerEntry, where: entry.request_id == ^request_id and entry.entry_kind == "settlement"), :count)
  end
end
