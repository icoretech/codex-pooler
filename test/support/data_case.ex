defmodule CodexPooler.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use CodexPooler.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  alias CodexPooler.Access.APIKeys.TouchDebounce
  alias CodexPooler.CommittedWriteGuard
  alias CodexPooler.InstanceSettings
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias CodexPooler.Repo

      use Oban.Testing, repo: CodexPooler.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import CodexPooler.DataCase
    end
  end

  setup tags do
    CodexPooler.DataCase.setup_sandbox(tags)
  end

  @doc """
  Sets up the sandbox based on the test tags.

  The instance settings cache lives in `:persistent_term`, so it survives the
  sandbox rollback that returns the settings row to its baseline `lock_version`.
  Handing the published entry back keeps every test's cache consistent with the
  database it can actually see; otherwise a leaked version makes later tests
  ignore their own settings broadcasts as stale.

  It also puts the test under `CodexPooler.CommittedWriteGuard`, which fails
  the test when it leaves committed rows behind.
  """
  def setup_sandbox(tags) do
    guard = CommittedWriteGuard.begin_test!(tags)
    pid = Sandbox.start_owner!(Repo, shared: not tags[:async])

    # Registered before every other `on_exit` of the test so that it runs after
    # all of them: after the sandbox owner stops and after each cleanup the test
    # registers. The owner's own sandbox calls above belong to the harness.
    :ok = CommittedWriteGuard.register_verify!(guard)

    settings_cache = InstanceSettings.snapshot_cache_for_test()

    on_exit(fn -> stop_sandbox(pid, settings_cache) end)

    %{sandbox_owner: pid, sandbox_settings_cache: settings_cache}
  end

  @doc """
  Stops the test's sandbox owner and restores the settings cache.

  Runs automatically on exit. A test that committed rows outside the sandbox
  (`Sandbox.unboxed_run/2`) and then touched them inside the sandboxed
  transaction must call this before deleting those rows, because the open
  sandbox transaction still holds their row locks; the exit callback then
  finds the owner already stopped and does nothing more.
  """
  @spec stop_sandbox(pid(), term()) :: :ok
  def stop_sandbox(pid, settings_cache) do
    TouchDebounce.reset()

    # Reconciliation can still use the shared connection without changing the snapshot.
    # The synchronous restore drains that work and cancels its timer before owner exit.
    InstanceSettings.restore_cache_for_test(settings_cache)

    if Process.alive?(pid), do: Sandbox.stop_owner(pid), else: :ok
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
