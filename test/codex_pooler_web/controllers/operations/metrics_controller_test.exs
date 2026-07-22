defmodule CodexPoolerWeb.Operations.MetricsControllerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.AccountsFixtures, only: [bootstrap_owner_fixture: 1]
  import CodexPooler.PoolerFixtures, only: [pool_fixture: 1]
  import ExUnit.CaptureLog

  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.Settings
  alias CodexPooler.Repo

  defmodule FailingRepo do
    def insert(_struct, _opts),
      do: raise(DBConnection.ConnectionError, message: "settings db unavailable")

    def get!(_schema, _id),
      do: raise(DBConnection.ConnectionError, message: "settings db unavailable")
  end

  setup do
    previous = Application.get_env(:codex_pooler, InstanceSettings, [])
    Application.put_env(:codex_pooler, InstanceSettings, Keyword.delete(previous, :repo))
    Repo.delete_all(Settings)
    InstanceSettings.reset_cache_for_test()

    on_exit(fn ->
      Application.put_env(:codex_pooler, InstanceSettings, previous)
      InstanceSettings.reset_cache_for_test()
    end)

    :ok
  end

  test "allows open metrics access when bearer token is intentionally unset", %{conn: conn} do
    conn = get(conn, ~p"/metrics")

    assert conn.status == 200
    assert metrics_content_type?(conn)
  end

  test "allows open metrics access when a configured bearer token is cleared", %{conn: conn} do
    configure_metrics_token!("metrics-secret")

    assert {:ok, _updated} =
             InstanceSettings.update_system_settings(
               InstanceSettings.get!(),
               InstanceSettings.clear_metrics_bearer_token(%{})
             )

    conn = get(conn, ~p"/metrics")

    assert conn.status == 200
    assert metrics_content_type?(conn)
  end

  test "rejects metrics access when configured bearer token is missing", %{conn: conn} do
    configure_metrics_token!("metrics-secret")

    conn = get(conn, ~p"/metrics")

    assert conn.status == 401
    assert json_response(conn, 401)["error"]["code"] == "metrics_unauthorized"
  end

  test "rejects metrics access when configured bearer token is wrong", %{conn: conn} do
    configure_metrics_token!("metrics-secret")

    conn =
      conn
      |> put_req_header("authorization", "Bearer wrong-secret")
      |> get(~p"/metrics")

    assert conn.status == 401
    assert json_response(conn, 401)["error"]["code"] == "metrics_unauthorized"
  end

  test "allows metrics access with the configured bearer token", %{conn: conn} do
    configure_metrics_token!("metrics-secret")

    conn =
      conn
      |> put_req_header("authorization", "Bearer metrics-secret")
      |> get(~p"/metrics")

    assert conn.status == 200
    assert metrics_content_type?(conn)
  end

  test "exposes admin stats metrics through an authorized scrape without unsafe labels", %{
    conn: conn
  } do
    %{user: user} =
      bootstrap_owner_fixture(%{
        "email" => "metrics-owner-#{System.unique_integer([:positive])}@example.com"
      })

    pool = pool_fixture(%{created_by_user_id: user.id})
    duration = System.convert_time_unit(15, :millisecond, :native)

    :telemetry.execute(
      [:codex_pooler, :admin, :stats_live, :reload],
      %{count: 1},
      %{stage: :scheduled, window: "24h", scope: "selected_pool", pid: self(), pool_id: pool.id}
    )

    :telemetry.execute(
      [:codex_pooler, :admin, :stats, :dashboard, :build],
      %{count: 1, duration: duration},
      %{outcome: :ok, window: "24h", scope: "selected_pool", user_id: user.id}
    )

    conn = get(conn, ~p"/metrics")

    assert conn.status == 200
    assert metrics_content_type?(conn)

    admin_stats_lines = admin_stats_metric_lines(conn.resp_body)

    assert Enum.any?(
             admin_stats_lines,
             &String.contains?(&1, "codex_pooler_admin_stats_reload_count")
           )

    assert Enum.any?(
             admin_stats_lines,
             &String.contains?(&1, "codex_pooler_admin_stats_dashboard_build_count")
           )

    assert Enum.any?(
             admin_stats_lines,
             &String.contains?(
               &1,
               "codex_pooler_admin_stats_dashboard_build_duration_seconds_bucket"
             )
           )

    assert Enum.any?(admin_stats_lines, &String.contains?(&1, ~s(stage="scheduled")))
    assert Enum.any?(admin_stats_lines, &String.contains?(&1, ~s(outcome="ok")))
    assert Enum.any?(admin_stats_lines, &String.contains?(&1, ~s(window="24h")))
    assert Enum.any?(admin_stats_lines, &String.contains?(&1, ~s(scope="selected_pool")))

    for line <- admin_stats_lines do
      refute line =~ "pid="
      refute line =~ pool.id
      refute line =~ user.id
    end
  end

  test "exports bounded stream finalization and quota cycle decision metrics", %{conn: conn} do
    :telemetry.execute(
      [:codex_pooler, :gateway, :stream, :finalization],
      %{count: 1},
      %{
        usage_status: "usage_known",
        usage_source: "upstream_usage",
        downstream_transport: "http_sse",
        upstream_transport: "websocket",
        request_id: "must-not-be-a-label"
      }
    )

    :telemetry.execute(
      [:codex_pooler, :quota, :cycle, :decision],
      %{count: 1},
      %{
        scope: "account",
        decision: :same_cycle_refreshed,
        source: "provider_usage",
        upstream_identity_id: "must-not-be-a-label"
      }
    )

    conn = get(conn, ~p"/metrics")

    assert conn.status == 200

    metric_lines =
      conn.resp_body
      |> String.split("\n", trim: true)
      |> Enum.filter(
        &(String.contains?(&1, "codex_pooler_gateway_stream_finalization_count") or
            String.contains?(&1, "codex_pooler_quota_cycle_decision_count"))
      )

    assert Enum.any?(metric_lines, &String.contains?(&1, ~s(usage_status="usage_known")))
    assert Enum.any?(metric_lines, &String.contains?(&1, ~s(usage_source="upstream_usage")))
    assert Enum.any?(metric_lines, &String.contains?(&1, ~s(downstream_transport="http_sse")))
    assert Enum.any?(metric_lines, &String.contains?(&1, ~s(upstream_transport="websocket")))
    assert Enum.any?(metric_lines, &String.contains?(&1, ~s(scope="account")))
    assert Enum.any?(metric_lines, &String.contains?(&1, ~s(decision="same_cycle_refreshed")))
    assert Enum.any?(metric_lines, &String.contains?(&1, ~s(source="provider_usage")))

    for line <- metric_lines do
      refute line =~ "request_id"
      refute line =~ "upstream_identity_id"
      refute line =~ "must-not-be-a-label"
    end
  end

  test "rotating the metrics bearer token invalidates the old bearer", %{conn: conn} do
    configure_metrics_token!("metrics-secret-v1")
    configure_metrics_token!("metrics-secret-v2")

    rejected =
      conn
      |> put_req_header("authorization", "Bearer metrics-secret-v1")
      |> get(~p"/metrics")

    assert rejected.status == 401
    assert json_response(rejected, 401)["error"]["code"] == "metrics_unauthorized"

    allowed =
      build_conn()
      |> put_req_header("authorization", "Bearer metrics-secret-v2")
      |> get(~p"/metrics")

    assert allowed.status == 200
    assert metrics_content_type?(allowed)
  end

  test "fails closed when metrics settings are unavailable", %{conn: conn} do
    Application.put_env(:codex_pooler, InstanceSettings, repo: FailingRepo)
    InstanceSettings.reset_cache_for_test()

    {conn, log} = with_instance_settings_db_failure_log(fn -> get(conn, ~p"/metrics") end)

    assert log =~ "instance settings db load failed warm_cache=false"
    assert conn.status == 401
    assert json_response(conn, 401)["error"]["code"] == "metrics_unauthorized"
    assert json_response(conn, 401)["error"]["message"] == "metrics bearer token is unavailable"
  end

  defp with_instance_settings_db_failure_log(fun) do
    ref = make_ref()

    log =
      capture_log(fn ->
        send(self(), {ref, fun.()})
      end)

    assert_received {^ref, result}
    {result, log}
  end

  defp admin_stats_metric_lines(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.contains?(&1, "codex_pooler_admin_stats_"))
  end

  defp metrics_content_type?(conn) do
    conn
    |> get_resp_header("content-type")
    |> List.first()
    |> String.starts_with?("text/plain")
  end

  defp configure_metrics_token!(token) do
    settings = InstanceSettings.ensure_singleton!()

    assert {:ok, _updated} =
             InstanceSettings.update_system_settings(
               settings,
               InstanceSettings.put_metrics_bearer_token(%{}, token)
             )
  end
end
