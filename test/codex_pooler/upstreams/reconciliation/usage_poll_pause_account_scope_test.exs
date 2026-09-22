defmodule CodexPooler.Upstreams.Reconciliation.UsagePollPauseAccountScopeTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.FakeOpenAIAuthProvider
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Jobs.TokenRefreshWorker
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Lifecycle.CredentialFencing
  alias CodexPooler.Upstreams.Reconciliation.PoolReconciliation
  alias CodexPooler.Upstreams.Reconciliation.UsageProbe
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  # findings#259: the provider throttles the provider account, not one access
  # token. A Retry-After pause therefore survives everything that keeps the
  # credential on the same provider account - token refreshes, including the
  # admin "Refresh token" action, pause then reactivate, a re-import of the
  # same account - and ends only at its deadline or when the identity now
  # belongs to a different provider account.
  @three_days 3 * 86_400

  setup do
    {:ok, fake} =
      FakeUpstream.start_link(
        {:path_json,
         %{
           "/backend-api/wham/usage" => {:json_headers, 429, %{}, [{"retry-after", Integer.to_string(@three_days)}]},
           "/backend-api/codex/usage" => {200, %{}},
           "/oauth/token" => {200, %{"access_token" => "usage-pause-scope-access-refreshed", "expires_in" => "3600"}}
         }}
      )

    on_exit(fn -> FakeUpstream.stop(fake) end)

    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    %{fake: fake, scope: Scope.for_user(owner, ["instance_owner"]), pool: pool_fixture()}
  end

  test "a successful token refresh through the admin action does not end the pause", ctx do
    %{identity: identity, assignment: assignment} = paused_account!(ctx)
    epoch = CredentialFencing.credential_epoch(identity)

    assert {:ok, _} = Upstreams.store_encrypted_secret(identity, %{secret_kind: "refresh_token", plaintext: "usage-pause-scope-refresh"})
    assert {:ok, %{job: job}} = Upstreams.enqueue_token_refresh_for_scope(ctx.scope, identity.id, trigger_kind: "admin_upstreams_live")
    assert :ok = perform_job(TokenRefreshWorker, job.args)

    refreshed = Repo.get!(UpstreamIdentity, identity.id)
    assert CredentialFencing.credential_epoch(refreshed) > epoch
    assert_still_paused!(ctx, refreshed, assignment)
  end

  test "pausing and reactivating the account does not end the pause", ctx do
    %{identity: identity, assignment: assignment} = paused_account!(ctx)
    epoch = CredentialFencing.credential_epoch(identity)

    assert {:ok, _} = Upstreams.pause_account_for_scope(ctx.scope, identity.id, %{reason: "usage_pause_scope"})
    assert {:ok, _} = Upstreams.reactivate_account_for_scope(ctx.scope, identity.id, %{reason: "usage_pause_scope"})

    reactivated = Repo.get!(UpstreamIdentity, identity.id)
    assert CredentialFencing.credential_epoch(reactivated) > epoch
    assert_still_paused!(ctx, reactivated, Repo.get!(PoolUpstreamAssignment, assignment.id))
  end

  test "a re-import of the same provider account does not end the pause", ctx do
    %{identity: identity, assignment: assignment} = paused_account!(ctx, "acct_usage_pause_same")
    epoch = CredentialFencing.credential_epoch(identity)

    assert {:ok, %{identity: reimported}} =
             Upstreams.import_codex_auth_json(ctx.scope, ctx.pool, auth_json("acct_usage_pause_same", "reimport"))

    assert reimported.id == identity.id
    assert CredentialFencing.credential_epoch(reimported) > epoch
    assert_still_paused!(ctx, reimported, Repo.get!(PoolUpstreamAssignment, assignment.id))
  end

  test "an import of a different provider account is not paused, and the throttled account stays paused", ctx do
    %{identity: identity, assignment: assignment} = paused_account!(ctx, "acct_usage_pause_first")

    assert {:ok, %{identity: other}} =
             Upstreams.import_codex_auth_json(ctx.scope, ctx.pool, auth_json("acct_usage_pause_other", "other"))

    refute other.id == identity.id
    assert Upstreams.usage_poll_pauses(other, DateTime.utc_now()) == []
    assert_still_paused!(ctx, Repo.get!(UpstreamIdentity, identity.id), assignment)
  end

  test "the pause ends when the identity now belongs to a different provider account", ctx do
    %{identity: identity} = paused_account!(ctx)

    # The stored account id is what the provider throttled; once the identity
    # carries another one, the pause describes an account it no longer is.
    rebound =
      identity
      |> Ecto.Changeset.change(chatgpt_account_id: "acct_usage_pause_rebound_#{System.unique_integer([:positive])}")
      |> Repo.update!()

    assert Upstreams.usage_poll_pauses(rebound, DateTime.utc_now()) == []
  end

  test "an identity without a provider account id keeps the credential epoch rule", ctx do
    %{identity: identity, assignment: assignment} = paused_account!(ctx, nil)
    assert [%{}] = Upstreams.usage_poll_pauses(identity, DateTime.utc_now())

    assert {:ok, _} = Upstreams.pause_account_for_scope(ctx.scope, identity.id, %{reason: "usage_pause_scope"})
    assert {:ok, _} = Upstreams.reactivate_account_for_scope(ctx.scope, identity.id, %{reason: "usage_pause_scope"})

    reactivated = Repo.get!(UpstreamIdentity, identity.id)
    assert Upstreams.usage_poll_pauses(reactivated, DateTime.utc_now()) == []
    assert Repo.get!(PoolUpstreamAssignment, assignment.id).status == "active"
  end

  # Imports (or creates) the account, points its usage and OAuth endpoints at
  # the fake upstream, and runs one real reconciliation that records the pause.
  defp paused_account!(ctx, account_id \\ :generated) do
    url = FakeUpstream.url(ctx.fake)

    {identity, assignment} =
      case account_id do
        :generated ->
          %{identity: identity, assignment: assignment} =
            active_upstream_assignment_fixture(ctx.pool, %{metadata: %{"usage_base_url" => url, "base_url" => url}})

          {identity, assignment}

        nil ->
          %{identity: identity, assignment: assignment} =
            active_upstream_assignment_fixture(ctx.pool, %{chatgpt_account_id: nil, metadata: %{"usage_base_url" => url, "base_url" => url}})

          {identity, assignment}

        account_id when is_binary(account_id) ->
          assert {:ok, %{identity: identity, assignment: assignment}} =
                   Upstreams.import_codex_auth_json(ctx.scope, ctx.pool, auth_json(account_id, "first"))

          {put_metadata!(identity, url), put_metadata!(assignment, url)}
      end

    reconcile_or_probe!(ctx, identity, assignment)
    assert usage_requests(ctx.fake) == 1

    identity = Repo.get!(UpstreamIdentity, identity.id)
    assert [%{status_code: 429, not_before: not_before}] = Upstreams.usage_poll_pauses(identity, DateTime.utc_now())
    assert DateTime.diff(not_before, DateTime.utc_now(), :second) > @three_days - 120

    %{identity: identity, assignment: Repo.get!(PoolUpstreamAssignment, assignment.id)}
  end

  defp assert_still_paused!(ctx, identity, assignment) do
    assert [%{status_code: 429}] = Upstreams.usage_poll_pauses(identity, DateTime.utc_now())

    # And the next cycle still does not reach the provider.
    reconcile_or_probe!(ctx, identity, assignment)
    assert usage_requests(ctx.fake) == 1
  end

  defp reconcile_or_probe!(_ctx, %UpstreamIdentity{chatgpt_account_id: nil} = identity, assignment) do
    _ = UsageProbe.fetch_from_identity(identity, assignment, DateTime.utc_now(), [])
  end

  defp reconcile_or_probe!(ctx, _identity, assignment) do
    assert {:ok, _} = PoolReconciliation.reconcile_pool_account(ctx.pool, assignment, [])
  end

  defp usage_requests(fake), do: fake |> FakeUpstream.requests() |> Enum.count(&(&1.path == "/backend-api/wham/usage"))

  defp put_metadata!(%schema{} = row, url) do
    row = Repo.get!(schema, row.id)

    row
    |> Ecto.Changeset.change(metadata: Map.merge(row.metadata || %{}, %{"usage_base_url" => url, "base_url" => url}))
    |> Repo.update!()
  end

  defp auth_json(account_id, suffix) do
    access =
      FakeOpenAIAuthProvider.id_token(%{
        "exp" => DateTime.utc_now() |> DateTime.add(3_600, :second) |> DateTime.to_unix(),
        "https://api.openai.com/auth" => %{"chatgpt_account_id" => account_id, "chatgpt_user_id" => "user_#{account_id}"}
      })

    CodexPooler.JSON.encode!(%{
      "auth_mode" => "chatgpt",
      "OPENAI_API_KEY" => nil,
      "tokens" => %{
        "id_token" =>
          FakeOpenAIAuthProvider.id_token(%{
            "email" => "#{account_id}@example.com",
            "https://api.openai.com/auth" => %{
              "chatgpt_account_id" => account_id,
              "chatgpt_user_id" => "user_#{account_id}",
              "chatgpt_plan_type" => "pro"
            }
          }),
        "access_token" => access,
        "refresh_token" => "usage-pause-scope-refresh-#{suffix}",
        "account_id" => account_id
      },
      "last_refresh" => "2026-09-01T00:00:00Z"
    })
  end
end
