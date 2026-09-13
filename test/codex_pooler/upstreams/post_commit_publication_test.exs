defmodule CodexPooler.Upstreams.PostCommitPublicationTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.UnboxedFixture, only: [register_unboxed_cleanup!: 1]

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Events
  alias CodexPooler.Pools
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams

  alias CodexPooler.Upstreams.Schemas.{
    EncryptedSecret,
    PoolUpstreamAssignment,
    UpstreamIdentity
  }

  alias CodexPooler.Upstreams.TokenLinking
  alias Ecto.Adapters.SQL.Sandbox

  @detection_timeout_ms 15_000
  @transaction_not_allowed %{
    code: :transaction_not_allowed,
    message: "auto-publishing token linking is not allowed inside a caller-owned transaction"
  }

  test "auto-publishing direct import rejects a caller-owned transaction before work or publication" do
    fixture = committed_fixture!()

    observer = start_event_observer(fixture.pool.id)
    before = snapshot(fixture)

    assert {:error, :intentional_rollback} =
             unboxed(fn ->
               Repo.transaction(fn ->
                 assert {:error, @transaction_not_allowed} =
                          Upstreams.import_codex_auth_json(
                            fixture.scope,
                            fixture.pool,
                            "synthetic-malformed-auth-json"
                          )

                 assert {:error, @transaction_not_allowed} =
                          Upstreams.import_trusted_account(
                            fixture.scope,
                            fixture.pool,
                            fixture.attrs
                          )

                 assert snapshot_in_transaction(fixture) == before
                 assert event_snapshot(observer) == []
                 Repo.rollback(:intentional_rollback)
               end)
             end)

    assert snapshot(fixture) == before
    assert event_snapshot(observer) == []
  end

  test "auto-publishing prepared link rejects a caller-owned transaction before work or publication" do
    fixture = committed_fixture!()

    prepared =
      unboxed(fn ->
        {:ok, prepared} =
          Upstreams.prepare_trusted_account(fixture.scope, fixture.pool, fixture.attrs)

        prepared
      end)

    observer = start_event_observer(fixture.pool.id)
    before = snapshot(fixture)

    assert {:error, :intentional_rollback} =
             unboxed(fn ->
               Repo.transaction(fn ->
                 assert {:error, @transaction_not_allowed} =
                          TokenLinking.link_prepared(
                            fixture.scope,
                            fixture.pool,
                            prepared,
                            publish_options()
                          )

                 assert snapshot_in_transaction(fixture) == before
                 assert event_snapshot(observer) == []
                 Repo.rollback(:intentional_rollback)
               end)
             end)

    assert snapshot(fixture) == before
    assert event_snapshot(observer) == []
  end

  test "direct publication refuses a transaction before audit job or PubSub effects" do
    fixture = committed_fixture!()

    prepared =
      unboxed(fn ->
        {:ok, prepared} =
          Upstreams.prepare_trusted_account(fixture.scope, fixture.pool, fixture.attrs)

        prepared
      end)

    observer = start_event_observer(fixture.pool.id)
    before = snapshot(fixture)

    assert {:error, :intentional_rollback} =
             unboxed(fn ->
               Repo.transaction(fn ->
                 assert {:ok, result} =
                          TokenLinking.link_prepared_in_transaction(
                            fixture.scope,
                            fixture.pool,
                            prepared,
                            []
                          )

                 persisted = snapshot_in_transaction(fixture)

                 assert {:error, @transaction_not_allowed} =
                          TokenLinking.publish_link_result(
                            fixture.scope,
                            fixture.pool,
                            result,
                            publish_options()
                          )

                 assert snapshot_in_transaction(fixture) == persisted
                 assert event_snapshot(observer) == []
                 Repo.rollback(:intentional_rollback)
               end)
             end)

    assert snapshot(fixture) == before
    assert event_snapshot(observer) == []
  end

  test "transaction-only persistence rolls back without publication and normal linking publishes once" do
    rollback_fixture = committed_fixture!()

    prepared =
      unboxed(fn ->
        {:ok, prepared} =
          Upstreams.prepare_trusted_account(
            rollback_fixture.scope,
            rollback_fixture.pool,
            rollback_fixture.attrs
          )

        prepared
      end)

    observer = start_event_observer(rollback_fixture.pool.id)
    before = snapshot(rollback_fixture)

    assert {:error, :intentional_rollback} =
             unboxed(fn ->
               Repo.transaction(fn ->
                 assert {:ok, _result} =
                          TokenLinking.link_prepared_in_transaction(
                            rollback_fixture.scope,
                            rollback_fixture.pool,
                            prepared,
                            []
                          )

                 assert event_snapshot(observer) == []
                 Repo.rollback(:intentional_rollback)
               end)
             end)

    assert snapshot(rollback_fixture) == before
    assert event_snapshot(observer) == []

    committed_fixture = committed_fixture!()

    observer = start_event_observer(committed_fixture.pool.id)
    before = snapshot(committed_fixture)

    assert {:ok, %{identity: identity}} =
             unboxed(fn ->
               Upstreams.import_codex_auth_json(
                 committed_fixture.scope,
                 committed_fixture.pool,
                 auth_json(committed_fixture)
               )
             end)

    after_publish = snapshot(committed_fixture)
    assert after_publish.identities == before.identities + 1
    assert after_publish.assignments == before.assignments + 1
    assert after_publish.secrets == before.secrets + 2
    assert after_publish.audits == before.audits + 1
    assert after_publish.jobs == before.jobs + 1

    reasons = Enum.map(event_snapshot(observer), & &1.reason)

    assert Enum.sort(reasons) == ["quota_priming_updated", "upstream_account_imported"]
    assert identity.chatgpt_account_id == committed_fixture.attrs.chatgpt_account_id
  end

  test "event observer snapshot includes an event queued before the barrier" do
    observer = start_event_observer(Ecto.UUID.generate())
    event = %{reason: "synthetic_observer_barrier"}

    send(observer, {Events, event})

    assert event_snapshot(observer) == [event]
  end

  # Registered before the commit, never scoped in `try/after`: a test process killed by the
  # ExUnit timeout or by its linked event observer never reaches an `after`, and the committed
  # pool, identities, audit rows and jobs would then outlive the test into every later file.
  defp committed_fixture! do
    suffix = System.unique_integer([:positive, :monotonic])
    register_unboxed_cleanup!(fn -> delete_committed_fixture!(suffix) end)

    unboxed(fn ->
      %{user: user} =
        bootstrap_owner_fixture(%{"email" => "post-commit-#{suffix}@example.com"})

      scope = Scope.for_user(user)

      {:ok, pool} =
        Pools.create_pool(scope, %{
          slug: "post-commit-#{suffix}",
          name: "Post commit #{suffix}"
        })

      %{
        scope: scope,
        pool: pool,
        attrs: %{
          chatgpt_account_id: "acct_post_commit_#{suffix}",
          chatgpt_user_id: "user_post_commit_#{suffix}",
          account_email: "account-#{suffix}@example.com",
          account_label: "Post commit #{suffix}",
          workspace_id: "workspace_post_commit_#{suffix}",
          workspace_label: "Workspace #{suffix}",
          seat_type: "team",
          credential_provenance: "codex_chatgpt_oauth",
          token: "synthetic-access-#{suffix}",
          refresh_token: "synthetic-refresh-#{suffix}"
        }
      }
    end)
  end

  defp publish_options do
    [
      audit_action: "upstream_account.import",
      broadcast_reason: "upstream_account_imported",
      quota_trigger_kind: "account_link"
    ]
  end

  defp auth_json(fixture) do
    id_token =
      jwt_token(%{
        "email" => fixture.attrs.account_email,
        "https://api.openai.com/auth" => %{
          "chatgpt_account_id" => fixture.attrs.chatgpt_account_id,
          "chatgpt_user_id" => fixture.attrs.chatgpt_user_id,
          "chatgpt_plan_type" => "team",
          "workspace_id" => fixture.attrs.workspace_id,
          "workspace_label" => fixture.attrs.workspace_label
        }
      })

    %{
      "auth_mode" => "chatgpt",
      "OPENAI_API_KEY" => nil,
      "tokens" => %{
        "id_token" => id_token,
        "access_token" =>
          jwt_token(%{"exp" => DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_unix()}),
        "refresh_token" => fixture.attrs.refresh_token,
        "account_id" => fixture.attrs.chatgpt_account_id
      },
      "last_refresh" => "2026-09-09T00:00:00Z"
    }
    |> CodexPooler.JSON.encode!()
  end

  defp jwt_token(payload) do
    encode = &Base.url_encode64(CodexPooler.JSON.encode!(&1), padding: false)

    Enum.join(
      [encode.(%{"alg" => "none", "typ" => "JWT"}), encode.(payload), encode.("sig")],
      "."
    )
  end

  defp snapshot(fixture), do: unboxed(fn -> snapshot_in_transaction(fixture) end)

  defp snapshot_in_transaction(fixture) do
    identity_ids =
      Repo.all(
        from identity in UpstreamIdentity,
          where: identity.chatgpt_account_id == ^fixture.attrs.chatgpt_account_id,
          select: identity.id
      )

    %{
      identities: length(identity_ids),
      assignments:
        Repo.aggregate(
          from(assignment in PoolUpstreamAssignment,
            where: assignment.upstream_identity_id in ^identity_ids
          ),
          :count
        ),
      secrets:
        Repo.aggregate(
          from(secret in EncryptedSecret, where: secret.upstream_identity_id in ^identity_ids),
          :count
        ),
      audits:
        Repo.aggregate(
          from(event in AuditEvent,
            where: event.pool_id == ^fixture.pool.id and event.action == "upstream_account.import"
          ),
          :count
        ),
      jobs:
        Repo.aggregate(
          from(job in Oban.Job,
            where: fragment("?->>'pool_id' = ?", job.args, ^fixture.pool.id)
          ),
          :count
        )
    }
  end

  # Keyed on the suffix `committed_fixture!/0` derives every committed key from, so it can be
  # registered before the fixture exists and still finds one that failed partway through.
  defp delete_committed_fixture!(suffix) do
    account_id = "acct_post_commit_#{suffix}"
    slug = "post-commit-#{suffix}"

    pool_ids =
      Repo.all(from pool in CodexPooler.Pools.Pool, where: pool.slug == ^slug, select: pool.id)

    Repo.delete_all(
      from identity in UpstreamIdentity, where: identity.chatgpt_account_id == ^account_id
    )

    Repo.delete_all(from event in AuditEvent, where: event.pool_id in ^pool_ids)

    for pool_id <- pool_ids do
      Repo.delete_all(
        from job in Oban.Job, where: fragment("?->>'pool_id' = ?", job.args, ^pool_id)
      )
    end

    Repo.delete_all(from pool in CodexPooler.Pools.Pool, where: pool.id in ^pool_ids)
    :ok
  end

  defp start_event_observer(pool_id) do
    parent = self()

    observer =
      spawn_link(fn ->
        :ok = Events.subscribe_pool(pool_id, "upstreams")
        send(parent, {:event_observer_ready, self()})
        observe_events([])
      end)

    assert_receive {:event_observer_ready, ^observer}, @detection_timeout_ms
    on_exit(fn -> send(observer, :stop) end)
    observer
  end

  defp observe_events(events) do
    receive do
      {Events, event} ->
        observe_events([event | events])

      {:snapshot, caller, ref} ->
        send(caller, {ref, Enum.reverse(events)})
        observe_events(events)

      :stop ->
        :ok
    end
  end

  defp event_snapshot(observer) do
    ref = make_ref()
    send(observer, {:snapshot, self(), ref})
    assert_receive {^ref, events}, @detection_timeout_ms
    events
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
