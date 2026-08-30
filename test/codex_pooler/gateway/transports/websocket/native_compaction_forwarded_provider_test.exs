defmodule CodexPooler.Gateway.Transports.Websocket.NativeCompactionForwardedProviderTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Gateway.Transports.NativeCompactionFailureScenarios.AccountingLifecycle
  alias CodexPooler.Gateway.Transports.NativeCompactionFailureScenarios.Context
  alias CodexPooler.Gateway.Transports.NativeCompactionFailureScenarios.ForwardedOwnerBoundary
  alias CodexPooler.Gateway.Transports.NativeCompactionFailureScenarios.Observed

  @variants [
    :caller_death_after_accounting,
    :socket_disconnect,
    :owner_timeout,
    :owner_crash,
    :owner_drain,
    :pending_handoff,
    :handoff_soft_timeout,
    :handoff_absolute_timeout,
    :stale_lease,
    :stale_epoch,
    :stale_control
  ]

  @expected %{
    caller_death_after_accounting: {:cleared, 0, 1, :survived},
    socket_disconnect: {:cleared, 0, 1, :survived},
    owner_timeout: {:cleared, 0, 1, :survived},
    owner_crash: {:destroyed_with_owner, 0, 1, :retired},
    owner_drain: {:destroyed_with_owner, 0, 1, :retired},
    pending_handoff: {:cleared, 0, 0, :survived},
    handoff_soft_timeout: {:cleared, 0, 0, :survived},
    handoff_absolute_timeout: {:destroyed_with_owner, 0, 1, :retired},
    stale_lease: {:destroyed_with_owner, 0, 0, :retired},
    stale_epoch: {:cleared, 0, 0, :survived},
    stale_control: {:cleared, 0, 0, :survived}
  }

  for variant <- @variants do
    test "#{variant} returns production-bound observations" do
      context = context()

      assert %Observed{} = observed = ForwardedOwnerBoundary.run(unquote(variant), context)
      assert observed.upstream_send_count >= 0
      assert observed.owner_fate in [:survived, :retired]
      assert observed.metadata[:observation_sources] == "monitor,repo,owner,upstream"

      assert observation_tuple(observed) == Map.fetch!(@expected, unquote(variant))
    end
  end

  test "observations do not depend on registry expectations" do
    first = ForwardedOwnerBoundary.run(:stale_control, context())
    second = ForwardedOwnerBoundary.run(:stale_control, context())

    assert Map.take(first, [
             :admission_phase,
             :upstream_send_count,
             :accounting_lifecycle,
             :owner_fate
           ]) ==
             Map.take(second, [
               :admission_phase,
               :upstream_send_count,
               :accounting_lifecycle,
               :owner_fate
             ])
  end

  defp context do
    %Context{
      test_pid: self(),
      sandbox_owner: self(),
      scenario_namespace: "forwarded-provider-#{System.unique_integer([:positive, :monotonic])}",
      cleanup_registry: self()
    }
  end

  defp observation_tuple(%Observed{
         admission_phase: phase,
         upstream_send_count: sends,
         accounting_lifecycle: %AccountingLifecycle{} = lifecycle,
         owner_fate: owner_fate
       }) do
    lifecycle_count =
      lifecycle
      |> Map.from_struct()
      |> Map.values()
      |> Enum.uniq()
      |> then(fn [count] -> count end)

    {phase, sends, lifecycle_count, owner_fate}
  end
end
