defmodule CodexPooler.StallingPostgresProxy do
  @moduledoc """
  A loopback TCP proxy in front of the test PostgreSQL that can stop relaying
  bytes on the connections it already carries, while new connections (the
  cancel request, reconnects) still pass. It is a deterministic stand-in for a
  server stalled on its storage: a statement sent on a frozen connection gets
  no answer until the client gives up, which is how a query budget is enforced
  by DBConnection (the pooled connection is disconnected).

  A table lock is not a substitute: PostgreSQL answers the cancel of a lock
  wait at once, so the error arrives before the socket closes and DBConnection
  never retries.

  `start_repo!/3` starts a production-style `DBConnection.ConnectionPool` Repo
  behind the proxy and waits until every pooled connection has finished its
  handshake, so the stall freezes statements rather than connects.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias CodexPooler.Repo

  @type t :: %{port: :inet.port_number(), listen: port(), acceptor: pid(), counters: :atomics.atomics_ref()}

  @spec start!() :: t()
  def start! do
    config = Repo.config()
    target = {String.to_charlist(config[:hostname]), config[:port]}
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    # slot 1: connections accepted so far; slot 2: connections with a sequence at or below it are frozen
    counters = :atomics.new(2, [])
    acceptor = spawn(fn -> accept_loop(listen, target, counters) end)
    %{port: port, listen: listen, acceptor: acceptor, counters: counters}
  end

  @doc "A supervised Repo instance (no registered name) whose pool connects through `proxy`."
  @spec start_repo!(t(), term(), pos_integer()) :: pid()
  def start_repo!(proxy, child_id, pool_size) do
    repo =
      start_supervised!(
        {Repo, name: nil, pool: DBConnection.ConnectionPool, pool_size: pool_size, idle_interval: 60_000, hostname: "127.0.0.1", port: proxy.port},
        id: child_id
      )

    await_pool_connected!(repo, pool_size)
    repo
  end

  @doc "Freezes every connection accepted so far."
  @spec stall!(t()) :: :ok
  def stall!(%{counters: counters}) do
    :atomics.put(counters, 2, :atomics.get(counters, 1))
    :ok
  end

  @spec stop!(t()) :: :ok
  def stop!(%{listen: listen, acceptor: acceptor}) do
    Process.exit(acceptor, :kill)
    :ok = :gen_tcp.close(listen)
  end

  # Every pooled connection must have finished its handshake before the stall,
  # or the stall would freeze a connect instead of a statement.
  defp await_pool_connected!(repo, size) do
    test_pid = self()
    ref = make_ref()

    holders = for _ <- 1..size, do: Task.async(fn -> hold_pool_connection(repo, test_pid, ref) end)

    for _ <- holders, do: assert_receive({:pool_connection_held, ^ref}, 15_000)
    for holder <- holders, do: send(holder.pid, {:release_pool_connection, ref})
    for holder <- holders, do: assert(Task.await(holder, 15_000) == :released)
    :ok
  end

  defp hold_pool_connection(repo, test_pid, ref) do
    _previous = Repo.put_dynamic_repo(repo)

    Repo.checkout(fn ->
      send(test_pid, {:pool_connection_held, ref})

      receive do
        {:release_pool_connection, ^ref} -> :released
      end
    end)
  end

  defp accept_loop(listen, {host, port} = target, counters) do
    case :gen_tcp.accept(listen) do
      {:ok, client} ->
        sequence = :atomics.add_get(counters, 1, 1)
        {:ok, upstream} = :gen_tcp.connect(host, port, [:binary, active: false])
        # Linked to the acceptor, so `stop!/1` ends the relays of frozen
        # connections too.
        spawn_link(fn -> relay(client, upstream, sequence, counters) end)
        spawn_link(fn -> relay(upstream, client, sequence, counters) end)
        accept_loop(listen, target, counters)

      {:error, _closed} ->
        :ok
    end
  end

  # Relays in bounded receive slices so a frozen connection keeps its bytes
  # unread without spinning. The freeze is checked again after every read: a
  # slice that was already waiting when `stall!/1` ran must not forward what
  # arrived after it (a `BEGIN` sent right after the stall passed that way).
  defp relay(from, to, sequence, counters) do
    if frozen?(sequence, counters) do
      frozen()
    else
      case :gen_tcp.recv(from, 0, 50) do
        {:ok, data} ->
          forward(data, from, to, sequence, counters)

        {:error, :timeout} ->
          relay(from, to, sequence, counters)

        {:error, _closed} ->
          _closed = :gen_tcp.close(to)
          :ok
      end
    end
  end

  defp forward(data, from, to, sequence, counters) do
    if frozen?(sequence, counters), do: frozen()
    _sent = :gen_tcp.send(to, data)
    relay(from, to, sequence, counters)
  end

  defp frozen?(sequence, counters), do: sequence <= :atomics.get(counters, 2)

  # A frozen connection is never thawed; its relays wait for `stop!/1`.
  defp frozen, do: Process.sleep(:infinity)
end
