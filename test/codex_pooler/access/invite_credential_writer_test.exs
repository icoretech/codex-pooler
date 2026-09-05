defmodule CodexPooler.Access.InviteCredentialWriterTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Access
  alias CodexPooler.Access.InviteOnboarding
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Auth.{CodexAuth, TokenRefreshMetadata}
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}
  alias CodexPooler.Upstreams.TokenLinking
  alias Ecto.Adapters.SQL.Sandbox

  test "invite completion persists canonical future access-token expiry at credential epoch one" do
    deadline = DateTime.utc_now() |> DateTime.add(3_600, :second) |> DateTime.truncate(:second)
    configure_auth_client!(token_payload(expires_in: 3_600))
    {scope, pool, token} = invite_fixture()

    assert {:ok, completed} = complete_invite(token)

    identity = Repo.reload!(completed.identity)
    assert identity.metadata["credential_epoch"] == 1

    assert %{state: :known, deadline: persisted_deadline} =
             TokenRefreshMetadata.project_access_token_expiry(identity.metadata)

    assert abs(DateTime.diff(persisted_deadline, deadline, :second)) <= 2

    assert get_in(identity.metadata, ["token_refresh", "access_token_expiry", "credential_epoch"]) ==
             1

    assert completed.assignment.status == "active"
    assert {:error, %{code: :invite_consumed}} = Access.load_usable_invite_contract(token)
    assert scope.user.id == pool.created_by_user_id
  end

  test "invite completion accepts unavailable access-token expiry and persists the canonical unknown marker" do
    configure_auth_client!(token_payload(expires_in: nil, received_at: nil))
    {_scope, _pool, token} = invite_fixture()

    assert {:ok, completed} = complete_invite(token)
    identity = Repo.reload!(completed.identity)

    assert identity.metadata["credential_epoch"] == 1

    assert %{state: :unknown} =
             TokenRefreshMetadata.project_access_token_expiry(identity.metadata)

    assert get_in(identity.metadata, ["token_refresh", "access_token_expiry", "credential_epoch"]) ==
             1
  end

  test "invite completion rejects an already expired access token before mutating invite state" do
    configure_auth_client!(
      token_payload(expires_in: 1, received_at: DateTime.add(now(), -60, :second))
    )

    {_scope, _pool, token} = invite_fixture()
    {:ok, started} = InviteOnboarding.start_device(token)

    assert {:error, %{code: :invite_consumed, message: "invite is expired or already consumed"}} =
             InviteOnboarding.poll_device(token, started.account.identity.id)

    assert Repo.reload!(started.account.identity).status == "pending"
    assert Repo.reload!(started.account.assignment).status == "pending"
    assert {:ok, _contract} = Access.load_usable_invite_contract(token)
  end

  test "invite completion rejects a token that expires while waiting for the locked invite" do
    configure_auth_client!(token_payload(expires_in: 2))
    {_scope, _pool, token} = invite_fixture()
    {:ok, started} = InviteOnboarding.start_device(token)
    parent = self()
    telemetry_id = "invite-late-expiry-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        telemetry_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, notify ->
          query = to_string(Map.get(metadata, :query, ""))

          if String.contains?(query, ~s(FROM "invites")) and
               String.contains?(query, "FOR UPDATE") do
            send(notify, {:invite_locked, self()})

            receive do
              :release_invite -> :ok
            end
          end
        end,
        parent
      )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    completion =
      Task.async(fn ->
        receive do
          :sandbox_allowed -> :ok
        end

        InviteOnboarding.poll_device(token, started.account.identity.id)
      end)

    Sandbox.allow(Repo, self(), completion.pid)
    send(completion.pid, :sandbox_allowed)
    assert_receive {:invite_locked, lock_waiter}, 15_000

    receive do
    after
      2_500 -> send(lock_waiter, :release_invite)
    end

    assert {:error, %{code: :invite_consumed, message: "invite is expired or already consumed"}} =
             Task.await(completion, 15_000)

    assert Repo.reload!(started.account.identity).status == "pending"
    assert Repo.reload!(started.account.assignment).status == "pending"
    assert {:ok, _contract} = Access.load_usable_invite_contract(token)
  end

  test "two completed invites converge on one identity, assignment, and advancing credential epoch" do
    configure_auth_client!(token_payload())
    {scope, pool, first_token} = invite_fixture()

    assert {:ok, first} = complete_invite(first_token)

    assert {:ok, %{token: second_token}} =
             Access.create_invite(scope, pool, %{invited_email: invited_email()})

    assert {:ok, second} = complete_invite(second_token)

    assert second.identity.id == first.identity.id
    assert second.assignment.id == first.assignment.id
    assert Repo.aggregate(UpstreamIdentity, :count) == 1
    assert Repo.aggregate(PoolUpstreamAssignment, :count) == 1
    assert Repo.reload!(second.identity).metadata["credential_epoch"] == 2
  end

  test "TokenLinking followed by invite completion converges on the committed identity and assignment" do
    configure_auth_client!(token_payload(access_token: "invite-replacement-token"))
    {scope, pool, token} = invite_fixture()

    assert {:ok, linked} =
             TokenLinking.link_tokens(
               scope,
               pool,
               account_attrs("direct-link-token"),
               credential_provenance: :codex_chatgpt
             )

    assert {:ok, completed} = complete_invite(token)

    assert completed.identity.id == linked.identity.id
    assert completed.assignment.id == linked.assignment.id
    assert Repo.aggregate(UpstreamIdentity, :count) == 1
    assert Repo.aggregate(PoolUpstreamAssignment, :count) == 1
    assert Repo.reload!(completed.identity).metadata["credential_epoch"] == 2
  end

  defp complete_invite(token) do
    with {:ok, started} <- InviteOnboarding.start_device(token) do
      InviteOnboarding.poll_device(token, started.account.identity.id)
    end
  end

  defp invite_fixture do
    %{user: user} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    scope = Scope.for_user(user, ["instance_owner"])

    pool =
      pool_fixture(%{
        name: "Invite credential writer",
        created_by_user_id: user.id
      })

    {:ok, %{token: token}} =
      Access.create_invite(scope, pool, %{invited_email: invited_email()})

    {scope, pool, token}
  end

  defp configure_auth_client!(payload, opts \\ []) do
    state = %{payload: payload, notify: Keyword.get(opts, :notify)}

    start_supervised!(%{
      id: __MODULE__.AuthState,
      start: {Agent, :start_link, [fn -> state end, [name: __MODULE__.AuthState]]}
    })

    previous = Application.get_env(:codex_pooler, CodexAuth)
    Application.put_env(:codex_pooler, CodexAuth, client: __MODULE__.AuthClient)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:codex_pooler, CodexAuth, previous),
        else: Application.delete_env(:codex_pooler, CodexAuth)
    end)
  end

  defp token_payload(opts \\ []) do
    %{
      access_token: Keyword.get(opts, :access_token, "invite-access-token"),
      refresh_token: Keyword.get(opts, :refresh_token, "invite-refresh-token"),
      id_token: id_token(),
      expires_in: Keyword.get(opts, :expires_in, 3_600),
      received_at: Keyword.get(opts, :received_at, now())
    }
  end

  defp account_attrs(access_token) do
    %{
      chatgpt_account_id: account_id(),
      chatgpt_user_id: user_id(),
      account_email: invited_email(),
      account_label: invited_email(),
      token: access_token,
      refresh_token: "direct-refresh-token",
      expires_in: 3_600,
      received_at: now(),
      plan_label: "plus"
    }
  end

  defp id_token do
    claims = %{
      "email" => invited_email(),
      "https://api.openai.com/auth" => %{
        "chatgpt_account_id" => account_id(),
        "chatgpt_user_id" => user_id(),
        "chatgpt_plan_type" => "plus"
      }
    }

    header = Base.url_encode64(~s({"alg":"none"}), padding: false)
    payload = Base.url_encode64(Jason.encode!(claims), padding: false)
    header <> "." <> payload <> ".signature"
  end

  defp invited_email, do: "invite-writer@example.com"
  defp account_id, do: "acct_invite_writer"
  defp user_id, do: "user_invite_writer"
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defmodule AuthClient do
    def request_device_code do
      {:ok,
       %{
         "device_auth_id" => "device-invite-writer",
         "user_code" => "ABCD-EFGH",
         "verification_url" => "https://example.com/device",
         "expires_at" =>
           DateTime.utc_now() |> DateTime.add(600, :second) |> DateTime.to_iso8601(),
         "poll_interval_seconds" => 5
       }}
    end

    def poll_device_authorization(_state) do
      %{payload: payload, notify: notify} =
        Agent.get(CodexPooler.Access.InviteCredentialWriterTest.AuthState, & &1)

      if is_pid(notify), do: send(notify, :auth_polled)
      {:ok, payload}
    end
  end
end
