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
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.

  The instance settings cache lives in `:persistent_term`, so it survives the
  sandbox rollback that returns the settings row to its baseline `lock_version`.
  Handing the published entry back keeps every test's cache consistent with the
  database it can actually see; otherwise a leaked version makes later tests
  ignore their own settings broadcasts as stale.
  """
  def setup_sandbox(tags) do
    pid = Sandbox.start_owner!(Repo, shared: not tags[:async])
    settings_cache = InstanceSettings.snapshot_cache_for_test()

    on_exit(fn -> stop_sandbox(pid, settings_cache) end)
  end

  @doc false
  @spec stop_sandbox(pid(), term()) :: :ok
  def stop_sandbox(pid, settings_cache) do
    TouchDebounce.reset()

    # Reconciliation can still use the shared connection without changing the snapshot.
    # The synchronous restore drains that work and cancels its timer before owner exit.
    InstanceSettings.restore_cache_for_test(settings_cache)

    Sandbox.stop_owner(pid)
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
