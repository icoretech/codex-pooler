defmodule CodexPooler.Upstreams.CredentialReplacementWritersTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Pools
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Auth.TokenRefreshMetadata
  alias CodexPooler.Upstreams.PreparedAccount
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias CodexPooler.Upstreams.TokenLinking

  import CodexPooler.AccountsFixtures

  test "prepared account is redacted, bound to scope and pool, and rejects reserved input" do
    scope = owner_scope()
    {:ok, pool} = Pools.create_pool(scope, %{slug: unique("prepared"), name: "Prepared"})
    attrs = account_attrs("prepared")

    assert {:ok, prepared} = PreparedAccount.prepare(scope, pool, attrs, [])
    refute inspect(prepared) =~ attrs.token
    assert {:ok, ^prepared} = PreparedAccount.validate(prepared, scope, pool)

    %{user: owner} = bootstrap_owner_fixture()
    %{user: operator} = operator_fixture(owner)
    other_scope = Scope.for_user(operator)

    assert {:error, %{code: :invalid_request}} =
             PreparedAccount.validate(prepared, other_scope, pool)

    assert {:error, %{code: :invalid_request}} =
             TokenLinking.link_tokens(scope, pool, Map.put(attrs, :credential_policy, :allow), [])
  end

  test "direct token linking writes a canonical future marker and rejects past expiry atomically" do
    scope = owner_scope()
    {:ok, pool} = Pools.create_pool(scope, %{slug: unique("expiry"), name: "Expiry"})
    future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:microsecond)

    assert {:ok, %{identity: identity}} =
             TokenLinking.link_tokens(scope, pool, account_attrs("future", future), [])

    persisted = Repo.get!(UpstreamIdentity, identity.id)
    assert persisted.metadata["credential_epoch"] == 1
    assert TokenRefreshMetadata.project_access_token_expiry(persisted.metadata).state == :known
    refute Map.has_key?(persisted.metadata, "secret_expires_at")

    assert {:ok, %{identity: unknown_identity}} =
             TokenLinking.link_tokens(scope, pool, account_attrs("unknown"), [])

    assert TokenRefreshMetadata.project_access_token_expiry(unknown_identity.metadata).state ==
             :unknown

    before_count = Repo.aggregate(UpstreamIdentity, :count)
    past = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:microsecond)

    assert {:error, %{code: :access_token_expired, message: "access token is expired"}} =
             TokenLinking.link_tokens(scope, pool, account_attrs("past", past), [])

    assert Repo.aggregate(UpstreamIdentity, :count) == before_count
  end

  test "trusted bundle preparation alone may accept a past token with refresh" do
    scope = owner_scope()
    {:ok, pool} = Pools.create_pool(scope, %{slug: unique("bundle-past"), name: "Bundle past"})
    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)
    attrs = account_attrs("bundle-past", past)

    assert {:ok, %PreparedAccount{policy: :bundle_recovery} = prepared} =
             PreparedAccount.prepare_bundle(scope, pool, attrs, [])

    assert :ok = PreparedAccount.evaluate(prepared, DateTime.utc_now())

    assert {:error, %{code: :invalid_request}} =
             PreparedAccount.prepare_bundle(scope, pool, %{attrs | refresh_token: ""}, [])
  end

  test "malformed existing credential epoch rolls replacement back without rotating secrets" do
    scope = owner_scope()
    {:ok, pool} = Pools.create_pool(scope, %{slug: unique("epoch"), name: "Epoch"})
    attrs = account_attrs("epoch")
    assert {:ok, %{identity: identity}} = TokenLinking.link_tokens(scope, pool, attrs, [])

    identity
    |> Ecto.Changeset.change(metadata: Map.put(identity.metadata, "credential_epoch", "bad"))
    |> Repo.update!()

    replacement = Map.put(attrs, :token, "replacement-secret-value")

    assert {:error, %{code: :invalid_credential_epoch}} =
             TokenLinking.link_tokens(scope, pool, replacement, [])
  end

  defp account_attrs(suffix, expires_at \\ nil) do
    %{
      chatgpt_account_id: unique("acct-#{suffix}"),
      account_email: unique("#{suffix}") <> "@example.com",
      account_label: "Account #{suffix}",
      token: "secret-access-#{suffix}-#{System.unique_integer([:positive])}",
      refresh_token: "secret-refresh-#{suffix}-#{System.unique_integer([:positive])}",
      access_token_expires_at: expires_at
    }
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp owner_scope do
    %{user: user} = bootstrap_owner_fixture(%{"email" => unique("owner") <> "@example.com"})
    Scope.for_user(user)
  end
end

alias CodexPooler.Accounts.Scope
