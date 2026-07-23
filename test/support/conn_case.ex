defmodule CodexPoolerWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use CodexPoolerWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.AccountsFixtures
  alias CodexPooler.Gateway.Transports.WebsocketRolloutDrainSupport
  alias Phoenix.ConnTest

  using do
    quote do
      # The default endpoint for testing
      @endpoint CodexPoolerWeb.Endpoint

      use CodexPoolerWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import CodexPoolerWeb.ConnCase
    end
  end

  setup tags do
    CodexPooler.DataCase.setup_sandbox(tags)
    {:ok, conn: ConnTest.build_conn()}
  end

  @doc """
  Setup helper that registers and logs in users.

      setup :register_and_log_in_user

  It stores an updated connection and a registered user in the
  test context.
  """
  def register_and_log_in_user(%{conn: conn}) do
    result = AccountsFixtures.bootstrap_owner_fixture()
    scope = Scope.for_user(result.user, ["instance_owner"])

    %{conn: log_in_user(conn, result.user, result.token), user: result.user, scope: scope}
  end

  @doc """
  Logs the given `user` into the `conn`.

  It returns an updated `conn`.
  """
  def log_in_user(conn, _user, token) do
    conn
    |> ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.put_session(
      :live_socket_id,
      CodexPoolerWeb.UserAuth.live_socket_id_for_token(token)
    )
  end

  @spec start_rollout_drain_harness(keyword()) :: %{deadline: pid(), name: atom()}
  def start_rollout_drain_harness(opts \\ []) do
    WebsocketRolloutDrainSupport.start_rollout_drain_harness(self(), opts)
  end
end
