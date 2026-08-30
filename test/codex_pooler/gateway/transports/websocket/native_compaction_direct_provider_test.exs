defmodule CodexPooler.Gateway.Transports.Websocket.NativeCompactionDirectProviderTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Gateway.Transports.NativeCompactionFailureScenarios.Context
  alias CodexPooler.Gateway.Transports.NativeCompactionFailureScenarios.DirectSessionBoundary
  alias CodexPooler.Gateway.Transports.NativeCompactionFailureScenarios.Observed

  @expected %{
    pre_commit_cancellation: {:pending_compact, 0, 0},
    caller_death_after_send: {:cleared, 1, 1},
    stale_token: {:cleared, 0, 1},
    reconnect_before_send: {:cleared, 0, 1},
    generation_replacement_before_send: {:cleared, 0, 1},
    send_failure: {:cleared, 1, 1},
    terminal_failure: {:cleared, 1, 1},
    finalization_failure: {:cleared, 1, 1},
    compact_collection: {:collected_unconfirmed, 1, 1},
    compact_ack_success: {:pending_final, 1, 1},
    compact_ack_failure: {:cleared, 1, 1},
    final_success: {:cleared, 1, 1},
    final_failure: {:cleared, 1, 1}
  }

  for {variant, {expected_phase, expected_sends, expected_accounting}} <- @expected do
    test "#{variant} returns production-bound observations" do
      context = %Context{
        test_pid: self(),
        sandbox_owner: self(),
        scenario_namespace:
          "direct-#{unquote(variant)}-#{System.unique_integer([:positive, :monotonic])}",
        cleanup_registry: self()
      }

      assert %Observed{} = observed = DirectSessionBoundary.run(unquote(variant), context)
      assert observed.admission_phase == unquote(expected_phase)
      assert observed.upstream_send_count == unquote(expected_sends)
      assert observed.owner_fate == :survived
      assert observed.metadata.sources == "session,upstream,repo,monitor"

      expected_accounting = unquote(expected_accounting)

      assert observed.accounting_lifecycle.requests == expected_accounting
      assert observed.accounting_lifecycle.attempts == expected_accounting
      assert observed.accounting_lifecycle.turns == expected_accounting
      assert observed.accounting_lifecycle.reservations == expected_accounting
      assert observed.accounting_lifecycle.settlements == expected_accounting
    end
  end

  test "pre-commit cancellation observes no persisted or physical side effects" do
    context = %Context{
      test_pid: self(),
      sandbox_owner: self(),
      scenario_namespace: "direct-pre-commit-#{System.unique_integer([:positive, :monotonic])}",
      cleanup_registry: self()
    }

    assert %Observed{
             admission_phase: :pending_compact,
             upstream_send_count: 0,
             accounting_lifecycle: %{
               requests: 0,
               attempts: 0,
               turns: 0,
               reservations: 0,
               settlements: 0
             },
             owner_fate: :survived
           } = DirectSessionBoundary.run(:pre_commit_cancellation, context)
  end
end
