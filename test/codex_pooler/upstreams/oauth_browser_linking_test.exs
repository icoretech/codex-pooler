defmodule CodexPooler.Upstreams.OAuthBrowserLinkingTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.FakeOpenAIAuthProvider
  alias CodexPooler.Jobs.AccountReconciliationWorker
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Auth.CodexAuth
  alias CodexPooler.Upstreams.OAuthFlows

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

  @tag :subject_plumbing
  test "browser callback completion exchanges the code and links the upstream account atomically" do
    scope = fixture_owner_scope()
    pool = pool_fixture()
    id_token = browser_id_token("acct_browser_success")
    access_token = "browser-access-token-must-be-encrypted"
    refresh_token = "browser-refresh-token-must-be-encrypted"

    provider =
      start_provider!(%{
        "/oauth/token" =>
          {200,
           FakeOpenAIAuthProvider.token_response(
             access_token: access_token,
             refresh_token: refresh_token,
             id_token: id_token
           )}
      })

    assert {:ok, %{flow: flow, authorization_url: authorization_url}} =
             Upstreams.start_browser_oauth(scope, pool)

    state = authorization_state(authorization_url)
    callback_url = callback_url(state, "browser-code-success")

    assert {:ok,
            %{
              status: :completed,
              link_status: :created,
              flow: completed_flow,
              identity: identity,
              assignment: assignment,
              secret_status: :present
            } = result} =
             Upstreams.complete_browser_oauth(scope, flow.id, callback_url)

    assert completed_flow.status == "completed"
    assert completed_flow.result_upstream_identity_id == identity.id
    assert %DateTime{} = completed_flow.completed_at
    assert identity.chatgpt_account_id == "acct_browser_success"
    assert identity.chatgpt_user_id == "user_acct_browser_success"
    assert identity.account_email == "browser-acct_browser_success@example.com"
    assert identity.account_label == "browser-acct_browser_success@example.com"
    assert identity.workspace_id == "workspace-browser"
    assert identity.workspace_label == "Browser Workspace"
    assert identity.seat_type == "team-seat"
    assert identity.onboarding_method == "browser"
    assert identity.plan_family == "team"
    assert identity.plan_label == "team"
    assert assignment.pool_id == pool.id
    assert assignment.upstream_identity_id == identity.id
    assert assignment.status == "active"

    assert active_secret_count("access_token") == 1
    assert active_secret_count("refresh_token") == 1
    jobs = all_enqueued(worker: AccountReconciliationWorker)
    assert job = Enum.find(jobs, &(&1.args["pool_upstream_assignment_id"] == assignment.id))
    assert job.args["pool_id"] == pool.id
    assert job.args["trigger_kind"] == "account_link"

    assert [request] = FakeOpenAIAuthProvider.requests(provider)
    form = FakeOpenAIAuthProvider.decode_form_request(request)
    assert form["code"] == "browser-code-success"
    assert form["redirect_uri"] == CodexAuth.browser_redirect_uri()
    assert {:ok, verifier} = OAuthFlows.decrypt_code_verifier(flow)
    assert form["code_verifier"] == verifier

    refute_result_contains(result, [
      callback_url,
      "browser-code-success",
      verifier,
      id_token,
      access_token,
      refresh_token
    ])
  end

  test "duplicate browser callback completion returns completed success without re-exchanging tokens" do
    scope = fixture_owner_scope()
    pool = pool_fixture()

    provider =
      start_provider!(%{
        "/oauth/token" =>
          {200,
           FakeOpenAIAuthProvider.token_response(
             access_token: "duplicate-access-token",
             refresh_token: "duplicate-refresh-token",
             id_token: browser_id_token("acct_browser_duplicate")
           )}
      })

    assert {:ok, %{flow: flow, authorization_url: authorization_url}} =
             Upstreams.start_browser_oauth(scope, pool)

    callback_url = callback_url(authorization_state(authorization_url), "browser-code-duplicate")

    assert {:ok, %{status: :completed, flow: completed_flow, identity: identity}} =
             Upstreams.complete_browser_oauth(scope, flow.id, callback_url)

    assert {:ok, %{status: :completed, flow: duplicate_flow}} =
             Upstreams.complete_browser_oauth(scope, flow.id, callback_url)

    assert duplicate_flow.id == completed_flow.id
    assert duplicate_flow.result_upstream_identity_id == identity.id
    assert length(FakeOpenAIAuthProvider.requests(provider)) == 1
    assert active_secret_count("access_token") == 1
    assert active_secret_count("refresh_token") == 1
  end

  test "wrong-state browser callback does not create identity assignment or secret rows" do
    scope = fixture_owner_scope()
    pool = pool_fixture()
    start_provider!(%{"/oauth/token" => {200, FakeOpenAIAuthProvider.token_response()}})

    assert {:ok, %{flow: flow}} = Upstreams.start_browser_oauth(scope, pool)

    assert {:error, %{code: :invalid_state}} =
             Upstreams.complete_browser_oauth(
               scope,
               flow.id,
               callback_url("wrong-state", "browser-code-wrong-state")
             )

    assert Repo.get!(OAuthFlow, flow.id).status == "pending"
    assert Repo.aggregate(UpstreamIdentity, :count) == 0
    assert Repo.aggregate(PoolUpstreamAssignment, :count) == 0
    assert Repo.aggregate(EncryptedSecret, :count) == 0
  end

  test "expired browser callback marks the flow expired without linking anything" do
    scope = fixture_owner_scope()
    pool = pool_fixture()
    expired_at = DateTime.utc_now() |> DateTime.add(-1, :second)
    start_provider!(%{"/oauth/token" => {200, FakeOpenAIAuthProvider.token_response()}})

    assert {:ok, %{flow: flow, authorization_url: authorization_url}} =
             Upstreams.start_browser_oauth(scope, pool, expires_at: expired_at)

    assert {:error, %{code: :expired_flow}} =
             Upstreams.complete_browser_oauth(
               scope,
               flow.id,
               callback_url(authorization_state(authorization_url), "browser-code-expired")
             )

    reloaded = Repo.get!(OAuthFlow, flow.id)
    assert reloaded.status == "expired"
    assert reloaded.error_code == "expired_flow"
    assert Repo.aggregate(UpstreamIdentity, :count) == 0
    assert Repo.aggregate(PoolUpstreamAssignment, :count) == 0
    assert Repo.aggregate(EncryptedSecret, :count) == 0
  end

  test "provider-denied browser callback stores only safe failure fields" do
    scope = fixture_owner_scope()
    pool = pool_fixture()
    raw_provider_value = "raw-provider-denial-token-must-not-leak"

    assert {:ok, %{flow: flow, authorization_url: authorization_url}} =
             Upstreams.start_browser_oauth(scope, pool)

    denied_callback_url =
      "http://localhost:1455/auth/callback?" <>
        URI.encode_query(%{
          "state" => authorization_state(authorization_url),
          "error" => "access_denied",
          "error_description" => raw_provider_value
        })

    assert {:error, %{code: :provider_denied, message: "OpenAI denied the OAuth request"} = error} =
             Upstreams.complete_browser_oauth(scope, flow.id, denied_callback_url)

    reloaded = Repo.get!(OAuthFlow, flow.id)
    assert reloaded.status == "failed"
    assert reloaded.error_code == "provider_denied"
    assert reloaded.error_message == "OpenAI denied the OAuth request"
    refute inspect(error) =~ raw_provider_value
    refute inspect(reloaded) =~ raw_provider_value
    assert Repo.aggregate(UpstreamIdentity, :count) == 0
    assert Repo.aggregate(EncryptedSecret, :count) == 0
  end

  test "token-exchange failure marks the flow failed without leaking provider payloads" do
    scope = fixture_owner_scope()
    pool = pool_fixture()
    raw_provider_value = "raw-token-exchange-secret-must-not-leak"

    start_provider!(%{
      "/oauth/token" =>
        {400,
         %{
           "error" => "invalid_grant",
           "error_description" => raw_provider_value,
           "access_token" => raw_provider_value
         }}
    })

    assert {:ok, %{flow: flow, authorization_url: authorization_url}} =
             Upstreams.start_browser_oauth(scope, pool)

    assert {:error,
            %{code: :token_exchange_failed, message: "OAuth token exchange failed"} = error} =
             Upstreams.complete_browser_oauth(
               scope,
               flow.id,
               callback_url(authorization_state(authorization_url), "browser-code-fails")
             )

    reloaded = Repo.get!(OAuthFlow, flow.id)
    assert reloaded.status == "failed"
    assert reloaded.error_code == "token_exchange_failed"
    assert reloaded.error_message == "OAuth token exchange failed"
    refute inspect(error) =~ raw_provider_value
    refute inspect(reloaded) =~ raw_provider_value
    assert Repo.aggregate(UpstreamIdentity, :count) == 0
    assert Repo.aggregate(PoolUpstreamAssignment, :count) == 0
    assert Repo.aggregate(EncryptedSecret, :count) == 0
  end

  test "successful browser linking does not persist raw callback verifier code or token values" do
    scope = fixture_owner_scope()
    pool = pool_fixture()
    access_token = "raw-browser-access-token-must-not-leak"
    refresh_token = "raw-browser-refresh-token-must-not-leak"
    id_token = browser_id_token("acct_browser_secret_boundary")

    start_provider!(%{
      "/oauth/token" =>
        {200,
         FakeOpenAIAuthProvider.token_response(
           access_token: access_token,
           refresh_token: refresh_token,
           id_token: id_token
         )}
    })

    assert {:ok, %{flow: flow, authorization_url: authorization_url}} =
             Upstreams.start_browser_oauth(scope, pool)

    state = authorization_state(authorization_url)
    callback_url = callback_url(state, "browser-code-secret-boundary")

    assert {:ok, %{flow: completed_flow}} =
             Upstreams.complete_browser_oauth(scope, flow.id, callback_url)

    assert {:ok, verifier} = OAuthFlows.decrypt_code_verifier(flow)

    persisted_flow = Repo.get!(OAuthFlow, completed_flow.id)
    secrets = Repo.all(EncryptedSecret)

    for raw_value <- [
          callback_url,
          state,
          "browser-code-secret-boundary",
          verifier,
          id_token,
          access_token,
          refresh_token
        ] do
      refute inspect(persisted_flow.metadata) =~ raw_value
      refute inspect(persisted_flow) =~ raw_value
      refute inspect(secrets) =~ raw_value
    end
  end

  defp fixture_owner_scope do
    %{user: user} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    Scope.for_user(user, ["instance_owner"])
  end

  defp start_provider!(routes) do
    {:ok, provider} = FakeOpenAIAuthProvider.start_link(routes)
    Application.put_env(:codex_pooler, CodexAuth, issuer: FakeOpenAIAuthProvider.url(provider))
    on_exit(fn -> FakeOpenAIAuthProvider.stop(provider) end)
    provider
  end

  defp browser_id_token(account_id) do
    FakeOpenAIAuthProvider.id_token(%{
      "email" => "browser-#{account_id}@example.com",
      "https://api.openai.com/auth" => %{
        "chatgpt_account_id" => account_id,
        "chatgpt_user_id" => "user_#{account_id}",
        "chatgpt_plan_type" => "team",
        "workspace_id" => "workspace-browser",
        "workspace_label" => "Browser Workspace",
        "seat_type" => "team-seat"
      }
    })
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

  defp active_secret_count(secret_kind) do
    Repo.aggregate(
      from(secret in EncryptedSecret,
        where: secret.secret_kind == ^secret_kind and secret.status == "active"
      ),
      :count
    )
  end

  defp refute_result_contains(result, raw_values) do
    result_text = inspect(result)

    Enum.each(raw_values, fn raw_value ->
      refute result_text =~ raw_value
    end)
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
