defmodule CodexPooler.Metrics.AccountSnapshotTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import Phoenix.ConnTest

  alias CodexPooler.Metrics.{AccountProjection, AccountSnapshot, AccountValues}
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows.CycleConfirmation
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodexPoolerWeb.Endpoint

  defmodule ObservingRepo do
    defdelegate transaction(fun, opts), to: CodexPooler.Repo

    def query!(sql, params, opts) do
      result = CodexPooler.Repo.query!(sql, params, opts)
      [{:observer, observer}] = :ets.lookup(__MODULE__, :observer)
      observer.(sql)
      result
    end
  end

  # A real top-level transaction is required to test isolation/read-only mode.
  # These committed rows belong only to this isolated test database and are
  # removed explicitly; ordinary suite fixtures stay SQL-sandboxed.
  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    on_exit(fn -> Sandbox.checkin(Repo) end)
    :ok
  end

  test "one bounded repeatable read snapshot omits secret and arbitrary metadata fields" do
    with_identity(fn identity ->
      _window =
        insert_window(identity, %{
          metadata: %{
            "reset_state" => nil,
            "rate_limit_allowed" => %{"private-sentinel" => "private-email@example.test"},
            "private-sentinel" => "private-email@example.test"
          }
        })

      statements = observe_queries()
      assert {:ok, snapshot} = AccountSnapshot.load()
      stop_observer(statements)
      queries = collected_queries()
      assert Enum.count(queries, &String.starts_with?(String.trim(&1), "SELECT")) == 3
      assert Enum.any?(queries, &String.contains?(&1, "REPEATABLE READ, READ ONLY"))

      assert Enum.all?(
               queries,
               &Regex.match?(~r/\A\s*(SELECT|SET TRANSACTION|begin|commit)/i, &1)
             )

      for forbidden <-
            ~w(upstream_secrets oauth access_token refresh_token account_email account_label chatgpt_user_id step_message) do
        refute Enum.any?(queries, &String.contains?(&1, forbidden))
      end

      [projected] = Enum.filter(snapshot.identities, &(&1.id == identity.id))

      assert Enum.sort(Map.keys(projected)) ==
               ~w(credential_provenance disabled_at id metadata status)a

      assert Map.keys(projected.metadata) |> Enum.sort() ==
               ~w(credential_epoch quota_account_availability)

      [window] = Enum.filter(snapshot.windows, &(&1.upstream_identity_id == identity.id))
      assert window.metadata == %{"reset_state" => nil, "rate_limit_allowed" => nil}
      refute inspect(snapshot) =~ "private-sentinel"
      refute inspect(snapshot) =~ "private-email@example.test"
      assert AccountProjection.project(snapshot).complete
    end)
  end

  test "PostgreSQL model normalization and original raw descriptor case drive the digest" do
    with_identity(fn identity ->
      original = insert_window(identity, %{model: "MODEL", raw_limit_name: "Raw"})
      assert {:ok, snapshot} = AccountSnapshot.load()
      first = Enum.find(snapshot.windows, &(&1.id == original.id))
      assert first.index_model == "model"
      Repo.update!(Ecto.Changeset.change(original, model: "Model", used_percent: Decimal.new(50)))
      assert {:ok, snapshot} = AccountSnapshot.load()
      second = Enum.find(snapshot.windows, &(&1.id == original.id))
      assert AccountValues.observation_id(first) == AccountValues.observation_id(second)
      alternate = insert_window(identity, %{model: "model", raw_limit_name: "raw"})
      assert {:ok, snapshot} = AccountSnapshot.load()
      third = Enum.find(snapshot.windows, &(&1.id == alternate.id))
      refute AccountValues.observation_id(first) == AccountValues.observation_id(third)
    end)
  end

  test "window sentinel count is per identity and never hides a later account" do
    with_identity(fn identity ->
      template = insert_window(identity)

      rows =
        Enum.map(1..512, fn number ->
          template
          |> Map.from_struct()
          |> Map.drop([:__meta__, :id])
          |> Map.put(:quota_key, "synthetic-#{number}")
        end)

      assert {512, nil} = Repo.insert_all(AccountQuotaWindow, rows)

      with_identity(fn later ->
        insert_window(later)
        assert {:ok, snapshot} = AccountSnapshot.load()
        bounded = Enum.filter(snapshot.windows, &(&1.upstream_identity_id == identity.id))
        assert length(bounded) == 513
        assert Enum.all?(bounded, &(&1.row_count == 513))
        assert Enum.any?(snapshot.windows, &(&1.upstream_identity_id == later.id))
        projection = AccountProjection.project(snapshot)
        refute projection.complete
        assert projection.groups == 1
      end)
    end)
  end

  test "marker reconstruction preserves validity and rejects extra keys, bad type, stale and future" do
    with_identity(fn identity ->
      now = DateTime.utc_now()

      window =
        insert_window(identity, %{observed_at: now, metadata: %{"reset_state" => "anchored"}})

      marker = marker(window)

      for {candidate, expected} <- [
            {marker, true},
            {Map.put(marker, "extra", "private-sentinel"), false},
            {[], false},
            {Map.put(marker, "confirmed_at", DateTime.to_iso8601(DateTime.add(now, 600))), false},
            {Map.put(
               marker,
               "provider_observed_at",
               DateTime.to_iso8601(DateTime.add(now, -901))
             ), false}
          ] do
        original =
          Repo.update!(
            Ecto.Changeset.change(window,
              metadata: %{
                "reset_state" => "anchored",
                "__quota_cycle_confirmation_v1" => candidate
              }
            )
          )

        assert {:ok, snapshot} = AccountSnapshot.load()
        row = Enum.find(snapshot.windows, &(&1.id == window.id))

        projected =
          row
          |> Map.drop([:index_model, :index_upstream_model, :row_count])
          |> then(&struct!(AccountQuotaWindow, &1))
          |> Map.update!(:observed_at, &AccountValues.timestamp/1)
          |> Map.update!(:reset_at, &AccountValues.timestamp/1)

        assert CycleConfirmation.selector_valid?(original, snapshot.as_of) == expected
        assert CycleConfirmation.selector_valid?(projected, snapshot.as_of) == expected
        refute inspect(row) =~ "private-sentinel"
      end
    end)
  end

  test "authorized native response appends gauges and account failure keeps operational metrics" do
    with_identity(fn identity ->
      insert_window(identity)
      conn = get(build_conn(), "/metrics")
      assert conn.status == 200
      assert conn.resp_body =~ "codex_pooler_account_metrics_collection_success 1"
      assert conn.resp_body =~ identity.id
      assert conn.resp_body =~ "# TYPE codex_pooler_repo_query_count"

      assert AccountSnapshot.scrape(fn -> {:error, :synthetic_failure} end) =~
               "codex_pooler_account_metrics_collection_success 0"
    end)
  end

  test "concurrent credential replacement cannot mix epochs inside a read-only snapshot" do
    with_identity(fn identity ->
      quota = insert_window(identity)

      table = :ets.new(ObservingRepo, [:named_table, :public])

      observer = fn sql ->
        if String.contains?(sql, "SELECT id::text") and
             is_nil(Process.get(:account_snapshot_changed)) do
          Process.put(:account_snapshot_changed, true)

          assert Repo.query!(
                   "SELECT current_setting('transaction_isolation'), current_setting('transaction_read_only')"
                 ).rows == [["repeatable read", "on"]]

          Task.async(fn ->
            :ok = Sandbox.checkout(Repo, sandbox: false)

            try do
              Repo.update!(Ecto.Changeset.change(identity, metadata: %{"credential_epoch" => 2}))
              Repo.update!(Ecto.Changeset.change(quota, used_percent: Decimal.new(80)))
            after
              Sandbox.checkin(Repo)
            end
          end)
          |> Task.await()
        end
      end

      :ets.insert(table, {:observer, observer})

      try do
        assert {:ok, snapshot} = AccountSnapshot.load(ObservingRepo)

        assert Enum.find(snapshot.identities, &(&1.id == identity.id)).metadata[
                 "credential_epoch"
               ] == 1

        assert Decimal.equal?(Enum.find(snapshot.windows, &(&1.id == quota.id)).used_percent, 6)
        assert {:ok, next} = AccountSnapshot.load()

        assert Enum.find(next.identities, &(&1.id == identity.id)).metadata["credential_epoch"] ==
                 2

        assert Decimal.equal?(Enum.find(next.windows, &(&1.id == quota.id)).used_percent, 80)
      after
        :ets.delete(table)
      end
    end)
  end

  test "two collections neither call HTTP, job or account-secret contexts nor mutate rows" do
    with_identity(fn identity ->
      quota = identity |> insert_window() |> Repo.reload!()

      modules = [
        Req,
        Finch,
        Oban,
        CodexPooler.Upstreams.Secrets,
        CodexPooler.Upstreams.OAuth,
        CodexPooler.Upstreams.OAuthFlows
      ]

      parent = self()
      tracer = spawn(fn -> trace_calls(parent) end)

      Enum.each(modules, fn module ->
        Code.ensure_loaded!(module)
        :erlang.trace_pattern({module, :_, :_}, true, [:local])
      end)

      :erlang.trace(self(), true, [:call, :set_on_spawn, {:tracer, tracer}])

      try do
        for _iteration <- 1..2 do
          assert AccountSnapshot.scrape() =~ "codex_pooler_account_metrics_collection_success 1"
        end

        :erlang.trace(self(), false, [:all])
        delivered = :erlang.trace_delivered(self())
        assert_receive {:trace_delivered, _, ^delivered}
        send(tracer, {:drain, self()})
        assert_receive :trace_drained
        refute_received {:forbidden_call, _}
        assert Repo.get!(UpstreamIdentity, identity.id) == identity
        assert Repo.get!(AccountQuotaWindow, quota.id) == quota
      after
        :erlang.trace(self(), false, [:all])
        Enum.each(modules, &:erlang.trace_pattern({&1, :_, :_}, false, [:local]))
        send(tracer, :stop)
      end
    end)
  end

  defp trace_calls(parent) do
    receive do
      {:trace, _pid, :call, {module, function, args}} ->
        send(parent, {:forbidden_call, {module, function, length(args)}})
        trace_calls(parent)

      {:drain, pid} ->
        send(pid, :trace_drained)
        trace_calls(parent)

      :stop ->
        :ok
    end
  end

  test "reconciliation SQL projects strings only and never serializes nested JSON payloads" do
    with_identity(fn identity ->
      pool_id = Ecto.UUID.generate()

      Repo.query!(
        "INSERT INTO pools(id,slug,name) VALUES ($1::text::uuid,$2,'synthetic')",
        [pool_id, "metrics-scalar-#{pool_id}"]
      )

      Repo.query!(
        """
        INSERT INTO pool_upstream_assignments(pool_id,upstream_identity_id,assignment_label,status,health_status,eligibility_status)
        VALUES ($1::text::uuid,$2::text::uuid,'synthetic','paused','unknown','eligible')
        """,
        [pool_id, identity.id]
      )

      try do
        for field <- ["status", "finished_at"],
            invalid <- [
              %{"message" => "nested-private-sentinel@example.test"},
              ["nested-private-sentinel@example.test"],
              true,
              42,
              nil
            ] do
          reconciliation =
            Map.put(
              %{"status" => "failed", "finished_at" => "2026-09-07T00:00:00Z"},
              field,
              invalid
            )

          Repo.query!(
            "UPDATE pool_upstream_assignments SET metadata=$1 WHERE upstream_identity_id::text=$2",
            [%{"last_reconciliation" => reconciliation}, identity.id]
          )

          assert {:ok, snapshot} = AccountSnapshot.load()
          row = Enum.find(snapshot.memberships, &(&1.upstream_identity_id == identity.id))

          column =
            if field == "status", do: :reconciliation_status, else: :reconciliation_finished_at

          assert Map.fetch!(row, column) == nil
          assert row.reconciliation_status == reconciliation["status"] or field == "status"

          assert row.reconciliation_finished_at == reconciliation["finished_at"] or
                   field == "finished_at"

          refute inspect(snapshot) =~ "nested-private-sentinel"
        end
      after
        Repo.delete_all(
          from a in PoolUpstreamAssignment, where: a.upstream_identity_id == ^identity.id
        )

        Repo.query!("DELETE FROM pools WHERE id::text=$1", [pool_id])
      end
    end)
  end

  defp with_identity(fun) do
    now = DateTime.utc_now()

    identity =
      Repo.insert!(%UpstreamIdentity{
        status: "paused",
        account_label: "private-sentinel",
        account_email: "private-email@example.test",
        onboarding_method: "import",
        headers_profile_version: 1,
        created_at: now,
        updated_at: now,
        credential_provenance: "codex_chatgpt_oauth",
        metadata: %{"credential_epoch" => 1, "private-sentinel" => "private-email@example.test"}
      })

    try do
      fun.(identity)
    after
      Repo.delete_all(from w in AccountQuotaWindow, where: w.upstream_identity_id == ^identity.id)

      Repo.delete_all(
        from a in PoolUpstreamAssignment, where: a.upstream_identity_id == ^identity.id
      )

      Repo.delete!(identity)
    end
  end

  defp insert_window(identity, attrs \\ %{}) do
    now = DateTime.utc_now()

    fields = %{
      upstream_identity_id: identity.id,
      quota_key: "account",
      quota_scope: "account",
      quota_family: "account",
      window_kind: "secondary",
      window_minutes: 10_080,
      source: "codex_usage_api",
      source_precision: "observed",
      freshness_state: "fresh",
      observed_at: now,
      last_sync_at: now,
      created_at: now,
      updated_at: now,
      reset_at: DateTime.add(now, 86_400),
      used_percent: Decimal.new(6),
      merge_precedence: 60,
      metadata: %{}
    }

    Repo.insert!(struct!(AccountQuotaWindow, Map.merge(fields, attrs)))
  end

  defp marker(window) do
    %{
      "version" => 1,
      "scope" => window.quota_scope,
      "family" => window.quota_family,
      "key" => window.quota_key,
      "kind" => window.window_kind,
      "minutes" => window.window_minutes,
      "model" => window.model,
      "upstream_model" => window.upstream_model,
      "reset_at" => DateTime.to_iso8601(window.reset_at),
      "provider_observed_at" => DateTime.to_iso8601(window.observed_at),
      "confirmed_at" => DateTime.to_iso8601(window.observed_at),
      "source_class" => "provider_usage"
    }
  end

  defp observe_queries do
    ref = make_ref()

    :telemetry.attach(
      ref,
      [:codex_pooler, :repo, :query],
      fn _, _, metadata, pid ->
        if self() == pid or pid in Process.get(:"$callers", []),
          do: send(pid, {:query, metadata.query})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(ref) end)
    ref
  end

  defp stop_observer(ref), do: :telemetry.detach(ref)

  defp collected_queries do
    receive do
      {:query, sql} -> [sql | collected_queries()]
    after
      0 -> []
    end
  end
end
