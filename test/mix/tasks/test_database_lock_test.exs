defmodule CodexPooler.MixTasks.TestDatabaseLockTest do
  use ExUnit.Case, async: false

  alias CodexPooler.MixTasks.TestDatabaseLock
  alias CodexPooler.Repo

  test "serializes concurrent callers for the configured test database" do
    parent = self()
    repo_config = Keyword.put(Repo.config(), :database, "codex_pooler_test_lock_regression")

    first =
      Task.async(fn ->
        TestDatabaseLock.with_lock!(repo_config, fn ->
          send(parent, :first_locked)

          receive do
            :release_first -> :first_released
          after
            5_000 -> raise "timed out waiting to release first lock holder"
          end
        end)
      end)

    assert_receive :first_locked, 5_000

    second =
      Task.async(fn ->
        send(parent, :second_waiting)

        TestDatabaseLock.with_lock!(repo_config, fn ->
          send(parent, :second_locked)
          :second_released
        end)
      end)

    assert_receive :second_waiting
    refute_receive :second_locked, 100

    send(first.pid, :release_first)

    assert Task.await(first) == :first_released
    assert Task.await(second) == :second_released
    assert_receive :second_locked
  end
end
