defmodule CodexPoolerWeb.Operations.MetricsControllerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.AccountsFixtures, only: [bootstrap_owner_fixture: 1]

  import CodexPooler.PoolerFixtures,
    only: [
      active_api_key_fixture: 1,
      model_fixture: 2,
      pool_fixture: 0,
      pool_fixture: 1,
      upstream_assignment_fixture: 1
    ]

  import ExUnit.CaptureLog

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Persistence.RoutingCircuitState
  alias CodexPooler.Gateway.Routing.CircuitState
  alias CodexPooler.Gateway.Runtime.Streaming.BufferTelemetry
  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.Settings
  alias CodexPooler.Repo
  alias CodexPooler.RouteClass
  alias CodexPoolerWeb.Telemetry.AdmissionSampler

  defmodule FailingRepo do
    def insert(_struct, _opts),
      do: raise(DBConnection.ConnectionError, message: "settings db unavailable")

    def get!(_schema, _id),
      do: raise(DBConnection.ConnectionError, message: "settings db unavailable")
  end

  setup do
    previous = Application.get_env(:codex_pooler, InstanceSettings, [])
    previous_operational_settings = Application.get_env(:codex_pooler, OperationalSettings)
    Application.put_env(:codex_pooler, InstanceSettings, Keyword.delete(previous, :repo))
    Repo.delete_all(Settings)
    InstanceSettings.reset_cache_for_test()

    on_exit(fn ->
      Application.put_env(:codex_pooler, InstanceSettings, previous)

      if previous_operational_settings do
        Application.put_env(:codex_pooler, OperationalSettings, previous_operational_settings)
      else
        Application.delete_env(:codex_pooler, OperationalSettings)
      end

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

  test "runtime firewall allowlist does not affect metrics or emit a denial observation", %{
    conn: conn
  } do
    event = [:codex_pooler, :ingress, :firewall, :denied]
    handler_id = {__MODULE__, :metrics_firewall_non_interference, self()}
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn ^event, measurements, metadata, ^test_pid ->
          send(test_pid, {handler_id, measurements, metadata})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    Application.put_env(:codex_pooler, OperationalSettings,
      settings: %OperationalSettings{firewall_allowlist: ["203.0.113.10"]},
      use_instance_settings?: false
    )

    conn = Map.put(conn, :remote_ip, {198, 51, 100, 20})

    {conn, log} =
      capture_result_and_log(fn ->
        conn
        |> put_req_header("x-forwarded-for", "198.51.100.20")
        |> get(~p"/metrics")
      end)

    assert conn.status == 200
    assert metrics_content_type?(conn)
    refute_received {^handler_id, _measurements, _metadata}
    refute log =~ "ingress firewall denied"
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

  test "exposes bounded stream outcomes without identifier metadata", %{conn: conn} do
    interrupted_metric =
      ~s(codex_pooler_gateway_stream_outcome_count{downstream_transport="http_sse",outcome="interrupted",upstream_transport="websocket"})

    unknown_metric =
      ~s(codex_pooler_gateway_stream_outcome_count{downstream_transport="unknown",outcome="unknown",upstream_transport="unknown"})

    :telemetry.execute(
      [:codex_pooler, :gateway, :stream, :outcome],
      %{count: 1},
      %{
        outcome: "interrupted",
        downstream_transport: "http_sse",
        upstream_transport: "websocket"
      }
    )

    baseline =
      build_conn()
      |> get(~p"/metrics")
      |> Map.fetch!(:resp_body)

    :telemetry.execute(
      [:codex_pooler, :gateway, :stream, :outcome],
      %{count: 1},
      %{
        outcome: "interrupted",
        downstream_transport: "http_sse",
        upstream_transport: "websocket",
        request_id: "request-identifier",
        upstream_identity_id: "identity-identifier"
      }
    )

    :telemetry.execute(
      [:codex_pooler, :gateway, :stream, :outcome],
      %{count: 1},
      %{
        outcome: "banana",
        downstream_transport: "banana",
        upstream_transport: "banana",
        request_id: "unsafe-request-identifier",
        upstream_identity_id: "unsafe-identity-identifier"
      }
    )

    conn = get(conn, ~p"/metrics")

    assert conn.status == 200

    metric_lines =
      conn.resp_body
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, "codex_pooler_gateway_stream_outcome_count"))

    assert metric_sample(conn.resp_body, interrupted_metric) ==
             metric_sample(baseline, interrupted_metric) + 1

    assert metric_sample(conn.resp_body, unknown_metric) ==
             metric_sample(baseline, unknown_metric) + 1

    for line <- metric_lines do
      refute line =~ "request_id"
      refute line =~ "upstream_identity_id"
      refute line =~ "unsafe-request-identifier"
      refute line =~ "unsafe-identity-identifier"
    end
  end

  @tag :rate_limit_runtime
  test "exports web-node saved-reset convergence metrics with bounded labels only", %{conn: conn} do
    event = [:codex_pooler, :saved_reset, :convergence]
    unsafe_id = Ecto.UUID.generate()

    baseline = get(conn, ~p"/metrics").resp_body

    :telemetry.execute(
      event,
      %{
        count: 1,
        applied_to_canonical_ms: 30_000,
        canonical_to_lifecycle_ms: 30_000,
        applied_to_lifecycle_ms: 60_000
      },
      %{
        source: "runtime_headers",
        outcome: "confirmed_by_quota",
        upstream_identity_id: unsafe_id,
        request_id: "must-not-be-a-label"
      }
    )

    :telemetry.execute(
      event,
      %{count: 1},
      %{source: "unbounded-source", outcome: "unbounded-outcome", account_id: unsafe_id}
    )

    body = get(build_conn(), ~p"/metrics").resp_body

    assert metric_sample(
             body,
             ~s(codex_pooler_saved_reset_convergence_count{outcome="confirmed_by_quota",source="runtime_headers"})
           ) ==
             metric_sample(
               baseline,
               ~s(codex_pooler_saved_reset_convergence_count{outcome="confirmed_by_quota",source="runtime_headers"})
             ) + 1

    assert metric_sample(
             body,
             ~s(codex_pooler_saved_reset_convergence_count{outcome="unknown",source="unknown"})
           ) ==
             metric_sample(
               baseline,
               ~s(codex_pooler_saved_reset_convergence_count{outcome="unknown",source="unknown"})
             ) + 1

    for metric <- ~w(applied_to_canonical canonical_to_lifecycle applied_to_lifecycle) do
      assert body =~ "codex_pooler_saved_reset_convergence_#{metric}_seconds_bucket"
    end

    convergence_lines =
      body
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, "codex_pooler_saved_reset_convergence_"))

    for line <- convergence_lines do
      refute line =~ unsafe_id
      refute line =~ "upstream_identity_id"
      refute line =~ "account_id"
      refute line =~ "request_id"
      refute line =~ "must-not-be-a-label"
      refute line =~ "unbounded-source"
      refute line =~ "unbounded-outcome"
    end

    original_oban_mode = System.get_env("OBAN_MODE")

    on_exit(fn ->
      if original_oban_mode,
        do: System.put_env("OBAN_MODE", original_oban_mode),
        else: System.delete_env("OBAN_MODE")
    end)

    for role <- ~w(worker scheduler) do
      System.put_env("OBAN_MODE", role)
      refute CodexPoolerWeb.Telemetry.prometheus_reporter_enabled?()
    end

    System.put_env("OBAN_MODE", "web")
    assert CodexPoolerWeb.Telemetry.prometheus_reporter_enabled?()
  end

  test "exposes sampler-driven admission saturation with only route class labels", %{
    conn: conn
  } do
    snapshot =
      RouteClass.all()
      |> Map.new(&{&1, %{running: 0, queued: 0}})
      |> Map.put("invalid_route_class", %{running: 99, queued: 99})

    sampler_name = {:global, {:metrics_admission_sampler, System.unique_integer([:positive])}}

    {:ok, sampler} =
      start_supervised(
        {AdmissionSampler,
         name: sampler_name,
         enabled?: true,
         interval_ms: 60_000,
         snapshot_reader: fn -> {:ok, snapshot} end}
      )

    _state = :sys.get_state(sampler)

    saturation_lines =
      conn
      |> get(~p"/metrics")
      |> Map.fetch!(:resp_body)
      |> String.split("\n", trim: true)
      |> Enum.filter(fn line ->
        String.starts_with?(line, "codex_pooler_gateway_admission_") and
          (String.contains?(line, "_running{") or String.contains?(line, "_queued{"))
      end)

    assert length(saturation_lines) == 18

    for line <- saturation_lines do
      assert line =~ ~s(route_class=")
      refute line =~ "request_id"
      refute line =~ "transport="
      refute line =~ "invalid_route_class"
      refute line =~ "99"
    end
  end

  test "exposes bounded bridge telemetry without fallback detail labels", %{conn: conn} do
    owner_busy_metric =
      "codex_pooler_gateway_websocket_bridge_fallback_count{reason=\"owner_busy\"}"

    unknown_metric = "codex_pooler_gateway_websocket_bridge_fallback_count{reason=\"unknown\"}"
    overflow_metric = "codex_pooler_gateway_websocket_bridge_precommit_overflow_count"

    fallback_baselines =
      conn
      |> get(~p"/metrics")
      |> Map.fetch!(:resp_body)
      |> String.split("\n", trim: true)
      |> Enum.reduce(
        %{owner_busy_metric => 0, unknown_metric => 0, overflow_metric => 0},
        fn line, baselines ->
          case String.split(line, " ", parts: 2) do
            [metric, sample] ->
              if Map.has_key?(baselines, metric) do
                Map.put(baselines, metric, String.to_integer(sample))
              else
                baselines
              end

            _other ->
              baselines
          end
        end
      )

    :telemetry.execute(
      [:codex_pooler, :gateway, :websocket_bridge, :fallback],
      %{count: 1},
      %{reason: "owner_busy", request_id: "unsafe-request-identifier"}
    )

    :telemetry.execute(
      [:codex_pooler, :gateway, :websocket_bridge, :fallback],
      %{count: 1},
      %{reason: "provider-specific-reason", upstream_identity_id: "unsafe-identity-identifier"}
    )

    :telemetry.execute(
      [:codex_pooler, :gateway, :websocket_bridge, :precommit_overflow],
      %{count: 1, frames: 65, bytes: 1_048_577},
      %{max_frames: 64, max_bytes: 1_048_576}
    )

    conn = get(build_conn(), ~p"/metrics")

    assert conn.status == 200

    metric_lines =
      conn.resp_body
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, "codex_pooler_gateway_websocket_bridge_"))

    assert "#{owner_busy_metric} #{fallback_baselines[owner_busy_metric] + 1}" in metric_lines

    assert "#{unknown_metric} #{fallback_baselines[unknown_metric] + 1}" in metric_lines

    assert "#{overflow_metric} #{fallback_baselines[overflow_metric] + 1}" in metric_lines

    for line <- metric_lines do
      refute line =~ "frames="
      refute line =~ "bytes="
      refute line =~ "max_frames="
      refute line =~ "max_bytes="
      refute line =~ "request_id"
      refute line =~ "upstream_identity_id"
      refute line =~ "unsafe-request-identifier"
      refute line =~ "unsafe-identity-identifier"
    end
  end

  test "saturates oversized stream-buffer histogram observations without changing raw telemetry",
       %{
         conn: conn
       } do
    event = [:codex_pooler, :gateway, :stream_buffer, :oversized]
    handler_id = {__MODULE__, self(), System.unique_integer([:positive])}
    test_pid = self()
    observed_bytes = 134_217_729

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn ^event, measurements, _metadata, ^test_pid ->
          send(test_pid, {handler_id, measurements})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    finite_bucket =
      ~s(codex_pooler_gateway_stream_buffer_oversized_bytes_bucket{buffer="oversized_saturation",endpoint="saturation_endpoint",route_class="proxy_stream",transport="http_sse",le="134217728"})

    infinite_bucket =
      ~s(codex_pooler_gateway_stream_buffer_oversized_bytes_bucket{buffer="oversized_saturation",endpoint="saturation_endpoint",route_class="proxy_stream",transport="http_sse",le="+Inf"})

    baselines = histogram_bucket_baselines(conn, [finite_bucket, infinite_bucket])

    BufferTelemetry.record_oversized_incomplete(
      "oversized_saturation",
      observed_bytes,
      8_388_608,
      endpoint: "saturation_endpoint",
      route_class: "proxy_stream",
      transport: "http_sse"
    )

    assert_receive {^handler_id, %{bytes: ^observed_bytes, count: 1, max_bytes: 8_388_608}}

    metric_lines =
      build_conn()
      |> get(~p"/metrics")
      |> Map.fetch!(:resp_body)
      |> String.split("\n", trim: true)

    assert "#{finite_bucket} #{baselines[finite_bucket] + 1}" in metric_lines
    assert "#{infinite_bucket} #{baselines[infinite_bucket] + 1}" in metric_lines
    assert baselines[finite_bucket] + 1 == baselines[infinite_bucket] + 1
  end

  test "exports bounded circuit transitions without circuit identity or raw reasons", %{
    conn: conn
  } do
    pool = pool_fixture()
    %{api_key: api_key} = active_api_key_fixture(pool)
    %{assignment: assignment} = upstream_assignment_fixture(pool)

    model =
      model_fixture(pool, %{
        exposed_model_id: "metrics-model-#{System.unique_integer([:positive])}"
      })

    raw_reason = "provider-" <> String.duplicate("x", 71)
    auth = %{pool: pool, api_key: api_key}

    for _failure <- 1..2 do
      assert {:ok, %RoutingCircuitState{status: "closed"}} =
               CircuitState.record_failure(
                 auth,
                 model,
                 assignment,
                 "proxy_stream",
                 raw_reason
               )
    end

    assert {:ok, %RoutingCircuitState{status: "open"}} =
             CircuitState.record_failure(
               auth,
               model,
               assignment,
               "proxy_stream",
               raw_reason
             )

    conn = get(conn, ~p"/metrics")

    assert conn.status == 200

    metric_lines =
      conn.resp_body
      |> String.split("\n", trim: true)
      |> Enum.filter(
        &String.contains?(&1, "codex_pooler_gateway_routing_circuit_transition_count")
      )

    assert Enum.any?(metric_lines, &String.contains?(&1, ~s(transition="closed_to_open")))
    assert Enum.any?(metric_lines, &String.contains?(&1, ~s(route_class="proxy_stream")))
    assert Enum.any?(metric_lines, &String.contains?(&1, ~s(reason_class="unknown")))

    for line <- metric_lines do
      refute line =~ "from_status"
      refute line =~ "to_status"
      refute line =~ "reason_code"
      refute line =~ "failure_count"
    end

    refute conn.resp_body =~ pool.id
    refute conn.resp_body =~ assignment.id
    refute conn.resp_body =~ assignment.upstream_identity_id
    refute conn.resp_body =~ model.exposed_model_id
    refute conn.resp_body =~ raw_reason
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

    {conn, log} = capture_result_and_log(fn -> get(conn, ~p"/metrics") end)

    assert log =~ "instance settings db load failed warm_cache=false"
    assert conn.status == 401
    assert json_response(conn, 401)["error"]["code"] == "metrics_unauthorized"
    assert json_response(conn, 401)["error"]["message"] == "metrics bearer token is unavailable"
  end

  defp capture_result_and_log(fun) do
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

  defp metric_sample(body, metric_name) do
    body
    |> String.split("\n", trim: true)
    |> Enum.find_value(0, fn line ->
      case String.split(line, " ", parts: 2) do
        [^metric_name, sample] -> String.to_integer(sample)
        _other -> nil
      end
    end)
  end

  defp histogram_bucket_baselines(conn, bucket_names) do
    conn
    |> get(~p"/metrics")
    |> Map.fetch!(:resp_body)
    |> String.split("\n", trim: true)
    |> Enum.reduce(Map.new(bucket_names, &{&1, 0}), fn line, baselines ->
      case String.split(line, " ", parts: 2) do
        [metric, sample] when is_map_key(baselines, metric) ->
          Map.put(baselines, metric, String.to_integer(sample))

        _other ->
          baselines
      end
    end)
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
