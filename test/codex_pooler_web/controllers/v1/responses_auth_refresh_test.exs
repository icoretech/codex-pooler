defmodule CodexPoolerWeb.V1.ResponsesAuthRefreshTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, start_upstream: 1, stream_success_sse: 0]

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams

  @upstream_path "/backend-api/codex/responses"
  @initial_token "upstream-token"

  test "POST /v1/responses streaming refreshes on upstream 401 and streams normally",
       %{conn: conn} do
    refreshed_token = "refreshed-access-v1-#{System.unique_integer([:positive])}-do-not-leak"
    provider_message = "provider-v1-401-sentinel"

    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          expect_dispatch(@initial_token, unauthorized_response(provider_message)),
          oauth_refresh(FakeUpstream.json_response(%{"access_token" => refreshed_token}, 200)),
          expect_dispatch(refreshed_token, stream_success_sse())
        ])
      )

    setup = gateway_setup(upstream)
    store_refresh_token!(setup.identity, "refresh-token-v1-stream-do-not-leak")

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic v1 auth refresh stream",
        "stream" => true
      })

    assert conn.status == 200
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/event-stream"
    assert conn.resp_body =~ "event: response.completed\n"
    refute conn.resp_body =~ provider_message
    refute conn.resp_body =~ refreshed_token
    assert :ok = FakeUpstream.verify!(upstream)

    assert [first_attempt, second_attempt] =
             Repo.all(from(a in Attempt, order_by: [asc: a.attempt_number]))

    assert first_attempt.status == "retryable_failed"
    assert first_attempt.network_error_code == "upstream_unauthorized"
    assert second_attempt.status == "succeeded"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.request_metadata["auth_refresh"]["status"] == "succeeded"
  end

  test "POST /v1/responses JSON refreshes on upstream 401 and returns the completed response",
       %{conn: conn} do
    refreshed_token = "refreshed-access-v1-json-#{System.unique_integer([:positive])}-do-not-leak"

    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          expect_dispatch(@initial_token, unauthorized_response("provider-v1-json-sentinel")),
          oauth_refresh(FakeUpstream.json_response(%{"access_token" => refreshed_token}, 200)),
          expect_dispatch(
            refreshed_token,
            FakeUpstream.json_response(%{
              "id" => "resp_v1_auth_refresh_json",
              "object" => "response",
              "status" => "completed",
              "output" => []
            })
          )
        ])
      )

    setup = gateway_setup(upstream)
    store_refresh_token!(setup.identity, "refresh-token-v1-json-do-not-leak")

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic v1 auth refresh json"
      })

    assert %{"id" => "resp_v1_auth_refresh_json", "status" => "completed"} =
             json_response(conn, 200)

    assert :ok = FakeUpstream.verify!(upstream)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.request_metadata["auth_refresh"]["status"] == "succeeded"
  end

  test "POST /v1/responses exhausted auth refresh returns 503 upstream_unauthorized, never 401",
       %{conn: conn} do
    provider_message = "provider-v1-exhausted-sentinel"

    # Strict: one 401 and one failed provider refresh; no retry entry exists.
    upstream =
      start_upstream(
        FakeUpstream.strict_sequence([
          expect_dispatch(@initial_token, unauthorized_response(provider_message)),
          oauth_refresh(FakeUpstream.json_response(%{"error" => "invalid_grant"}, 400))
        ])
      )

    setup = gateway_setup(upstream)
    store_refresh_token!(setup.identity, "refresh-token-v1-exhausted-do-not-leak")

    conn =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic v1 auth refresh exhausted",
        "stream" => true
      })

    assert %{"error" => error} = json_response(conn, 503)

    assert error == %{
             "code" => "upstream_unauthorized",
             "type" => "server_error",
             "message" => "upstream request failed"
           }

    refute conn.resp_body =~ provider_message
    assert :ok = FakeUpstream.verify!(upstream)

    assert [attempt] = Repo.all(from(a in Attempt))
    assert attempt.status == "failed"
    assert attempt.network_error_code == "upstream_unauthorized"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.response_status_code == 503
    assert request.last_error_code == "upstream_unauthorized"
    assert request.request_metadata["auth_refresh"]["status"] == "reauth_required"
  end

  defp unauthorized_response(message) do
    FakeUpstream.json_response(
      %{
        "error" => %{
          "code" => "invalid_api_key",
          "message" => message,
          "type" => "invalid_request_error"
        }
      },
      401
    )
  end

  defp oauth_refresh(respond),
    do: FakeUpstream.expect_request(method: "POST", path: "/oauth/token", respond: respond)

  defp expect_dispatch(token, respond) do
    FakeUpstream.expect_request(
      method: "POST",
      path: @upstream_path,
      headers: [required: %{"authorization" => "Bearer #{token}"}],
      respond: respond
    )
  end

  defp store_refresh_token!(identity, plaintext) do
    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(identity, %{
               secret_kind: "refresh_token",
               plaintext: plaintext
             })
  end
end
