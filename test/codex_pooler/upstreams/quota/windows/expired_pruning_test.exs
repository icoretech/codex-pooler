defmodule CodexPooler.Upstreams.Quota.Windows.ExpiredPruningTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures
  import CodexPooler.UnboxedFixture, only: [register_unboxed_cleanup!: 1]

  alias CodexPooler.Jobs.RuntimeStateCleanup
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Quota.Windows.EvidenceStore
  alias CodexPooler.Upstreams.Quota.Windows.ExpiredPruning
  alias CodexPooler.Upstreams.SavedResets.AutomaticConfirmation
  alias Ecto.Adapters.SQL.Sandbox

  @day 86_400
  @detection_timeout_ms 15_000

  describe "within one transaction" do
    test "deletes rows expired beyond the retention across every source and keeps the rest" do
      now = now()
      identity = upstream_identity_fixture()
      old = DateTime.add(now, -(retention_days() + 1) * @day, :second)
      recent = DateTime.add(now, -(retention_days() - 1) * @day, :second)

      expired_headers = insert_window!(identity, source: "codex_response_headers", reset_at: old)
      expired_event = insert_window!(identity, source: "codex_rate_limit_event", reset_at: old)
      expired_error = insert_window!(identity, source: "codex_rate_limit_error", reset_at: old)
      # A Usage API descriptor the provider stopped returning: never covered by
      # a later complete poll, so the poll-time delete never reaches it.
      retired_usage = insert_window!(identity, source: "codex_usage_api", quota_key: "gpt_reserve", quota_scope: "model", model: "gpt-reserve", reset_at: old)
      recently_expired = insert_window!(identity, source: "codex_usage_api", reset_at: recent)
      running = insert_window!(identity, source: "codex_usage_api", window_kind: "primary", window_minutes: 300, reset_at: DateTime.add(now, 3_600, :second))

      assert {:ok, %{expired_quota_windows_pruned: 4}} = Windows.prune_expired_windows(now)

      for deleted <- [expired_headers, expired_event, expired_error, retired_usage] do
        refute Repo.get(AccountQuotaWindow, deleted.id)
      end

      assert Repo.get(AccountQuotaWindow, recently_expired.id)
      assert Repo.get(AccountQuotaWindow, running.id)
      assert {:ok, %{expired_quota_windows_pruned: 0}} = Windows.prune_expired_windows(now)
    end

    test "keeps an expired row that carries the saved-reset confirmation marker" do
      now = now()
      identity = upstream_identity_fixture()
      old = DateTime.add(now, -(retention_days() + 10) * @day, :second)

      marked =
        insert_window!(identity,
          source: "codex_usage_api",
          reset_at: old,
          metadata: %{AutomaticConfirmation.metadata_key() => %{"version" => 1, "state" => "approach"}}
        )

      unmarked = insert_window!(identity, source: "codex_response_headers", reset_at: old)

      assert {:ok, %{expired_quota_windows_pruned: 1}} = Windows.prune_expired_windows(now)
      assert Repo.get(AccountQuotaWindow, marked.id)
      refute Repo.get(AccountQuotaWindow, unmarked.id)
    end

    test "a pass deletes at most the batch size, oldest reset first" do
      now = now()
      identity = upstream_identity_fixture()
      base = DateTime.add(now, -(retention_days() + 5) * @day, :second)

      oldest = insert_window!(identity, source: "codex_rate_limit_event", reset_at: DateTime.add(base, -@day, :second))
      younger = insert_window!(identity, source: "codex_response_headers", reset_at: base)

      assert {:ok, %{expired_quota_windows_pruned: 1}} = Windows.prune_expired_windows(now, batch_size: 1)
      refute Repo.get(AccountQuotaWindow, oldest.id)
      assert Repo.get(AccountQuotaWindow, younger.id)
      assert ExpiredPruning.batch_size() == 500
    end

    test "runtime state cleanup runs the quota step and reports its count" do
      now = now()
      identity = upstream_identity_fixture()
      expired = insert_window!(identity, source: "codex_response_headers", reset_at: DateTime.add(now, -(retention_days() + 1) * @day, :second))

      assert {:ok, summary} = RuntimeStateCleanup.run(now)
      assert summary.expired_quota_windows_pruned == 1
      refute Repo.get(AccountQuotaWindow, expired.id)
    end
  end

  describe "against concurrent committed transactions" do
    setup do
      identity = unboxed(fn -> upstream_identity_fixture() end)
      register_unboxed_cleanup!(fn -> Repo.delete!(identity) end)
      %{identity: identity, now: now()}
    end

    # A saved-reset claim and its reservation lock their proof rows FOR UPDATE.
    # The pass must neither delete such a row nor wait for the claim.
    test "skips a row another transaction holds locked and deletes the unlocked one", %{identity: identity, now: now} do
      old = DateTime.add(now, -(retention_days() + 1) * @day, :second)
      held = unboxed(fn -> insert_window!(identity, source: "codex_usage_api", reset_at: old) end)
      free = unboxed(fn -> insert_window!(identity, source: "codex_response_headers", reset_at: old) end)
      parent = self()

      holder =
        Task.async(fn ->
          unboxed(fn ->
            Repo.transaction(fn ->
              Repo.query!("SELECT id FROM account_quota_windows WHERE id = $1 FOR UPDATE", [Ecto.UUID.dump!(held.id)])
              send(parent, {:held, self()})

              receive do
                :release -> :ok
              after
                @detection_timeout_ms -> flunk("holder was never released")
              end
            end)
          end)
        end)

      assert_receive {:held, holder_pid}, @detection_timeout_ms

      assert {:ok, %{expired_quota_windows_pruned: 1}} = unboxed(fn -> Windows.prune_expired_windows(now) end)

      send(holder_pid, :release)
      assert {:ok, :ok} = Task.await(holder, @detection_timeout_ms)

      assert unboxed(fn -> Repo.get(AccountQuotaWindow, held.id) end)
      refute unboxed(fn -> Repo.get(AccountQuotaWindow, free.id) end)
    end

    # An evidence writer holds the identity locks and refreshes the expired row
    # with a new cycle. The pass must queue behind it on the identity advisory
    # mutex and then keep the refreshed row, because the candidate conditions
    # are evaluated again under the lock.
    test "waits for a concurrent evidence writer and keeps the row it refreshed", %{identity: identity, now: now} do
      old = DateTime.add(now, -(retention_days() + 1) * @day, :second)
      expired = unboxed(fn -> insert_window!(identity, source: "codex_rate_limit_event", reset_at: old) end)
      parent = self()

      writer =
        Task.async(fn ->
          unboxed(fn ->
            Repo.transaction(fn ->
              :ok = EvidenceStore.lock_evidence_identity!(identity.id)
              %{rows: [[writer_pid]]} = Repo.query!("SELECT pg_backend_pid()")

              assert {:ok, %AccountQuotaWindow{id: refreshed_id}} =
                       EvidenceStore.record_evidence(identity, CodexPooler.QuotaEvidenceSupport.account_secondary_evidence("12", now), now)

              send(parent, {:writer_holding, self(), writer_pid, refreshed_id})

              receive do
                :commit -> :ok
              after
                @detection_timeout_ms -> flunk("writer was never released")
              end
            end)
          end)
        end)

      assert_receive {:writer_holding, writer_task_pid, writer_pid, refreshed_id}, @detection_timeout_ms
      assert refreshed_id == expired.id

      pruner =
        Task.async(fn ->
          unboxed(fn ->
            %{rows: [[pruner_pid]]} = Repo.query!("SELECT pg_backend_pid()")
            send(parent, {:pruner, pruner_pid})
            Windows.prune_expired_windows(now)
          end)
        end)

      assert_receive {:pruner, pruner_pid}, @detection_timeout_ms
      assert await_blocked_on(pruner_pid, writer_pid) == {"advisory", [writer_pid]}

      send(writer_task_pid, :commit)
      assert {:ok, :ok} = Task.await(writer, @detection_timeout_ms)
      assert {:ok, %{expired_quota_windows_pruned: 0}} = Task.await(pruner, @detection_timeout_ms)

      assert %AccountQuotaWindow{reset_at: reset_at} = unboxed(fn -> Repo.get(AccountQuotaWindow, expired.id) end)
      assert DateTime.compare(reset_at, now) == :gt
    end
  end

  defp await_blocked_on(backend_pid, holder_pid) do
    deadline = System.monotonic_time(:millisecond) + @detection_timeout_ms
    do_await_blocked_on(backend_pid, holder_pid, deadline)
  end

  defp do_await_blocked_on(backend_pid, holder_pid, deadline) do
    %{rows: rows} =
      unboxed(fn ->
        Repo.query!("SELECT wait_event, pg_blocking_pids(pid) FROM pg_stat_activity WHERE pid = $1", [backend_pid])
      end)

    case rows do
      [[wait_event, [^holder_pid]]] ->
        {wait_event, [holder_pid]}

      other ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: {:not_blocked, other},
          else: do_await_blocked_on(backend_pid, holder_pid, deadline)
    end
  end

  defp insert_window!(identity, attrs) do
    attrs = Map.new(attrs)
    reset_at = Map.fetch!(attrs, :reset_at)
    observed_at = DateTime.add(reset_at, -3_600, :second)

    %AccountQuotaWindow{}
    |> AccountQuotaWindow.changeset(
      Map.merge(
        %{
          upstream_identity_id: identity.id,
          quota_key: "account",
          quota_scope: "account",
          quota_family: "account",
          window_kind: "secondary",
          window_minutes: 10_080,
          used_percent: Decimal.new("40"),
          source_precision: "observed",
          freshness_state: "fresh",
          last_sync_at: observed_at,
          observed_at: observed_at,
          metadata: %{},
          created_at: observed_at,
          updated_at: observed_at
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp retention_days, do: div(ExpiredPruning.retention_seconds(), @day)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
