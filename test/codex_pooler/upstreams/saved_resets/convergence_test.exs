defmodule CodexPooler.Upstreams.SavedResets.ConvergenceTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Quota.Windows.EvidenceStore
  alias CodexPooler.Upstreams.SavedResets.ConfirmationMetadata
  alias CodexPooler.Upstreams.SavedResets.Convergence
  alias CodexPooler.Upstreams.SavedResets.ConvergenceTelemetry
  alias CodexPooler.Upstreams.SavedResets.RedemptionLifecycle
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias Ecto.Adapters.SQL.Sandbox

  defp identity_with_pending(consumed_at, opts \\ []) do
    deadline = Keyword.get(opts, :deadline_at, DateTime.add(consumed_at, 15, :minute))
    phase = Keyword.get(opts, :phase, "consumed_pending_probe")
    redemption_overrides = Keyword.get(opts, :redemption_overrides, %{})

    redemption =
      case phase do
        nil ->
          %{"status" => "succeeded", "result" => %{"code" => "reset", "applied" => true}}

        phase ->
          Map.merge(
            %{
              "status" => RedemptionLifecycle.legacy_status_for(phase),
              "phase" => phase,
              "attempt_id" => Ecto.UUID.generate(),
              "generation" => 3,
              "trigger_kind" => "gateway_auto",
              "started_at" => DateTime.to_iso8601(consumed_at),
              "consumed_at" => DateTime.to_iso8601(consumed_at),
              "deadline_at" => DateTime.to_iso8601(deadline),
              "finished_at" => nil,
              "result" => %{"code" => "reset", "applied" => true}
            },
            redemption_overrides
          )
      end

    metadata =
      opts
      |> Keyword.get(:metadata, %{})
      |> Map.put("saved_reset_redemption", redemption)

    pool = Keyword.get_lazy(opts, :pool, &pool_fixture/0)

    %{identity: identity} =
      active_upstream_assignment_fixture(pool, %{
        metadata: metadata
      })

    identity
  end

  test "missing identities converge without raising" do
    identity = %UpstreamIdentity{id: Ecto.UUID.generate()}

    assert {:ok, :unchanged} = Convergence.converge(identity)
  end

  defp upsert_account_window!(identity, used_percent) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    upsert_source_window!(identity, used_percent, source: "codex_usage_api", observed_at: now)
  end

  defp upsert_source_window!(identity, used_percent, opts) do
    observed_at = Keyword.fetch!(opts, :observed_at)

    assert {:ok, [window]} =
             Windows.upsert_quota_windows(identity, [
               %{
                 quota_key: Keyword.get(opts, :quota_key, "account"),
                 window_kind: Keyword.get(opts, :window_kind, "secondary"),
                 window_minutes: Keyword.get(opts, :window_minutes, 10_080),
                 used_percent: used_percent,
                 reset_at: Keyword.get(opts, :reset_at, DateTime.add(observed_at, 2, :day)),
                 observed_at: observed_at,
                 last_sync_at: observed_at,
                 source: Keyword.fetch!(opts, :source),
                 source_precision: "observed",
                 quota_scope: Keyword.get(opts, :quota_scope, "account"),
                 quota_family: Keyword.get(opts, :quota_family, "account"),
                 model: Keyword.get(opts, :model),
                 metered_feature: Keyword.get(opts, :metered_feature),
                 freshness_state: "fresh",
                 metadata: Keyword.get(opts, :metadata, %{})
               }
             ])

    window
  end

  defp put_confirmation_marker!(window, confirmed_at) do
    marker = %{
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
      "confirmed_at" => confirmed_at,
      "source_class" => "provider_usage"
    }

    window
    |> Ecto.Changeset.change(%{
      metadata:
        window.metadata
        |> Map.put("reset_state", "anchored")
        |> Map.put("__quota_cycle_confirmation_v1", marker)
    })
    |> Repo.update!()
  end

  defp redemption(identity), do: Repo.reload!(identity).metadata["saved_reset_redemption"]

  @tag :saved_reset_metadata
  test "persists bounded source outcome and accepted canonical timing at convergence" do
    decision_at = ~U[2026-08-08 10:10:00Z]
    consumed_at = DateTime.add(decision_at, -60, :second)
    confirmed_at = DateTime.add(decision_at, -30, :second)

    identity =
      identity_with_pending(consumed_at,
        redemption_overrides: %{
          "confirmation_timing" => %{"version" => 99, "raw" => "not-trusted"},
          "convergence_source" => "not-trusted",
          "convergence_outcome" => "not-trusted"
        }
      )

    identity
    |> upsert_source_window!(Decimal.new("0"),
      source: "codex_usage_api",
      observed_at: decision_at
    )
    |> put_confirmation_marker!(DateTime.to_iso8601(confirmed_at))

    assert {:ok, :confirmed_by_quota} =
             Convergence.converge(identity, decision_at, "runtime_headers")

    assert Map.take(redemption(identity), [
             "confirmation_timing",
             "convergence_source",
             "convergence_outcome"
           ]) == %{
             "confirmation_timing" => %{
               "version" => 1,
               "canonical_confirmed_at" => DateTime.to_iso8601(confirmed_at)
             },
             "convergence_source" => "runtime_headers",
             "convergence_outcome" => "confirmed_by_quota"
           }
  end

  @tag :saved_reset_metadata
  test "leaves canonical timing absent for pre-consume future and malformed markers" do
    decision_at = ~U[2026-08-08 10:10:00Z]
    consumed_at = DateTime.add(decision_at, -60, :second)

    marker_values = [
      DateTime.to_iso8601(DateTime.add(consumed_at, -1, :microsecond)),
      DateTime.to_iso8601(DateTime.add(decision_at, 1, :microsecond)),
      "not-a-timestamp"
    ]

    for marker_value <- marker_values do
      identity = identity_with_pending(consumed_at)

      identity
      |> upsert_source_window!(Decimal.new("0"),
        source: "codex_usage_api",
        observed_at: decision_at
      )
      |> put_confirmation_marker!(marker_value)

      assert {:ok, :confirmed_by_quota} =
               Convergence.converge(identity, decision_at, "reconciliation")

      assert redemption(identity)["confirmation_timing"] == %{"version" => 1}
    end
  end

  @tag :saved_reset_metadata
  test "candidate clearing preserves the canonical confirmation marker" do
    marker = %{"version" => 1, "confirmed_at" => "synthetic-bounded-marker"}

    metadata = %{
      "__quota_confirmed_candidate_v1" => %{"count" => 1},
      "__quota_candidate_provider_status_v1" => %{"status" => "present"},
      "__quota_cycle_confirmation_v1" => marker
    }

    assert EvidenceStore.clear_candidate(metadata)["__quota_cycle_confirmation_v1"] == marker
  end

  @tag :saved_reset_metadata
  test "unknown persisted source outcome and timing versions read fail closed" do
    assert ConfirmationMetadata.read(%{
             "convergence_source" => "unbounded-source",
             "convergence_outcome" => "unbounded-outcome",
             "confirmation_timing" => %{
               "version" => 2,
               "canonical_confirmed_at" => "2026-08-08T10:09:30Z"
             }
           }) == %{
             source: "unknown",
             outcome: "unknown",
             canonical_confirmed_at: nil
           }
  end

  @tag :saved_reset_metadata
  test "repeated convergence after settlement performs no steady-state write" do
    decision_at = ~U[2026-08-08 10:10:00Z]
    consumed_at = DateTime.add(decision_at, -60, :second)
    identity = identity_with_pending(consumed_at)

    upsert_source_window!(identity, Decimal.new("0"),
      source: "codex_usage_api",
      observed_at: decision_at
    )

    assert {:ok, :confirmed_by_quota} =
             Convergence.converge(identity, decision_at, "runtime_event")

    settled = Repo.reload!(identity)

    assert {:ok, :unchanged} =
             Convergence.converge(identity, decision_at, "runtime_error")

    unchanged = Repo.reload!(identity)
    assert unchanged.metadata == settled.metadata
    assert DateTime.compare(unchanged.updated_at, settled.updated_at) == :eq
  end

  @tag :saved_reset_runtime
  test "emits only after a committed transition and stays silent for rollback and unchanged" do
    event = [:codex_pooler, :saved_reset, :convergence]
    handler_id = attach_convergence_handler!(event)
    decision_at = ~U[2026-08-08 10:10:00Z]
    identity = convergable_identity_with_usable_evidence!(decision_at)

    assert {:ok, :confirmed_by_quota} =
             Convergence.converge(identity, decision_at, "runtime_headers")

    assert_receive {^handler_id, %{count: 1} = measurements,
                    %{source: "runtime_headers", outcome: "confirmed_by_quota"}}

    assert is_integer(measurements.applied_to_lifecycle_ms)
    assert measurements.applied_to_lifecycle_ms >= 0

    assert {:ok, :unchanged} =
             Convergence.converge(identity, decision_at, "runtime_event")

    refute_received {^handler_id, _measurements, _metadata}

    rolled_back = convergable_identity_with_usable_evidence!(decision_at)

    assert {:error, :forced_rollback} =
             Repo.transaction(fn ->
               assert {:ok, :confirmed_by_quota} =
                        Convergence.converge(rolled_back, decision_at, "runtime_error")

               Repo.rollback(:forced_rollback)
             end)

    refute_received {^handler_id, _measurements, _metadata}
    assert redemption(rolled_back)["phase"] == "consumed_pending_probe"
  end

  @tag :saved_reset_runtime
  test "accepts all bounded sources and normalizes malformed source outcome and timing" do
    event = [:codex_pooler, :saved_reset, :convergence]
    handler_id = attach_convergence_handler!(event)
    decision_at = ~U[2026-08-08 10:10:00Z]

    for source <-
          ~w(reconciliation runtime_headers runtime_websocket_upgrade_headers runtime_websocket_frame_headers runtime_event runtime_error finalizer) do
      identity = convergable_identity_with_usable_evidence!(decision_at)

      assert {:ok, :confirmed_by_quota} = Convergence.converge(identity, decision_at, source)

      assert_receive {^handler_id, %{count: 1}, %{source: ^source, outcome: "confirmed_by_quota"}}
    end

    malformed = %{
      "consumed_at" => "2030-01-01T00:00:00Z",
      "finished_at" => "not-a-time",
      "convergence_source" => "identity-#{Ecto.UUID.generate()}",
      "convergence_outcome" => "provider-specific-outcome",
      "confirmation_timing" => %{
        "version" => 99,
        "canonical_confirmed_at" => "2030-01-01T00:00:00Z"
      }
    }

    :ok = ConvergenceTelemetry.emit(malformed)

    assert_receive {^handler_id, %{count: 1}, %{source: "unknown", outcome: "unknown"}}
    refute_received {^handler_id, %{applied_to_canonical_ms: _value}, _metadata}
    refute_received {^handler_id, %{canonical_to_lifecycle_ms: _value}, _metadata}
    refute_received {^handler_id, %{applied_to_lifecycle_ms: _value}, _metadata}
  end

  @tag :saved_reset_runtime
  test "emits canonical latency measurements and accepts zero-length intervals" do
    event = [:codex_pooler, :saved_reset, :convergence]
    handler_id = attach_convergence_handler!(event)
    decision_at = ~U[2026-08-08 10:10:00Z]
    consumed_at = DateTime.add(decision_at, -60, :second)
    confirmed_at = DateTime.add(decision_at, -30, :second)
    identity = identity_with_pending(consumed_at)

    identity
    |> upsert_source_window!(Decimal.new("0"),
      source: "codex_usage_api",
      observed_at: decision_at
    )
    |> put_confirmation_marker!(DateTime.to_iso8601(confirmed_at))

    assert {:ok, :confirmed_by_quota} =
             Convergence.converge(identity, decision_at, "runtime_headers")

    assert_receive {^handler_id,
                    %{
                      count: 1,
                      applied_to_canonical_ms: 30_000,
                      canonical_to_lifecycle_ms: 30_000,
                      applied_to_lifecycle_ms: 60_000
                    }, %{source: "runtime_headers", outcome: "confirmed_by_quota"}}

    timestamp = DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:microsecond)

    :ok =
      ConvergenceTelemetry.emit(
        %{
          "consumed_at" => DateTime.to_iso8601(timestamp),
          "finished_at" => DateTime.to_iso8601(timestamp),
          "convergence_source" => "finalizer",
          "convergence_outcome" => "confirmed_by_quota",
          "confirmation_timing" => %{
            "version" => 1,
            "canonical_confirmed_at" => DateTime.to_iso8601(timestamp)
          }
        },
        timestamp
      )

    assert_receive {^handler_id,
                    %{
                      count: 1,
                      applied_to_canonical_ms: 0,
                      canonical_to_lifecycle_ms: 0,
                      applied_to_lifecycle_ms: 0
                    }, %{source: "finalizer", outcome: "confirmed_by_quota"}}
  end

  defp attach_convergence_handler!(event) do
    test_pid = self()
    handler_id = {__MODULE__, :saved_reset_convergence, System.unique_integer([:positive])}

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn ^event, measurements, metadata, ^test_pid ->
          send(test_pid, {handler_id, measurements, metadata})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    handler_id
  end

  defp convergable_identity_with_usable_evidence!(decision_at) do
    identity = identity_with_pending(DateTime.add(decision_at, -60, :second))

    upsert_source_window!(identity, Decimal.new("0"),
      source: "codex_usage_api",
      observed_at: decision_at
    )

    identity
  end

  test "fresh usable evidence confirms a pending reset" do
    consumed_at =
      DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)

    identity = identity_with_pending(consumed_at)
    upsert_account_window!(identity, Decimal.new("0"))

    assert {:ok, :confirmed_by_quota} = Convergence.converge(identity)

    assert redemption(identity)["phase"] == "confirmed_by_quota"
    assert redemption(identity)["status"] == "succeeded"
    assert redemption(identity)["terminal_reason"] == "converged_confirmed_by_quota"

    # The transition merges over the record: the fields the automatic-consume
    # latch reads must survive, and the fresh consume keeps the latch armed.
    converged = redemption(identity)
    assert converged["consumed_at"] == DateTime.to_iso8601(consumed_at)
    assert converged["result"]["applied"] == true

    assert RedemptionLifecycle.gateway_auto_latch(converged, DateTime.utc_now()) == :cooldown
  end

  test "fresh exhausted evidence reblocks a pending reset" do
    consumed_at =
      DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)

    identity = identity_with_pending(consumed_at)
    upsert_account_window!(identity, Decimal.new("100"))

    assert {:ok, :reblocked} = Convergence.converge(identity)
    assert redemption(identity)["phase"] == "reblocked"
    assert redemption(identity)["status"] == "failed"
  end

  test "a pending reset without fresh evidence stays pending until its window elapses" do
    consumed_at =
      DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)

    identity = identity_with_pending(consumed_at)

    # No fresh account window observed after consume -> nothing to converge yet.
    assert {:ok, :unchanged} = Convergence.converge(identity)
    assert redemption(identity)["phase"] == "consumed_pending_probe"
  end

  test "model-scoped additional quota leaves account-weekly convergence pending" do
    consumed_at =
      DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)

    identity = identity_with_pending(consumed_at)

    upsert_source_window!(identity, Decimal.new("0"),
      source: "codex_usage_api",
      observed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
      quota_key: "gpt_reserve",
      quota_scope: "model",
      quota_family: "codex_model",
      model: "gpt-reserve",
      metered_feature: "base_model_inference"
    )

    before = redemption(identity)
    assert {:ok, :unchanged} = Convergence.converge(identity)
    assert redemption(identity) == before
  end

  test "a pending reset past its bounded window expires fail-closed" do
    consumed_at =
      DateTime.utc_now() |> DateTime.add(-30, :minute) |> DateTime.truncate(:microsecond)

    identity = identity_with_pending(consumed_at)

    assert {:ok, :expired} = Convergence.converge(identity)
    assert redemption(identity)["phase"] == "expired"
    assert redemption(identity)["status"] == "failed"
  end

  test "an expired lifecycle recovers through fresh usable evidence" do
    consumed_at =
      DateTime.utc_now() |> DateTime.add(-30, :minute) |> DateTime.truncate(:microsecond)

    identity = identity_with_pending(consumed_at, phase: "expired")
    upsert_account_window!(identity, Decimal.new("0"))

    assert {:ok, :confirmed_by_quota} = Convergence.converge(identity)
    assert redemption(identity)["phase"] == "confirmed_by_quota"
  end

  test "an expired lifecycle reblocks through fresh exhausted evidence" do
    consumed_at =
      DateTime.utc_now() |> DateTime.add(-30, :minute) |> DateTime.truncate(:microsecond)

    identity = identity_with_pending(consumed_at, phase: "expired")
    upsert_account_window!(identity, Decimal.new("100"))

    assert {:ok, :reblocked} = Convergence.converge(identity)
    assert redemption(identity)["phase"] == "reblocked"
  end

  test "later usable evidence confirms the same applied reblocked lifecycle without field loss" do
    consumed_at =
      DateTime.utc_now() |> DateTime.add(-20, :minute) |> DateTime.truncate(:microsecond)

    replay = %{
      "version" => 1,
      "provider_dispatches" => 1,
      "scope_fingerprint" => "synthetic-scope-fingerprint"
    }

    target_history = [%{"version" => 1, "fingerprint" => "synthetic-target-fingerprint"}]

    identity =
      identity_with_pending(consumed_at,
        phase: "reblocked",
        metadata: %{"unrelated_identity_field" => %{"preserved" => true}},
        redemption_overrides: %{
          "trigger_detail" => "exhausted",
          "last_applied_consume_at" => DateTime.to_iso8601(consumed_at),
          "provider_replay" => replay,
          "encrypted_target_history" => target_history,
          "unrelated_redemption_field" => %{"preserved" => true}
        }
      )

    before = redemption(identity)
    now = DateTime.add(consumed_at, 20, :minute)

    assert Convergence.convergeable_lifecycle?(identity)
    assert RedemptionLifecycle.gateway_auto_latch(before, now) == :blocked_awaiting_quota

    upsert_account_window!(identity, Decimal.new("4"))

    # The canonical effective view evaluates at the convergence clock, so the
    # clock must not precede the just-persisted observation.
    converge_now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, :confirmed_by_quota} = Convergence.converge(identity, converge_now)
    assert {:ok, :unchanged} = Convergence.converge(identity, converge_now)

    converged = redemption(identity)

    assert Map.take(converged, [
             "attempt_id",
             "generation",
             "started_at",
             "consumed_at",
             "deadline_at",
             "last_applied_consume_at",
             "result",
             "trigger_kind",
             "trigger_detail",
             "provider_replay",
             "encrypted_target_history",
             "unrelated_redemption_field"
           ]) ==
             Map.take(before, [
               "attempt_id",
               "generation",
               "started_at",
               "consumed_at",
               "deadline_at",
               "last_applied_consume_at",
               "result",
               "trigger_kind",
               "trigger_detail",
               "provider_replay",
               "encrypted_target_history",
               "unrelated_redemption_field"
             ])

    assert converged["phase"] == "confirmed_by_quota"
    assert converged["status"] == "succeeded"
    assert converged["terminal_reason"] == "converged_confirmed_by_quota"
    assert converged["finished_at"] == DateTime.to_iso8601(converge_now)

    assert Repo.reload!(identity).metadata["unrelated_identity_field"] == %{"preserved" => true}
    assert RedemptionLifecycle.gateway_auto_latch(converged, converge_now) == :cooldown

    assert RedemptionLifecycle.gateway_auto_latch(
             converged,
             DateTime.add(consumed_at, 30, :minute)
           ) == :clear
  end

  test "stale duplicate-source rows cannot veto canonical usable convergence" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    consumed_at = DateTime.add(now, -20, :hour)
    stale_observed_at = DateTime.add(now, -14, :hour)

    identity = identity_with_pending(consumed_at, phase: "reblocked")
    before = redemption(identity)

    # Historical post-consume observations from other sources, now obsolete:
    # same logical windows, already-ended cycle.
    upsert_source_window!(identity, Decimal.new("100"),
      source: "codex_rate_limit_event",
      observed_at: stale_observed_at,
      reset_at: DateTime.add(stale_observed_at, 2, :hour)
    )

    upsert_source_window!(identity, Decimal.new("100"),
      source: "codex_response_headers",
      window_kind: "primary",
      window_minutes: 300,
      observed_at: stale_observed_at,
      reset_at: DateTime.add(stale_observed_at, 1, :hour)
    )

    # Current canonical usable account evidence for both logical windows.
    upsert_source_window!(identity, Decimal.new("26"),
      source: "codex_usage_api",
      observed_at: now
    )

    upsert_source_window!(identity, Decimal.new("20"),
      source: "codex_usage_api",
      window_kind: "primary",
      window_minutes: 300,
      observed_at: now,
      reset_at: DateTime.add(now, 5, :hour)
    )

    assert {:ok, :confirmed_by_quota} = Convergence.converge(identity)
    assert {:ok, :unchanged} = Convergence.converge(identity)

    converged = redemption(identity)
    assert converged["phase"] == "confirmed_by_quota"
    assert converged["status"] == "succeeded"
    assert converged["terminal_reason"] == "converged_confirmed_by_quota"

    assert Map.take(converged, ["attempt_id", "generation", "consumed_at", "result"]) ==
             Map.take(before, ["attempt_id", "generation", "consumed_at", "result"])
  end

  test "a current canonical exhausted window keeps the applied reblock reblocked" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    consumed_at = DateTime.add(now, -20, :hour)
    stale_observed_at = DateTime.add(now, -14, :hour)

    identity = identity_with_pending(consumed_at, phase: "reblocked")

    upsert_source_window!(identity, Decimal.new("10"),
      source: "codex_rate_limit_event",
      observed_at: stale_observed_at,
      reset_at: DateTime.add(stale_observed_at, 2, :hour)
    )

    upsert_source_window!(identity, Decimal.new("100"),
      source: "codex_usage_api",
      observed_at: now
    )

    assert {:ok, :unchanged} = Convergence.converge(identity)
    assert redemption(identity)["phase"] == "reblocked"
  end

  test "an applied reblocked lifecycle remains reblocked for exhausted or absent evidence" do
    consumed_at =
      DateTime.utc_now() |> DateTime.add(-30, :minute) |> DateTime.truncate(:microsecond)

    without_evidence = identity_with_pending(consumed_at, phase: "reblocked")

    assert {:ok, :unchanged} =
             Convergence.converge(without_evidence, DateTime.add(consumed_at, 1, :day))

    assert redemption(without_evidence)["phase"] == "reblocked"

    exhausted = identity_with_pending(consumed_at, phase: "reblocked")
    upsert_account_window!(exhausted, Decimal.new("100"))

    assert {:ok, :unchanged} = Convergence.converge(exhausted)
    assert redemption(exhausted)["phase"] == "reblocked"
  end

  test "malformed and non-applied reblocked lifecycles never become convergeable" do
    consumed_at =
      DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)

    invalid_overrides = [
      %{"attempt_id" => nil},
      %{"attempt_id" => "not-a-uuid"},
      %{"generation" => nil},
      %{"generation" => "3"},
      %{"consumed_at" => nil},
      %{"consumed_at" => "not-a-date"},
      %{"result" => %{"code" => "reset", "applied" => false}},
      %{"result" => nil}
    ]

    for overrides <- invalid_overrides do
      identity =
        identity_with_pending(consumed_at,
          phase: "reblocked",
          redemption_overrides: overrides
        )

      before = redemption(identity)
      upsert_account_window!(identity, Decimal.new("0"))

      refute Convergence.convergeable_lifecycle?(Repo.reload!(identity))
      assert {:ok, :unchanged} = Convergence.converge(identity)
      assert redemption(identity) == before
    end
  end

  test "concurrent convergence attempts serialize to one confirmed lifecycle" do
    consumed_at =
      DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)

    %{pool: pool, identity: identity} =
      Sandbox.unboxed_run(Repo, fn ->
        pool = pool_fixture()
        identity = identity_with_pending(consumed_at, pool: pool, phase: "reblocked")
        upsert_account_window!(identity, Decimal.new("0"))
        %{pool: pool, identity: identity}
      end)

    on_exit(fn -> cleanup_committed_fixture!(pool.id, identity.id) end)

    parent = self()
    barrier = make_ref()

    tasks =
      for _index <- 1..2 do
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            backend_pid = Repo.query!("SELECT pg_backend_pid()").rows |> hd() |> hd()
            send(parent, {:convergence_ready, barrier, self(), backend_pid})

            receive do
              {:converge, ^barrier} -> Convergence.converge(identity.id)
            end
          end)
        end)
      end

    actors =
      for _index <- 1..2 do
        assert_receive {:convergence_ready, ^barrier, actor, backend_pid}, 5_000
        {actor, backend_pid}
      end

    assert actors |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == 2
    Enum.each(actors, fn {actor, _backend_pid} -> send(actor, {:converge, barrier}) end)

    results = tasks |> Enum.map(&Task.await(&1, 5_000)) |> Enum.sort()
    assert results == [{:ok, :confirmed_by_quota}, {:ok, :unchanged}]

    converged = Sandbox.unboxed_run(Repo, fn -> Repo.get!(UpstreamIdentity, identity.id) end)
    assert converged.metadata["saved_reset_redemption"]["phase"] == "confirmed_by_quota"
  end

  test "a legacy record without a phase is never converged" do
    consumed_at =
      DateTime.utc_now() |> DateTime.add(-30, :minute) |> DateTime.truncate(:microsecond)

    identity = identity_with_pending(consumed_at, phase: nil)
    upsert_account_window!(identity, Decimal.new("0"))

    assert {:ok, :unchanged} = Convergence.converge(identity)
    assert redemption(identity)["status"] == "succeeded"
    refute Map.has_key?(redemption(identity), "phase")
  end

  @tag :scheduled_expiry_stale_claim_residual
  test "a stale phase-bearing consuming claim is not converged" do
    started_at =
      DateTime.utc_now() |> DateTime.add(-5, :minute) |> DateTime.truncate(:microsecond)

    identity = identity_with_pending(started_at, phase: "consuming")
    before_redemption = redemption(identity)

    refute Convergence.convergeable_lifecycle?(identity)
    assert {:ok, :unchanged} = Convergence.converge(identity, DateTime.utc_now())
    assert redemption(identity) == before_redemption
  end

  defp cleanup_committed_fixture!(pool_id, identity_id) do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.delete_all(from identity in UpstreamIdentity, where: identity.id == ^identity_id)
      Repo.delete_all(from pool in CodexPooler.Pools.Pool, where: pool.id == ^pool_id)
    end)
  end
end
