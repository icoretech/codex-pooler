defmodule CodexPoolerWeb.Runtime.RuntimeDatabaseUnavailableTest do
  # A transient database failure before anything was admitted, reserved or sent
  # used to escape as an exception and render a 500, which the Codex client shows
  # as "We're currently experiencing high demand". Production met it on every
  # PostgreSQL restart (authentication is the first query of every runtime
  # request) and behind a migration's table locks (the reservation transaction).
  # Both now answer a retryable 503 that names no database detail
  # (findings#206 row 206-358). One node, HTTP; the websocket upgrade is refused
  # by the same authentication before it happens.
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, native_text_input: 1, start_upstream: 1]

  import Ecto.Query

  alias CodexPooler.Accounting.{LedgerEntry, Request}
  alias CodexPooler.CompatibilityMatrix
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  @unavailable_body %{
    "error" => %{
      "type" => "server_error",
      "code" => "service_unavailable",
      "param" => nil,
      "message" => "Codex Pooler is temporarily unavailable; retry the request"
    }
  }

  describe "authentication cannot reach the database" do
    setup do
      upstream = start_upstream(FakeUpstream.json_response(%{}))
      setup = gateway_setup(upstream)
      unavailable = hold_unavailable_repo!()
      %{setup: setup, upstream: upstream, unavailable: unavailable}
    end

    test "the Codex model catalog answers a retryable 503", %{conn: conn} = context do
      {response, log} = request_on_unavailable_repo(context, fn -> conn |> auth(context.setup) |> get("/backend-api/codex/models") end)

      assert_unavailable!(response, log, "authentication")
      assert FakeUpstream.count(context.upstream) == 0
    end

    test "a native responses turn answers a retryable 503 before admission", %{conn: conn} = context do
      {response, log} =
        request_on_unavailable_repo(context, fn ->
          conn
          |> auth(context.setup)
          |> post("/backend-api/codex/responses", %{"model" => context.setup.model.exposed_model_id, "input" => native_text_input("hello"), "stream" => true})
        end)

      assert_unavailable!(response, log, "authentication")
      assert FakeUpstream.count(context.upstream) == 0
    end

    test "an OpenAI /v1 responses request answers a retryable 503 from the ingress", %{conn: conn} = context do
      {response, log} =
        request_on_unavailable_repo(context, fn ->
          conn
          |> auth(context.setup)
          |> post("/v1/responses", %{"model" => context.setup.model.exposed_model_id, "input" => "hello"})
        end)

      assert_unavailable!(response, log, "authentication")
      assert FakeUpstream.count(context.upstream) == 0
    end

    test "a websocket upgrade is refused with a retryable 503 before it happens", %{conn: conn} = context do
      {response, log} =
        request_on_unavailable_repo(context, fn ->
          conn
          |> auth(context.setup)
          |> put_req_header("connection", "upgrade")
          |> put_req_header("upgrade", "websocket")
          |> put_req_header("sec-websocket-version", "13")
          |> put_req_header("sec-websocket-key", Base.encode64(:crypto.strong_rand_bytes(16)))
          |> get("/backend-api/codex/responses")
        end)

      assert_unavailable!(response, log, "authentication")
      assert FakeUpstream.count(context.upstream) == 0
    end
  end

  # PostgreSQL ends in-flight statements with `57P01 admin_shutdown` when the
  # instance stops (a restart, an operator upgrade). A trigger raises the same
  # condition from the first write of the reservation transaction, inside the
  # sandbox transaction, so the rollback removes it with the test.
  test "a reservation cut by a database shutdown answers a retryable 503 and leaves no request", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{}))
    setup = gateway_setup(upstream)

    Repo.query!("CREATE FUNCTION pg_temp.p77_reservation_shutdown() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'terminating connection due to administrator command' USING ERRCODE = 'admin_shutdown'; END $$")
    Repo.query!("CREATE TRIGGER p77_reservation_shutdown BEFORE INSERT ON requests FOR EACH ROW EXECUTE FUNCTION pg_temp.p77_reservation_shutdown()")

    {response, log} =
      ExUnit.CaptureLog.with_log(fn ->
        conn
        |> auth(setup)
        |> post("/backend-api/codex/responses", %{"model" => setup.model.exposed_model_id, "input" => native_text_input("hello"), "stream" => true})
      end)

    assert_unavailable!(response, log, "reservation", "postgres_admin_shutdown")
    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 0
    assert Repo.aggregate(from(l in LedgerEntry, where: l.pool_id == ^setup.pool.id), :count) == 0
  end

  defp assert_unavailable!(response, log, stage, reason_class \\ "DBConnection.ConnectionError") do
    fixture = CompatibilityMatrix.fixture!(:database_unavailable)
    assert stage in Enum.map(fixture.stages, &Atom.to_string/1)
    assert {fixture.status, fixture.error_code, fixture.error_type} == {503, @unavailable_body["error"]["code"], @unavailable_body["error"]["type"]}
    assert {response.status, CodexPooler.JSON.decode(response.resp_body)} == {503, {:ok, @unavailable_body}}
    assert log =~ "stage=#{stage} reason_class=#{reason_class}"
    # No database detail reaches the client or the log line.
    refute response.resp_body =~ ~r/(?i)postgres|dbconnection|queue|administrator|codex_pooler_test/
    refute log =~ "administrator command"
  end

  # All database calls the request makes in this process go to a second Repo
  # instance outside the sandbox, whose only connection a task holds and whose
  # queue drops a waiter after a few milliseconds: the same
  # `DBConnection.ConnectionError` a production pool raises when PostgreSQL is
  # restarting or stalled ("connection not available and request was dropped
  # from queue").
  defp request_on_unavailable_repo(%{unavailable: %{repo: repo} = unavailable}, request) do
    previous = Repo.put_dynamic_repo(repo)

    try do
      ExUnit.CaptureLog.with_log(request)
    after
      Repo.put_dynamic_repo(previous)
      release_unavailable_repo!(unavailable)
    end
  end

  defp release_unavailable_repo!(%{holder: holder, release_ref: release_ref}) do
    send(holder.pid, {:release_unavailable_repo, release_ref})
    assert Task.await(holder, 15_000) == :released
  end

  defp hold_unavailable_repo! do
    repo = start_supervised!({Repo, name: nil, pool: DBConnection.ConnectionPool, pool_size: 1, queue_target: 1, queue_interval: 10}, id: :runtime_database_unavailable_repo)
    test_pid = self()
    release_ref = make_ref()

    holder =
      Task.async(fn ->
        _previous = Repo.put_dynamic_repo(repo)
        hold_only_connection(test_pid, release_ref, System.monotonic_time(:millisecond) + 15_000)
      end)

    assert_receive {:unavailable_repo_held, ^release_ref}, 15_000
    %{repo: repo, holder: holder, release_ref: release_ref}
  end

  # The pool's only connection may still be connecting when the holder asks for
  # it, and the queue that drops the request's checkout drops the holder's too
  # until the connection is up; retry against a bounded deadline.
  defp hold_only_connection(test_pid, release_ref, deadline) do
    Repo.checkout(fn ->
      send(test_pid, {:unavailable_repo_held, release_ref})

      receive do
        {:release_unavailable_repo, ^release_ref} -> :released
      end
    end)
  rescue
    error in DBConnection.ConnectionError ->
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(10)
        hold_only_connection(test_pid, release_ref, deadline)
      else
        reraise error, __STACKTRACE__
      end
  end
end
