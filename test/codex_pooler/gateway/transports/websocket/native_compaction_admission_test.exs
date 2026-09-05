defmodule CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmissionTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission
  alias NativeCompactionAdmission.Binding
  alias NativeCompactionAdmission.Capability
  alias NativeCompactionAdmission.CapabilityToken
  alias NativeCompactionAdmission.Confirmation
  alias NativeCompactionAdmission.FirstCompactCollection
  alias NativeCompactionAdmission.Topology.Direct
  alias NativeCompactionAdmission.Topology.Forwarded

  @now 1_800_000_000_000

  test "walks the only compact and final transition sequence with one-shot capabilities" do
    binding = direct_binding()

    assert {:ok, ordinary} = NativeCompactionAdmission.ordinary_success(binding)
    assert NativeCompactionAdmission.phase(ordinary) == :ordinary_success
    assert {:ok, pending_compact} = NativeCompactionAdmission.arm_compact(ordinary, @now + 1_000)
    assert NativeCompactionAdmission.phase(pending_compact) == :pending_compact

    assert {:ok, reserved_compact, compact_capability} =
             NativeCompactionAdmission.reserve(
               pending_compact,
               :compact,
               binding,
               make_ref(),
               @now
             )

    assert NativeCompactionAdmission.phase(reserved_compact) == :reserved_compact

    assert {:ok, accounting_compact} =
             NativeCompactionAdmission.mark_accounting_started(
               reserved_compact,
               compact_capability,
               @now
             )

    assert NativeCompactionAdmission.phase(accounting_compact) == :accounting_started_compact

    assert {:ok, consumed_compact} =
             NativeCompactionAdmission.consume(accounting_compact, compact_capability, @now)

    assert NativeCompactionAdmission.phase(consumed_compact) == :consumed_compact
    assert {:ok, collected} = NativeCompactionAdmission.record_compact_collected(consumed_compact)
    assert NativeCompactionAdmission.phase(collected) == :collected_unconfirmed

    compact_item_digest = <<1::256>>

    confirmation_binding = %{binding | compaction_item_digest: compact_item_digest}

    final_binding =
      direct_binding(
        window_digest: <<2::256>>,
        context_digest: <<3::256>>,
        window_number: binding.window_number + 1,
        compaction_item_digest: compact_item_digest
      )

    confirmation = %Confirmation{
      source_phase: :compact,
      source_control_ref: NativeCompactionAdmission.control_ref(compact_capability),
      binding: confirmation_binding
    }

    assert {:ok, pending_final} =
             NativeCompactionAdmission.confirm_compact(
               collected,
               compact_item_digest,
               confirmation,
               @now + 1_000
             )

    assert NativeCompactionAdmission.phase(pending_final) == :pending_final

    assert {:ok, reserved_final, final_capability} =
             NativeCompactionAdmission.reserve(
               pending_final,
               :final,
               final_binding,
               make_ref(),
               @now
             )

    assert {:ok, accounting_final} =
             NativeCompactionAdmission.mark_accounting_started(
               reserved_final,
               final_capability,
               @now
             )

    assert {:ok, consumed_final} =
             NativeCompactionAdmission.consume(accounting_final, final_capability, @now)

    assert NativeCompactionAdmission.phase(consumed_final) == :consumed_final
    assert {:ok, cleared} = NativeCompactionAdmission.clear_consumed(consumed_final)
    assert NativeCompactionAdmission.phase(cleared) == :cleared
  end

  test "final reservation requires exact compact item digest and next window number" do
    binding = direct_binding()
    digest = <<91::256>>
    control_ref = make_ref()

    assert {:ok, ordinary} = NativeCompactionAdmission.ordinary_success(binding)
    assert {:ok, pending_compact} = NativeCompactionAdmission.arm_compact(ordinary, @now + 1_000)

    assert {:ok, reserved, capability} =
             NativeCompactionAdmission.reserve(
               pending_compact,
               :compact,
               binding,
               control_ref,
               @now
             )

    assert {:ok, accounting} =
             NativeCompactionAdmission.mark_accounting_started(reserved, capability, @now)

    assert {:ok, consumed} = NativeCompactionAdmission.consume(accounting, capability, @now)
    assert {:ok, collected} = NativeCompactionAdmission.record_compact_collected(consumed)

    confirmation_binding = %{binding | compaction_item_digest: digest}

    confirmation = %Confirmation{
      source_phase: :compact,
      source_control_ref: control_ref,
      binding: confirmation_binding
    }

    assert {:ok, pending_final} =
             NativeCompactionAdmission.confirm_compact(
               collected,
               digest,
               confirmation,
               @now + 1_000
             )

    valid =
      direct_binding(
        window_digest: <<92::256>>,
        context_digest: <<93::256>>,
        window_number: binding.window_number + 1,
        compaction_item_digest: digest
      )

    for invalid <- [
          %{valid | compaction_item_digest: nil},
          %{valid | compaction_item_digest: <<94::256>>},
          %{valid | window_number: binding.window_number}
        ] do
      assert {:error, :binding_mismatch} =
               NativeCompactionAdmission.reserve(
                 pending_final,
                 :final,
                 invalid,
                 make_ref(),
                 @now
               )
    end

    assert {:ok, _reserved, _capability} =
             NativeCompactionAdmission.reserve(
               pending_final,
               :final,
               valid,
               make_ref(),
               @now
             )
  end

  test "promotes one trusted first full-history compact and reserves the exact final request once" do
    binding = direct_binding()
    control_ref = make_ref()

    assert {:ok, ordinary} = NativeCompactionAdmission.ordinary_success(binding)

    assert {:ok, ordinary, provenance} =
             NativeCompactionAdmission.authorize_first_compact_collection(
               ordinary,
               control_ref
             )

    assert inspect(provenance) =~ "redacted"
    refute inspect(provenance) =~ Base.encode16(provenance.signature)

    assert {:ok, collected} =
             NativeCompactionAdmission.record_first_compact_collected(ordinary, provenance)

    assert NativeCompactionAdmission.phase(collected) == :collected_unconfirmed

    confirmation = %Confirmation{
      source_phase: :first_full_history_compact,
      source_control_ref: control_ref,
      binding: %{binding | compaction_item_digest: <<61::256>>}
    }

    assert {:ok, pending_final} =
             NativeCompactionAdmission.confirm_compact(
               collected,
               <<61::256>>,
               confirmation,
               @now + 100
             )

    final_binding =
      direct_binding(
        window_digest: <<62::256>>,
        context_digest: <<63::256>>,
        window_number: binding.window_number + 1,
        compaction_item_digest: <<61::256>>,
        previous_response_digest: nil
      )

    assert {:ok, reserved_final, _capability} =
             NativeCompactionAdmission.reserve(
               pending_final,
               :final,
               final_binding,
               make_ref(),
               @now
             )

    assert NativeCompactionAdmission.phase(reserved_final) == :reserved_final

    assert {:error, :invalid_transition} =
             NativeCompactionAdmission.confirm_compact(
               pending_final,
               <<61::256>>,
               confirmation,
               @now + 100
             )

    assert {:error, :invalid_transition} =
             NativeCompactionAdmission.reserve(
               reserved_final,
               :final,
               final_binding,
               make_ref(),
               @now
             )
  end

  test "rejects untrusted or mismatched first full-history collection provenance" do
    binding = direct_binding()
    control_ref = make_ref()
    assert {:ok, ordinary} = NativeCompactionAdmission.ordinary_success(binding)

    assert {:ok, ordinary, provenance} =
             NativeCompactionAdmission.authorize_first_compact_collection(
               ordinary,
               control_ref
             )

    assert {:error, :invalid_provenance} =
             NativeCompactionAdmission.record_first_compact_collected(ordinary, %{})

    for mismatch <- [
          FirstCompactCollection.replace_binding(
            provenance,
            direct_binding(generation: 2)
          ),
          FirstCompactCollection.replace_control_ref(provenance, make_ref()),
          FirstCompactCollection.replace_phase(provenance, :compact)
        ] do
      assert {:error, :provenance_mismatch, cleared} =
               NativeCompactionAdmission.record_first_compact_collected(ordinary, mismatch)

      assert NativeCompactionAdmission.phase(cleared) == :cleared
    end

    assert {:ok, collected} =
             NativeCompactionAdmission.record_first_compact_collected(ordinary, provenance)

    valid_confirmation = %Confirmation{
      source_phase: :first_full_history_compact,
      source_control_ref: control_ref,
      binding: binding
    }

    for mismatch <- [
          %{valid_confirmation | source_phase: :compact},
          %{valid_confirmation | source_control_ref: make_ref()},
          put_confirmation_binding(valid_confirmation, generation: 2)
        ] do
      assert {:error, :binding_mismatch, cleared} =
               NativeCompactionAdmission.confirm_compact(
                 collected,
                 <<64::256>>,
                 mismatch,
                 @now + 100
               )

      assert NativeCompactionAdmission.phase(cleared) == :cleared
    end

    assert {:error, :invalid_transition} =
             NativeCompactionAdmission.confirm_compact(
               collected,
               <<1>>,
               valid_confirmation,
               @now + 100
             )
  end

  test "binds reservations and rejects concurrency, replay, wrong phase, generation, and expiry" do
    assert {:ok, ordinary} = NativeCompactionAdmission.ordinary_success(direct_binding())
    assert {:ok, pending} = NativeCompactionAdmission.arm_compact(ordinary, @now + 100)

    assert {:ok, reserved, capability} =
             NativeCompactionAdmission.reserve(
               pending,
               :compact,
               direct_binding(),
               make_ref(),
               @now
             )

    assert {:error, :invalid_transition} =
             NativeCompactionAdmission.reserve(
               reserved,
               :compact,
               direct_binding(),
               make_ref(),
               @now
             )

    assert {:error, :invalid_transition} =
             NativeCompactionAdmission.reserve(
               pending,
               :final,
               direct_binding(),
               make_ref(),
               @now
             )

    stale_capability = Capability.replace_token(capability, :crypto.strong_rand_bytes(32))

    assert {:error, :capability_mismatch} =
             NativeCompactionAdmission.mark_accounting_started(reserved, stale_capability, @now)

    assert {:error, :binding_mismatch} =
             NativeCompactionAdmission.reserve(
               pending,
               :compact,
               direct_binding(generation: 2),
               make_ref(),
               @now
             )

    assert {:error, :expired} =
             NativeCompactionAdmission.mark_accounting_started(reserved, capability, @now + 101)

    assert {:expired, expired_cleared} = NativeCompactionAdmission.expire(reserved, @now + 101)
    assert NativeCompactionAdmission.phase(expired_cleared) == :cleared

    assert {:ok, accounting} =
             NativeCompactionAdmission.mark_accounting_started(reserved, capability, @now)

    assert {:error, :invalid_transition} =
             NativeCompactionAdmission.mark_accounting_started(accounting, capability, @now)

    assert {:ok, consumed} = NativeCompactionAdmission.consume(accounting, capability, @now)

    assert {:error, :invalid_transition} =
             NativeCompactionAdmission.consume(consumed, capability, @now)
  end

  test "compact reservation matches optional window number and previous response corroboration" do
    binding = direct_binding(window_number: 7)
    assert {:ok, ordinary} = NativeCompactionAdmission.ordinary_success(binding)
    assert {:ok, pending} = NativeCompactionAdmission.arm_compact(ordinary, @now + 100)

    for mismatch <- [
          direct_binding(window_number: 8),
          direct_binding(previous_response_digest: <<99::256>>)
        ] do
      assert {:error, :binding_mismatch} =
               NativeCompactionAdmission.reserve(
                 pending,
                 :compact,
                 mismatch,
                 make_ref(),
                 @now
               )
    end

    assert {:ok, _reserved, _capability} =
             NativeCompactionAdmission.reserve(
               pending,
               :compact,
               direct_binding(window_number: 7, previous_response_digest: nil),
               make_ref(),
               @now
             )
  end

  test "releases only a proven pre-accounting cancellation and clears committed work" do
    assert {:ok, ordinary} = NativeCompactionAdmission.ordinary_success(direct_binding())
    assert {:ok, pending} = NativeCompactionAdmission.arm_compact(ordinary, @now + 100)

    assert {:ok, reserved, capability} =
             NativeCompactionAdmission.reserve(
               pending,
               :compact,
               direct_binding(),
               make_ref(),
               @now
             )

    assert {:ok, released} =
             NativeCompactionAdmission.cancel(reserved, capability, :pre_accounting, @now)

    assert NativeCompactionAdmission.phase(released) == :pending_compact

    assert {:ok, reserved_again, committed_capability} =
             NativeCompactionAdmission.reserve(
               released,
               :compact,
               direct_binding(),
               make_ref(),
               @now
             )

    assert {:ok, accounting} =
             NativeCompactionAdmission.mark_accounting_started(
               reserved_again,
               committed_capability,
               @now
             )

    assert {:error, :committed, cleared} =
             NativeCompactionAdmission.cancel(
               accounting,
               committed_capability,
               :pre_accounting,
               @now
             )

    assert NativeCompactionAdmission.phase(cleared) == :cleared
  end

  test "redacts state, capabilities, bindings, tokens, and digests from inspection" do
    sentinel = "unique-raw-sentinel-#{System.unique_integer([:positive])}"
    digest = :crypto.hash(:sha256, sentinel)
    binding = direct_binding(window_digest: digest)
    assert {:ok, ordinary} = NativeCompactionAdmission.ordinary_success(binding)
    assert {:ok, pending} = NativeCompactionAdmission.arm_compact(ordinary, @now + 100)

    assert {:ok, reserved, capability} =
             NativeCompactionAdmission.reserve(pending, :compact, binding, make_ref(), @now)

    for value <- [binding, reserved, capability] do
      inspected = inspect(value)
      refute inspected =~ sentinel
      refute inspected =~ Base.encode16(digest)
      assert inspected =~ "redacted"
    end
  end

  test "delegates opaque equal-length token authentication to the secure compare boundary" do
    expected = :crypto.strong_rand_bytes(32)
    presented = :crypto.strong_rand_bytes(32)
    parent = self()

    comparator = fn left, right ->
      send(parent, {:secure_compare_called, left, right})
      left == right
    end

    refute CapabilityToken.match?(expected, presented, comparator)
    assert_receive {:secure_compare_called, ^expected, ^presented}
    assert CapabilityToken.match?(expected, expected)
    refute CapabilityToken.match?(expected, presented)
    refute CapabilityToken.match?(expected, <<1>>)
  end

  test "models direct and forwarded bindings without fabricated topology fields" do
    assert {:ok, direct} = NativeCompactionAdmission.ordinary_success(direct_binding())
    assert NativeCompactionAdmission.phase(direct) == :ordinary_success

    assert {:ok, forwarded} = NativeCompactionAdmission.ordinary_success(forwarded_binding())
    assert NativeCompactionAdmission.phase(forwarded) == :ordinary_success

    refute Map.has_key?(direct_binding().topology, :downstream_epoch)

    for invalid <- [
          forwarded_binding(
            topology: %Forwarded{
              owner_instance_digest: <<1>>,
              downstream_epoch: 1,
              owner_lease_digest: <<2::256>>
            }
          ),
          forwarded_binding(
            topology: %Forwarded{
              owner_instance_digest: <<1::256>>,
              downstream_epoch: -1,
              owner_lease_digest: <<2::256>>
            }
          ),
          forwarded_binding(
            topology: %Forwarded{
              owner_instance_digest: <<1::256>>,
              downstream_epoch: 1,
              owner_lease_digest: <<2>>
            }
          )
        ] do
      assert {:error, :invalid_binding} = NativeCompactionAdmission.ordinary_success(invalid)
    end
  end

  test "compact confirmation preserves every immutable direct binding and transition dimension" do
    binding = direct_binding()
    {collected, control_ref} = collected_state(binding)

    valid_confirmation = %Confirmation{
      source_phase: :compact,
      source_control_ref: control_ref,
      binding: %{binding | compaction_item_digest: <<23::256>>}
    }

    assert {:ok, pending_final} =
             NativeCompactionAdmission.confirm_compact(
               collected,
               <<23::256>>,
               valid_confirmation,
               @now + 100
             )

    assert NativeCompactionAdmission.phase(pending_final) == :pending_final

    mismatches = [
      %{valid_confirmation | source_phase: :final},
      %{valid_confirmation | source_control_ref: make_ref()},
      put_confirmation_binding(valid_confirmation, semantic_turn_key: <<31::256>>),
      put_confirmation_binding(valid_confirmation, serving_mode: :other),
      put_confirmation_binding(valid_confirmation,
        lifecycle_id: "018f60df-713f-7ca8-b9a0-0d12c508a999"
      ),
      put_confirmation_binding(valid_confirmation, generation: 2),
      put_confirmation_binding(valid_confirmation, window_digest: <<21::256>>),
      put_confirmation_binding(valid_confirmation, context_digest: <<22::256>>),
      put_confirmation_binding(valid_confirmation,
        topology: %Forwarded{
          owner_instance_digest: <<32::256>>,
          downstream_epoch: 1,
          owner_lease_digest: <<33::256>>
        }
      )
    ]

    for mismatch <- mismatches do
      assert {:error, :binding_mismatch, cleared} =
               NativeCompactionAdmission.confirm_compact(
                 collected,
                 <<23::256>>,
                 mismatch,
                 @now + 100
               )

      assert NativeCompactionAdmission.phase(cleared) == :cleared
    end
  end

  test "compact confirmation preserves forwarded owner, downstream epoch, and lease" do
    binding = forwarded_binding()
    {collected, control_ref} = collected_state(binding)

    valid_confirmation = %Confirmation{
      source_phase: :compact,
      source_control_ref: control_ref,
      binding: %{binding | compaction_item_digest: <<43::256>>}
    }

    assert {:ok, _pending_final} =
             NativeCompactionAdmission.confirm_compact(
               collected,
               <<43::256>>,
               valid_confirmation,
               @now + 100
             )

    topology_mismatches = [
      %Forwarded{
        owner_instance_digest: <<51::256>>,
        downstream_epoch: 4,
        owner_lease_digest: <<53::256>>
      },
      %Forwarded{
        owner_instance_digest: <<52::256>>,
        downstream_epoch: 5,
        owner_lease_digest: <<53::256>>
      },
      %Forwarded{
        owner_instance_digest: <<52::256>>,
        downstream_epoch: 4,
        owner_lease_digest: <<54::256>>
      }
    ]

    for topology <- topology_mismatches do
      assert {:error, :binding_mismatch, cleared} =
               NativeCompactionAdmission.confirm_compact(
                 collected,
                 <<43::256>>,
                 put_confirmation_binding(valid_confirmation, topology: topology),
                 @now + 100
               )

      assert NativeCompactionAdmission.phase(cleared) == :cleared
    end
  end

  test "standalone compact rebinds only semantic turn with a resolved matching anchor" do
    for binding <- [direct_binding(), forwarded_binding()] do
      {:ok, ordinary} = NativeCompactionAdmission.ordinary_success(binding)
      {:ok, pending} = NativeCompactionAdmission.arm_compact(ordinary, @now + 100)

      candidate =
        Map.put(%{binding | semantic_turn_key: <<99::256>>}, :standalone_resolved_anchor?, true)

      assert {:ok, reserved, _} =
               NativeCompactionAdmission.reserve(pending, :compact, candidate, make_ref(), @now)

      assert reserved.binding.semantic_turn_key == <<99::256>>

      {:ok, accounting} =
        NativeCompactionAdmission.mark_accounting_started(reserved, reserved.capability, @now)

      {:ok, consumed} = NativeCompactionAdmission.consume(accounting, reserved.capability, @now)
      {:ok, collected} = NativeCompactionAdmission.record_compact_collected(consumed)
      digest = <<96::256>>

      confirmation = %Confirmation{
        source_phase: :compact,
        source_control_ref: reserved.capability.control_ref,
        binding: %{candidate | compaction_item_digest: digest}
      }

      assert {:ok, finished} =
               NativeCompactionAdmission.confirm_compact(
                 collected,
                 digest,
                 confirmation,
                 @now + 100
               )

      assert finished.phase == :cleared

      for invalid <- [
            Map.put(candidate, :standalone_resolved_anchor?, false),
            %{candidate | previous_response_digest: nil},
            %{candidate | previous_response_digest: <<98::256>>},
            %{candidate | generation: 2},
            %{candidate | window_digest: <<97::256>>}
          ] do
        assert {:error, :binding_mismatch} =
                 NativeCompactionAdmission.reserve(pending, :compact, invalid, make_ref(), @now)
      end
    end
  end

  defp direct_binding(overrides \\ []) do
    defaults = [
      semantic_turn_key: <<10::256>>,
      window_digest: <<11::256>>,
      context_digest: <<12::256>>,
      window_number: 1,
      previous_response_digest: <<13::256>>,
      serving_mode: :responses,
      topology: %Direct{},
      lifecycle_id: "018f60df-713f-7ca8-b9a0-0d12c508a123",
      generation: 1
    ]

    struct!(Binding, Keyword.merge(defaults, overrides))
  end

  defp forwarded_binding(overrides \\ []) do
    direct_binding(
      Keyword.merge(
        [
          topology: %Forwarded{
            owner_instance_digest: <<52::256>>,
            downstream_epoch: 4,
            owner_lease_digest: <<53::256>>
          }
        ],
        overrides
      )
    )
  end

  defp collected_state(binding) do
    assert {:ok, ordinary} = NativeCompactionAdmission.ordinary_success(binding)
    assert {:ok, pending} = NativeCompactionAdmission.arm_compact(ordinary, @now + 100)
    control_ref = make_ref()

    assert {:ok, reserved, capability} =
             NativeCompactionAdmission.reserve(pending, :compact, binding, control_ref, @now)

    assert {:ok, accounting} =
             NativeCompactionAdmission.mark_accounting_started(reserved, capability, @now)

    assert {:ok, consumed} = NativeCompactionAdmission.consume(accounting, capability, @now)
    assert {:ok, collected} = NativeCompactionAdmission.record_compact_collected(consumed)
    {collected, control_ref}
  end

  defp put_confirmation_binding(confirmation, overrides) do
    %{confirmation | binding: struct!(confirmation.binding, overrides)}
  end
end
