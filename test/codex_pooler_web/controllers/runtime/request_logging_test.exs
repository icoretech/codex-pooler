defmodule CodexPoolerWeb.Runtime.RequestLoggingTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Access
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Repo
  alias CodexPoolerWeb.WebsocketConnectionLogger

  require Logger

  @websocket_lifecycle_metadata_keys ~w(
    codex_session_id
    downstream_epoch
    elapsed_ms
    endpoint
    owner_instance_id
    phase
    proxy_instance_id
    reason_class
    request_id
    route_class
    transport
  )

  @websocket_lifecycle_forbidden_terms ~w(
    auth.json
    authorization
    bearer
    cookie
    headers
    idempotency
    payload
    prompt
    upstream_body
    websocket_frame
  )

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

  test "websocket init timeout emits one bounded lifecycle line and no request row" do
    remote_instance_id = "codex_pooler@request-log-init-timeout.example"
    upstream = start_upstream(FakeUpstream.json_response(%{"unexpected" => true}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    {:ok, session} =
      Gateway.start_codex_session(auth, %{
        accepted_turn_state: "stable-ws-request-log-init-timeout",
        owner_instance_id: remote_instance_id
      })

    request_id = "ws-request-log-init-timeout"

    logs =
      capture_websocket_lifecycle_log(fn ->
        assert :ok =
                 WebsocketConnectionLogger.log_init_failed_before_request_reservation(
                   %{
                     request_id: request_id,
                     endpoint: "/backend-api/codex/responses",
                     transport: "websocket",
                     route_class: "proxy_websocket",
                     phase: "init",
                     elapsed_ms: 17,
                     codex_session_id: session.id,
                     owner_instance_id: remote_instance_id,
                     proxy_instance_id: Atom.to_string(node())
                   },
                   :timeout
                 )
      end)

    line =
      assert_websocket_lifecycle_line!(
        logs,
        "websocket init failed before request reservation",
        ~w(codex_session_id elapsed_ms endpoint phase reason_class request_id route_class transport),
        ~w(owner_instance_id proxy_instance_id)
      )

    expected_endpoint = String.replace("/backend-api/codex/responses", ~r/[^a-zA-Z0-9_.:-]+/, "_")
    expected_owner_instance_id = String.replace(remote_instance_id, ~r/[^a-zA-Z0-9_.:-]+/, "_")

    expected_proxy_instance_id =
      String.replace(Atom.to_string(node()), ~r/[^a-zA-Z0-9_.:-]+/, "_")

    assert line =~ "request_id=#{request_id}"
    assert line =~ "endpoint=#{expected_endpoint}"
    assert line =~ "transport=websocket"
    assert line =~ "route_class=proxy_websocket"
    assert line =~ "codex_session_id=#{session.id}"
    assert line =~ "owner_instance_id=#{expected_owner_instance_id}"
    assert line =~ "proxy_instance_id=#{expected_proxy_instance_id}"

    assert [] = Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))
    assert %{items: [], total: 0} = Accounting.list_request_logs(setup.pool)

    assert FakeUpstream.count(upstream) == 0
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

    {conn, query_events} =
      collect_repo_query_events(fn ->
        conn
        |> put_req_header("x-request-id", Ecto.UUID.generate())
        |> auth(setup)
        |> post("/backend-api/codex/responses", %{
          "model" => setup.model.exposed_model_id,
          "input" => input
        })
      end)

    assert %{"id" => "resp_metadata_coalesced"} = json_response(conn, 200)

    assert [request] =
             Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))

    routing = request.request_metadata["routing"]
    assert routing["strategy"]
    assert routing["selected_bridge_candidate_id"] == setup.assignment.id
    assert routing["selected_bridge_candidate_rank"] == 1

    assert request_update_count(query_events) <= 4

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

  defp capture_websocket_lifecycle_log(fun) when is_function(fun, 0) do
    capture_log(
      [
        level: :info,
        format: "$metadata$message\n",
        metadata: @websocket_lifecycle_metadata_keys,
        colors: [enabled: false]
      ],
      fun
    )
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

  defp assert_websocket_lifecycle_line!(logs, message, required_keys, optional_keys) do
    lifecycle_lines =
      logs
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.contains?(&1, message))

    assert [line] = lifecycle_lines

    metadata_text =
      line
      |> String.replace_prefix(message, "")
      |> String.trim_leading()

    metadata_keys =
      metadata_text
      |> String.split(" ", trim: true)
      |> Enum.map(fn token -> token |> String.split("=", parts: 2) |> hd() end)

    assert Enum.all?(metadata_keys, &(&1 in @websocket_lifecycle_metadata_keys))
    assert Enum.all?(required_keys, &(&1 in metadata_keys))
    assert Enum.all?(metadata_keys, &(&1 in (required_keys ++ optional_keys)))
    assert_no_websocket_lifecycle_leaks!(logs)

    line
  end

  defp assert_no_websocket_lifecycle_leaks!(logs) do
    downcased_logs = String.downcase(logs)

    for forbidden_term <- @websocket_lifecycle_forbidden_terms do
      refute downcased_logs =~ forbidden_term
    end
  end
end
