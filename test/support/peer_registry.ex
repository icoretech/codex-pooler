defmodule CodexPooler.PeerRegistry do
  @moduledoc """
  Bounded waits for the asynchronous half of `:peer` node shutdown.

  `:peer.stop/1` returns once the peer VM is down, but the two facts a test wants to assert
  afterwards settle later and independently: the node leaves `Node.list(:connected)` when the
  local net_kernel processes nodedown, and the name leaves epmd when epmd processes the closed
  registration socket. Sampling either once asserts a state that is merely *about* to be true,
  which fails a build on a loaded host while the product is fine.

  A leaked peer is still worth failing on — it holds a port and a name that a later run can
  collide with — so the wait is bounded and the timeout carries the budget it spent, which is
  what tells a real leak apart from a slow host.

  The `:names_fun` and `:connected_fun` options exist so the wait itself can be tested without
  starting peers.
  """

  # Peer shutdown competes with four partitions' worth of schedulers under `make test-fast`,
  # so this is a failure-detection budget rather than any timing contract of `:peer`.
  @default_budget_ms 15_000
  @default_poll_ms 25

  @type detail :: %{
          budget_ms: non_neg_integer(),
          elapsed_ms: non_neg_integer(),
          samples: pos_integer(),
          registered: boolean(),
          connected: boolean(),
          names: term()
        }

  @doc """
  Polls until `peer_name` has left epmd and `peer_node` has left the connected node list.

  Returns `{:ok, detail}` as soon as both hold, or `{:timeout, detail}` once the budget is
  spent. `detail` carries `:budget_ms`, the `:elapsed_ms` and `:samples` actually spent, and
  which of `:registered` / `:connected` was still true at the last sample.

  Options: `:peer_node` (skip the connected check when absent), `:budget_ms`, `:poll_ms`,
  `:names_fun`, `:connected_fun`.
  """
  @spec await_peer_absent(atom(), keyword()) :: {:ok, detail()} | {:timeout, detail()}
  def await_peer_absent(peer_name, opts \\ []) when is_atom(peer_name) do
    state = %{
      name: Atom.to_charlist(peer_name),
      peer_node: Keyword.get(opts, :peer_node),
      budget_ms: Keyword.get(opts, :budget_ms, @default_budget_ms),
      poll_ms: Keyword.get(opts, :poll_ms, @default_poll_ms),
      names_fun: Keyword.get(opts, :names_fun, &:erl_epmd.names/0),
      connected_fun: Keyword.get(opts, :connected_fun, fn -> Node.list(:connected) end),
      started: System.monotonic_time(:millisecond)
    }

    poll(state, 1)
  end

  defp poll(state, samples) do
    names = state.names_fun.()

    registered? =
      case names do
        {:ok, entries} -> Enum.any?(entries, fn {name, _port} -> name == state.name end)
        # An epmd that cannot be read yet is not evidence of absence.
        _unreadable -> true
      end

    connected? = state.peer_node != nil and state.peer_node in state.connected_fun.()
    elapsed = System.monotonic_time(:millisecond) - state.started

    detail = %{
      budget_ms: state.budget_ms,
      elapsed_ms: elapsed,
      samples: samples,
      registered: registered?,
      connected: connected?,
      names: names
    }

    cond do
      not registered? and not connected? -> {:ok, detail}
      elapsed >= state.budget_ms -> {:timeout, detail}
      true -> sleep_and_poll(state, samples, elapsed)
    end
  end

  defp sleep_and_poll(state, samples, elapsed) do
    receive do
    after
      min(state.poll_ms, state.budget_ms - elapsed) -> poll(state, samples + 1)
    end
  end
end
