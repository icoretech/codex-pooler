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

    on_exit(fn ->
      :telemetry.detach({GatewayPerfProbe, :telemetry})
      File.rm_rf!(root)
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
    assert query_summary["query_count_total"] == 1

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

    assert query_summary["query_count_total"] == 3
    assert query_summary["query_count_per_request"] > 0
    assert query_summary["query_time_ms_total"] > 0

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
    conn =
      Plug.Test.conn("POST", attrs.path)
      |> Plug.Conn.put_req_header("x-codex-pooler-perf-run-id", attrs.run_id)
      |> Plug.Conn.put_req_header("x-codex-pooler-perf-scenario", attrs.scenario)
      |> Plug.Conn.put_req_header("x-codex-pooler-perf-profile", attrs.profile)
      |> Plug.Conn.put_req_header("x-codex-pooler-perf-request-index", attrs.request_index)
      |> Plug.Conn.put_req_header("x-request-id", attrs.request_id)
      |> Plug.Conn.resp(200, "")

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
