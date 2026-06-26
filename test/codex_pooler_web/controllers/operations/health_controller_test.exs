defmodule CodexPoolerWeb.Operations.HealthControllerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias CodexPooler.Accounting.Request
  alias CodexPooler.Gateway.Transports.Websocket.RolloutDrain
  alias CodexPooler.Repo

  setup do
    previous_config =
      Application.get_env(:codex_pooler, CodexPoolerWeb.Operations.HealthController)

    previous_rollout_drain_config = Application.get_env(:codex_pooler, RolloutDrain)

    on_exit(fn ->
      if previous_config do
        Application.put_env(
          :codex_pooler,
          CodexPoolerWeb.Operations.HealthController,
          previous_config
        )
      else
        Application.delete_env(:codex_pooler, CodexPoolerWeb.Operations.HealthController)
      end

      if previous_rollout_drain_config do
        Application.put_env(:codex_pooler, RolloutDrain, previous_rollout_drain_config)
      else
        Application.delete_env(:codex_pooler, RolloutDrain)
      end
    end)
  end

  test "GET /healthz returns a lightweight liveness response", %{conn: conn} do
    conn = get(conn, ~p"/healthz")

    assert json_response(conn, 200) == %{"status" => "ok"}
  end

  test "GET /readyz verifies database readiness", %{conn: conn} do
    conn = get(conn, ~p"/readyz")

    assert json_response(conn, 200) == %{"status" => "ready"}
  end

  test "GET /readyz stays ready when configured drain marker is absent", %{conn: conn} do
    drain_marker_path = drain_marker_path()

    Application.put_env(:codex_pooler, CodexPoolerWeb.Operations.HealthController,
      drain_marker_path: drain_marker_path,
      readiness_probe: __MODULE__.AvailableReadinessProbe
    )

    conn = get(conn, ~p"/readyz")

    assert json_response(conn, 200) == %{"status" => "ready"}
    assert_receive :available_readiness_probe_called
  end

  test "GET /readyz returns unavailable while drain marker exists without probing DB", %{
    conn: conn
  } do
    drain_marker_path = drain_marker_path()
    File.write!(drain_marker_path, "draining")
    on_exit(fn -> File.rm(drain_marker_path) end)

    Application.put_env(:codex_pooler, CodexPoolerWeb.Operations.HealthController,
      drain_marker_path: drain_marker_path,
      readiness_probe: __MODULE__.UnexpectedReadinessProbe
    )

    {conn, log} = with_log([level: :info], fn -> get(conn, ~p"/readyz") end)

    assert json_response(conn, 503) == %{"status" => "unavailable"}
    refute log =~ "readiness probe failed"
    refute_received :unexpected_readiness_probe_called
  end

  test "GET /readyz returns unavailable while runtime rollout drain is active without marker",
       %{conn: conn} do
    drain_name = :"health-rollout-drain-#{System.unique_integer([:positive])}"
    start_supervised!({RolloutDrain, name: drain_name})
    Application.put_env(:codex_pooler, RolloutDrain, server_name: drain_name)

    Application.put_env(:codex_pooler, CodexPoolerWeb.Operations.HealthController,
      drain_marker_path: drain_marker_path(),
      readiness_probe: __MODULE__.UnexpectedReadinessProbe
    )

    assert %{result: :ok, owners_seen: 0} =
             RolloutDrain.start_drain(name: drain_name, timeout_ms: 100)

    {conn, log} = with_log([level: :info], fn -> get(conn, ~p"/readyz") end)

    assert json_response(conn, 503) == %{"status" => "unavailable"}
    refute log =~ "readiness probe failed"
    refute_received :unexpected_readiness_probe_called
  end

  test "healthy probes disable endpoint info request logging and request rows", %{conn: conn} do
    before_count = Repo.aggregate(Request, :count)

    events =
      capture_endpoint_log_decisions(fn ->
        conn |> get(~p"/healthz") |> json_response(200)
        conn |> recycle() |> get(~p"/readyz") |> json_response(200)
      end)

    assert length(events) == 4
    assert Enum.all?(events, &(&1.log_level == false))

    assert Enum.map(events, & &1.path) |> Enum.sort() == [
             "/healthz",
             "/healthz",
             "/readyz",
             "/readyz"
           ]

    assert Repo.aggregate(Request, :count) == before_count
  end

  test "readiness failures emit sanitized warning and no accounting request row", %{conn: conn} do
    Application.put_env(:codex_pooler, CodexPoolerWeb.Operations.HealthController,
      readiness_probe: __MODULE__.UnavailableReadinessProbe
    )

    before_count = Repo.aggregate(Request, :count)

    {conn, log} =
      with_log([level: :info], fn ->
        get(conn, ~p"/readyz")
      end)

    assert json_response(conn, 503) == %{"status" => "unavailable"}
    assert log =~ "readiness probe failed path=/readyz reason_class=RuntimeError"
    refute log =~ "database refused example-secret"
    refute log =~ "GET /readyz"
    refute log =~ "Sent 503"
    assert Repo.aggregate(Request, :count) == before_count
  end

  test "non-health runtime requests keep endpoint info logging", %{conn: conn} do
    events =
      capture_endpoint_log_decisions(fn ->
        conn |> get(~p"/backend-api/codex/models") |> response(401)
      end)

    assert length(events) == 2
    assert Enum.all?(events, &(&1.path == "/backend-api/codex/models"))
    assert Enum.all?(events, &(&1.log_level == :info))
  end

  defp capture_endpoint_log_decisions(fun) do
    test_pid = self()
    handler_id = {__MODULE__, test_pid, System.unique_integer([:positive])}

    :ok =
      :telemetry.attach_many(
        handler_id,
        [[:phoenix, :endpoint, :start], [:phoenix, :endpoint, :stop]],
        fn event, _measurements, metadata, destination ->
          send(
            destination,
            {:endpoint_log_decision, event, metadata.conn.request_path,
             endpoint_log_level(metadata)}
          )
        end,
        test_pid
      )

    try do
      fun.()
      collect_endpoint_log_decisions([])
    after
      :telemetry.detach(handler_id)
    end
  end

  defp collect_endpoint_log_decisions(events) do
    receive do
      {:endpoint_log_decision, event, path, log_level} ->
        collect_endpoint_log_decisions([
          %{event: event, path: path, log_level: log_level} | events
        ])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp endpoint_log_level(%{options: options, conn: conn}) do
    case Keyword.fetch!(options, :log) do
      {module, function, args} -> apply(module, function, [conn | args])
      level -> level
    end
  end

  defp drain_marker_path do
    Path.join(
      System.tmp_dir!(),
      "codex-pooler-drain-#{System.unique_integer([:positive])}"
    )
  end

  defmodule AvailableReadinessProbe do
    def query(_repo, _statement, _params, _opts) do
      send(self(), :available_readiness_probe_called)
      {:ok, %{}}
    end
  end

  defmodule UnexpectedReadinessProbe do
    def query(_repo, _statement, _params, _opts) do
      send(self(), :unexpected_readiness_probe_called)
      raise "drain marker should short-circuit readiness probe"
    end
  end

  defmodule UnavailableReadinessProbe do
    def query(_repo, _statement, _params, _opts) do
      {:error, %RuntimeError{message: "database refused example-secret"}}
    end
  end
end
