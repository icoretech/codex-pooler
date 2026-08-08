defmodule CodexPooler.Dev.SavedResetConfirmationFixturesTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures
  import Phoenix.LiveViewTest

  alias CodexPooler.Accounts
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Accounts.User
  alias CodexPooler.Dev.SavedResetConfirmationFixtures, as: Fixtures
  alias CodexPooler.Pools
  alias CodexPooler.Pools.{Membership, OperatorPoolAssignment}
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.QuotaProjection
  alias CodexPoolerWeb.Admin.UpstreamPageComponents.AccountCard.SavedResetMeter

  test "serializes concurrent fixture holders with a PostgreSQL advisory lock" do
    parent = self()

    first =
      Task.async(fn ->
        Fixtures.with_advisory_lock(Repo.config(), fn ->
          send(parent, :fixture_lock_held)

          receive do
            :release_fixture_lock -> :ok
          end
        end)
      end)

    assert_receive :fixture_lock_held

    assert {:error, "another saved-reset confirmation fixture run is active"} =
             Fixtures.with_advisory_lock(Repo.config(), fn -> :unexpected end)

    send(first.pid, :release_fixture_lock)
    assert {:ok, :ok} = Task.await(first)
  end

  test "fails closed when the advisory lock database is unavailable" do
    unavailable_config =
      Repo.config() |> Keyword.put(:hostname, "127.0.0.1") |> Keyword.put(:port, 1)

    assert {:error, "saved-reset confirmation fixture lock could not connect"} =
             Fixtures.with_advisory_lock(unavailable_config, fn -> :unexpected end)
  end

  test "a browser-auth crash retains a metadata-only journal that resumes exact cleanup" do
    root = temp_journal_root!()

    assert {:error, _reason} =
             Fixtures.seed(
               "confirmed",
               fixture_opts(root, browser_auth: true, crash_after: :browser_auth_actor)
             )

    [journal_path] =
      root
      |> Path.join("*.json")
      |> Path.wildcard()
      |> Enum.reject(&String.ends_with?(&1, ".browser-auth.json"))

    journal = Fixtures.read_journal!(journal_path)

    assert Map.keys(journal) |> Enum.sort() ==
             ~w(actor_membership_ids actor_operator_pool_assignment_ids actor_user_ids assignment_ids browser_auth_path identity_ids pool_ids run_fingerprint scenario status)

    assert journal["status"] == "seeding"
    assert [_user_id] = journal["actor_user_ids"]
    assert [_membership_id] = journal["actor_membership_ids"]
    assert [_operator_assignment_id] = journal["actor_operator_pool_assignment_ids"]
    assert [auth_path] = Path.wildcard(Path.join(root, "*.browser-auth.json"))
    assert {:ok, %File.Stat{mode: mode}} = File.stat(auth_path)
    assert Bitwise.band(mode, 0o777) == 0o600

    assert {:ok, %{cleanup: "exact_owned_rows_removed"}} =
             Fixtures.cleanup(journal_path, fixture_opts(root))

    refute File.exists?(journal_path)
    refute File.exists?(auth_path)
  end

  test "cleanup deletes only journaled rows and retains unrelated sentinels" do
    sentinel = active_upstream_assignment_fixture(pool_fixture())
    root = temp_journal_root!()

    assert {:ok, receipt} = Fixtures.seed("all", fixture_opts(root))
    assert receipt.status == "ready"
    assert receipt.scenario_count > 1

    journal = Fixtures.read_journal!(receipt.journal_path)
    assert Enum.all?(journal["pool_ids"], &Repo.get(Pool, &1))
    assert Enum.all?(journal["identity_ids"], &Repo.get(UpstreamIdentity, &1))
    assert Enum.all?(journal["assignment_ids"], &Repo.get(PoolUpstreamAssignment, &1))

    assert {:ok, %{cleanup: "exact_owned_rows_removed"}} =
             Fixtures.cleanup(receipt.journal_path, fixture_opts(root))

    assert Repo.get(Pool, sentinel.assignment.pool_id)
    assert Repo.get(UpstreamIdentity, sentinel.identity.id)
    assert Repo.get(PoolUpstreamAssignment, sentinel.assignment.id)
  end

  test "browser-auth seed journals a disposable instance admin and its private auth file" do
    sentinel = active_upstream_assignment_fixture(pool_fixture())
    root = temp_journal_root!()

    assert {:ok, receipt} = Fixtures.seed("confirmed", fixture_opts(root, browser_auth: true))

    journal = Fixtures.read_journal!(receipt.journal_path)

    assert Path.basename(receipt.browser_auth_path) == journal["browser_auth_path"]
    assert [user_id] = journal["actor_user_ids"]
    assert [membership_id] = journal["actor_membership_ids"]
    assert [operator_assignment_id] = journal["actor_operator_pool_assignment_ids"]
    assert %User{password_change_required: false, status: "active"} = Repo.get(User, user_id)

    assert %Membership{user_id: ^user_id, role: "instance_admin", status: "active"} =
             Repo.get(Membership, membership_id)

    assert %OperatorPoolAssignment{user_id: ^user_id, pool_id: pool_id, status: "active"} =
             Repo.get(OperatorPoolAssignment, operator_assignment_id)

    assert pool_id in journal["pool_ids"]
    assert File.exists?(receipt.browser_auth_path)

    assert {:ok, %File.Stat{mode: mode}} = File.stat(receipt.browser_auth_path)
    assert Bitwise.band(mode, 0o777) == 0o600

    assert {:ok, %{"email" => email, "password" => password}} =
             receipt.browser_auth_path
             |> File.read()
             |> then(fn result -> with {:ok, auth} <- result, do: Jason.decode(auth) end)

    assert {:ok, %{user: %User{id: ^user_id}}} =
             Accounts.login_user(%{"email" => email, "password" => password})

    assert {:ok, %{cleanup: "exact_owned_rows_removed"}} =
             Fixtures.cleanup(receipt.journal_path, fixture_opts(root))

    refute File.exists?(receipt.browser_auth_path)
    refute File.exists?(receipt.journal_path)
    refute Repo.get(User, user_id)
    refute Repo.get(Membership, membership_id)
    refute Repo.get(OperatorPoolAssignment, operator_assignment_id)
    assert Repo.get(Pool, sentinel.assignment.pool_id)
    assert Repo.get(UpstreamIdentity, sentinel.identity.id)
    assert Repo.get(PoolUpstreamAssignment, sentinel.assignment.id)

    assert {:error, "saved-reset confirmation fixture journal does not exist"} =
             Fixtures.cleanup(receipt.journal_path, fixture_opts(root))
  end

  test "browser-auth cleanup fails closed for missing or foreign auth paths" do
    root = temp_journal_root!()

    assert {:ok, receipt} = Fixtures.seed("confirmed", fixture_opts(root, browser_auth: true))
    journal = Fixtures.read_journal!(receipt.journal_path)
    [user_id] = journal["actor_user_ids"]

    File.write!(receipt.journal_path, Jason.encode!(Map.delete(journal, "browser_auth_path")))

    assert {:error, "invalid saved-reset confirmation fixture journal"} =
             Fixtures.cleanup(receipt.journal_path, fixture_opts(root))

    assert Repo.get(User, user_id)

    File.write!(
      receipt.journal_path,
      Jason.encode!(Map.put(journal, "browser_auth_path", "foreign.browser-auth.json"))
    )

    assert {:error, "invalid saved-reset confirmation fixture browser auth file"} =
             Fixtures.cleanup(receipt.journal_path, fixture_opts(root))

    assert Repo.get(User, user_id)

    File.write!(receipt.journal_path, Jason.encode!(journal))

    assert {:ok, %{cleanup: "exact_owned_rows_removed"}} =
             Fixtures.cleanup(receipt.journal_path, fixture_opts(root))
  end

  test "browser-auth cleanup retains owned rows when the private auth file is missing" do
    root = temp_journal_root!()

    assert {:ok, receipt} = Fixtures.seed("confirmed", fixture_opts(root, browser_auth: true))
    journal = Fixtures.read_journal!(receipt.journal_path)
    [user_id] = journal["actor_user_ids"]

    File.rm!(receipt.browser_auth_path)

    assert {:error, "invalid saved-reset confirmation fixture browser auth file"} =
             Fixtures.cleanup(receipt.journal_path, fixture_opts(root))

    assert Repo.get(User, user_id)
    assert File.exists?(receipt.journal_path)
  end

  test "fixture scenarios render canonical confirmation states through the operator projection" do
    root = temp_journal_root!()

    assert {:ok, receipt} = Fixtures.seed("all", fixture_opts(root, browser_auth: true))

    assert_scenario_confirmation!(receipt, "candidate_progression", :awaiting_confirmation,
      state_label: "Awaiting confirmation",
      routing_label: "Routing paused",
      blocker_state: :none,
      blocker_label: "None"
    )

    assert_scenario_confirmation!(receipt, "confirmed", :confirmed,
      state_label: "Confirmed",
      routing_label: "Routing pause released",
      blocker_state: :none,
      blocker_label: "None"
    )

    assert_scenario_confirmation!(receipt, "expired", :confirmation_expired,
      state_label: "Confirmation expired",
      routing_label: "Routing pause released",
      blocker_state: :none,
      blocker_label: "None"
    )

    assert_scenario_confirmation!(receipt, "not_applied", :not_applied,
      state_label: "Not applied",
      routing_label: "Routing pause released",
      blocker_state: :none,
      blocker_label: "None"
    )

    for scenario <- ["blocker_sibling", "blocker_circuit"] do
      assert_scenario_confirmation!(receipt, scenario, :awaiting_confirmation,
        state_label: "Awaiting confirmation",
        routing_label: "Routing paused",
        blocker_state: :exhausted,
        blocker_label: "Exhausted"
      )
    end

    assert {:ok, %{cleanup: "exact_owned_rows_removed"}} =
             Fixtures.cleanup(receipt.journal_path, fixture_opts(root))
  end

  test "fixture task rejects unknown scenarios before it creates a journal or rows" do
    root = temp_journal_root!()
    sentinel = active_upstream_assignment_fixture(pool_fixture())

    assert {:error, "unknown saved-reset confirmation fixture scenario"} =
             Fixtures.seed("malformed-scenario", fixture_opts(root, browser_auth: true))

    assert Path.wildcard(Path.join(root, "*")) == []
    assert Repo.get(Pool, sentinel.assignment.pool_id)
    assert Repo.get(UpstreamIdentity, sentinel.identity.id)
    assert Repo.get(PoolUpstreamAssignment, sentinel.assignment.id)
  end

  test "the real confirmation projection omits a noncanonical phase" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert QuotaProjection.saved_reset_confirmation(
             %{"phase" => "not_applied"},
             [],
             [],
             now
           ) == nil
  end

  defp fixture_opts(root, extra \\ []) do
    [environment: :test, allow_test_database: true, journal_root: root] ++ extra
  end

  defp assert_scenario_confirmation!(receipt, scenario, expected_state, expected) do
    account = scenario_account!(receipt, scenario)

    assert %{confirmation_state: ^expected_state} = account.saved_reset_confirmation

    html =
      render_component(&SavedResetMeter.saved_reset_meter/1,
        id: "fixture-#{scenario}",
        saved_resets: account.saved_resets,
        saved_reset_policy: account.saved_reset_policy,
        saved_reset_confirmation: account.saved_reset_confirmation
      )

    document = LazyHTML.from_fragment(html)
    state = Atom.to_string(expected_state)
    blocker_state = expected |> Keyword.fetch!(:blocker_state) |> Atom.to_string()

    assert LazyHTML.query(
             document,
             "[data-role='upstream-saved-reset-confirmation-state'][data-confirmation-state='#{state}']"
           )
           |> LazyHTML.text()
           |> String.trim() == Keyword.fetch!(expected, :state_label)

    assert LazyHTML.query(
             document,
             "[data-role='upstream-saved-reset-additional-blocker'][data-blocker-state='#{blocker_state}']"
           )
           |> LazyHTML.text()
           |> String.trim() == Keyword.fetch!(expected, :blocker_label)

    assert LazyHTML.query(
             document,
             "[data-role='upstream-saved-reset-routing-pause'][data-routing-paused='#{expected_state == :awaiting_confirmation}']"
           )
           |> LazyHTML.text()
           |> String.trim() == Keyword.fetch!(expected, :routing_label)

    assert LazyHTML.query(document, "[data-role='upstream-saved-reset-confirmation-summary']")
           |> LazyHTML.text()
           |> String.trim() != ""
  end

  defp scenario_account!(receipt, scenario) do
    journal = Fixtures.read_journal!(receipt.journal_path)
    [user_id] = journal["actor_user_ids"]
    scope = User |> Repo.get!(user_id) |> Scope.for_user()
    pools = Pools.list_visible_pools(scope)

    identity_id =
      journal["scenario"]
      |> String.split(",")
      |> Enum.zip(journal["identity_ids"])
      |> Map.new()
      |> Map.fetch!(scenario)

    assert [account] =
             UpstreamAccountsReadModel.list_visible_accounts(scope, pools, %{
               identity_id: identity_id
             })

    account
  end

  defp temp_journal_root! do
    root =
      Path.join(System.tmp_dir!(), "saved-reset-fixtures-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end
end
