defmodule CodexPooler.Accounting.NativeWebsocketSizeRecoveryTest do
  use ExUnit.Case, async: false
  use CodexPooler.CommittedWriteGuard

  import Ecto.Query
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Access
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.Accounting.NativeWebsocketSizeRecovery, as: RecoveryMarker
  alias CodexPooler.Gateway.{Denials, NativeWebsocketSizeRecovery}
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint "/backend-api/codex/responses"
  @limit 16_777_216

  setup do
    {:ok, owned} = Agent.start(fn -> %{pools: [], owners: []} end)

    on_exit(fn ->
      unboxed(fn ->
        %{pools: ids, owners: owners} = Agent.get(owned, & &1)
        delete_committed_pools!(ids, owners)
        refute Repo.exists?(from p in CodexPooler.Pools.Pool, where: p.id in ^ids)
      end)

      Agent.stop(owned)
    end)

    auth =
      unboxed(fn ->
        pool = pool_fixture()
        Agent.update(owned, &%{&1 | pools: [pool.id | &1.pools]})
        fixture = api_key_fixture(pool)
        Agent.update(owned, &%{&1 | owners: [fixture.api_key.created_by_user_id | &1.owners]})
        {:ok, auth} = Access.authenticate_authorization_header(fixture.authorization)
        auth
      end)

    %{auth: auth, owned: owned}
  end

  test "confirmed denial is committed, claimless, sanitized and visible on a second PostgreSQL connection", %{auth: auth} do
    parent = self()

    task =
      Task.async(fn ->
        unboxed(fn ->
          writer_pid = backend_pid()
          assert {:ok, :native_websocket_size_recovery} = Denials.record_native_websocket_size_recovery(context(auth), @limit + 1)
          send(parent, {:committed, writer_pid})
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive {:committed, writer_pid}, 15_000

    unboxed(fn ->
      refute backend_pid() == writer_pid
      assert {:ok, true} = lookup(auth)
      assert [request] = Repo.all(from r in Request, where: r.pool_id == ^auth.pool.id)
      assert request.status == "rejected"
      assert request.usage_status == "not_applicable"
      refute request.correlation_id == "synthetic-original-claim"
      assert request.api_key_id == auth.api_key.id
      assert request.request_metadata["native_websocket_size_recovery"] == marker()
      refute inspect(request.request_metadata) =~ "synthetic-window"
      assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) == 0
      assert Repo.aggregate(from(l in LedgerEntry, where: l.request_id == ^request.id), :count) == 0
      assert {:ok, true} = lookup(auth)
      assert Repo.get!(Request, request.id) == request
    end)

    send(task.pid, :release)
    Task.await(task)
  end

  test "lookup scopes key pool window and bypasses more than 100 unrelated newer rows", %{auth: auth, owned: owned} do
    unboxed(fn ->
      assert {:ok, :native_websocket_size_recovery} = Denials.record_native_websocket_size_recovery(context(auth), @limit + 1)

      for _ <- 1..105 do
        assert {:ok, _} = Accounting.record_denied_request(auth, nil, %{endpoint: @endpoint, transport: "websocket"})
      end

      assert {:ok, true} = lookup(auth)
      {:ok, other_digest} = NativeWebsocketSizeRecovery.window_digest([{"x-codex-window-id", "other-window"}])
      assert {:ok, false} = Accounting.native_websocket_size_recovery(auth, other_digest)
      other_key = api_key_fixture(auth.pool).api_key
      assert {:ok, false} = lookup(%{auth | api_key: other_key})
      other_pool = pool_fixture()
      Agent.update(owned, &%{&1 | pools: [other_pool.id | &1.pools]})
      assert {:ok, false} = lookup(%{auth | pool: other_pool})
    end)
  end

  test "database clock excludes exact sixty second boundary and future rows without sliding", %{auth: auth} do
    unboxed(fn ->
      assert {:ok, :native_websocket_size_recovery} = Denials.record_native_websocket_size_recovery(context(auth), @limit + 1)

      Repo.transaction(fn ->
        for {interval, expected} <- [{"-60 seconds", false}, {"-61 seconds", false}, {"1 second", false}, {"0 seconds", true}, {"-59 seconds", true}] do
          Repo.query!("UPDATE requests SET admitted_at = now() + $1::text::interval WHERE pool_id = $2", [interval, Ecto.UUID.dump!(auth.pool.id)])
          assert {:ok, ^expected} = lookup(auth)
        end
      end)
    end)
  end

  test "malformed and unrelated persisted marker shapes cannot authorize recovery", %{auth: auth} do
    unboxed(fn ->
      assert {:ok, :native_websocket_size_recovery} = Denials.record_native_websocket_size_recovery(context(auth), @limit + 1)

      for bad <- [Map.put(marker(), "version", 2), Map.put(marker(), "version", 1.0), Map.put(marker(), "limit_bytes", 16_777_216.0), Map.put(marker(), "message_bytes", "16777217"), Map.put(marker(), "message_bytes", @limit), Map.put(marker(), "decision", "postclaim"), Map.put(marker(), "serving_mode", "lite"), Map.put(marker(), "extra", true), %{}, nil] do
        Repo.update_all(from(r in Request, where: r.pool_id == ^auth.pool.id), set: [request_metadata: %{"native_websocket_size_recovery" => bad}])
        assert {:ok, false} = lookup(auth)
      end

      for changes <- [[endpoint: "/v1/responses"], [transport: "http_sse"], [status: "failed"], [usage_status: "usage_unknown"], [last_error_code: "other"]] do
        Repo.update_all(from(r in Request, where: r.pool_id == ^auth.pool.id), set: [request_metadata: %{"native_websocket_size_recovery" => marker()}, endpoint: @endpoint, transport: "websocket", status: "rejected", usage_status: "not_applicable", last_error_code: "native_websocket_message_too_large"])
        Repo.update_all(from(r in Request, where: r.pool_id == ^auth.pool.id), set: changes)
        assert {:ok, false} = lookup(auth)
      end
    end)
  end

  @tag :storage_failure
  test "nested rollback never advertises a committed marker", %{auth: auth} do
    unboxed(fn ->
      assert {:error, :rollback_control} =
               Repo.transaction(fn ->
                 assert {:error, :storage_unavailable} = Denials.record_native_websocket_size_recovery(context(auth), @limit + 1)
                 Repo.rollback(:rollback_control)
               end)

      assert {:ok, false} = lookup(auth)
      refute Repo.exists?(from r in Request, where: r.pool_id == ^auth.pool.id)
    end)
  end

  @tag :storage_failure
  test "revoked and deleted authenticated keys cannot create or read recovery markers", %{auth: auth} do
    unboxed(fn ->
      assert {:ok, :native_websocket_size_recovery} = Denials.record_native_websocket_size_recovery(context(auth), @limit + 1)
      Repo.update_all(from(k in Access.APIKey, where: k.id == ^auth.api_key.id), set: [status: "revoked"])
      assert {:error, :storage_unavailable} = Denials.record_native_websocket_size_recovery(context(auth), @limit + 1)
      assert {:ok, false} = lookup(auth)
      Repo.delete_all(from k in Access.APIKey, where: k.id == ^auth.api_key.id)
      assert {:error, :storage_unavailable} = Denials.record_native_websocket_size_recovery(context(auth), @limit + 1)
      assert {:ok, false} = lookup(auth)
      assert Repo.aggregate(from(r in Request, where: r.pool_id == ^auth.pool.id), :count) == 1
    end)
  end

  @tag :storage_failure
  test "database trigger rejection and stored-marker mutation roll back the whole refusal", %{auth: auth} do
    trigger = "size_recovery_" <> String.replace(Ecto.UUID.generate(), "-", "")

    on_exit(fn ->
      unboxed(fn ->
        Repo.query!("DROP TRIGGER IF EXISTS #{trigger} ON requests")
        Repo.query!("DROP FUNCTION IF EXISTS #{trigger}()")
      end)
    end)

    unboxed(fn ->
      for body <- ["RAISE EXCEPTION 'synthetic persistence refusal';", "NEW.request_metadata = '{}'::jsonb;"] do
        Repo.query!("CREATE OR REPLACE FUNCTION #{trigger}() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.pool_id = '#{auth.pool.id}'::uuid THEN #{body} END IF; RETURN NEW; END $$")
        Repo.query!("CREATE OR REPLACE TRIGGER #{trigger} BEFORE INSERT ON requests FOR EACH ROW EXECUTE FUNCTION #{trigger}()")
        assert {:error, :storage_unavailable} = Denials.record_native_websocket_size_recovery(context(auth), @limit + 1)
        refute Repo.exists?(from r in Request, where: r.pool_id == ^auth.pool.id)
        assert {:ok, false} = lookup(auth)
      end
    end)
  end

  @tag :storage_failure
  test "database read and write timeouts never imply recovery readiness", %{auth: auth} do
    parent = self()

    holder =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            Repo.query!("LOCK TABLE requests IN ACCESS EXCLUSIVE MODE")
            send(parent, :table_locked)
            receive do: (:release -> :ok)
          end)
        end)
      end)

    assert_receive :table_locked, 15_000

    try do
      unboxed(fn ->
        Repo.query!("SET statement_timeout = '50ms'")

        try do
          assert {:error, :storage_unavailable} = lookup(auth)
          assert {:error, :storage_unavailable} = Denials.record_native_websocket_size_recovery(context(auth), @limit + 1)
        after
          Repo.query!("SET statement_timeout = DEFAULT")
        end
      end)
    after
      send(holder.pid, :release)
      Task.await(holder)
    end

    unboxed(fn -> assert {:ok, false} = lookup(auth) end)
  end

  test "an existing original semantic claim is unchanged and still excludes duplicate execution", %{auth: auth} do
    unboxed(fn ->
      model = model_fixture(auth.pool)
      opts = %{endpoint: @endpoint, transport: "websocket", correlation_id: "synthetic-original-claim"}
      assert {:ok, %{request: original}} = Accounting.claim_websocket_turn(auth, model, opts)
      assert {:ok, :native_websocket_size_recovery} = Denials.record_native_websocket_size_recovery(%{context(auth) | model: model}, @limit + 1)
      assert Repo.get!(Request, original.id) == original
      assert {:error, %{code: :duplicate_request}} = Accounting.claim_websocket_turn(auth, model, opts)
      assert Repo.aggregate(from(a in Attempt, join: r in Request, on: a.request_id == r.id, where: r.pool_id == ^auth.pool.id), :count) == 0
      assert Repo.aggregate(from(l in LedgerEntry, where: l.pool_id == ^auth.pool.id), :count) == 0
      assert Repo.aggregate(CodexPooler.Gateway.Persistence.CodexTurn, :count) == 0
    end)
  end

  test "bounded lookup uses the existing scope and time index on representative history", %{auth: auth} do
    unboxed(fn ->
      assert {:ok, :native_websocket_size_recovery} = Denials.record_native_websocket_size_recovery(context(auth), @limit + 1)
      old = DateTime.add(DateTime.utc_now(), -120, :second)
      rows = for _ <- 1..3_000, do: %{id: Ecto.UUID.generate(), pool_id: auth.pool.id, api_key_id: auth.api_key.id, endpoint: @endpoint, requested_model: "synthetic", transport: "websocket", status: "rejected", usage_status: "not_applicable", correlation_id: Ecto.UUID.generate(), admitted_at: old, completed_at: old, request_metadata: %{}}
      Repo.insert_all(Request, rows)
      Repo.query!("ANALYZE requests")
      query = RecoveryMarker.query(auth, marker()["window_digest"])
      {sql, params} = SQL.to_sql(:all, Repo, query)
      assert [[[%{"Plan" => plan}]]] = Repo.query!("EXPLAIN (FORMAT JSON) " <> sql, params).rows
      nodes = plan_nodes(plan)
      assert Enum.any?(nodes, &(&1["Index Name"] in ["requests_api_key_pool_admitted_idx", "requests_api_key_pool_admitted_id_idx"]))
      refute Enum.any?(nodes, &(&1["Node Type"] == "Aggregate"))
      assert plan["Node Type"] == "Limit"
      assert {:ok, true} = lookup(auth)
    end)
  end

  defp plan_nodes(plan), do: [Map.take(plan, ["Node Type", "Index Name"]) | Enum.flat_map(Map.get(plan, "Plans", []), &plan_nodes/1)]

  test "canonical window requires exactly one nonblank window header and never substitutes session identity", %{auth: auth} do
    assert NativeWebsocketSizeRecovery.window_digest([{"x-codex-window-id", " synthetic-window "}]) == NativeWebsocketSizeRecovery.window_digest(context(auth).opts)

    for headers <- [[], [{"session-id", "synthetic-window"}], [{"x-codex-window-id", " "}], [{"x-codex-window-id", "a"}, {"x-codex-window-id", "a"}]] do
      assert :error = NativeWebsocketSizeRecovery.window_digest(headers)
      opts = RequestOptions.build(%{transport: "websocket", forwarded_headers: headers}, @endpoint, %{})
      assert {:error, :missing_window} = Denials.record_native_websocket_size_recovery(%{context(auth) | opts: opts}, @limit + 1)
    end
  end

  test "canonical accounting endpoint is required and invalid bytes and nonnative transports cannot persist a marker", %{auth: auth} do
    unboxed(fn ->
      for bytes <- [0, @limit - 1, @limit, @limit + 0.5] do
        assert {:error, :invalid_recovery} = Denials.record_native_websocket_size_recovery(context(auth), bytes)
      end

      for endpoint <- ["/v1/responses", "/backend-api/codex/v1/responses", "/backend-api/codex/responses/compact"] do
        assert {:error, :storage_unavailable} = Denials.record_native_websocket_size_recovery(%{context(auth) | endpoint: endpoint}, @limit + 1)
      end

      http = RequestOptions.build(%{transport: "http_sse", forwarded_headers: [{"x-codex-window-id", "synthetic-window"}]}, @endpoint, %{})
      assert {:error, :storage_unavailable} = Denials.record_native_websocket_size_recovery(%{context(auth) | opts: http}, @limit + 1)
      refute Repo.exists?(from r in Request, where: r.pool_id == ^auth.pool.id)
      assert {:ok, :native_websocket_size_recovery} = Denials.record_native_websocket_size_recovery(context(auth), @limit + 1)
      assert {:ok, true} = lookup(auth)
    end)
  end

  test "paused expired and stale-epoch keys and inactive pools cannot read or write markers", %{auth: auth} do
    unboxed(fn ->
      assert {:ok, :native_websocket_size_recovery} = Denials.record_native_websocket_size_recovery(context(auth), @limit + 1)

      for updates <- [[status: "paused"], [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)], [runtime_revocation_epoch: 1]] do
        Repo.update_all(from(k in Access.APIKey, where: k.id == ^auth.api_key.id), set: updates)
        assert {:ok, false} = lookup(auth)
        assert {:error, :storage_unavailable} = Denials.record_native_websocket_size_recovery(context(auth), @limit + 1)
        Repo.update_all(from(k in Access.APIKey, where: k.id == ^auth.api_key.id), set: [status: "active", expires_at: nil, runtime_revocation_epoch: 0])
      end

      Repo.update_all(from(p in CodexPooler.Pools.Pool, where: p.id == ^auth.pool.id), set: [status: "disabled"])
      assert {:ok, false} = lookup(auth)
      assert {:error, :storage_unavailable} = Denials.record_native_websocket_size_recovery(context(auth), @limit + 1)
    end)
  end

  test "marker sanitizer rejects invalid schemas and removes unknown fields" do
    assert Accounting.sanitize_metadata(%{"native_websocket_size_recovery" => marker()}) == %{"native_websocket_size_recovery" => marker()}

    for bad <- [Map.put(marker(), "version", 2), Map.put(marker(), "window_digest", "invalid"), Map.put(marker(), "message_bytes", @limit), Map.put(marker(), "extra", "discarded")] do
      refute Accounting.sanitize_metadata(%{"native_websocket_size_recovery" => bad})["native_websocket_size_recovery"]
    end
  end

  defp context(auth) do
    opts = RequestOptions.build(%{transport: "websocket", request_id: "synthetic-original-claim", forwarded_headers: [{"x-codex-window-id", " synthetic-window "}]}, @endpoint, %{})
    %Denials.Context{auth: auth, model: nil, endpoint: @endpoint, payload: %{}, opts: opts}
  end

  defp marker do
    {:ok, digest} = NativeWebsocketSizeRecovery.window_digest([{"x-codex-window-id", "synthetic-window"}])
    %{"version" => 1, "window_digest" => digest, "limit_bytes" => @limit, "message_bytes" => @limit + 1, "serving_mode" => "full", "decision" => "preclaim"}
  end

  defp lookup(auth), do: Accounting.native_websocket_size_recovery(auth, marker()["window_digest"])
  defp backend_pid, do: Repo.query!("SELECT pg_backend_pid()").rows |> hd() |> hd()
  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
