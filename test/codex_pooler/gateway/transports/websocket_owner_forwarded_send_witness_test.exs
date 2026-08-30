defmodule CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwardedSendWitnessTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Transports.Websocket.ForwardedOwnerRequestHandoff
  alias CodexPooler.Gateway.Transports.Websocket.ForwardedSendWitnessV1
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission

  test "issues a redacted signed witness bound to capability downstream and lifecycle" do
    capability = capability()

    assert {:ok, witness} =
             ForwardedSendWitnessV1.issue(
               capability,
               %{correlation_id: "sensitive-correlation", epoch: 7},
               1_000
             )

    assert ForwardedSendWitnessV1.valid?(witness)
    assert ForwardedSendWitnessV1.digest(witness) |> byte_size() == 32
    assert inspect(witness) == "#ForwardedSendWitnessV1<compact:redacted>"
    refute inspect(witness) =~ "sensitive-correlation"
    refute inspect(witness) =~ Base.encode16(capability.token)

    assert ForwardedSendWitnessV1.authorizes?(
             witness,
             capability.binding,
             capability.control_ref,
             %{correlation_id: "sensitive-correlation", epoch: 7},
             %{lifecycle_id: capability.binding.lifecycle_id, generation: 2},
             :full,
             1_000
           )

    refute ForwardedSendWitnessV1.authorizes?(
             witness,
             capability.binding,
             capability.control_ref,
             %{correlation_id: "sensitive-correlation", epoch: 7},
             %{lifecycle_id: capability.binding.lifecycle_id, generation: 3},
             :full,
             1_000
           )
  end

  test "rejects malformed expired stale-control stale-epoch stale-mode and replay-shaped witnesses" do
    capability = capability()

    {:ok, witness} =
      ForwardedSendWitnessV1.issue(capability, %{correlation_id: "corr", epoch: 7}, 1_000)

    lifecycle = %{lifecycle_id: capability.binding.lifecycle_id, generation: 2}

    refute ForwardedSendWitnessV1.authorizes?(
             witness,
             capability.binding,
             capability.control_ref,
             %{correlation_id: "corr", epoch: 7},
             lifecycle,
             :full,
             capability.expires_at_ms + 1
           )

    refute ForwardedSendWitnessV1.authorizes?(
             witness,
             capability.binding,
             make_ref(),
             %{correlation_id: "corr", epoch: 7},
             lifecycle,
             :full,
             1_000
           )

    refute ForwardedSendWitnessV1.authorizes?(
             witness,
             capability.binding,
             capability.control_ref,
             %{correlation_id: "corr", epoch: 8},
             lifecycle,
             :full,
             1_000
           )

    refute ForwardedSendWitnessV1.authorizes?(
             witness,
             capability.binding,
             capability.control_ref,
             %{correlation_id: "corr", epoch: 7},
             lifecycle,
             :lite,
             1_000
           )

    refute ForwardedSendWitnessV1.valid?(%{witness | signature: <<0::256>>})
  end

  test "dead owner redemption returns a bounded rejection without exiting" do
    owner = spawn(fn -> :ok end)
    monitor = Process.monitor(owner)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}

    handoff = ForwardedOwnerRequestHandoff.new(owner, witness())

    assert ForwardedOwnerRequestHandoff.redeem(handoff, lifecycle(), :full) ==
             {:error, :forwarded_send_witness_rejected}
  end

  test "owner shutdown during redemption returns a bounded rejection" do
    owner =
      spawn(fn ->
        receive do
          {:"$gen_call", _from, _message} ->
            exit(:shutdown)
        end
      end)

    handoff = ForwardedOwnerRequestHandoff.new(owner, witness())

    assert ForwardedOwnerRequestHandoff.redeem(handoff, lifecycle(), :full) ==
             {:error, :forwarded_send_witness_rejected}
  end

  test "hung owner redemption uses the explicit finite call budget" do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    handoff = ForwardedOwnerRequestHandoff.new(owner, witness())

    started = System.monotonic_time(:millisecond)

    assert ForwardedOwnerRequestHandoff.redeem(handoff, lifecycle(), :full, 10) ==
             {:error, :forwarded_send_witness_rejected}

    assert System.monotonic_time(:millisecond) - started < 1_000
    send(owner, :stop)
  end

  defp capability do
    binding = %NativeCompactionAdmission.Binding{
      semantic_turn_key: <<1::256>>,
      window_digest: <<2::256>>,
      context_digest: <<3::256>>,
      window_number: nil,
      previous_response_digest: nil,
      serving_mode: :full,
      topology: %NativeCompactionAdmission.Topology.Forwarded{
        owner_instance_digest: <<4::256>>,
        downstream_epoch: 7,
        owner_lease_digest: <<5::256>>
      },
      lifecycle_id: Ecto.UUID.generate(),
      generation: 2
    }

    {:ok, ordinary} = NativeCompactionAdmission.ordinary_success(binding)
    {:ok, pending} = NativeCompactionAdmission.arm_compact(ordinary, 10_000)

    {:ok, _reserved, capability} =
      NativeCompactionAdmission.reserve(pending, :compact, binding, make_ref(), 1_000)

    capability
  end

  defp witness do
    {:ok, witness} =
      ForwardedSendWitnessV1.issue(
        capability(),
        %{correlation_id: "corr", epoch: 7},
        1_000
      )

    witness
  end

  defp lifecycle do
    witness().binding
    |> Map.take([:lifecycle_id, :generation])
  end
end
