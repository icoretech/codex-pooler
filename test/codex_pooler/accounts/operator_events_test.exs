defmodule CodexPooler.Accounts.OperatorEventsTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounts.OperatorEvents

  test "broadcast_update reaches subscribers in other processes" do
    assert :ok = OperatorEvents.subscribe_updates()

    assert :ok =
             publish_from_task(fn ->
               OperatorEvents.broadcast_update("operator.updated", %{operator_id: "external"})
             end)

    assert_receive {OperatorEvents, event}
    assert event.reason == "operator.updated"
    assert event.payload == %{"operator_id" => "external"}
  end

  test "broadcast_update does not deliver back to the broadcasting subscriber" do
    assert :ok = OperatorEvents.subscribe_updates()

    assert :ok = OperatorEvents.broadcast_update("operator.updated", %{operator_id: "self"})

    refute_receive {OperatorEvents, %{reason: "operator.updated"}}
  end

  defp publish_from_task(fun) when is_function(fun, 0) do
    fun
    |> Task.async()
    |> Task.await(5_000)
  end
end
