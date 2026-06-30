defmodule CodexPooler.Upstreams.OAuthRelinkTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.FakeOpenAIAuthProvider
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Auth.CodexAuth
  alias CodexPooler.Upstreams.Secrets

  alias CodexPooler.Upstreams.Schemas.{
    EncryptedSecret,
    OAuthFlow,
    PoolUpstreamAssignment,
    UpstreamIdentity
  }

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  setup do
    configure_upstream_secret_key!()
    restore_codex_auth_config!()
    :ok
  end

  test "browser relink preserves identity label and assignment while replacing active secrets" do
    scope = fixture_owner_scope()
    pool = pool_fixture()

    identity =
      active_upstream_identity_fixture(relink_identity_attrs("acct_relink_same", "ws_same"))

    assert {:ok, assignment} =
             Upstreams.store_encrypted_secret(
               identity,
               secret_attrs("access_token", "old-access")
             )

    assert {:ok, _refresh_secret} =
             Upstreams.store_encrypted_secret(
               identity,
               secret_attrs("refresh_token", "old-refresh")
             )

    assert {:ok, pool_assignment} =
             PoolAssignments.create_pool_assignment(
               pool,
               identity,
               %{assignment_label: "Custom pool slot label"}
             )

    assert {:ok, pool_assignment} =
             PoolAssignments.activate_pool_assignment(pool_assignment)

    start_provider!(%{
      "/oauth/token" =>
        {200,
         FakeOpenAIAuthProvider.token_response(
           access_token: "new-access",
           refresh_token: "new-refresh",
           id_token: relink_id_token("acct_relink_same", "ws_same")
         )}
    })

    assert {:ok, %{flow: flow, authorization_url: authorization_url}} =
             Upstreams.start_browser_oauth(scope, pool, upstream_identity: identity)

    assert flow.purpose == "relink"
    assert flow.upstream_identity_id == identity.id

    assert {:ok, %{status: :completed, identity: relinked, assignment: relinked_assignment}} =
             Upstreams.complete_browser_oauth(
               scope,
               flow.id,
               callback_url(authorization_state(authorization_url), "relink-code-success")
             )

    assert relinked.id == identity.id
    assert relinked.account_label == "Existing operator label"
    assert relinked.workspace_id == "ws_same"
    assert relinked_assignment.id == pool_assignment.id
    assert relinked_assignment.assignment_label == "Custom pool slot label"
    assert Repo.aggregate(UpstreamIdentity, :count) == 1
    assert Repo.aggregate(PoolUpstreamAssignment, :count) == 1
    assert Repo.get!(EncryptedSecret, assignment.id).status == "superseded"
    assert {:ok, "new-access"} = Secrets.decrypt_active_secret(identity, "access_token")
    assert {:ok, "new-refresh"} = Secrets.decrypt_active_secret(identity, "refresh_token")
    assert Repo.get!(OAuthFlow, flow.id).result_upstream_identity_id == identity.id
  end

  test "browser relink rejects callbacks for a different ChatGPT account without mutating state" do
    scope = fixture_owner_scope()
    pool = pool_fixture()

    identity =
      active_upstream_identity_fixture(relink_identity_attrs("acct_relink_target", "ws_target"))

    assert {:ok, _assignment} =
             PoolAssignments.create_pool_assignment(pool, identity)

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(
               identity,
               secret_attrs("access_token", "old-access-target")
             )

    other_identity =
      active_upstream_identity_fixture(relink_identity_attrs("acct_relink_other", "ws_other"))

    start_provider!(%{
      "/oauth/token" =>
        {200,
         FakeOpenAIAuthProvider.token_response(
           access_token: "wrong-account-access",
           refresh_token: "wrong-account-refresh",
           id_token: relink_id_token("acct_relink_other", "ws_other")
         )}
    })

    assert {:ok, %{flow: flow, authorization_url: authorization_url}} =
             Upstreams.start_browser_oauth(scope, pool, upstream_identity: identity)

    assert {:error,
            %{
              code: :identity_mismatch,
              message: "OAuth account does not match the selected upstream account"
            }} =
             Upstreams.complete_browser_oauth(
               scope,
               flow.id,
               callback_url(authorization_state(authorization_url), "wrong-account-code")
             )

    reloaded_flow = Repo.get!(OAuthFlow, flow.id)
    assert reloaded_flow.status == "failed"
    assert reloaded_flow.error_code == "identity_mismatch"
    assert reloaded_flow.result_upstream_identity_id == nil
    assert Repo.get!(UpstreamIdentity, identity.id).account_label == "Existing operator label"

    assert Repo.get!(UpstreamIdentity, other_identity.id).account_label ==
             "Existing operator label"

    assert {:ok, "old-access-target"} = Secrets.decrypt_active_secret(identity, "access_token")
    assert Repo.aggregate(EncryptedSecret, :count) == 1
  end

  test "browser relink rejects callbacks for a different workspace slot without mutating secrets" do
    scope = fixture_owner_scope()
    pool = pool_fixture()

    identity =
      active_upstream_identity_fixture(
        relink_identity_attrs("acct_relink_workspace", "ws_selected")
      )

    assert {:ok, _assignment} =
             PoolAssignments.create_pool_assignment(pool, identity)

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(
               identity,
               secret_attrs("access_token", "old-workspace-access")
             )

    start_provider!(%{
      "/oauth/token" =>
        {200,
         FakeOpenAIAuthProvider.token_response(
           access_token: "wrong-workspace-access",
           refresh_token: "wrong-workspace-refresh",
           id_token: relink_id_token("acct_relink_workspace", "ws_other")
         )}
    })

    assert {:ok, %{flow: flow, authorization_url: authorization_url}} =
             Upstreams.start_browser_oauth(scope, pool, upstream_identity: identity)

    assert {:error, %{code: :identity_mismatch}} =
             Upstreams.complete_browser_oauth(
               scope,
               flow.id,
               callback_url(authorization_state(authorization_url), "wrong-workspace-code")
             )

    assert Repo.get!(OAuthFlow, flow.id).error_code == "identity_mismatch"
    assert Repo.get!(UpstreamIdentity, identity.id).workspace_id == "ws_selected"
    assert {:ok, "old-workspace-access"} = Secrets.decrypt_active_secret(identity, "access_token")
    assert Repo.aggregate(EncryptedSecret, :count) == 1
  end

  @tag :subject_relink
  test "browser relink rejects a missing subject for a subject-bound identity without rotating secrets" do
    scope = fixture_owner_scope()
    pool = pool_fixture()
    account_id = "acct_relink_subject_missing"
    target_subject = "user_subject_relink_target"
    rejected_access = "missing-subject-access"
    rejected_refresh = "missing-subject-refresh"

    identity =
      account_id
      |> relink_identity_attrs("ws_subject_missing")
      |> active_upstream_identity_fixture()
      |> subject_bound_identity_fixture(target_subject)

    assert {:ok, _assignment} =
             PoolAssignments.create_pool_assignment(pool, identity)

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(
               identity,
               secret_attrs("access_token", "old-subject-missing-access")
             )

    assert {:ok, "old-subject-missing-access"} =
             Secrets.decrypt_active_secret(identity, "access_token")

    assert active_secret_count(identity) == 1

    start_provider!(%{
      "/oauth/token" =>
        {200,
         FakeOpenAIAuthProvider.token_response(
           access_token: rejected_access,
           refresh_token: rejected_refresh,
           id_token: relink_id_token(account_id, "ws_subject_missing", chatgpt_user_id: nil)
         )}
    })

    assert {:ok, %{flow: flow, authorization_url: authorization_url}} =
             Upstreams.start_browser_oauth(scope, pool, upstream_identity: identity)

    assert {:error, %{code: :identity_mismatch} = error} =
             Upstreams.complete_browser_oauth(
               scope,
               flow.id,
               callback_url(authorization_state(authorization_url), "missing-subject-code")
             )

    assert_identity_mismatch_without_leak(error, [
      target_subject,
      rejected_access,
      rejected_refresh
    ])

    assert Repo.get!(OAuthFlow, flow.id).error_code == "identity_mismatch"
    assert Repo.get!(UpstreamIdentity, identity.id).chatgpt_user_id == target_subject

    assert {:ok, "old-subject-missing-access"} =
             Secrets.decrypt_active_secret(identity, "access_token")

    assert active_secret_count(identity) == 1
    assert Repo.aggregate(EncryptedSecret, :count) == 1
  end

  @tag :subject_relink
  test "browser relink rejects a different subject for a subject-bound identity without rotating secrets" do
    scope = fixture_owner_scope()
    pool = pool_fixture()
    account_id = "acct_relink_subject_different"
    target_subject = "user_subject_relink_selected"
    incoming_subject = "user_subject_relink_other"
    rejected_access = "different-subject-access"
    rejected_refresh = "different-subject-refresh"

    identity =
      account_id
      |> relink_identity_attrs("ws_subject_different")
      |> active_upstream_identity_fixture()
      |> subject_bound_identity_fixture(target_subject)

    assert {:ok, _assignment} =
             PoolAssignments.create_pool_assignment(pool, identity)

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(
               identity,
               secret_attrs("access_token", "old-subject-different-access")
             )

    assert {:ok, "old-subject-different-access"} =
             Secrets.decrypt_active_secret(identity, "access_token")

    assert active_secret_count(identity) == 1

    start_provider!(%{
      "/oauth/token" =>
        {200,
         FakeOpenAIAuthProvider.token_response(
           access_token: rejected_access,
           refresh_token: rejected_refresh,
           id_token:
             relink_id_token(account_id, "ws_subject_different",
               chatgpt_user_id: incoming_subject
             )
         )}
    })

    assert {:ok, %{flow: flow, authorization_url: authorization_url}} =
             Upstreams.start_browser_oauth(scope, pool, upstream_identity: identity)

    assert {:error, %{code: :identity_mismatch} = error} =
             Upstreams.complete_browser_oauth(
               scope,
               flow.id,
               callback_url(authorization_state(authorization_url), "different-subject-code")
             )

    assert_identity_mismatch_without_leak(error, [
      target_subject,
      incoming_subject,
      rejected_access,
      rejected_refresh
    ])

    assert Repo.get!(OAuthFlow, flow.id).error_code == "identity_mismatch"
    assert Repo.get!(UpstreamIdentity, identity.id).chatgpt_user_id == target_subject

    assert {:ok, "old-subject-different-access"} =
             Secrets.decrypt_active_secret(identity, "access_token")

    assert active_secret_count(identity) == 1
    assert Repo.aggregate(EncryptedSecret, :count) == 1
  end

  @tag :subject_relink
  test "browser relink accepts a matching subject for a subject-bound identity and rotates secrets" do
    scope = fixture_owner_scope()
    pool = pool_fixture()
    account_id = "acct_relink_subject_matching"
    target_subject = "user_subject_relink_matching"

    identity =
      account_id
      |> relink_identity_attrs("ws_subject_matching")
      |> active_upstream_identity_fixture()
      |> subject_bound_identity_fixture(target_subject)

    assert {:ok, _assignment} =
             PoolAssignments.create_pool_assignment(pool, identity)

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(
               identity,
               secret_attrs("access_token", "old-subject-matching-access")
             )

    assert {:ok, "old-subject-matching-access"} =
             Secrets.decrypt_active_secret(identity, "access_token")

    assert active_secret_count(identity) == 1

    start_provider!(%{
      "/oauth/token" =>
        {200,
         FakeOpenAIAuthProvider.token_response(
           access_token: "matching-subject-access",
           refresh_token: "matching-subject-refresh",
           id_token:
             relink_id_token(account_id, "ws_subject_matching", chatgpt_user_id: target_subject)
         )}
    })

    assert {:ok, %{flow: flow, authorization_url: authorization_url}} =
             Upstreams.start_browser_oauth(scope, pool, upstream_identity: identity)

    assert {:ok, %{status: :completed, identity: relinked}} =
             Upstreams.complete_browser_oauth(
               scope,
               flow.id,
               callback_url(authorization_state(authorization_url), "matching-subject-code")
             )

    assert relinked.id == identity.id
    assert relinked.chatgpt_user_id == target_subject
    assert Repo.get!(OAuthFlow, flow.id).result_upstream_identity_id == identity.id

    assert {:ok, "matching-subject-access"} =
             Secrets.decrypt_active_secret(identity, "access_token")

    assert {:ok, "matching-subject-refresh"} =
             Secrets.decrypt_active_secret(identity, "refresh_token")

    assert active_secret_count(identity) == 2
    assert Repo.aggregate(EncryptedSecret, :count) == 3
  end

  @tag :subject_relink
  test "browser relink accepts the selected nil-workspace subject identity among siblings" do
    scope = fixture_owner_scope()
    pool = pool_fixture()
    account_id = "acct_relink_subject_siblings"
    first_subject = "user_subject_relink_sibling_first"
    second_subject = "user_subject_relink_sibling_second"

    first_identity =
      account_id
      |> relink_identity_attrs(nil)
      |> active_upstream_identity_fixture()
      |> subject_bound_identity_fixture(first_subject)

    second_identity =
      account_id
      |> relink_identity_attrs(nil)
      |> active_upstream_identity_fixture()
      |> subject_bound_identity_fixture(second_subject)

    assert {:ok, _first_assignment} =
             PoolAssignments.create_pool_assignment(pool, first_identity)

    assert {:ok, _second_assignment} =
             PoolAssignments.create_pool_assignment(pool, second_identity)

    assert {:ok, _first_secret} =
             Upstreams.store_encrypted_secret(
               first_identity,
               secret_attrs("access_token", "old-first-sibling-access")
             )

    assert {:ok, _second_secret} =
             Upstreams.store_encrypted_secret(
               second_identity,
               secret_attrs("access_token", "old-second-sibling-access")
             )

    assert active_secret_count(first_identity) == 1
    assert active_secret_count(second_identity) == 1

    start_provider!(%{
      "/oauth/token" =>
        {200,
         FakeOpenAIAuthProvider.token_response(
           access_token: "new-second-sibling-access",
           refresh_token: "new-second-sibling-refresh",
           id_token: relink_id_token(account_id, nil, chatgpt_user_id: second_subject)
         )}
    })

    assert {:ok, %{flow: flow, authorization_url: authorization_url}} =
             Upstreams.start_browser_oauth(scope, pool, upstream_identity: second_identity)

    assert {:ok, %{status: :completed, identity: relinked}} =
             Upstreams.complete_browser_oauth(
               scope,
               flow.id,
               callback_url(authorization_state(authorization_url), "second-sibling-code")
             )

    reloaded_first = Repo.get!(UpstreamIdentity, first_identity.id)
    reloaded_second = Repo.get!(UpstreamIdentity, second_identity.id)

    assert relinked.id == second_identity.id
    assert reloaded_first.chatgpt_user_id == first_subject
    assert reloaded_first.workspace_id == nil
    assert reloaded_second.chatgpt_user_id == second_subject
    assert reloaded_second.workspace_id == nil
    assert Repo.get!(OAuthFlow, flow.id).result_upstream_identity_id == second_identity.id

    assert {:ok, "old-first-sibling-access"} =
             Secrets.decrypt_active_secret(first_identity, "access_token")

    assert {:ok, "new-second-sibling-access"} =
             Secrets.decrypt_active_secret(second_identity, "access_token")

    assert {:ok, "new-second-sibling-refresh"} =
             Secrets.decrypt_active_secret(second_identity, "refresh_token")

    assert active_secret_count(first_identity) == 1
    assert active_secret_count(second_identity) == 2
    assert Repo.aggregate(EncryptedSecret, :count) == 4
  end

  test "browser relink upgrades a unique legacy slot to the incoming workspace" do
    scope = fixture_owner_scope()
    pool = pool_fixture()

    legacy_identity =
      active_upstream_identity_fixture(relink_identity_attrs("acct_relink_legacy_upgrade", nil))

    assert {:ok, assignment} =
             PoolAssignments.create_pool_assignment(pool, legacy_identity)

    start_provider!(%{
      "/oauth/token" =>
        {200,
         FakeOpenAIAuthProvider.token_response(
           access_token: "legacy-upgrade-access",
           refresh_token: "legacy-upgrade-refresh",
           id_token: relink_id_token("acct_relink_legacy_upgrade", "ws_promoted_oauth")
         )}
    })

    assert {:ok, %{flow: flow, authorization_url: authorization_url}} =
             Upstreams.start_browser_oauth(scope, pool, upstream_identity: legacy_identity)

    assert {:ok, %{status: :completed, identity: promoted, assignment: promoted_assignment}} =
             Upstreams.complete_browser_oauth(
               scope,
               flow.id,
               callback_url(authorization_state(authorization_url), "legacy-upgrade-code")
             )

    assert promoted.id == legacy_identity.id
    assert promoted.workspace_id == "ws_promoted_oauth"
    assert promoted.account_label == "Existing operator label"
    assert promoted_assignment.id == assignment.id
    assert Repo.aggregate(UpstreamIdentity, :count) == 1
  end

  test "browser relink rejects ambiguous legacy slot when concrete siblings exist" do
    scope = fixture_owner_scope()
    pool = pool_fixture()
    account_id = "acct_relink_legacy_ambiguous"

    legacy_identity = active_upstream_identity_fixture(relink_identity_attrs(account_id, nil))

    concrete_identity =
      active_upstream_identity_fixture(relink_identity_attrs(account_id, "ws_existing"))

    assert {:ok, assignment} =
             PoolAssignments.create_pool_assignment(pool, legacy_identity)

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(
               legacy_identity,
               secret_attrs("access_token", "legacy-access")
             )

    start_provider!(%{
      "/oauth/token" =>
        {200,
         FakeOpenAIAuthProvider.token_response(
           access_token: "ambiguous-access",
           refresh_token: "ambiguous-refresh",
           id_token: relink_id_token(account_id, "ws_new")
         )}
    })

    assert {:ok, %{flow: flow, authorization_url: authorization_url}} =
             Upstreams.start_browser_oauth(scope, pool, upstream_identity: legacy_identity)

    assert {:error, %{code: :identity_conflict}} =
             Upstreams.complete_browser_oauth(
               scope,
               flow.id,
               callback_url(authorization_state(authorization_url), "ambiguous-code")
             )

    assert Repo.get!(OAuthFlow, flow.id).error_code == "identity_conflict"
    assert Repo.get!(UpstreamIdentity, legacy_identity.id).workspace_id == nil
    assert Repo.get!(UpstreamIdentity, concrete_identity.id).workspace_id == "ws_existing"

    assert Repo.get!(PoolUpstreamAssignment, assignment.id).upstream_identity_id ==
             legacy_identity.id

    assert {:ok, "legacy-access"} = Secrets.decrypt_active_secret(legacy_identity, "access_token")
    assert Repo.aggregate(UpstreamIdentity, :count) == 2
    assert Repo.aggregate(EncryptedSecret, :count) == 1
  end

  test "browser relink rejects missing-workspace claims for ambiguous legacy slot" do
    scope = fixture_owner_scope()
    pool = pool_fixture()
    account_id = "acct_relink_legacy_missing_workspace"

    legacy_identity = active_upstream_identity_fixture(relink_identity_attrs(account_id, nil))

    concrete_identity =
      active_upstream_identity_fixture(relink_identity_attrs(account_id, "ws_existing"))

    assert {:ok, assignment} =
             PoolAssignments.create_pool_assignment(pool, legacy_identity)

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(
               legacy_identity,
               secret_attrs("access_token", "legacy-missing-workspace-access")
             )

    start_provider!(%{
      "/oauth/token" =>
        {200,
         FakeOpenAIAuthProvider.token_response(
           access_token: "missing-workspace-access",
           refresh_token: "missing-workspace-refresh",
           id_token: relink_id_token(account_id, nil)
         )}
    })

    assert {:ok, %{flow: flow, authorization_url: authorization_url}} =
             Upstreams.start_browser_oauth(scope, pool, upstream_identity: legacy_identity)

    assert {:error, %{code: :identity_conflict}} =
             Upstreams.complete_browser_oauth(
               scope,
               flow.id,
               callback_url(authorization_state(authorization_url), "missing-workspace-code")
             )

    assert Repo.get!(OAuthFlow, flow.id).error_code == "identity_conflict"
    assert Repo.get!(UpstreamIdentity, legacy_identity.id).workspace_id == nil
    assert Repo.get!(UpstreamIdentity, concrete_identity.id).workspace_id == "ws_existing"

    assert Repo.get!(PoolUpstreamAssignment, assignment.id).upstream_identity_id ==
             legacy_identity.id

    assert {:ok, "legacy-missing-workspace-access"} =
             Secrets.decrypt_active_secret(legacy_identity, "access_token")

    assert Repo.aggregate(UpstreamIdentity, :count) == 2
    assert Repo.aggregate(EncryptedSecret, :count) == 1
  end

  defp fixture_owner_scope do
    %{user: user} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    Scope.for_user(user, ["instance_owner"])
  end

  defp relink_identity_attrs(account_id, workspace_id) do
    %{
      chatgpt_account_id: account_id,
      account_email: "#{account_id}@example.com",
      account_label: "Existing operator label",
      workspace_id: workspace_id,
      workspace_label: workspace_id && "Existing Workspace",
      onboarding_method: "browser"
    }
  end

  defp relink_id_token(account_id, workspace_id, opts \\ []) do
    auth_claims =
      %{
        "chatgpt_account_id" => account_id,
        "chatgpt_plan_type" => "team"
      }
      |> maybe_put_claim(
        "chatgpt_user_id",
        Keyword.get(opts, :chatgpt_user_id, "user_#{account_id}")
      )
      |> maybe_put_claim("workspace_id", workspace_id)
      |> maybe_put_claim("workspace_label", workspace_id && "OAuth Workspace")
      |> maybe_put_claim("seat_type", "team-seat")

    FakeOpenAIAuthProvider.id_token(%{
      "email" => "#{account_id}@example.com",
      "https://api.openai.com/auth" => auth_claims
    })
  end

  defp maybe_put_claim(map, _key, nil), do: map
  defp maybe_put_claim(map, key, value), do: Map.put(map, key, value)

  defp subject_bound_identity_fixture(identity, subject) do
    identity
    |> UpstreamIdentity.changeset(%{chatgpt_user_id: subject})
    |> Repo.update!()
  end

  defp active_secret_count(identity) do
    Repo.aggregate(
      from(secret in EncryptedSecret,
        where: secret.upstream_identity_id == ^identity.id and secret.status == "active"
      ),
      :count
    )
  end

  defp assert_identity_mismatch_without_leak(error, denied_values) do
    assert error.message == "OAuth account does not match the selected upstream account"

    error_dump = inspect(error)

    for denied_value <- denied_values do
      refute error_dump =~ denied_value
    end
  end

  defp secret_attrs(secret_kind, plaintext) do
    %{secret_kind: secret_kind, plaintext: plaintext}
  end

  defp start_provider!(routes) do
    {:ok, provider} = FakeOpenAIAuthProvider.start_link(routes)
    Application.put_env(:codex_pooler, CodexAuth, issuer: FakeOpenAIAuthProvider.url(provider))
    on_exit(fn -> FakeOpenAIAuthProvider.stop(provider) end)
    provider
  end

  defp authorization_state(authorization_url) do
    authorization_url
    |> URI.parse()
    |> Map.fetch!(:query)
    |> URI.decode_query()
    |> Map.fetch!("state")
  end

  defp callback_url(state, code) do
    "http://localhost:1455/auth/callback?" <>
      URI.encode_query(%{"state" => state, "code" => code})
  end

  defp restore_codex_auth_config! do
    previous = Application.get_env(:codex_pooler, CodexAuth)

    on_exit(fn ->
      if previous do
        Application.put_env(:codex_pooler, CodexAuth, previous)
      else
        Application.delete_env(:codex_pooler, CodexAuth)
      end
    end)
  end

  defp configure_upstream_secret_key! do
    previous = Application.get_env(:codex_pooler, CodexPooler.Upstreams)

    Application.put_env(:codex_pooler, CodexPooler.Upstreams,
      upstream_secret_key: Base.encode64(:crypto.hash(:sha256, "test-upstream-secret-key")),
      upstream_secret_key_version: "test-v1"
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:codex_pooler, CodexPooler.Upstreams, previous)
      else
        Application.delete_env(:codex_pooler, CodexPooler.Upstreams)
      end
    end)
  end
end
