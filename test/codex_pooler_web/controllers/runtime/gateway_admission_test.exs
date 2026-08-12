defmodule CodexPoolerWeb.Runtime.GatewayAdmissionTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Transports.Admission

  setup do
    old_config = Application.get_env(:codex_pooler, OperationalSettings)
    Admission.reset_for_test()
    Application.put_env(:codex_pooler, OperationalSettings, settings: settings())

    on_exit(fn ->
      Admission.reset_for_test()

      if old_config do
        Application.put_env(:codex_pooler, OperationalSettings, old_config)
      else
        Application.delete_env(:codex_pooler, OperationalSettings)
      end
    end)
  end

  test "overloaded proxy lane returns sanitized JSON while browser lane still passes", %{
    conn: conn
  } do
    setup = active_api_key_fixture()
    assert {:ok, lease} = Admission.acquire("proxy_http", %{request_id: "held-proxy"})

    conn =
      conn
      |> put_req_header("authorization", setup.authorization)
      |> post(~p"/backend-api/codex/responses", %{
        "model" => "gpt-test",
        "input" => "private prompt must not leak"
      })

    assert %{"error" => error} = json_response(conn, 503)
    assert error["code"] == "service_unavailable"
    assert error["message"] == "gemma3 is temporarily unavailable"
    refute inspect(error) =~ "private prompt"
    refute inspect(error) =~ setup.authorization

    browser_conn = get(build_conn(), ~p"/session?optional=1")
    assert %{"authenticated" => false} = json_response(browser_conn, 200)

    Admission.release(lease)
  end

  defp settings do
    %OperationalSettings{
      bulkheads:
        Map.new(Admission.route_classes(), fn route_class ->
          {route_class, %{max_concurrency: 4, queue_limit: 4, queue_timeout_ms: 1_000}}
        end)
        |> Map.put("proxy_http", %{max_concurrency: 1, queue_limit: 0, queue_timeout_ms: 1_000})
    }
  end
end
