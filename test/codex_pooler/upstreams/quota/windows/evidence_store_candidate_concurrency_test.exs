defmodule CodexPooler.Upstreams.Quota.Windows.EvidenceStoreCandidateConcurrencyTest do
  use ExUnit.Case, async: false
  use CodexPooler.CommittedWriteGuard

  import CodexPooler.PoolerFixtures
  import CodexPooler.UnboxedFixture
  import Ecto.Query

  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows.EvidenceStore
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias Ecto.Adapters.SQL.Sandbox

  @at ~U[2026-11-01 10:00:00.000000Z]
  @detection_ms 5_000

  for pressure <- [:zero, :positive, :denied], order <- [:runtime_first, :provider_first] do
    test "#{pressure} runtime and provider maturity serialize with #{order}" do
      identity = fixture!()
      first = DateTime.add(@at, 10)
      reset = DateTime.add(first, 604_800)
      runtime_at = DateTime.add(first, if(unquote(order) == :runtime_first, do: 179, else: 181))
      provider_at = DateTime.add(first, 180)
      runtime = attrs("codex_rate_limit_event", if(unquote(pressure) == :positive, do: 90, else: 0), runtime_at, reset)
      runtime = if unquote(pressure) == :denied, do: put_in(runtime, [:metadata, "rate_limit_allowed"], false), else: runtime
      provider = attrs("codex_usage_api", 0, provider_at, reset)
      {first_attrs, second_attrs} = if unquote(order) == :runtime_first, do: {runtime, provider}, else: {provider, runtime}
      supervisor = start_supervised!(Task.Supervisor)
      test_pid = self()
      barrier = make_ref()

      {waiter, holder_backend, waiter_backend, observer_backend} =
        Sandbox.unboxed_run(Repo, fn ->
          {:ok, result} =
            Repo.transaction(fn ->
              EvidenceStore.lock_evidence_identity!(identity.id)
              holder_backend = backend_pid!()
              assert {:ok, _} = write(identity, first_attrs)

              waiter =
                Task.Supervisor.async_nolink(supervisor, fn ->
                  Sandbox.unboxed_run(Repo, fn ->
                    Repo.checkout(fn ->
                      send(test_pid, {barrier, :waiter, backend_pid!()})
                      write(identity, second_attrs)
                    end)
                  end)
                end)

              assert_receive {^barrier, :waiter, waiter_backend}, @detection_ms

              observer_backend =
                run_unboxed(fn ->
                  observer_backend = backend_pid!()
                  await_advisory!(waiter_backend, holder_backend, System.monotonic_time(:millisecond) + @detection_ms)
                  observer_backend
                end)

              {waiter, holder_backend, waiter_backend, observer_backend}
            end)

          result
        end)

      assert length(Enum.uniq([holder_backend, waiter_backend, observer_backend])) == 3
      assert {:ok, _} = Task.await(waiter, @detection_ms)
      rows = run_unboxed(fn -> EvidenceStore.list_evidence(identity) end)
      provider_row = Enum.find(rows, &(&1.source == "codex_usage_api"))
      runtime_row = Enum.find(rows, &(&1.source == "codex_rate_limit_event"))
      assert runtime_row.observed_at == runtime_at
      assert Decimal.equal?(runtime_row.used_percent, if(unquote(pressure) == :positive, do: 90, else: 0))
      assert runtime_row.metadata["rate_limit_allowed"] == (unquote(pressure) != :denied)

      if unquote(pressure) in [:positive, :denied] and unquote(order) == :runtime_first do
        assert Decimal.equal?(provider_row.used_percent, 86)
        assert {:ok, %{observed_at: ^provider_at}} = EvidenceStore.parse_candidate(provider_row.metadata)
      else
        assert Decimal.equal?(provider_row.used_percent, 0)
        assert provider_row.reset_at == reset
        assert :none = EvidenceStore.parse_candidate(provider_row.metadata)
      end
    end
  end

  defp fixture! do
    account_id = "synthetic-concurrency-#{Ecto.UUID.generate()}"

    register_unboxed_cleanup!(fn ->
      Repo.delete_all(from identity in UpstreamIdentity, where: identity.chatgpt_account_id == ^account_id)
    end)

    run_unboxed(fn ->
      identity = upstream_identity_fixture(%{chatgpt_account_id: account_id, metadata: %{"credential_epoch" => 4}})
      first = DateTime.add(@at, 10)
      assert {:ok, _} = write(identity, attrs("codex_usage_api", 86, @at, DateTime.add(@at, 5, :day)))
      assert {:ok, _} = write(identity, attrs("codex_usage_api", 0, first, DateTime.add(first, 604_800)))
      provider = Repo.one!(from window in AccountQuotaWindow, where: window.upstream_identity_id == ^identity.id)
      assert {:ok, %{observed_at: ^first}} = EvidenceStore.parse_candidate(provider.metadata)
      identity
    end)
  end

  defp write(identity, attrs), do: EvidenceStore.record_evidence(identity, attrs, attrs.observed_at, attrs.observed_at)

  defp attrs(source, used, observed_at, reset_at) do
    %{quota_key: "account", quota_scope: "account", quota_family: "account", window_kind: "secondary", window_minutes: 10_080, source: source, source_precision: "observed", freshness_state: "fresh", used_percent: Decimal.new(used), observed_at: observed_at, last_sync_at: observed_at, reset_at: reset_at, metadata: %{"credential_epoch" => 4, "rate_limit_allowed" => true, "rate_limit_reached" => false, "reset_after_seconds" => DateTime.diff(reset_at, observed_at)}}
  end

  defp backend_pid! do
    %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  defp await_advisory!(waiter, holder, deadline) do
    %{rows: rows} = Repo.query!("SELECT wait_event, pg_blocking_pids(pid) FROM pg_stat_activity WHERE pid = $1", [waiter])

    unless rows == [["advisory", [holder]]] do
      assert System.monotonic_time(:millisecond) < deadline, "writer did not contend on the identity advisory mutex"
      await_advisory!(waiter, holder, deadline)
    end
  end
end
