defmodule CodexPoolerWeb.OnboardingLive.InviteTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Access
  alias CodexPooler.Access.{APIKey, InviteAcceptance}
  alias CodexPooler.Access.InviteOnboarding
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Events
  alias CodexPooler.Jobs.AccountReconciliationWorker
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.EncryptedSecret
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  test "renders a valid invite link without authentication" do
    pool = pool_fixture(%{slug: "team-alpha", name: "Team Alpha"})
    scope = fixture_owner_scope()

    {:ok, %{token: token}} =
      Access.create_invite(scope, pool, %{
        invited_email: "invited@example.com",
        expires_at: DateTime.utc_now() |> DateTime.add(3600, :second)
      })

    {:ok, view, _html} = live(build_conn(), ~p"/onboarding/invites/#{token}")
    html = render(view)

    assert has_element?(view, "#invite-page")
    assert has_element?(view, "h1.text-primary", "Connect your Codex account")
    assert_public_footer(view, "#invite-footer")
    assert has_element?(view, "#invite-metadata")
    assert has_element?(view, "#invite-pool-name", "Team Alpha")
    assert has_element?(view, "#invite-inviter", scope.user.email)
    assert has_element?(view, "#invite-invited-email", "invited@example.com")
    assert has_element?(view, "#invite-status", "Active invite")
    assert has_element?(view, "#invite-expiry-countdown", "Expires in")
    refute has_element?(view, "header")
    refute has_element?(view, "nav")
    refute has_element?(view, "#admin-nav")
    refute has_element?(view, "#invite-pool-slug")
    refute has_element?(view, "#invite-methods")
    refute has_element?(view, "#accept-invite-button")
    assert has_element?(view, "#device-onboarding-button")
    refute html =~ "OPERATOR AUTH"
    refute html =~ "Redemptions"
    refute html =~ "Browser sign-in"
    refute html =~ "oauth/authorize"
    refute html =~ "The device-code flow keeps browser callbacks out of this public page"
    refute html =~ token
  end

  test "bootstrap and login use the public auth chrome" do
    {:ok, bootstrap_view, _html} = live(build_conn(), ~p"/bootstrap")

    refute has_element?(bootstrap_view, "header", "CODEX POOLER")
    refute has_element?(bootstrap_view, "header", "OPERATOR AUTH")
    assert_auth_logo(bootstrap_view, "#bootstrap-logo")
    assert has_element?(bootstrap_view, "h1.text-primary", "Bootstrap")
    assert_public_footer(bootstrap_view, "#auth-footer")
    refute render(bootstrap_view) =~ ~s(data-phx-theme="system")

    bootstrap_owner_fixture()

    {:ok, login_view, _html} = live(build_conn(), ~p"/login")

    refute has_element?(login_view, "header", "CODEX POOLER")
    refute has_element?(login_view, "header", "OPERATOR AUTH")
    assert_auth_logo(login_view, "#login-logo")
    assert has_element?(login_view, "h1.text-primary", "Sign in")
    assert_public_footer(login_view, "#auth-footer")
    refute render(login_view) =~ ~s(data-phx-theme="system")
  end

  test "renders a clean error for an invalid invite link" do
    invalid_token = "not-a-real-token-with-sensitive-fragment"

    {:ok, view, _html} = live(build_conn(), ~p"/onboarding/invites/#{invalid_token}")

    assert has_element?(view, "#invite-error")
    refute has_element?(view, "#invite-metadata")
    refute has_element?(view, "#accept-invite-button")
    refute has_element?(view, "#device-onboarding-button")
    refute render(view) =~ invalid_token
  end

  test "renders an expired invite without onboarding actions" do
    pool = pool_fixture(%{slug: "expired-pool", name: "Expired Pool"})
    scope = fixture_owner_scope()

    {:ok, %{token: token}} =
      Access.create_invite(scope, pool, %{
        invited_email: "expired@example.com",
        expires_at: DateTime.utc_now() |> DateTime.add(-60, :second)
      })

    {:ok, view, _html} = live(build_conn(), ~p"/onboarding/invites/#{token}")

    assert has_element?(view, "#invite-expired")
    refute has_element?(view, "#invite-error")
    refute has_element?(view, "#invite-metadata")
    refute has_element?(view, "#accept-invite-button")
    refute has_element?(view, "#device-onboarding-button")
  end

  test "renders a valid public invite for an authenticated admin session" do
    %{user: user, token: user_token} = bootstrap_owner_fixture()
    scope = Scope.for_user(user, ["instance_owner"])

    pool =
      pool_fixture(%{slug: "admin-opened", name: "Admin Opened", created_by_user_id: user.id})

    {:ok, %{token: token}} =
      Access.create_invite(scope, pool, %{invited_email: "admin-opened@example.com"})

    conn = log_in_user(build_conn(), user, user_token)
    {:ok, view, _html} = live(conn, ~p"/onboarding/invites/#{token}")

    assert has_element?(view, "#invite-page")
    assert has_element?(view, "#invite-metadata")
    refute has_element?(view, "header")
    refute has_element?(view, "#accept-invite-button")
    assert has_element?(view, "#device-onboarding-button")
  end

  test "removed browser callback route fails closed by route absence" do
    {token, _pool} = invite_fixture()

    conn = get(build_conn(), "/api/onboarding/invites/#{token}/browser/callback")

    assert html_response(conn, 404) =~ "Not Found"
    assert Repo.aggregate(InviteAcceptance, :count) == 0
    assert Repo.aggregate(UpstreamIdentity, :count) == 0
    assert Repo.aggregate(PoolUpstreamAssignment, :count) == 0
    assert active_secret_count("access_token") == 0
    assert active_secret_count("refresh_token") == 0
  end

  test "starts device onboarding and shows pending polling state" do
    configure_codex_auth_client!(%{
      poll_result:
        {:error,
         %{
           code: :codex_device_authorization_pending,
           message: "pending",
           retry_after_seconds: 7
         }}
    })

    {token, _pool} = invite_fixture()
    {:ok, view, _html} = live(build_conn(), ~p"/onboarding/invites/#{token}")

    view
    |> element("#device-onboarding-button")
    |> render_click()

    assert has_element?(view, "#device-authorization")
    assert has_element?(view, "#device-user-code", "ABCD-EFGH")
    assert has_element?(view, "#invite-device-code-copy[phx-hook='ClipboardCopy']")
    assert has_element?(view, "#invite-device-code-copy[aria-label='Copy device code']")
    assert has_element?(view, "#invite-device-code-copy[data-copy-text='ABCD-EFGH']")

    assert has_element?(
             view,
             "#device-verification-url[target='_blank'][rel='noopener noreferrer']",
             "https://auth.openai.com/codex/device"
           )

    assert has_element?(view, "#device-poll-spinner")
    assert has_element?(view, "#device-poll-status", "Open the verification page")
    refute has_element?(view, "#device-user-code-copy")
    refute has_element?(view, "#poll-device-onboarding-button")
    refute render(view) =~ "Copy device code</span>"

    send_current_device_poll(view)

    assert has_element?(view, "#device-poll-spinner")
    assert has_element?(view, "#device-poll-status", "Checking again in 7 seconds")
  end

  test "device polling stops cleanly when the device code expires" do
    configure_codex_auth_client!(%{
      poll_result:
        {:error,
         %{
           code: :codex_device_code_expired,
           message: "expired"
         }}
    })

    {token, _pool} = invite_fixture()
    {:ok, view, _html} = live(build_conn(), ~p"/onboarding/invites/#{token}")

    view
    |> element("#device-onboarding-button")
    |> render_click()

    assert has_element?(view, "#device-poll-spinner")

    send_current_device_poll(view)

    assert has_element?(view, "#device-poll-status", "authorization window expired")
    refute has_element?(view, "#device-poll-spinner")
    refute current_device_poll_ref(view)
  end

  test "automatic device polling handles slow down before completion" do
    configure_codex_auth_client!(%{
      poll_results: [
        {:error,
         %{
           code: :codex_device_authorization_slow_down,
           message: "slow down",
           retry_after_seconds: 9
         }},
        {:ok, token_payload()}
      ]
    })

    {token, _pool} = invite_fixture()
    {:ok, view, _html} = live(build_conn(), ~p"/onboarding/invites/#{token}")

    view
    |> element("#device-onboarding-button")
    |> render_click()

    send_current_device_poll(view)

    assert has_element?(view, "#device-poll-status", "Checking again in 9 seconds")

    send_current_device_poll(view)

    assert has_element?(view, "#invite-accepted")
    assert has_element?(view, "#completed-account-email", "codex-user@example.com")
  end

  test "stale duplicate device poll timer messages are ignored" do
    configure_codex_auth_client!(%{
      poll_results: [
        {:error,
         %{
           code: :codex_device_authorization_pending,
           message: "pending",
           retry_after_seconds: 5
         }},
        {:ok, token_payload()}
      ]
    })

    {token, _pool} = invite_fixture()
    {:ok, view, _html} = live(build_conn(), ~p"/onboarding/invites/#{token}")

    view |> element("#device-onboarding-button") |> render_click()

    first_ref = current_device_poll_ref(view)
    send(view.pid, {:poll_device_authorization, make_ref()})
    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#device-poll-status", "Open the verification page")
    assert poll_count() == 0

    send(view.pid, {:poll_device_authorization, first_ref})
    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#device-poll-status", "Checking again in 5 seconds")
    assert poll_count() == 1

    send(view.pid, {:poll_device_authorization, first_ref})
    _ = :sys.get_state(view.pid)

    refute has_element?(view, "#invite-accepted")
    assert has_element?(view, "#device-poll-status", "Checking again in 5 seconds")
    assert poll_count() == 1

    send_current_device_poll(view)

    assert has_element?(view, "#invite-accepted")
    assert poll_count() == 2
  end

  test "polls device onboarding to completion" do
    configure_codex_auth_client!(%{poll_result: {:ok, token_payload()}})

    {token, _pool} = invite_fixture()
    api_key_count_before = Repo.aggregate(APIKey, :count)
    identity_count_before = Repo.aggregate(UpstreamIdentity, :count)
    assignment_count_before = Repo.aggregate(PoolUpstreamAssignment, :count)
    acceptance_count_before = Repo.aggregate(InviteAcceptance, :count)

    {:ok, view, _html} = live(build_conn(), ~p"/onboarding/invites/#{token}")

    view
    |> element("#device-onboarding-button")
    |> render_click()

    send_current_device_poll(view)

    assert has_element?(view, "#invite-accepted")
    assert has_element?(view, "#completed-account-email", "codex-user@example.com")
    assert has_element?(view, "#invite-config-panel")
    assert has_element?(view, "#invite-config-copy[data-copy-text*='CODEX_POOLER_API_KEY']")
    assert Repo.aggregate(APIKey, :count) == api_key_count_before
    assert Repo.aggregate(UpstreamIdentity, :count) == identity_count_before + 1
    assert Repo.aggregate(PoolUpstreamAssignment, :count) == assignment_count_before + 1
    assert Repo.aggregate(InviteAcceptance, :count) == acceptance_count_before + 1
    assert Repo.one!(UpstreamIdentity).status == "active"
    assert Repo.one!(PoolUpstreamAssignment).status == "active"
    assert active_secret_count("access_token") == 1
    assert active_secret_count("refresh_token") == 1
    assert active_secret_count("device_code") == 1
    assert {:error, %{code: :invite_consumed}} = Access.load_usable_invite_contract(token)

    assignment = Repo.one!(PoolUpstreamAssignment)

    assert job =
             Repo.one(
               from job in Oban.Job,
                 where:
                   job.worker == ^worker_name(AccountReconciliationWorker) and
                     fragment("?->>?", job.args, "pool_upstream_assignment_id") == ^assignment.id
             )

    assert job.args["trigger_kind"] == "account_link"
    assert assignment.metadata["quota_priming"]["status"] == "unknown"
  end

  test "restricted invite rejects a different authorized Codex email without side effects" do
    configure_codex_auth_client!(%{
      poll_result: {:ok, token_payload(%{"email" => "other@example.com"})}
    })

    {token, _pool} = invite_fixture(%{invited_email: "invited@example.com"})
    identity_count_before = Repo.aggregate(UpstreamIdentity, :count)
    assignment_count_before = Repo.aggregate(PoolUpstreamAssignment, :count)
    acceptance_count_before = Repo.aggregate(InviteAcceptance, :count)
    job_count_before = Repo.aggregate(Oban.Job, :count)

    {:ok, view, _html} = live(build_conn(), ~p"/onboarding/invites/#{token}")

    view
    |> element("#device-onboarding-button")
    |> render_click()

    send_current_device_poll(view)

    refute has_element?(view, "#invite-accepted")
    assert render(view) =~ "The authorized Codex account email does not match this invite."
    assert Repo.aggregate(UpstreamIdentity, :count) == identity_count_before + 1
    assert Repo.aggregate(PoolUpstreamAssignment, :count) == assignment_count_before + 1
    assert Repo.aggregate(InviteAcceptance, :count) == acceptance_count_before
    assert Repo.aggregate(Oban.Job, :count) == job_count_before
    assert Repo.one!(UpstreamIdentity).status == "pending"
    assert Repo.one!(PoolUpstreamAssignment).status == "pending"
    assert active_secret_count("access_token") == 0
    assert active_secret_count("refresh_token") == 0
    assert active_secret_count("device_code") == 1
    assert {:ok, contract} = Access.load_usable_invite_contract(token)
    assert contract.invite.status == "active"
  end

  test "restricted invite accepts normalized matching Codex email" do
    configure_codex_auth_client!(%{
      poll_result: {:ok, token_payload(%{"email" => " Invited@Example.COM "})}
    })

    {token, _pool} = invite_fixture(%{invited_email: "Invited@Example.COM"})
    {:ok, view, _html} = live(build_conn(), ~p"/onboarding/invites/#{token}")

    view
    |> element("#device-onboarding-button")
    |> render_click()

    send_current_device_poll(view)

    assert has_element?(view, "#invite-accepted")
    assert has_element?(view, "#completed-account-email", "invited@example.com")
    assert Repo.one!(UpstreamIdentity).status == "active"
    assert Repo.one!(PoolUpstreamAssignment).status == "active"
    assert active_secret_count("access_token") == 1
    assert active_secret_count("refresh_token") == 1
    assert active_secret_count("device_code") == 1
    assert {:error, %{code: :invite_consumed}} = Access.load_usable_invite_contract(token)
  end

  test "second invite completion reuses the existing upstream account" do
    configure_codex_auth_client!(%{poll_result: {:ok, token_payload()}})

    {first_token, pool} = invite_fixture()
    assert :ok = Events.subscribe_pool(pool.id)
    {:ok, first_start} = InviteOnboarding.start_device(first_token)

    {:ok, first_completed} =
      InviteOnboarding.poll_device(first_token, first_start.account.identity.id)

    assert_receive {Events, %{topics: ["upstreams"], reason: "upstream_account_onboarded"}}

    scope =
      Scope.for_user(Repo.get!(CodexPooler.Accounts.User, pool.created_by_user_id), [
        "instance_owner"
      ])

    {:ok, %{token: second_token}} =
      Access.create_invite(scope, pool, %{invited_email: "codex-user@example.com"})

    {:ok, second_start} = InviteOnboarding.start_device(second_token)

    assert second_start.account.identity.id != first_completed.identity.id

    {:ok, second_completed} =
      InviteOnboarding.poll_device(second_token, second_start.account.identity.id)

    assert second_completed.identity.id == first_completed.identity.id
    assert second_completed.assignment.id == first_completed.assignment.id

    assert Repo.aggregate(UpstreamIdentity, :count) == 1
    assert Repo.aggregate(PoolUpstreamAssignment, :count) == 1

    assert [first_acceptance, second_acceptance] =
             Repo.all(
               from acceptance in InviteAcceptance, order_by: [asc: acceptance.accepted_at]
             )

    assert first_acceptance.upstream_identity_id == first_completed.identity.id
    assert second_acceptance.upstream_identity_id == first_completed.identity.id
    assert first_acceptance.pool_upstream_assignment_id == first_completed.assignment.id
    assert second_acceptance.pool_upstream_assignment_id == first_completed.assignment.id

    assert active_secret_count("access_token") == 1
    assert active_secret_count("refresh_token") == 1
    assert active_secret_count("device_code") == 1
  end

  test "invite onboarding into a second Pool reuses the existing upstream account and creates the target Pool assignment" do
    access_token = "invite-cross-pool-access"
    refresh_token = "invite-cross-pool-refresh"

    configure_codex_auth_client!(%{
      poll_result:
        {:ok, token_payload(%{}, access_token: access_token, refresh_token: refresh_token)}
    })

    {first_token, source_pool} = invite_fixture()

    {:ok, first_start} = InviteOnboarding.start_device(first_token)

    {:ok, first_completed} =
      InviteOnboarding.poll_device(first_token, first_start.account.identity.id)

    scope =
      Scope.for_user(Repo.get!(CodexPooler.Accounts.User, source_pool.created_by_user_id), [
        "instance_owner"
      ])

    {:ok, target_pool} =
      CodexPooler.Pools.create_pool(scope, %{slug: "invite-target", name: "Invite Target"})

    {:ok, %{token: second_token}} =
      Access.create_invite(scope, target_pool, %{invited_email: "codex-user@example.com"})

    {:ok, second_start} = InviteOnboarding.start_device(second_token)

    assert second_start.account.identity.id != first_completed.identity.id

    {:ok, second_completed} =
      InviteOnboarding.poll_device(second_token, second_start.account.identity.id)

    assert second_completed.identity.id == first_completed.identity.id
    assert second_completed.assignment.id != first_completed.assignment.id
    assert second_completed.assignment.pool_id == target_pool.id

    assignments_by_pool =
      first_completed.identity
      |> CodexPooler.Upstreams.list_pool_assignments_for_identity()
      |> Map.new(&{&1.pool_id, &1})

    assert Map.fetch!(assignments_by_pool, source_pool.id).id == first_completed.assignment.id
    assert Map.fetch!(assignments_by_pool, target_pool.id).id == second_completed.assignment.id
    assert Repo.aggregate(UpstreamIdentity, :count) == 1
    assert Repo.aggregate(PoolUpstreamAssignment, :count) == 2

    assert [first_acceptance, second_acceptance] =
             Repo.all(
               from acceptance in InviteAcceptance, order_by: [asc: acceptance.accepted_at]
             )

    assert first_acceptance.pool_upstream_assignment_id == first_completed.assignment.id
    assert second_acceptance.pool_upstream_assignment_id == second_completed.assignment.id
    assert first_acceptance.upstream_identity_id == first_completed.identity.id
    assert second_acceptance.upstream_identity_id == first_completed.identity.id
    assert active_secret_count("access_token") == 1
    assert active_secret_count("refresh_token") == 1
    assert active_secret_count("device_code") == 1

    refute inspect(first_acceptance) =~ access_token
    refute inspect(second_acceptance) =~ refresh_token

    html =
      build_conn()
      |> live(~p"/onboarding/invites/#{second_token}")
      |> elem(2)

    refute html =~ access_token
    refute html =~ refresh_token
    refute html =~ "cookie"
    refute html =~ "/Users/"
  end

  defp fixture_owner_scope do
    %{user: user} = bootstrap_owner_fixture()
    Scope.for_user(user, ["instance_owner"])
  end

  defp invite_fixture(attrs \\ %{}) do
    scope = fixture_owner_scope()
    attrs = Map.put_new(attrs, :invited_email, "codex-user@example.com")

    pool =
      pool_fixture(%{slug: "team-alpha", name: "Team Alpha", created_by_user_id: scope.user.id})

    {:ok, %{token: token}} = Access.create_invite(scope, pool, attrs)
    {token, pool}
  end

  defp configure_codex_auth_client!(attrs) do
    start_supervised!(%{
      id: __MODULE__.FakeCodexAuthState,
      start: {Agent, :start_link, [fn -> attrs end, [name: __MODULE__.FakeCodexAuthState]]}
    })

    previous = Application.get_env(:codex_pooler, CodexPooler.Upstreams.Auth.CodexAuth)

    Application.put_env(:codex_pooler, CodexPooler.Upstreams.Auth.CodexAuth,
      client: __MODULE__.FakeCodexAuthClient
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:codex_pooler, CodexPooler.Upstreams.Auth.CodexAuth, previous)
      else
        Application.delete_env(:codex_pooler, CodexPooler.Upstreams.Auth.CodexAuth)
      end
    end)
  end

  defp active_secret_count(secret_kind) do
    Repo.aggregate(
      from(secret in EncryptedSecret,
        where: secret.secret_kind == ^secret_kind and secret.status == "active"
      ),
      :count
    )
  end

  defp worker_name(worker), do: worker |> Atom.to_string() |> String.replace_prefix("Elixir.", "")

  defp send_current_device_poll(view) do
    send(view.pid, {:poll_device_authorization, current_device_poll_ref(view)})
    _ = :sys.get_state(view.pid)
    :ok
  end

  defp current_device_poll_ref(view) do
    view.pid
    |> :sys.get_state()
    |> Map.fetch!(:socket)
    |> then(& &1.assigns.device_poll_ref)
  end

  defp poll_count do
    Agent.get(__MODULE__.FakeCodexAuthState, &Map.get(&1, :poll_count, 0))
  end

  defp token_payload(claim_overrides \\ %{}, opts \\ []) do
    %{
      access_token: Keyword.get(opts, :access_token, "access-token"),
      refresh_token: Keyword.get(opts, :refresh_token, "refresh-token"),
      id_token: id_token(claim_overrides)
    }
  end

  defp id_token(claim_overrides) do
    claims =
      Map.merge(
        %{
          "email" => "codex-user@example.com",
          "https://api.openai.com/auth" => %{
            "chatgpt_account_id" => "acct_test",
            "chatgpt_user_id" => "user_test",
            "chatgpt_plan_type" => "plus"
          }
        },
        claim_overrides
      )

    header = Base.url_encode64(~s({"alg":"none"}), padding: false)
    payload = Base.url_encode64(Jason.encode!(claims), padding: false)
    header <> "." <> payload <> ".signature"
  end

  defmodule FakeCodexAuthClient do
    def request_device_code do
      {:ok,
       %{
         "device_auth_id" => "dev_123",
         "user_code" => "ABCD-EFGH",
         "verification_url" => "https://auth.openai.com/codex/device",
         "expires_at" =>
           DateTime.utc_now() |> DateTime.add(600, :second) |> DateTime.to_iso8601(),
         "poll_interval_seconds" => 5
       }}
    end

    def poll_device_authorization(_state) do
      Agent.get_and_update(
        CodexPoolerWeb.OnboardingLive.InviteTest.FakeCodexAuthState,
        fn state ->
          state = Map.update(state, :poll_count, 1, &(&1 + 1))

          case Map.get(state, :poll_results) do
            [result | rest] -> {result, Map.put(state, :poll_results, rest)}
            _results -> {Map.get(state, :poll_result), state}
          end
        end
      )
    end
  end

  defp assert_public_footer(view, selector) do
    app_version = :codex_pooler |> Application.spec(:vsn) |> to_string()

    assert has_element?(view, selector, "Codex Pooler #{app_version}")
    assert has_element?(view, selector, "© #{Date.utc_today().year} iCoreTech, Inc.")
    assert has_element?(view, "#{selector} a[href='https://github.com/icoretech/codex-pooler']")
    assert has_element?(view, "#{selector} a[aria-label='Codex Pooler on GitHub']")
  end

  defp assert_auth_logo(view, selector) do
    assert has_element?(view, "#{selector}[aria-label='Codex Pooler']")
    assert has_element?(view, "#{selector} img[src='/images/project-icon.png'][alt='']")
    refute render(view) =~ ~s(/images/logo.svg)
  end
end
