defmodule CodexPooler.Dev.GatewayPerfProbeTest do
  use ExUnit.Case, async: false

  alias CodexPooler.Dev.GatewayPerfProbe

  @script Path.expand("../../../scripts/dev/gateway-perf-sanitize.sh", __DIR__)

  setup do
    :telemetry.detach({GatewayPerfProbe, :telemetry})

    root =
      Path.join(
        System.tmp_dir!(),
        "gateway-perf-probe-test-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(root)
    previous_budget_target = System.get_env("CODEX_POOLER_PERF_BUDGET_TARGET_QPR")
    System.delete_env("CODEX_POOLER_PERF_BUDGET_TARGET_QPR")

    on_exit(fn ->
      :telemetry.detach({GatewayPerfProbe, :telemetry})
      File.rm_rf!(root)

      if previous_budget_target do
        System.put_env("CODEX_POOLER_PERF_BUDGET_TARGET_QPR", previous_budget_target)
      else
        System.delete_env("CODEX_POOLER_PERF_BUDGET_TARGET_QPR")
      end
    end)

    {:ok, root: root}
  end

  test "enabled probe writes metadata-only query, request, memory, and metrics artifacts", %{
    root: root
  } do
    pid = start_supervised!({GatewayPerfProbe, root: root, name: :gateway_perf_probe_test})

    conn =
      Plug.Test.conn("POST", "/backend-api/codex/responses")
      |> Plug.Conn.put_req_header("x-codex-pooler-perf-run-id", "probe-test")
      |> Plug.Conn.put_req_header("x-codex-pooler-perf-scenario", "backend-short-10c")
      |> Plug.Conn.put_req_header("x-gateway-perf-profile", "short-ok")
      |> Plug.Conn.put_req_header("x-codex-pooler-perf-phase", "measured")
      |> Plug.Conn.put_req_header("x-codex-pooler-perf-request-index", "7")
      |> Plug.Conn.put_req_header("x-request-id", "req_probe_test")
      |> Plug.Conn.resp(200, "")

    :telemetry.execute([:phoenix, :endpoint, :start], %{system_time: System.system_time()}, %{
      conn: conn
    })

    :telemetry.execute(
      [:codex_pooler, :repo, :query],
      %{
        query_time: System.convert_time_unit(3, :millisecond, :native),
        queue_time: System.convert_time_unit(1, :millisecond, :native)
      },
      %{
        query: ~s(SELECT * FROM "requests" WHERE prompt = $1),
        params: ["SENTINEL_PROMPT_DO_NOT_LOG"],
        source: "requests"
      }
    )

    :telemetry.execute(
      [:phoenix, :endpoint, :stop],
      %{duration: System.convert_time_unit(25, :millisecond, :native)},
      %{conn: conn}
    )

    assert :ok = GatewayPerfProbe.flush(pid, "probe-test")

    probe_dir = Path.join([root, "probe-test", "probe"])
    assert File.exists?(Path.join(probe_dir, "query-summary.json"))
    assert File.exists?(Path.join(probe_dir, "request-summary.json"))
    assert File.exists?(Path.join(probe_dir, "memory.csv"))
    assert File.exists?(Path.join(probe_dir, "metrics-before.txt"))
    assert File.exists?(Path.join(probe_dir, "metrics-after.txt"))

    query_summary =
      probe_dir |> Path.join("query-summary.json") |> File.read!() |> Jason.decode!()

    request_summary =
      probe_dir |> Path.join("request-summary.json") |> File.read!() |> Jason.decode!()

    assert query_summary["run_id"] == "probe-test"
    assert query_summary["scenario"] == "backend-short-10c"
    assert query_summary["phase"] == "measured"
    assert query_summary["budget_scope"] == "successful_measured_requests"
    assert query_summary["request_count"] == 1
    assert query_summary["query_count_total"] == 1
    assert query_summary["query_count_per_request"] == 1.0
    assert is_number(query_summary["query_count_per_request"])

    assert query_summary["budget_status"] == %{
             "actual_qpr" => 1.0,
             "pass" => true,
             "target_qpr" => 20.0
           }

    assert [%{"command" => "SELECT", "source_table" => "requests"}] =
             query_summary["fingerprints"]

    assert request_summary["request_count"] == 1
    assert request_summary["success_count"] == 1

    assert [request] = request_summary["requests"]
    assert request["request_index"] == 7
    assert request["route_family"] == "backend_codex"
    assert request["route_path"] == "/backend-api/codex/responses"
    assert request["status"] == 200

    all_artifacts =
      Enum.map_join(
        [
          "query-summary.json",
          "request-summary.json",
          "memory.csv",
          "metrics-before.txt",
          "metrics-after.txt"
        ],
        "\n",
        fn file -> File.read!(Path.join(probe_dir, file)) end
      )

    refute all_artifacts =~ "SENTINEL_PROMPT_DO_NOT_LOG"
    refute all_artifacts =~ "WHERE prompt"
  end

  test "backend and v1 success paths summarize query evidence without raw details", %{
    root: root
  } do
    pid = start_supervised!({GatewayPerfProbe, root: root, name: :gateway_perf_probe_matrix_test})

    emit_successful_probe_request(%{
      path: "/backend-api/codex/responses",
      run_id: "probe-matrix-test",
      scenario: "backend-short-10c",
      profile: "short-ok",
      request_id: "req_backend_probe_matrix",
      request_index: "1",
      queries: [
        %{
          query: ~s(SELECT * FROM "requests" WHERE prompt = $1 AND authorization = $2),
          params: ["SENTINEL_PROMPT_DO_NOT_LOG", "Bearer raw-token-do-not-log"],
          source: "requests"
        },
        %{
          query: ~s|INSERT INTO "attempts" (request_body, sql_params) VALUES ($1, $2)|,
          params: [%{"input" => "raw request body"}, ["raw SQL params"]],
          source: "attempts"
        }
      ]
    })

    emit_successful_probe_request(%{
      path: "/v1/responses",
      run_id: "probe-matrix-test",
      scenario: "v1-short-10c",
      profile: "short-ok",
      request_id: "req_v1_probe_matrix",
      request_index: "2",
      queries: [
        %{
          query: ~s(SELECT * FROM "requests" WHERE raw_body = $1),
          params: ["SENTINEL_PROMPT_DO_NOT_LOG"],
          source: "requests"
        }
      ]
    })

    assert :ok = GatewayPerfProbe.flush(pid, "probe-matrix-test")

    probe_dir = Path.join([root, "probe-matrix-test", "probe"])

    query_summary =
      probe_dir |> Path.join("query-summary.json") |> File.read!() |> Jason.decode!()

    request_summary =
      probe_dir |> Path.join("request-summary.json") |> File.read!() |> Jason.decode!()

    assert query_summary["request_count"] == 2
    assert query_summary["measured_request_count"] == 2
    assert query_summary["measured_success_count"] == 2
    assert query_summary["query_count_total"] == 3
    assert query_summary["query_count_per_request"] == 1.5
    assert is_number(query_summary["query_count_per_request"])
    assert query_summary["query_time_ms_total"] > 0
    assert query_summary["route_families"]["backend"]["success_request_count"] == 1
    assert query_summary["route_families"]["backend"]["query_count_per_request"] == 2.0
    assert query_summary["route_families"]["v1"]["success_request_count"] == 1
    assert query_summary["route_families"]["v1"]["query_count_per_request"] == 1.0
    assert query_summary["table_shares"]["requests"] == 0.667
    assert query_summary["table_commands"]["api_keys"]["update_count"] == 0

    assert query_summary["fingerprints"] == [
             %{
               "command" => "INSERT",
               "count" => 1,
               "max_time_ms" => 3.0,
               "source_table" => "attempts",
               "total_time_ms" => 3.0
             },
             %{
               "command" => "SELECT",
               "count" => 2,
               "max_time_ms" => 3.0,
               "source_table" => "requests",
               "total_time_ms" => 6.0
             }
           ]

    assert request_summary["request_count"] == 2
    assert request_summary["success_count"] == 2

    assert Enum.map(request_summary["requests"], & &1["route_family"]) == ["backend_codex", "v1"]

    assert Enum.map(request_summary["requests"], & &1["route_path"]) == [
             "/backend-api/codex/responses",
             "/v1/responses"
           ]

    all_artifacts = read_probe_artifacts!(probe_dir)

    refute all_artifacts =~ "SENTINEL_PROMPT_DO_NOT_LOG"
    refute all_artifacts =~ "Bearer"
    refute all_artifacts =~ "authorization"
    refute all_artifacts =~ "raw-token-do-not-log"
    refute all_artifacts =~ "raw request body"
    refute all_artifacts =~ "request_body"
    refute all_artifacts =~ "raw SQL params"
    refute all_artifacts =~ "sql_params"
    refute all_artifacts =~ "WHERE prompt"
    refute all_artifacts =~ "WHERE raw_body"
    refute all_artifacts =~ "VALUES ($1, $2)"
  end

  test "query budget report exposes target status, route families, table shares, and table commands",
       %{
         root: root
       } do
    previous_target = System.get_env("CODEX_POOLER_PERF_BUDGET_TARGET_QPR")
    System.put_env("CODEX_POOLER_PERF_BUDGET_TARGET_QPR", "3")

    on_exit(fn ->
      if previous_target do
        System.put_env("CODEX_POOLER_PERF_BUDGET_TARGET_QPR", previous_target)
      else
        System.delete_env("CODEX_POOLER_PERF_BUDGET_TARGET_QPR")
      end
    end)

    pid = start_supervised!({GatewayPerfProbe, root: root, name: :gateway_perf_probe_budget_test})

    emit_successful_probe_request(%{
      path: "/backend-api/codex/responses",
      run_id: "probe-budget-test",
      scenario: "short-25c",
      profile: "short-ok",
      request_id: "req_backend_probe_budget",
      request_index: "1",
      queries: [
        query_for("account_quota_windows"),
        query_for("routing_circuit_states"),
        query_for("pool_upstream_assignments"),
        query_for("models")
      ]
    })

    emit_successful_probe_request(%{
      path: "/v1/responses",
      run_id: "probe-budget-test",
      scenario: "short-25c",
      profile: "short-ok",
      request_id: "req_v1_probe_budget",
      request_index: "2",
      queries: [
        %{query: ~s(UPDATE "api_keys" SET last_used_at = $1), params: [], source: "api_keys"},
        query_for("requests"),
        query_for("ledger_entries"),
        query_for("pool_routing_settings")
      ]
    })

    assert :ok = GatewayPerfProbe.flush(pid, "probe-budget-test")

    query_summary =
      root
      |> Path.join("probe-budget-test/probe/query-summary.json")
      |> File.read!()
      |> Jason.decode!()

    assert query_summary["budget_status"] == %{
             "actual_qpr" => 4.0,
             "pass" => false,
             "target_qpr" => 3.0
           }

    assert query_summary["route_families"]["backend"] == %{
             "query_count_per_request" => 4.0,
             "query_count_total" => 4,
             "success_request_count" => 1
           }

    assert query_summary["route_families"]["v1"] == %{
             "query_count_per_request" => 4.0,
             "query_count_total" => 4,
             "success_request_count" => 1
           }

    for table <- [
          "account_quota_windows",
          "routing_circuit_states",
          "api_keys",
          "requests",
          "ledger_entries",
          "pool_upstream_assignments",
          "models",
          "pool_routing_settings"
        ] do
      assert is_number(query_summary["table_shares"][table])
      assert is_integer(query_summary["table_commands"][table]["total_count"])
    end

    assert query_summary["table_shares"]["account_quota_windows"] == 0.125
    assert query_summary["table_shares"]["routing_circuit_states"] == 0.125
    assert query_summary["table_commands"]["api_keys"]["update_count"] == 1
  end

  test "query budget uses successful measured requests and excludes warmup and cooldown", %{
    root: root
  } do
    pid = start_supervised!({GatewayPerfProbe, root: root, name: :gateway_perf_probe_phase_test})

    emit_probe_request(%{
      path: "/backend-api/codex/responses",
      run_id: "probe-phase-test",
      scenario: "warmup-default",
      phase: "warmup",
      profile: "short-ok",
      request_id: "req_warmup_probe_phase",
      request_index: "1",
      status: 200,
      queries: repeated_queries(5, "warmup_queries")
    })

    emit_probe_request(%{
      path: "/backend-api/codex/responses",
      run_id: "probe-phase-test",
      scenario: "short-25c",
      phase: "measured",
      profile: "short-ok",
      request_id: "req_measured_success_probe_phase",
      request_index: "2",
      status: 200,
      queries: repeated_queries(2, "measured_success_queries")
    })

    emit_probe_request(%{
      path: "/backend-api/codex/responses",
      run_id: "probe-phase-test",
      scenario: "short-25c",
      phase: "measured",
      profile: "short-ok",
      request_id: "req_measured_failure_probe_phase",
      request_index: "3",
      status: 500,
      queries: repeated_queries(7, "measured_failure_queries")
    })

    emit_probe_request(%{
      path: "/backend-api/codex/responses",
      run_id: "probe-phase-test",
      scenario: "cooldown-default",
      phase: "cooldown",
      profile: "short-ok",
      request_id: "req_cooldown_probe_phase",
      request_index: "4",
      status: 200,
      queries: repeated_queries(11, "cooldown_queries")
    })

    assert :ok = GatewayPerfProbe.flush(pid, "probe-phase-test")

    probe_dir = Path.join([root, "probe-phase-test", "probe"])

    query_summary =
      probe_dir |> Path.join("query-summary.json") |> File.read!() |> Jason.decode!()

    request_summary =
      probe_dir |> Path.join("request-summary.json") |> File.read!() |> Jason.decode!()

    assert query_summary["scenario"] == "short-25c"
    assert query_summary["phase"] == "measured"
    assert query_summary["budget_phase"] == "measured"
    assert query_summary["budget_scope"] == "successful_measured_requests"
    assert query_summary["all_phase_request_count"] == 4
    assert query_summary["all_phase_query_count_total"] == 25
    assert query_summary["measured_request_count"] == 2
    assert query_summary["measured_success_count"] == 1
    assert query_summary["measured_failure_count"] == 1
    assert query_summary["request_count"] == 1
    assert query_summary["query_count_total"] == 2
    assert query_summary["query_count_per_request"] == 2.0
    assert is_number(query_summary["query_count_per_request"])
    assert query_summary["budget_status"]["actual_qpr"] == 2.0
    assert query_summary["budget_status"]["pass"] == true

    assert [fingerprint] = query_summary["fingerprints"]
    assert fingerprint["count"] == 2
    assert fingerprint["source_table"] == "measured_success_queries"

    assert request_summary["request_count"] == 4
    assert request_summary["success_count"] == 3
    assert request_summary["failure_count"] == 1
    assert request_summary["measured_request_count"] == 2
    assert request_summary["measured_success_count"] == 1
    assert request_summary["measured_failure_count"] == 1
  end

  test "local short-25c dry-run writes top-level measured plan summary without changing scenario contract" do
    run_id = "probe-contract-dry-run-#{System.unique_integer([:positive])}"
    run_dir = Path.join(["tmp", "gateway-perf", run_id])

    on_exit(fn -> File.rm_rf!(run_dir) end)

    assert {output, 0} =
             System.cmd(
               "bash",
               [
                 "scripts/dev/gateway-perf-run.sh",
                 "--scenario",
                 "short-25c",
                 "--run-id",
                 run_id,
                 "--dry-run"
               ],
               stderr_to_stdout: true
             )

    assert output =~ "summary: tmp/gateway-perf/#{run_id}/summary.json"

    scenario_plan = run_dir |> Path.join("scenario.json") |> File.read!() |> Jason.decode!()
    summary = run_dir |> Path.join("summary.json") |> File.read!() |> Jason.decode!()

    assert Enum.map(scenario_plan["plan"], & &1["phase"]) == ["warmup", "measured", "cooldown"]

    assert Enum.map(scenario_plan["plan"], & &1["name"]) == [
             "warmup-default",
             "short-25c",
             "cooldown-default"
           ]

    assert [measured] = Enum.filter(summary["scenarios"], &(&1["phase"] == "measured"))
    assert measured["name"] == "short-25c"
    assert measured["driver_scenario"] == "short-25c"
    assert measured["duration_seconds"] == 120
    assert measured["concurrency"] == 25

    assert summary["scenario_count"] == 3
    assert summary["failed_scenario_count"] == 0
    assert summary["artifact_paths"]["probe"] == "tmp/gateway-perf/#{run_id}/probe"
    assert File.exists?(Path.join(run_dir, "summary.json"))
  end

  test "without a running probe telemetry does not write artifacts", %{root: root} do
    conn =
      Plug.Test.conn("POST", "/backend-api/codex/responses")
      |> Plug.Conn.put_req_header("x-codex-pooler-perf-run-id", "disabled-test")
      |> Plug.Conn.put_req_header("x-codex-pooler-perf-scenario", "backend-short-10c")
      |> Plug.Conn.resp(200, "")

    :telemetry.execute([:phoenix, :endpoint, :start], %{system_time: System.system_time()}, %{
      conn: conn
    })

    :telemetry.execute(
      [:phoenix, :endpoint, :stop],
      %{duration: System.convert_time_unit(10, :millisecond, :native)},
      %{conn: conn}
    )

    refute File.exists?(Path.join([root, "disabled-test", "probe"]))
  end

  test "sanitizer exits zero for clean artifacts and nonzero for sentinel or log token leakage",
       %{
         root: root
       } do
    clean_dir = Path.join(root, "clean-run")
    dirty_dir = Path.join(root, "dirty-run")
    dirty_log_dir = Path.join(root, "dirty-log-run")
    File.mkdir_p!(Path.join(clean_dir, "probe"))
    File.mkdir_p!(Path.join(dirty_dir, "probe"))
    File.mkdir_p!(Path.join(dirty_log_dir, "logs"))

    File.write!(Path.join([clean_dir, "probe", "request-summary.json"]), ~s({"run_id":"clean"}))

    File.write!(
      Path.join([dirty_dir, "probe", "request-summary.json"]),
      "SENTINEL_PROMPT_DO_NOT_LOG"
    )

    File.write!(
      Path.join([dirty_log_dir, "logs", "perf-seed.log"]),
      "metrics token dev-perf-metrics-synthetic-leak"
    )

    assert {clean_output, 0} = System.cmd("bash", [@script, clean_dir], stderr_to_stdout: true)
    assert clean_output =~ "ok"

    assert {dirty_output, 1} = System.cmd("bash", [@script, dirty_dir], stderr_to_stdout: true)
    assert dirty_output =~ "request-summary.json"

    assert {dirty_log_output, 1} =
             System.cmd("bash", [@script, dirty_log_dir], stderr_to_stdout: true)

    assert dirty_log_output =~ "perf-seed.log"
  end

  defp emit_successful_probe_request(%{} = attrs) do
    attrs = Map.put_new(attrs, :phase, "measured")
    emit_probe_request(Map.put_new(attrs, :status, 200))
  end

  defp emit_probe_request(%{} = attrs) do
    conn =
      Plug.Test.conn("POST", attrs.path)
      |> Plug.Conn.put_req_header("x-codex-pooler-perf-run-id", attrs.run_id)
      |> Plug.Conn.put_req_header("x-codex-pooler-perf-scenario", attrs.scenario)
      |> Plug.Conn.put_req_header("x-codex-pooler-perf-profile", attrs.profile)
      |> Plug.Conn.put_req_header("x-codex-pooler-perf-phase", attrs.phase)
      |> Plug.Conn.put_req_header("x-codex-pooler-perf-request-index", attrs.request_index)
      |> Plug.Conn.put_req_header("x-request-id", attrs.request_id)
      |> Plug.Conn.resp(attrs.status, "")

    :telemetry.execute([:phoenix, :endpoint, :start], %{system_time: System.system_time()}, %{
      conn: conn
    })

    Enum.each(attrs.queries, fn metadata ->
      :telemetry.execute(
        [:codex_pooler, :repo, :query],
        %{
          query_time: System.convert_time_unit(3, :millisecond, :native),
          queue_time: System.convert_time_unit(1, :millisecond, :native)
        },
        metadata
      )
    end)

    :telemetry.execute(
      [:phoenix, :endpoint, :stop],
      %{duration: System.convert_time_unit(25, :millisecond, :native)},
      %{conn: conn}
    )
  end

  defp query_for(source) do
    %{
      query: ~s(SELECT * FROM "#{source}"),
      params: [],
      source: source
    }
  end

  defp repeated_queries(count, source) do
    Enum.map(1..count, fn _index ->
      %{
        query: ~s(SELECT * FROM "#{source}"),
        params: [],
        source: source
      }
    end)
  end

  defp read_probe_artifacts!(probe_dir) do
    Enum.map_join(
      [
        "query-summary.json",
        "request-summary.json",
        "memory.csv",
        "metrics-before.txt",
        "metrics-after.txt"
      ],
      "\n",
      fn file -> File.read!(Path.join(probe_dir, file)) end
    )
  end
end
