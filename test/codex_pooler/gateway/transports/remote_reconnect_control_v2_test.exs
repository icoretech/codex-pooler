defmodule CodexPooler.Gateway.Transports.RemoteReconnectControlV2Test do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Transports.Websocket.RemoteReconnectControlV2

  @tag :replay_protocol_v2
  test "validates the exact preflight shape and redacts every sensitive value" do
    attrs = attrs()
    assert {:ok, control} = RemoteReconnectControlV2.new(attrs)
    assert RemoteReconnectControlV2.validate(control) == :ok

    inspected = inspect(control)
    assert inspected =~ "token: redacted"

    for secret <- [
          attrs.codex_session_id,
          attrs.owner_lease_token,
          Base.encode16(attrs.semantic_turn_digest),
          attrs.authorization_binding.api_key_id
        ] do
      refute inspected =~ secret
    end

    assert {:error, {:unknown_fields, [:payload]}} =
             attrs |> Map.put(:payload, "forbidden") |> RemoteReconnectControlV2.new()
  end

  @tag :replay_provisional_state
  test "locks reserve commit query and cancel presence cells" do
    reserve =
      attrs()
      |> Map.merge(%{
        action: :provisional_reserve,
        intent: :suspended_replay,
        authorization_binding: nil,
        provisional_token: <<9::256>>,
        replay_generation: 1,
        consume_binding: nil
      })

    assert {:ok, _control} = RemoteReconnectControlV2.new(reserve)

    assert {:ok, _control} =
             RemoteReconnectControlV2.new(%{
               reserve
               | action: :provisional_commit,
                 consume_binding: consume_binding()
             })

    for action <- [:provisional_query, :provisional_cancel] do
      assert {:ok, _control} =
               RemoteReconnectControlV2.new(%{reserve | action: action, downstream: nil})
    end

    assert {:error, {:invalid_field, :provisional_token}} =
             RemoteReconnectControlV2.new(%{reserve | provisional_token: <<1>>})
  end

  defp attrs do
    session_id = Ecto.UUID.generate()

    %{
      version: 2,
      action: :preflight,
      intent: :active_reattach,
      codex_session_id: session_id,
      downstream: %{pid: self(), epoch: 2, correlation_id: "synthetic"},
      semantic_turn_digest: <<1::256>>,
      replay_claim_digest: <<2::256>>,
      provisional_token: nil,
      replay_generation: nil,
      owner_lease_token: Ecto.UUID.generate(),
      control_ref: make_ref(),
      authorization_binding: %{
        api_key_id: Ecto.UUID.generate(),
        api_key_runtime_epoch: 0,
        pool_id: Ecto.UUID.generate(),
        codex_session_id: session_id,
        model_identifier: "gpt-test"
      },
      consume_binding: %{
        request_id: Ecto.UUID.generate(),
        codex_turn_id: Ecto.UUID.generate(),
        eligible_attempt_id: Ecto.UUID.generate(),
        replay_attempt_id: nil,
        replay_generation: 0,
        provisional_binding_digest: nil,
        owner_lease_digest: <<4::256>>
      }
    }
  end

  defp consume_binding do
    %{
      request_id: Ecto.UUID.generate(),
      codex_turn_id: Ecto.UUID.generate(),
      eligible_attempt_id: Ecto.UUID.generate(),
      replay_attempt_id: Ecto.UUID.generate(),
      replay_generation: 1,
      provisional_binding_digest: <<3::256>>,
      owner_lease_digest: <<4::256>>
    }
  end
end
