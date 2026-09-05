defmodule CodexPooler.Gateway.Transports.Websocket.NativeCompactionLifecycleObservationTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission, as: Admission

  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionLifecycleObservation,
    as: Observation

  alias Admission.Binding
  alias Admission.Topology.Direct
  alias Admission.Topology.Forwarded

  @lifecycle_id "11111111-1111-4111-8111-111111111111"
  @max_counter 9_223_372_036_854_775_807

  test "observes an actual reservation without exposing or changing its capability" do
    binding = admission_binding()
    assert {:ok, ordinary} = Admission.ordinary_success(binding)
    assert {:ok, pending} = Admission.arm_compact(ordinary, 2_000)

    assert {:ok, reserved, capability} =
             Admission.reserve(pending, :compact, binding, make_ref(), 1_000)

    assert Observation.observe(pending, reserved, :reserve, :success, :direct) == %{
             operation: :reserve,
             reason: :success,
             topology: :direct,
             phase_from: :pending_compact,
             phase_to: :reserved_compact,
             native_lifecycle_id: @lifecycle_id,
             generation: 7,
             downstream_epoch: nil
           }

    assert {:ok, accounted} = Admission.mark_accounting_started(reserved, capability, 1_000)

    assert Observation.observe(reserved, accounted, :accounting, :success, :direct).phase_to ==
             :accounting_started_compact

    assert {:ok, _consumed} = Admission.consume(accounted, capability, 1_000)
  end

  test "a clear retains only the removed forwarded lifecycle snapshot" do
    topology = %Forwarded{
      owner_instance_digest: <<1::256>>,
      owner_lease_digest: <<2::256>>,
      downstream_epoch: 12
    }

    before = %Admission{phase: :pending_final, binding: admission_binding(topology: topology)}

    assert Observation.observe(
             before,
             Admission.clear(before),
             :clear,
             :connection_invalidated,
             :forwarded
           ) == %{
             operation: :clear,
             reason: :connection_invalidated,
             topology: :forwarded,
             phase_from: :pending_final,
             phase_to: :cleared,
             native_lifecycle_id: @lifecycle_id,
             generation: 7,
             downstream_epoch: 12
           }
  end

  test "a replacement uses the new lifecycle and generation without carrying the old binding" do
    before = %Admission{phase: :ordinary_success, binding: admission_binding()}
    next_id = "22222222-2222-4222-8222-222222222222"
    after_state = %{before | binding: admission_binding(lifecycle_id: next_id, generation: 8)}
    observation = Observation.observe(before, after_state, :ordinary_success, :success, :direct)
    assert observation.native_lifecycle_id == next_id
    assert observation.generation == 8
  end

  test "unknown operations reasons topologies and phases use fixed fallbacks" do
    private = "PRIVATE_OBSERVATION_SENTINEL"

    invalid = %Admission{
      phase: private,
      binding: %{lifecycle_id: @lifecycle_id},
      capability: private
    }

    assert Observation.observe(invalid, private, private, private, private) == %{
             operation: :unknown,
             reason: :unknown,
             topology: :unknown,
             phase_from: :unknown,
             phase_to: :unknown,
             native_lifecycle_id: nil,
             generation: nil,
             downstream_epoch: nil
           }

    observation = Observation.observe(nil, nil, :reject, :invalid_input, :direct)
    assert observation.phase_from == :cleared
    assert observation.phase_to == :cleared
  end

  test "only textual UUIDs from admission binding structs can become lifecycle correlators" do
    for value <- ["PRIVATE_16_BYTES", <<255>>, "not-a-uuid", 123, %{}, nil] do
      state = %Admission{
        phase: :ordinary_success,
        binding: admission_binding(lifecycle_id: value)
      }

      assert Observation.observe(nil, state, :ordinary_success, :success, :direct).native_lifecycle_id ==
               nil
    end

    state = %Admission{phase: :ordinary_success, binding: Map.from_struct(admission_binding())}

    assert Observation.observe(nil, state, :ordinary_success, :success, :direct).native_lifecycle_id ==
             nil
  end

  test "generation and epoch reject malformed and unbounded counters" do
    for value <- [-1, @max_counter + 1, "PRIVATE_COUNTER_SENTINEL", 1.0, nil] do
      topology = %Forwarded{
        owner_instance_digest: <<1::256>>,
        owner_lease_digest: <<2::256>>,
        downstream_epoch: value
      }

      state = %Admission{
        phase: :pending_compact,
        binding: admission_binding(generation: value, topology: topology)
      }

      observation = Observation.observe(nil, state, :reserve, :success, :forwarded)
      assert observation.generation == nil
      assert observation.downstream_epoch == nil
    end

    topology = %Forwarded{
      owner_instance_digest: <<1::256>>,
      owner_lease_digest: <<2::256>>,
      downstream_epoch: 0
    }

    state = %Admission{
      phase: :ordinary_success,
      binding: admission_binding(generation: 0, topology: topology)
    }

    observation = Observation.observe(nil, state, :ordinary_success, :success, :forwarded)
    assert observation.generation == nil
    assert observation.downstream_epoch == 0
  end

  test "fixed lifecycle operation and reason vocabulary remains observable" do
    operations = [
      :reserve,
      :accounting,
      :consume,
      :confirm,
      :cancel,
      :clear,
      :ordinary_success,
      :collect,
      :reject
    ]

    reasons = [
      :success,
      :stale_downstream,
      :stale_capability,
      :invalid_transition,
      :binding_mismatch,
      :expired,
      :invalid_input,
      :owner_unavailable,
      :request_rejected,
      :connection_invalidated,
      :connection_closed,
      :final_success,
      :final_failure,
      :compact_failure,
      :send_failure,
      :caller_exit
    ]

    for operation <- operations, reason <- reasons, topology <- [:direct, :forwarded] do
      observation = Observation.observe(nil, nil, operation, reason, topology)
      assert observation.operation == operation
      assert observation.reason == reason
      assert observation.topology == topology
    end
  end

  defp admission_binding(overrides \\ []) do
    struct!(
      Binding,
      Keyword.merge(
        [
          semantic_turn_key: <<0::256>>,
          window_digest: <<1::256>>,
          context_digest: <<2::256>>,
          window_number: 1,
          serving_mode: :owner_reuse,
          topology: %Direct{},
          lifecycle_id: @lifecycle_id,
          generation: 7
        ],
        overrides
      )
    )
  end
end
