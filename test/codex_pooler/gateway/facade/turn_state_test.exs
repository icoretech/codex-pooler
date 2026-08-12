defmodule CodexPooler.Gateway.Facade.TurnStateTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Facade.TurnState

  test "round trips exact upstream state within a bounded opaque handle" do
    auth = auth()
    assignment_id = Ecto.UUID.generate()
    session_id = Ecto.UUID.generate()
    raw = String.duplicate("r", 2_048)

    assert {:ok, handle} =
             TurnState.mint(raw, auth, assignment_id,
               session_id: session_id,
               now: 1_000,
               ttl_seconds: 60
             )

    assert byte_size(handle) <= 4_096
    refute handle =~ raw

    assert {:ok,
            %{
              public: ^handle,
              upstream: ^raw,
              assignment_id: ^assignment_id,
              session_id: ^session_id
            }} = TurnState.resolve(handle, auth, now: 1_059)

    assert {:error, :invalid} =
             TurnState.mint(String.duplicate("r", 2_049), auth, assignment_id)
  end

  test "rejects expiry, tampering, cross-key, and cross-Pool use" do
    auth = auth()
    assignment_id = Ecto.UUID.generate()

    assert {:ok, handle} =
             TurnState.mint("raw-upstream-state", auth, assignment_id,
               now: 1_000,
               ttl_seconds: 60
             )

    assert {:error, :invalid} = TurnState.resolve(handle, auth, now: 1_060)
    assert {:error, :invalid} = TurnState.resolve(handle <> "x", auth, now: 1_001)

    assert {:error, :invalid} =
             TurnState.resolve(handle, %{auth | api_key: %{id: Ecto.UUID.generate()}}, now: 1_001)

    assert {:error, :invalid} =
             TurnState.resolve(handle, %{auth | pool: %{id: Ecto.UUID.generate()}}, now: 1_001)
  end

  defp auth do
    %{
      pool: %{id: Ecto.UUID.generate()},
      api_key: %{id: Ecto.UUID.generate()}
    }
  end
end
