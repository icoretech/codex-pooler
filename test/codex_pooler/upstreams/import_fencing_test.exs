defmodule CodexPooler.Upstreams.ImportFencingTest do
  use ExUnit.Case, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import Ecto.Query

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Dev.UpstreamAccountBundle
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Auth.{CodexAuth, TokenRefresh}
  alias CodexPooler.Upstreams.Lifecycle.IdentitySlotLock
  alias CodexPooler.Upstreams.PreparedAccount
  alias CodexPooler.Upstreams.Schemas.{EncryptedSecret, PoolUpstreamAssignment, UpstreamIdentity}
  alias CodexPooler.Upstreams.Secrets
  alias CodexPooler.Upstreams.TokenLinking
  alias Ecto.Adapters.SQL.Sandbox

  defmodule RefreshClient do
    def refresh_token(_token, _opts) do
      {:ok,
       %{
         access_token: "synthetic-rotated-access",
         refresh_token: "synthetic-rotated-refresh",
         expires_in: 3600
       }}
    end
  end

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    old_auth = Application.fetch_env(:codex_pooler, CodexAuth)
    Application.put_env(:codex_pooler, CodexAuth, client: RefreshClient)
    %{user: user} = bootstrap_owner_fixture()
    pool = pool_fixture(%{created_by_user_id: user.id})
    account_id = "import-fence-#{Ecto.UUID.generate()}"

    attrs = %{
      chatgpt_account_id: account_id,
      account_email: "#{account_id}@example.invalid",
      account_label: "Import fencing fixture",
      token: jwt(%{"exp" => DateTime.to_unix(DateTime.utc_now()) + 3600}),
      refresh_token: "synthetic-original-refresh",
      credential_provenance: "codex_chatgpt_oauth"
    }

    on_exit(fn ->
      case old_auth do
        {:ok, config} -> Application.put_env(:codex_pooler, CodexAuth, config)
        :error -> Application.delete_env(:codex_pooler, CodexAuth)
      end

      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from pool in Pool, where: pool.id == ^pool.id)

        Repo.delete_all(
          from identity in UpstreamIdentity, where: identity.chatgpt_account_id == ^account_id
        )
      end)
    end)

    %{scope: Scope.for_user(user), pool: pool, attrs: attrs}
  end

  test "public auth-json import waiting on a slot lock cannot overwrite a committed refresh", %{
    scope: scope,
    pool: pool,
    attrs: attrs
  } do
    content = exported(attrs)
    assert {:ok, %{identity: identity}} = Upstreams.import_codex_auth_json(scope, pool, content)
    parent = self()

    holder =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            IdentitySlotLock.lock_slots!([attrs])
            send(parent, :slot_locked)

            receive do
              :release -> :ok
            after
              15_000 -> raise "slot lock barrier timed out"
            end
          end)
        end)
      end)

    assert_receive :slot_locked, 5_000

    importer =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:import_started, backend_pid})
          Upstreams.import_codex_auth_json(scope, pool, content)
        end)
      end)

    try do
      assert_receive {:import_started, backend_pid}, 5_000
      wait_advisory!(backend_pid, 500)
      assert Task.yield(importer, 0) == nil
      assert {:ok, %{status: :active}} = TokenRefresh.refresh_access_token(identity)
      refreshed = Repo.reload!(identity)
      assert refreshed.metadata["credential_epoch"] == 2
      send(holder.pid, :release)
      assert {:ok, :ok} = Task.await(holder, 5_000)

      assert {:error, %{code: :stale_import}} = Task.await(importer, 5_000)
      assert Repo.reload!(identity) == refreshed
      assert_rotated_pair(identity)
    after
      Task.shutdown(holder, :brutal_kill)
      Task.shutdown(importer, :brutal_kill)
    end
  end

  test "a new explicit old export submitted after refresh remains a replacement", %{
    scope: scope,
    pool: pool,
    attrs: attrs
  } do
    content = exported(attrs)
    assert {:ok, %{identity: identity}} = Upstreams.import_codex_auth_json(scope, pool, content)
    assert {:ok, %{status: :active}} = TokenRefresh.refresh_access_token(identity)
    assert {:ok, %{identity: imported}} = Upstreams.import_codex_auth_json(scope, pool, content)
    assert imported.metadata["credential_epoch"] == 3
    assert {:ok, token} = Secrets.decrypt_active_secret(identity, "refresh_token")
    assert token == attrs.refresh_token
  end

  test "an absent slot snapshot rejects a competing initial import", context do
    %{scope: scope, pool: pool, attrs: attrs} = context
    assert {:ok, prepared} = Upstreams.prepare_trusted_account(scope, pool, attrs)
    assert {:ok, %{identity: identity}} = Upstreams.import_trusted_account(scope, pool, attrs)
    before = persistence_counts()

    assert {:error, %{code: :stale_import}} =
             TokenLinking.link_prepared(scope, pool, prepared, [])

    assert persistence_counts() == before
    assert Repo.reload!(identity).metadata["credential_epoch"] == 1
  end

  test "input attrs cannot supply or disable the internal import snapshot", context do
    %{scope: scope, pool: pool, attrs: attrs} = context
    assert {:ok, %{identity: identity}} = Upstreams.import_trusted_account(scope, pool, attrs)
    injected = attrs |> Map.put(:import_snapshot, nil) |> Map.put("import_snapshot", :absent)
    assert {:ok, prepared} = Upstreams.prepare_trusted_account(scope, pool, injected)
    refute inspect(prepared) =~ attrs.token
    assert {:ok, %{status: :active}} = TokenRefresh.refresh_access_token(identity)

    assert {:error, %{code: :stale_import} = error} =
             TokenLinking.link_prepared(scope, pool, prepared, [])

    refute inspect(error) =~ attrs.token
    refute inspect(error) =~ attrs.refresh_token
    assert_rotated_pair(identity)
  end

  test "a pending snapshot rejects initial activation even when epoch stays one", context do
    %{scope: scope, pool: pool, attrs: attrs} = context

    identity =
      attrs
      |> Map.put(:credential_provenance, :codex_chatgpt)
      |> Map.put(:metadata, %{"credential_epoch" => 1})
      |> upstream_identity_fixture()

    assert identity.status == "pending"
    assert {:ok, prepared} = Upstreams.prepare_trusted_account(scope, pool, attrs)
    assert {:ok, %{identity: activated}} = Upstreams.import_trusted_account(scope, pool, attrs)
    assert activated.metadata["credential_epoch"] == 1

    assert {:error, %{code: :stale_import}} =
             TokenLinking.link_prepared(scope, pool, prepared, [])

    assert Repo.reload!(identity) == activated
  end

  test "deleted or replaced canonical identity cannot reuse the old snapshot", context do
    %{scope: scope, pool: pool, attrs: attrs} = context
    assert {:ok, %{identity: identity}} = Upstreams.import_trusted_account(scope, pool, attrs)
    assert {:ok, prepared} = Upstreams.prepare_trusted_account(scope, pool, attrs)
    Repo.delete!(identity)

    assert {:error, %{code: :stale_import}} =
             TokenLinking.link_prepared(scope, pool, prepared, [])

    assert {:ok, %{identity: replacement}} = Upstreams.import_trusted_account(scope, pool, attrs)
    assert replacement.id != identity.id

    assert {:error, %{code: :stale_import}} =
             TokenLinking.link_prepared(scope, pool, prepared, [])

    assert Repo.reload!(replacement).metadata["credential_epoch"] == 1
  end

  test "same row and epoch with changed canonical evidence rejects the old snapshot", context do
    %{scope: scope, pool: pool, attrs: attrs} = context
    assert {:ok, %{identity: identity}} = Upstreams.import_trusted_account(scope, pool, attrs)
    assert {:ok, prepared} = Upstreams.prepare_trusted_account(scope, pool, attrs)

    updated =
      identity
      |> Ecto.Changeset.change(account_email: "changed@example.invalid")
      |> Repo.update!()

    assert {:error, %{code: :stale_import}} =
             TokenLinking.link_prepared(scope, pool, prepared, [])

    assert Repo.reload!(identity) == updated
  end

  test "missing legacy epoch remains epoch one but concurrent refresh still fences it", context do
    %{scope: scope, pool: pool, attrs: attrs} = context
    assert {:ok, %{identity: identity}} = Upstreams.import_trusted_account(scope, pool, attrs)

    identity =
      identity
      |> Ecto.Changeset.change(metadata: Map.delete(identity.metadata, "credential_epoch"))
      |> Repo.update!()

    assert {:ok, prepared} = Upstreams.prepare_trusted_account(scope, pool, attrs)
    assert {:ok, %{status: :active}} = TokenRefresh.refresh_access_token(identity)

    assert {:error, %{code: :stale_import}} =
             TokenLinking.link_prepared(scope, pool, prepared, [])

    assert_rotated_pair(identity)

    current = Repo.reload!(identity)

    current
    |> Ecto.Changeset.change(metadata: Map.delete(current.metadata, "credential_epoch"))
    |> Repo.update!()

    assert {:ok, %{identity: imported}} = Upstreams.import_trusted_account(scope, pool, attrs)
    assert imported.metadata["credential_epoch"] == 2
  end

  test "invalid epochs at preparation or persistence never rotate credentials", context do
    %{scope: scope, pool: pool, attrs: attrs} = context
    assert {:ok, %{identity: identity}} = Upstreams.import_trusted_account(scope, pool, attrs)

    for epoch <- [nil, 0, -1, "1", 1.5] do
      identity
      |> Ecto.Changeset.change(metadata: Map.put(identity.metadata, "credential_epoch", epoch))
      |> Repo.update!()

      assert {:ok, prepared} = Upstreams.prepare_trusted_account(scope, pool, attrs)
      before = persistence_counts()

      assert {:error, %{code: :invalid_credential_epoch}} =
               TokenLinking.link_prepared(scope, pool, prepared, [])

      assert persistence_counts() == before

      Repo.update!(
        Ecto.Changeset.change(identity,
          metadata: Map.put(identity.metadata, "credential_epoch", 2)
        )
      )

      assert {:error, %{code: :invalid_credential_epoch}} =
               TokenLinking.link_prepared(scope, pool, prepared, [])
    end

    assert {:ok, prepared} = Upstreams.prepare_trusted_account(scope, pool, attrs)

    identity
    |> Ecto.Changeset.change(metadata: Map.put(identity.metadata, "credential_epoch", false))
    |> Repo.update!()

    assert {:error, %{code: :invalid_credential_epoch}} =
             TokenLinking.link_prepared(scope, pool, prepared, [])

    assert {:ok, token} = Secrets.decrypt_active_secret(identity, "refresh_token")
    assert token == attrs.refresh_token
  end

  test "ordinary OAuth and invite preparation retain replacement semantics", context do
    %{scope: scope, pool: pool, attrs: attrs} = context
    assert {:ok, %{identity: identity}} = Upstreams.import_trusted_account(scope, pool, attrs)

    for method <- ["browser", "device", "invite"] do
      assert {:ok, prepared} =
               PreparedAccount.prepare(scope, pool, attrs, onboarding_method: method)

      assert {:ok, %{status: :active}} = TokenRefresh.refresh_access_token(identity)
      assert {:ok, %{identity: imported}} = TokenLinking.link_prepared(scope, pool, prepared, [])
      assert imported.onboarding_method == method
    end
  end

  test "canonical workspace slots and noncredential health changes remain independent", context do
    %{scope: scope, pool: pool, attrs: attrs} = context
    first = Map.put(attrs, :workspace_id, "workspace-first")
    second = Map.put(attrs, :workspace_id, "workspace-second")
    assert {:ok, %{identity: a}} = Upstreams.import_trusted_account(scope, pool, first)
    assert {:ok, %{identity: b}} = Upstreams.import_trusted_account(scope, pool, second)
    assert {:ok, prepared} = Upstreams.prepare_trusted_account(scope, pool, first)
    Repo.update!(Ecto.Changeset.change(a, status: "refresh_due"))
    assert {:ok, %{status: :active}} = TokenRefresh.refresh_access_token(b)
    assert {:ok, %{identity: imported}} = TokenLinking.link_prepared(scope, pool, prepared, [])
    assert imported.id == a.id
    assert_rotated_pair(b)
  end

  test "batch rejects a stale later entry before any credential or side effect writes", context do
    %{scope: scope, pool: pool, attrs: attrs} = context
    first = Map.put(attrs, :workspace_id, "workspace-first")
    second = Map.put(attrs, :workspace_id, "workspace-second")
    assert {:ok, fresh} = Upstreams.prepare_bundle_account(scope, pool, first)
    assert {:ok, %{identity: identity}} = Upstreams.import_trusted_account(scope, pool, second)
    assert {:ok, stale} = Upstreams.prepare_bundle_account(scope, pool, second)
    assert {:ok, %{status: :active}} = TokenRefresh.refresh_access_token(identity)
    before = persistence_counts()

    assert {:error, %{code: :stale_import}} =
             Repo.transaction(fn ->
               TokenLinking.link_prepared_batch_in_transaction(scope, pool, [fresh, stale])
             end)

    assert persistence_counts() == before
    assert_rotated_pair(identity)
  end

  test "batch duplicate entries retain order for absent and existing canonical slots", context do
    %{scope: scope, pool: pool, attrs: attrs} = context

    for _state <- [:absent, :existing] do
      assert {:ok, first} = Upstreams.prepare_bundle_account(scope, pool, attrs)

      replacement = %{
        attrs
        | token: "synthetic-batch-last-access",
          refresh_token: "synthetic-batch-last-refresh"
      }

      assert {:ok, second} = Upstreams.prepare_bundle_account(scope, pool, replacement)

      assert {:ok, {:ok, [a, b]}} =
               Repo.transaction(fn ->
                 TokenLinking.link_prepared_batch_in_transaction(scope, pool, [first, second])
               end)

      assert a.identity.id == b.identity.id

      assert {:ok, "synthetic-batch-last-refresh"} =
               Secrets.decrypt_active_secret(b.identity, "refresh_token")
    end
  end

  test "database rejection after the first batch entry rolls back the entire credential pair",
       context do
    %{scope: scope, pool: pool, attrs: attrs} = context
    first = Map.put(attrs, :workspace_id, "workspace-first")
    second = Map.put(attrs, :workspace_id, "workspace-second")
    assert {:ok, a} = Upstreams.prepare_bundle_account(scope, pool, first)
    assert {:ok, b} = Upstreams.prepare_bundle_account(scope, pool, second)
    before = persistence_counts()
    suffix = String.replace(Ecto.UUID.generate(), "-", "")
    sequence = "import_fence_count_#{suffix}"
    function = "import_fence_reject_#{suffix}"
    trigger = "import_fence_trigger_#{suffix}"

    # A PostgreSQL sequence survives rollback, proving both refresh inserts were
    # reached (rather than only observing a failure during batch prevalidation).
    Repo.query!("CREATE SEQUENCE #{sequence}")

    Repo.query!("""
    CREATE FUNCTION #{function}() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.secret_kind = 'refresh_token' AND nextval('#{sequence}') = 2 THEN
        RAISE EXCEPTION 'synthetic second refresh insert rejection';
      END IF;
      RETURN NEW;
    END;
    $$
    """)

    Repo.query!(
      "CREATE TRIGGER #{trigger} BEFORE INSERT ON encrypted_secrets FOR EACH ROW EXECUTE FUNCTION #{function}()"
    )

    try do
      assert_raise Postgrex.Error, ~r/synthetic second refresh insert rejection/, fn ->
        Repo.transaction(fn ->
          TokenLinking.link_prepared_batch_in_transaction(scope, pool, [a, b])
        end)
      end

      assert %{rows: [[2]]} = Repo.query!("SELECT last_value FROM #{sequence}")
      assert persistence_counts() == before
    after
      Repo.query!("DROP TRIGGER #{trigger} ON encrypted_secrets")
      Repo.query!("DROP FUNCTION #{function}()")
      Repo.query!("DROP SEQUENCE #{sequence}")
    end
  end

  test "public bundle import rejects a refresh committed while waiting for batch locks",
       context do
    %{scope: scope, pool: pool, attrs: attrs} = context
    password = "synthetic-import-bundle-password"
    assert {:ok, %{identity: identity}} = Upstreams.import_trusted_account(scope, pool, attrs)
    assert {:ok, bundle, _receipt} = UpstreamAccountBundle.export_bundle(pool, password)
    parent = self()

    holder =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            IdentitySlotLock.lock_slots!([attrs])
            send(parent, :bundle_locked)

            receive do
              :release -> :ok
            after
              15_000 -> raise "bundle lock barrier timed out"
            end
          end)
        end)
      end)

    assert_receive :bundle_locked, 5_000

    importer =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:bundle_started, pid})
          UpstreamAccountBundle.import_bundle(bundle, pool, scope, password)
        end)
      end)

    try do
      assert_receive {:bundle_started, pid}, 5_000
      wait_advisory!(pid, 500)
      assert {:ok, %{status: :active}} = TokenRefresh.refresh_access_token(identity)
      before = persistence_counts()
      send(holder.pid, :release)
      assert {:ok, :ok} = Task.await(holder, 5_000)
      assert {:error, %{code: :bundle_import_failed}} = Task.await(importer, 5_000)
      assert persistence_counts() == before
      assert_rotated_pair(identity)
    after
      Task.shutdown(holder, :brutal_kill)
      Task.shutdown(importer, :brutal_kill)
    end
  end

  defp persistence_counts do
    for schema <- [
          UpstreamIdentity,
          EncryptedSecret,
          PoolUpstreamAssignment,
          AuditEvent,
          Oban.Job
        ],
        into: %{},
        do: {schema, Repo.aggregate(schema, :count)}
  end

  defp assert_rotated_pair(identity) do
    assert {:ok, "synthetic-rotated-access"} =
             Secrets.decrypt_active_secret(identity, "access_token")

    assert {:ok, "synthetic-rotated-refresh"} =
             Secrets.decrypt_active_secret(identity, "refresh_token")
  end

  defp exported(attrs) do
    Jason.encode!(%{
      "tokens" => %{
        "account_id" => attrs.chatgpt_account_id,
        "id_token" => jwt(%{"email" => attrs.account_email}),
        "access_token" => attrs.token,
        "refresh_token" => attrs.refresh_token
      }
    })
  end

  defp jwt(claims),
    do: "e30." <> Base.url_encode64(Jason.encode!(claims), padding: false) <> ".synthetic"

  defp wait_advisory!(_pid, 0), do: flunk("public import never reached its slot lock")

  defp wait_advisory!(pid, remaining) do
    query =
      "SELECT EXISTS (SELECT 1 FROM pg_locks WHERE pid=$1 AND locktype='advisory' AND NOT granted)"

    case Repo.query!(query, [pid]).rows do
      [[true]] ->
        :ok

      [[false]] ->
        Process.sleep(10)
        wait_advisory!(pid, remaining - 1)
    end
  end
end
