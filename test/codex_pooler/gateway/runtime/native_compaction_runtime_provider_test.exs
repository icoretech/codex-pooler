defmodule CodexPooler.Gateway.Runtime.NativeCompactionRuntimeProviderTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Gateway.Transports.NativeCompactionFailureScenarios.AccountingLifecycle
  alias CodexPooler.Gateway.Transports.NativeCompactionFailureScenarios.Observed
  alias CodexPooler.Gateway.Transports.NativeCompactionFailureScenarios.RuntimeBoundary

  @variants [
    :validation_admission_overload,
    :routing_denial,
    :saved_reset,
    :accounting_reservation_failure,
    :caller_death_before_accounting
  ]

  for variant <- @variants do
    test "#{variant} observes the real zero-work runtime boundary" do
      assert %Observed{
               admission_phase: :cleared,
               upstream_send_count: 0,
               accounting_lifecycle: %AccountingLifecycle{
                 requests: 0,
                 attempts: 0,
                 turns: 0,
                 reservations: 0,
                 settlements: 0
               },
               owner_fate: :survived,
               metadata: metadata
             } = RuntimeBoundary.run(unquote(variant), %{provider_run_id: unquote(variant)})

      assert is_map(metadata)
      refute inspect(metadata) =~ "input_text"
      refute inspect(metadata) =~ "Bearer"
    end
  end

  test "shared accounting helpers observe real reservation, attempt, and turn rows" do
    handle = RuntimeBoundary.open_accounted_lifecycle!(%{}, :shared_accounting_contract)

    assert %AccountingLifecycle{
             requests: 1,
             attempts: 1,
             turns: 1,
             reservations: 1,
             settlements: 0
           } = RuntimeBoundary.observe_accounting!(handle)

    assert %AccountingLifecycle{
             requests: 1,
             attempts: 1,
             turns: 1,
             reservations: 1,
             settlements: 1
           } =
             RuntimeBoundary.settle_accounted_lifecycle!(
               handle,
               :shared_accounting_contract_failure
             )
  end

  test "shared accounting helpers complete a real success lifecycle" do
    handle = RuntimeBoundary.open_accounted_lifecycle!(%{}, :shared_accounting_success)

    assert %AccountingLifecycle{
             requests: 1,
             attempts: 1,
             turns: 1,
             reservations: 1,
             settlements: 1
           } = RuntimeBoundary.settle_accounted_lifecycle!(handle, :success)
  end

  test "multiple accounting lifecycles compose in one sandbox with distinct pricing versions" do
    context = %{scenario_namespace: "runtime-composability"}
    first = RuntimeBoundary.open_accounted_lifecycle!(context, :first_lifecycle)
    second = RuntimeBoundary.open_accounted_lifecycle!(context, :second_lifecycle)

    assert first.resource.fixture.pricing.price_version !=
             second.resource.fixture.pricing.price_version

    for handle <- [first, second] do
      assert %AccountingLifecycle{
               requests: 1,
               attempts: 1,
               turns: 1,
               reservations: 1,
               settlements: 1
             } = RuntimeBoundary.settle_accounted_lifecycle!(handle, :success)
    end
  end
end
