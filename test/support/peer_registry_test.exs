defmodule CodexPooler.PeerRegistryTest do
  @moduledoc """
  The wait must actually wait. A fixed sleep would pass "it eventually returned :ok" just as
  well, so every case here pins what the wait spent: how many samples it took, and how its
  elapsed time relates to the moment the peer became absent and to the budget.
  """
  use ExUnit.Case, async: true

  alias CodexPooler.PeerRegistry

  @peer :peer_registry_probe
  @registered {:ok, [{~c"peer_registry_probe", 41_475}, {~c"someone_else", 40_431}]}
  @absent {:ok, [{~c"someone_else", 40_431}]}

  # Long enough to be unambiguously more than one poll interval, short enough to stay a
  # sub-second test. The property under test is real elapsed time, so it cannot be faked out.
  @flip_after_ms 150

  test "returns as soon as the name leaves epmd instead of waiting out the budget" do
    names = replies([@registered, @registered, @absent])

    assert {:ok, detail} =
             PeerRegistry.await_peer_absent(@peer,
               names_fun: names,
               budget_ms: 5_000,
               poll_ms: 5
             )

    assert detail.samples == 3
    assert detail.elapsed_ms < 5_000
  end

  test "keeps polling across real elapsed time rather than sampling once" do
    started = System.monotonic_time(:millisecond)
    names = fn -> if elapsed_since(started) < @flip_after_ms, do: @registered, else: @absent end

    assert {:ok, detail} =
             PeerRegistry.await_peer_absent(@peer,
               names_fun: names,
               budget_ms: 5_000,
               poll_ms: 10
             )

    # It cannot have succeeded before the peer became absent, and it cannot have got there in
    # one sample: it waited, and it re-read epmd while waiting.
    assert detail.elapsed_ms >= @flip_after_ms
    assert detail.samples > 1
    # A single fixed sleep of the budget would also have returned :ok, so pin that it did not.
    assert detail.elapsed_ms < 1_000
  end

  test "a peer that never leaves times out on the budget and reports it" do
    assert {:timeout, detail} =
             PeerRegistry.await_peer_absent(@peer,
               names_fun: fn -> @registered end,
               budget_ms: 120,
               poll_ms: 10
             )

    assert detail.budget_ms == 120
    assert detail.elapsed_ms >= 120
    assert detail.registered
    assert detail.samples > 1
  end

  test "an unreadable epmd is retried, not read as absence" do
    names = replies([{:error, :address}, {:error, :address}, @absent])

    assert {:ok, detail} =
             PeerRegistry.await_peer_absent(@peer, names_fun: names, budget_ms: 5_000, poll_ms: 5)

    assert detail.samples == 3
  end

  test "a node still in the connected list keeps the wait open after epmd is clean" do
    started = System.monotonic_time(:millisecond)
    peer_node = :"peer_registry_probe@nowhere.invalid"

    connected = fn ->
      if elapsed_since(started) < @flip_after_ms, do: [peer_node], else: []
    end

    assert {:ok, detail} =
             PeerRegistry.await_peer_absent(@peer,
               peer_node: peer_node,
               names_fun: fn -> @absent end,
               connected_fun: connected,
               budget_ms: 5_000,
               poll_ms: 10
             )

    assert detail.elapsed_ms >= @flip_after_ms
    refute detail.connected
  end

  test "a peer that never leaves fails the assertion with the budget it spent" do
    error =
      assert_raise ExUnit.AssertionError, fn ->
        PeerRegistry.assert_peer_absent!(@peer,
          names_fun: fn -> @registered end,
          budget_ms: 60,
          poll_ms: 10
        )
      end

    assert error.message =~ "over the 60ms detection budget"
    assert error.message =~ "still registered with epmd: true"
  end

  test "epmd readiness keeps polling unreadable replies instead of sampling once" do
    names = replies([{:error, :address}, {:error, :address}, @absent])

    assert {:ok, detail} =
             PeerRegistry.await_epmd_ready(names_fun: names, budget_ms: 5_000, poll_ms: 5)

    assert detail.samples == 3
    assert detail.elapsed_ms < 5_000
  end

  test "an epmd that never answers times out on the budget and the assertion names it" do
    unreadable = fn -> {:error, :address} end

    assert {:timeout, detail} =
             PeerRegistry.await_epmd_ready(names_fun: unreadable, budget_ms: 120, poll_ms: 10)

    assert detail.budget_ms == 120
    assert detail.elapsed_ms >= 120
    assert detail.samples > 1

    error =
      assert_raise ExUnit.AssertionError, fn ->
        PeerRegistry.assert_epmd_ready!(names_fun: unreadable, budget_ms: 60, poll_ms: 10)
      end

    assert error.message =~ "within the 60ms detection budget"
  end

  defp replies(list) do
    {:ok, agent} = Agent.start_link(fn -> list end)

    fn ->
      Agent.get_and_update(agent, fn
        [last] -> {last, [last]}
        [head | rest] -> {head, rest}
      end)
    end
  end

  defp elapsed_since(started), do: System.monotonic_time(:millisecond) - started
end
