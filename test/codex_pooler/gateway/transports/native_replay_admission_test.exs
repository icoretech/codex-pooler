defmodule CodexPooler.Gateway.Transports.NativeReplayAdmissionTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Transports.Websocket.NativeReplayAdmission

  test "validates every binding dimension and exposes the exact consume subset" do
    binding = replay_binding()
    assert {:ok, digest} = NativeReplayAdmission.binding_digest(binding)
    assert byte_size(digest) == 32

    assert NativeReplayAdmission.consume_binding(binding) ==
             Map.take(binding, [
               :request_id,
               :codex_turn_id,
               :eligible_attempt_id,
               :replay_attempt_id,
               :replay_generation,
               :provisional_binding_digest,
               :owner_lease_digest
             ])

    for invalid <- [
          %{binding | replay_generation: 0},
          %{binding | replay_claim_digest: <<1>>},
          %{binding | downstream_epoch: 0},
          %{binding | owner_process_generation: 0}
        ] do
      assert {:error, :invalid_binding} = NativeReplayAdmission.binding_digest(invalid)
    end

    assert inspect(binding) == "#NativeReplayAdmission.Binding<redacted>"
  end

  defp replay_binding do
    %NativeReplayAdmission.Binding{
      request_id: Ecto.UUID.generate(),
      codex_turn_id: Ecto.UUID.generate(),
      eligible_attempt_id: Ecto.UUID.generate(),
      replay_attempt_id: Ecto.UUID.generate(),
      replay_generation: 1,
      semantic_turn_digest: <<1::256>>,
      replay_claim_digest: <<2::256>>,
      provisional_binding_digest: <<3::256>>,
      owner_lease_digest: <<4::256>>,
      downstream_epoch: 2,
      owner_process_generation: 1
    }
  end
end
