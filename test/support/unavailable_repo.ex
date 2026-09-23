defmodule CodexPooler.UnavailableRepo do
  @moduledoc """
  A second Repo instance outside the sandbox whose only connection a task
  holds and whose queue drops a waiter after a few milliseconds. A process
  that routes its Repo calls to it (`run/2`) meets the same
  `DBConnection.ConnectionError` a production pool raises when PostgreSQL is
  restarting or stalled ("connection not available and request was dropped
  from queue").

  `Repo.put_dynamic_repo/1` is process-local, so only the calling process's
  queries fail; processes it starts keep the sandbox.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias CodexPooler.Repo

  @type t :: %{repo: pid(), holder: Task.t(), release_ref: reference()}

  @spec hold!(term()) :: t()
  def hold!(child_id \\ :unavailable_repo) do
    repo = start_supervised!({Repo, name: nil, pool: DBConnection.ConnectionPool, pool_size: 1, queue_target: 1, queue_interval: 10}, id: child_id)
    test_pid = self()
    release_ref = make_ref()

    holder =
      Task.async(fn ->
        _previous = Repo.put_dynamic_repo(repo)
        hold_only_connection(test_pid, release_ref, System.monotonic_time(:millisecond) + 15_000)
      end)

    assert_receive {:unavailable_repo_held, ^release_ref}, 15_000
    %{repo: repo, holder: holder, release_ref: release_ref}
  end

  @doc "Runs `fun` with this process's Repo calls routed to the unavailable pool, then releases it."
  @spec run(t(), (-> result)) :: result when result: term()
  def run(%{repo: repo} = unavailable, fun) do
    previous = Repo.put_dynamic_repo(repo)

    try do
      fun.()
    after
      Repo.put_dynamic_repo(previous)
      release!(unavailable)
    end
  end

  defp release!(%{holder: holder, release_ref: release_ref}) do
    send(holder.pid, {:release_unavailable_repo, release_ref})
    assert Task.await(holder, 15_000) == :released
  end

  # The pool's only connection may still be connecting when the holder asks for
  # it, and the queue that drops the request's checkout drops the holder's too
  # until the connection is up; retry against a bounded deadline.
  defp hold_only_connection(test_pid, release_ref, deadline) do
    Repo.checkout(fn ->
      send(test_pid, {:unavailable_repo_held, release_ref})

      receive do
        {:release_unavailable_repo, ^release_ref} -> :released
      end
    end)
  rescue
    error in DBConnection.ConnectionError ->
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(10)
        hold_only_connection(test_pid, release_ref, deadline)
      else
        reraise error, __STACKTRACE__
      end
  end
end
