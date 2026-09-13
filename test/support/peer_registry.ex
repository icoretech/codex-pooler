defmodule CodexPooler.PeerRegistry do
  @moduledoc """
  Bounded waits for the asynchronous facts around `:peer` nodes: the shutdown half, and epmd
  becoming readable after `epmd -daemon`.

  `:peer.stop/1` returns once the peer VM is down, but the two facts a test wants to assert
  afterwards settle later and independently: the node leaves `Node.list(:connected)` when the
  local net_kernel processes nodedown, and the name leaves epmd when epmd processes the closed
  registration socket. Sampling either once asserts a state that is merely *about* to be true,
  which fails a build on a loaded host while the product is fine. `epmd -daemon` has the same
  shape in the other direction: it returns before the daemon accepts a names request.

  A leaked peer is still worth failing on — it holds a port and a name that a later run can
  collide with — so the wait is bounded and the timeout carries the budget it spent, which is
  what tells a real leak apart from a slow host. `assert_peer_absent!/2` and
  `assert_epmd_ready!/1` are the one place that failure is worded, so every caller reports it
  the same way.

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

  @type epmd_detail :: %{
          budget_ms: non_neg_integer(),
          elapsed_ms: non_neg_integer(),
          samples: pos_integer(),
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

  @doc """
  `await_peer_absent/2`, failing the calling test once the budget is spent.

  Takes the same options and returns the `detail` of the successful wait.
  """
  @spec assert_peer_absent!(atom(), keyword()) :: detail()
  def assert_peer_absent!(peer_name, opts \\ []) when is_atom(peer_name) do
    case await_peer_absent(peer_name, opts) do
      {:ok, detail} ->
        detail

      {:timeout, detail} ->
        ExUnit.Assertions.flunk("""
        peer #{peer_name} was still visible #{detail.elapsed_ms}ms into its shutdown wait, over the #{detail.budget_ms}ms detection budget (#{detail.samples} samples)
        still registered with epmd: #{detail.registered}
        still in Node.list(:connected): #{detail.connected}
        epmd names: #{inspect(detail.names)}
        """)
    end
  end

  @doc """
  Polls until epmd answers a names request.

  Returns `{:ok, detail}` on the first readable reply, or `{:timeout, detail}` once the budget is
  spent; `detail` carries `:budget_ms`, the `:elapsed_ms` and `:samples` actually spent, and the
  last `:names` reply.

  Options: `:budget_ms`, `:poll_ms`, `:names_fun`.
  """
  @spec await_epmd_ready(keyword()) :: {:ok, epmd_detail()} | {:timeout, epmd_detail()}
  def await_epmd_ready(opts \\ []) do
    state = %{
      budget_ms: Keyword.get(opts, :budget_ms, @default_budget_ms),
      poll_ms: Keyword.get(opts, :poll_ms, @default_poll_ms),
      names_fun: Keyword.get(opts, :names_fun, &:erl_epmd.names/0),
      started: System.monotonic_time(:millisecond)
    }

    poll_epmd(state, 1)
  end

  @doc """
  `await_epmd_ready/1`, failing the calling test once the budget is spent.

  Takes the same options and returns the `detail` of the successful wait.
  """
  @spec assert_epmd_ready!(keyword()) :: epmd_detail()
  def assert_epmd_ready!(opts \\ []) do
    case await_epmd_ready(opts) do
      {:ok, detail} ->
        detail

      {:timeout, detail} ->
        ExUnit.Assertions.flunk(
          "epmd did not answer a names request within the #{detail.budget_ms}ms detection " <>
            "budget (#{detail.elapsed_ms}ms, #{detail.samples} samples); last reply: " <>
            inspect(detail.names)
        )
    end
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
      true -> sleep_and_then(state, elapsed, fn -> poll(state, samples + 1) end)
    end
  end

  defp poll_epmd(state, samples) do
    names = state.names_fun.()
    elapsed = System.monotonic_time(:millisecond) - state.started

    detail = %{
      budget_ms: state.budget_ms,
      elapsed_ms: elapsed,
      samples: samples,
      names: names
    }

    cond do
      match?({:ok, _entries}, names) -> {:ok, detail}
      elapsed >= state.budget_ms -> {:timeout, detail}
      true -> sleep_and_then(state, elapsed, fn -> poll_epmd(state, samples + 1) end)
    end
  end

  defp sleep_and_then(state, elapsed, next) do
    receive do
    after
      min(state.poll_ms, state.budget_ms - elapsed) -> next.()
    end
  end
end
