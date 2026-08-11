defmodule CodexPoolerWeb.Runtime.GatewayAdmissionTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Transports.Admission
  alias CodexPooler.Repo

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

  test "overloaded proxy HTTP and SSE lanes use the Codex overload vocabulary while browser lane still passes",
       %{
         conn: conn
       } do
    setup = active_api_key_fixture()

    for stream? <- [false, true] do
      route_class = if stream?, do: "proxy_stream", else: "proxy_http"
      assert {:ok, lease} = Admission.acquire(route_class, %{request_id: "held-#{route_class}"})

      response =
        conn
        |> recycle()
        |> put_req_header("authorization", setup.authorization)
        |> post(~p"/backend-api/codex/responses", %{
          "model" => "gpt-test",
          "input" => "private prompt must not leak",
          "stream" => stream?
        })

      assert %{"error" => error} = json_response(response, 503)

      assert error == %{
               "code" => "server_is_overloaded",
               "message" => "gateway route class is temporarily overloaded",
               "param" => nil,
               "type" => "server_error"
             }

      refute inspect(error) =~ "private prompt"
      refute inspect(error) =~ setup.authorization
      assert Repo.aggregate(Request, :count) == 0
      assert Repo.aggregate(Attempt, :count) == 0
      assert Repo.aggregate(LedgerEntry, :count) == 0

      Admission.release(lease)
    end

    browser_conn = get(build_conn(), ~p"/session?optional=1")
    assert %{"authenticated" => false} = json_response(browser_conn, 200)
  end

  test "queued proxy requests retain their timeout reason internally while exposing the same overload vocabulary",
       %{conn: conn} do
    Application.put_env(:codex_pooler, OperationalSettings, settings: queued_settings())
    setup = active_api_key_fixture()
    assert {:ok, lease} = Admission.acquire("proxy_http", %{request_id: "held-proxy"})

    response =
      conn
      |> put_req_header("authorization", setup.authorization)
      |> post(~p"/backend-api/codex/responses", %{
        "model" => "gpt-test",
        "input" => "bounded queue timeout"
      })

    assert %{"error" => error} = json_response(response, 503)

    assert error == %{
             "code" => "server_is_overloaded",
             "message" => "gateway route class is temporarily overloaded",
             "param" => nil,
             "type" => "server_error"
           }

    assert {:error,
            %{
              code: "server_is_overloaded",
              internal_reason: "bulkhead_queue_timeout",
              accounting_disposition: :zero_work
            }} =
             Admission.run("proxy_http", %{request_id: "post-timeout"}, fn -> :ok end)

    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
    assert Repo.aggregate(LedgerEntry, :count) == 0

    Admission.release(lease)
  end

  defp settings do
    %OperationalSettings{
      bulkheads:
        Map.new(Admission.route_classes(), fn route_class ->
          {route_class, %{max_concurrency: 4, queue_limit: 4, queue_timeout_ms: 1_000}}
        end)
        |> Map.put("proxy_http", %{max_concurrency: 1, queue_limit: 0, queue_timeout_ms: 1_000})
        |> Map.put("proxy_stream", %{max_concurrency: 1, queue_limit: 0, queue_timeout_ms: 1_000})
    }
  end

  defp queued_settings do
    %OperationalSettings{
      bulkheads:
        settings().bulkheads
        |> Map.put("proxy_http", %{max_concurrency: 1, queue_limit: 1, queue_timeout_ms: 25})
    }
  end
end
