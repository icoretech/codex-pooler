defmodule CodexPooler.Upstreams.UsageCapPolicyTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.{Repo, Upstreams}
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Lifecycle.IdentityLifecycle
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @action "upstream_account.usage_cap_policy_update"

  setup do
    settings = CodexPooler.TestAppEnv.restore_on_exit(Upstreams, [])

    Application.put_env(
      :codex_pooler,
      Upstreams,
      Keyword.merge(settings,
        upstream_secret_key: Base.encode64(:crypto.hash(:sha256, "synthetic-usage-cap-policy-key")),
        upstream_secret_key_version: "test-usage-cap-v1"
      )
    )

    :ok
  end

  test "new identities have no cap and generic changesets cannot set one" do
    suffix = System.unique_integer([:positive])

    assert {:ok, identity} =
             IdentityLifecycle.create_upstream_identity(%{
               chatgpt_account_id: "acct_usage_cap_default_#{suffix}",
               account_label: "Usage cap default #{suffix}",
               onboarding_method: "import",
               usage_cap_percent: 50
             })

    assert is_nil(identity.usage_cap_percent)
    assert {:ok, identity} = identity |> UpstreamIdentity.changeset(%{usage_cap_percent: 50}) |> Repo.update()
    assert is_nil(Repo.reload!(identity).usage_cap_percent)
  end

  test "the database refuses a cap outside 1..99" do
    fixture = scoped_fixture!()

    for value <- [0, 100] do
      assert_raise Ecto.ConstraintError, ~r/upstream_identities_usage_cap_percent_check/, fn ->
        Repo.transaction(fn -> fixture.identity |> Ecto.Changeset.change(usage_cap_percent: value) |> Repo.update!() end)
      end
    end
  end

  for {name, input, expected} <- [
        {"integer", 80, 80},
        {"web string", "80", 80},
        {"padded web string", " 75 ", 75},
        {"lowest", "1", 1},
        {"highest", 99, 99}
      ] do
    test "accepts #{name} and audits old and new values" do
      fixture = scoped_fixture!()

      assert {:ok, %{status: :usage_cap_policy_updated, identity: updated}} =
               Upstreams.update_usage_cap_policy_for_scope(fixture.scope, fixture.identity.id, %{"usage_cap_percent" => unquote(input)})

      assert updated.usage_cap_percent == unquote(expected)
      assert Repo.reload!(fixture.identity).usage_cap_percent == unquote(expected)
      assert [event] = audit_events(fixture.identity.id)
      assert Map.has_key?(event.details, "previous_usage_cap_percent")
      assert is_nil(event.details["previous_usage_cap_percent"])
      assert event.details["usage_cap_percent"] == unquote(expected)
    end
  end

  test "a blank value or nil lifts the cap" do
    for value <- ["", nil] do
      fixture = scoped_fixture!()
      capped = fixture.identity |> Ecto.Changeset.change(usage_cap_percent: 60) |> Repo.update!()

      assert {:ok, %{status: :usage_cap_policy_updated, identity: updated}} =
               Upstreams.update_usage_cap_policy_for_scope(fixture.scope, capped.id, %{usage_cap_percent: value})

      assert is_nil(updated.usage_cap_percent)
      assert [event] = audit_events(capped.id)
      assert event.details["previous_usage_cap_percent"] == 60
      assert is_nil(event.details["usage_cap_percent"])
    end
  end

  for {name, value} <- [{"zero", 0}, {"hundred", 100}, {"negative", -5}, {"decimal string", "80.5"}, {"junk", "eighty"}, {"float", 80.0}, {"list", []}, {"map", %{}}] do
    test "rejects #{name} without audit or publication" do
      fixture = scoped_fixture!()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Upstreams.update_usage_cap_policy_for_scope(fixture.scope, fixture.identity.id, %{usage_cap_percent: unquote(Macro.escape(value))})

      assert %{usage_cap_percent: [_error]} = errors_on(changeset)
      assert is_nil(Repo.reload!(fixture.identity).usage_cap_percent)
      assert audit_events(fixture.identity.id) == []
    end
  end

  for {name, attrs} <- [
        {"missing control", %{}},
        {"extra field", %{"usage_cap_percent" => 80, "pool_id" => "hidden"}},
        {"provider metadata", %{usage_cap_percent: 80, metadata: %{}}},
        {"another policy", %{usage_cap_percent: 80, allow_provider_credits: false}}
      ] do
    test "rejects #{name} instead of dropping untrusted fields" do
      fixture = scoped_fixture!()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Upstreams.update_usage_cap_policy_for_scope(fixture.scope, fixture.identity.id, unquote(Macro.escape(attrs)))

      assert %{usage_cap_percent: [_error]} = errors_on(changeset)
      assert audit_events(fixture.identity.id) == []
    end
  end

  test "a same-value save changes nothing" do
    fixture = scoped_fixture!()
    capped = fixture.identity |> Ecto.Changeset.change(usage_cap_percent: 70) |> Repo.update!()

    assert {:ok, %{status: :usage_cap_policy_unchanged}} = Upstreams.update_usage_cap_policy_for_scope(fixture.scope, capped.id, %{usage_cap_percent: "70"})
    assert Repo.reload!(capped) == capped
    assert audit_events(capped.id) == []
  end

  test "a one-Pool operator cannot cap an identity shared with a hidden Pool" do
    fixture = scoped_fixture!(2)
    %{user: operator} = operator_fixture(fixture.scope.user)
    [visible_pool, hidden_pool] = fixture.pools
    operator_pool_assignment_fixture(operator, visible_pool, created_by_user_id: fixture.scope.user.id)

    assert {:error, %{code: :capability_denied}} = Upstreams.update_usage_cap_policy_for_scope(Scope.for_user(operator), fixture.identity.id, %{usage_cap_percent: 80})
    assert is_nil(Repo.reload!(fixture.identity).usage_cap_percent)

    operator_pool_assignment_fixture(operator, hidden_pool, created_by_user_id: fixture.scope.user.id)
    assert {:ok, %{identity: %{usage_cap_percent: 80}}} = Upstreams.update_usage_cap_policy_for_scope(Scope.for_user(operator), fixture.identity.id, %{usage_cap_percent: 80})
    assert Enum.sort(Enum.map(audit_events(fixture.identity.id), & &1.pool_id)) == Enum.sort(Enum.map(fixture.pools, & &1.id))
  end

  test "caller-owned transactions and missing identities are refused" do
    fixture = scoped_fixture!()

    Repo.transaction(fn ->
      assert {:error, %{code: :transaction_not_allowed}} = Upstreams.update_usage_cap_policy_for_scope(fixture.scope, fixture.identity.id, %{usage_cap_percent: 80})
    end)

    assert {:error, %{code: :upstream_identity_not_found}} = Upstreams.update_usage_cap_policy_for_scope(fixture.scope, Ecto.UUID.generate(), %{usage_cap_percent: 80})
    assert {:error, %{code: :invalid_request}} = Upstreams.update_usage_cap_policy_for_scope(nil, fixture.identity.id, %{usage_cap_percent: 80})
  end

  defp scoped_fixture!(pool_count \\ 1) do
    %{user: owner} = bootstrap_owner_fixture()
    pools = Enum.map(1..pool_count, fn _ -> pool_fixture() end)
    identity = active_upstream_identity_fixture()
    assert {:ok, _secret} = Upstreams.store_encrypted_secret(identity, %{secret_kind: "access_token", plaintext: "synthetic-usage-cap-access-#{System.unique_integer([:positive])}"})

    Enum.each(pools, fn pool ->
      assert {:ok, assignment} = PoolAssignments.create_pool_assignment(pool, identity)
      assert {:ok, _assignment} = PoolAssignments.activate_pool_assignment(assignment)
    end)

    %{scope: Scope.for_user(owner), pools: pools, identity: Repo.reload!(identity)}
  end

  defp audit_events(identity_id) do
    Repo.all(from event in AuditEvent, where: event.action == @action and event.target_id == ^identity_id, order_by: [asc: event.pool_id])
  end
end
