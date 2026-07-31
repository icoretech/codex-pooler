defmodule CodexPoolerWeb.Runtime.RequestLoggingTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Repo

  setup do
    previous_level = Logger.level()

    previous_owner_forwarding =
      Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)

    Logger.configure(level: :info)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)
    CodexPoolerWeb.RequestLogger.attach()

    on_exit(fn ->
      Logger.configure(level: previous_level)

      case previous_owner_forwarding do
        nil -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
        value -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
      end
    end)

    :ok
  end

  test "runtime request logging is one-line metadata-only and includes production fields", %{
    conn: conn
  } do
    log =
      capture_log([level: :info], fn ->
        conn
        |> put_req_header("user-agent", "Codex CLI/1.2.3")
        |> get(~p"/backend-api/codex/models")
        |> response(401)
      end)

    lines =
      log
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.contains?(&1, "request_completed"))

    assert [line] = lines
    assert line =~ "request_completed"
    assert line =~ "method=GET"
    assert line =~ "path=/backend-api/codex/models"
    assert line =~ "status=401"
    assert line =~ "duration_ms="
    assert line =~ "remote_ip="
    assert line =~ ~s(user_agent="Codex CLI/1.2.3")
    assert log =~ "request_id="
    assert length(Regex.scan(~r/request_id=/, line)) == 1
    refute log =~ "GET /backend-api/codex/models"
    refute log =~ "Sent 401"
  end

  test "runtime request logging sanitizes multiline control user agents and ignores untrusted forwarded IP",
       %{conn: conn} do
    malicious_user_agent = "Codex\nInjected-Header: secret-token\r\nsecond-line\ttrail"

    log =
      capture_log([level: :info], fn ->
        conn
        |> Map.put(:remote_ip, {198, 51, 100, 20})
        |> put_req_header("x-forwarded-for", "203.0.113.55")
        |> put_req_header("user-agent", malicious_user_agent)
        |> get(~p"/backend-api/codex/models")
        |> response(401)
      end)

    assert [line] =
             log
             |> String.split("\n", trim: true)
             |> Enum.filter(&String.contains?(&1, "request_completed"))

    assert line =~ "remote_ip=198.51.100.20"
    assert line =~ ~s(user_agent="Codex Injected-Header: secret-token second-line trail")
    refute line =~ "203.0.113.55"
    refute line =~ "\n"
    refute line =~ "\r"
    refute log =~ "Injected-Header: secret-token\n"
  end

  test "request logging uses forwarded IPs from trusted proxies on browser routes", %{conn: conn} do
    setup_trusted_proxies(["10.42.0.0/16"])

    log =
      capture_log([level: :info], fn ->
        conn
        |> Map.put(:remote_ip, {10, 42, 0, 50})
        |> put_req_header("x-forwarded-for", "203.0.113.55, 10.42.0.50")
        |> get(~p"/login")
        |> response(302)
      end)

    assert [line] =
             log
             |> String.split("\n", trim: true)
             |> Enum.filter(&String.contains?(&1, "request_completed"))

    assert line =~ "path=/login"
    assert line =~ "remote_ip=203.0.113.55"
    refute line =~ "10.42.0.50"
  end

  test "healthy backend response coalesces routing request metadata writes", %{conn: conn} do
    input = "metadata coalescing input #{System.unique_integer([:positive])}"

    upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_metadata_coalesced",
          "object" => "response",
          "usage" => %{"input_tokens" => 2, "output_tokens" => 1, "total_tokens" => 3}
        })
      )

    setup = gateway_setup(upstream)

    {{conn, query_events}, _log} =
      with_log([level: :info], fn ->
        collect_repo_query_events(fn ->
          conn
          |> put_req_header("x-request-id", Ecto.UUID.generate())
          |> auth(setup)
          |> post("/backend-api/codex/responses", %{
            "model" => setup.model.exposed_model_id,
            "input" => input
          })
        end)
      end)

    assert %{"id" => "resp_metadata_coalesced"} = json_response(conn, 200)

    assert [request] =
             Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))

    routing = request.request_metadata["routing"]
    assert routing["strategy"]
    assert routing["selected_bridge_candidate_id"] == setup.assignment.id
    assert routing["selected_bridge_candidate_rank"] == 1

    assert request_update_count(query_events) <= 3

    metadata_text = inspect(request.request_metadata)
    refute metadata_text =~ input
    refute metadata_text =~ setup.authorization
  end

  defp setup_trusted_proxies(trusted_proxies) do
    previous = Application.get_env(:codex_pooler, OperationalSettings, [])

    Application.put_env(
      :codex_pooler,
      OperationalSettings,
      previous
      |> Keyword.put(:settings, %OperationalSettings{trusted_proxies: trusted_proxies})
      |> Keyword.put(:use_instance_settings?, false)
    )

    on_exit(fn -> Application.put_env(:codex_pooler, OperationalSettings, previous) end)
  end

  defp collect_repo_query_events(fun) when is_function(fun, 0) do
    handler_id = {__MODULE__, self(), System.unique_integer([:positive])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        &__MODULE__.handle_repo_query_event/4,
        {handler_id, self()}
      )

    try do
      result = fun.()
      {result, drain_repo_query_events(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  def handle_repo_query_event(_event, _measurements, metadata, {handler_id, test_pid}) do
    if metadata[:repo] == Repo do
      send(test_pid, {handler_id, metadata[:source], query_command(metadata[:query])})
    end
  end

  defp drain_repo_query_events(handler_id, events) do
    receive do
      {^handler_id, source, command} ->
        drain_repo_query_events(handler_id, [{source, command} | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp request_update_count(events) do
    Enum.count(events, fn {source, command} -> source == "requests" and command == "UPDATE" end)
  end

  defp query_command(query) when is_binary(query) do
    query
    |> String.trim_leading()
    |> String.split(~r/\s+/, parts: 2)
    |> List.first()
    |> String.upcase()
  end

  defp query_command(_query), do: "UNKNOWN"
end
