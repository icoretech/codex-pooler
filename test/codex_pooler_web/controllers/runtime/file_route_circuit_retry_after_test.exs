defmodule CodexPoolerWeb.Runtime.FileRouteCircuitRetryAfterTest do
  # The file route renders the circuit retry advice of the turn routes
  # (findings#206 rows 206-532, 206-548): when open circuits took out every
  # file-bridge assignment, `POST /backend-api/files` answers the retryable
  # `503` with `Retry-After` set to the seconds until the earliest circuit
  # admits a probe, clamped to 1..60, and no `x-should-retry`.
  #
  # One BEAM node, two assignments, FakeUpstream never dispatched to.
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.PoolerFixtures
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport, only: [auth: 2, start_upstream: 1]

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.RoutingCircuitState
  alias CodexPooler.Repo

  @moduletag capture_log: true

  test "every file-bridge assignment circuit-open answers 503 with Retry-After to the earliest probe", %{conn: conn} do
    setup = active_api_key_fixture()
    [first, second] = for index <- [1, 2], do: file_assignment!(setup, index)
    open_file_circuit!(setup, first.assignment, 45)
    open_file_circuit!(setup, second.assignment, 30)

    conn =
      conn
      |> auth(setup)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/backend-api/files", %{"file_name" => "circuit.txt", "file_size" => 12})

    CodexPooler.TestDiagnostics.puts(fn -> "206-548 wire file route: #{conn.status} #{inspect(Enum.filter(conn.resp_headers, fn {name, _value} -> name in ["retry-after", "x-should-retry"] end))} #{conn.resp_body}" end)

    assert %{"error" => %{"code" => "no_eligible_backend"}} = json_response(conn, 503)
    assert [seconds] = get_resp_header(conn, "retry-after")
    assert String.to_integer(seconds) in 25..30
    assert get_resp_header(conn, "x-should-retry") == []
    assert Enum.all?([first, second], &(FakeUpstream.requests(&1.upstream) == []))
  end

  defp file_assignment!(setup, index) do
    upstream = start_upstream(FakeUpstream.file_protocol_success(file_id: "file_circuit_#{index}", file_name: "circuit-#{index}.txt", mime_type: "text/plain"))

    assignment =
      active_upstream_assignment_fixture(setup.pool, %{
        chatgpt_account_id: "acct_file_circuit_#{index}_#{System.unique_integer([:positive])}",
        metadata: %{"base_url" => FakeUpstream.url(upstream)},
        access_token: "file-circuit-token-#{index}"
      })

    %{assignment: assignment.assignment, upstream: upstream}
  end

  defp open_file_circuit!(setup, assignment, probe_in_seconds) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %RoutingCircuitState{
      pool_id: setup.pool.id,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: assignment.upstream_identity_id,
      model_identifier: "backend-api/files",
      route_class: "file_upload",
      status: "open",
      reason_code: "upstream_5xx",
      failure_count: 3,
      success_count: 0,
      opened_at: now,
      last_failure_at: now,
      next_probe_at: DateTime.add(now, probe_in_seconds, :second),
      metadata: %{"probe_in_flight_count" => 0},
      created_at: now,
      updated_at: now
    }
    |> Repo.insert!()
  end
end
