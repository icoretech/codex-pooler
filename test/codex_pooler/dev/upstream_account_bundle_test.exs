defmodule CodexPooler.Dev.UpstreamAccountBundleTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounting.Request
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Dev.UpstreamAccountBundle
  alias CodexPooler.Events
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Schemas.{EncryptedSecret, PoolUpstreamAssignment, UpstreamIdentity}
  alias CodexPooler.Upstreams.Secrets

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  @password "synthetic-bundle-password-12345"

  test "round trips an encrypted active account through trusted token linking" do
    source_pool = pool_fixture()
    source = account_fixture(source_pool)
    target_pool = pool_fixture()
    scope = owner_scope()

    assert {:ok, bundle, export_receipt} =
             UpstreamAccountBundle.export_bundle(source_pool, @password)

    assert export_receipt.exported == 1
    assert export_receipt.skipped_missing_refresh_token == 0
    refute bundle =~ source.access_token
    refute bundle =~ source.refresh_token

    assert {:ok, import_receipt} =
             UpstreamAccountBundle.import_bundle(bundle, target_pool, scope, @password)

    assert import_receipt.imported == 1
    assert import_receipt.dry_run == false

    assert {:ok, %{imported: 1}} =
             UpstreamAccountBundle.import_bundle(bundle, target_pool, scope, @password)

    assert length(Upstreams.list_active_pool_assignments(target_pool)) == 1

    imported =
      Upstreams.get_upstream_identity_by_chatgpt_account(source.identity.chatgpt_account_id)

    assert {:ok, access_token} = Secrets.decrypt_active_secret(imported, "access_token")
    assert {:ok, refresh_token} = Secrets.decrypt_active_secret(imported, "refresh_token")
    assert access_token == source.access_token
    assert refresh_token == source.refresh_token
    assert Secrets.secret_status(imported) == :present

    refute inspect(export_receipt) =~ source.access_token
    refute inspect(export_receipt) =~ source.refresh_token
    refute inspect(import_receipt) =~ source.access_token
    refute inspect(import_receipt) =~ source.refresh_token
    refute inspect(import_receipt) =~ source.identity.account_email
  end

  test "rejects a wrong password, tampering, and unsupported versions before writes" do
    source_pool = pool_fixture()
    source = account_fixture(source_pool)
    target_pool = pool_fixture()
    scope = owner_scope()

    assert {:ok, bundle, _receipt} = UpstreamAccountBundle.export_bundle(source_pool, @password)

    assert {:error, %{code: :bundle_decryption_failed}} =
             UpstreamAccountBundle.import_bundle(
               bundle,
               target_pool,
               scope,
               "wrong-password-12345"
             )

    assert Upstreams.list_active_pool_assignments(target_pool) == []

    tampered =
      bundle
      |> Jason.decode!()
      |> Map.update!("ciphertext", fn ciphertext ->
        <<first, rest::binary>> = Base.decode64!(ciphertext)
        Base.encode64(<<Bitwise.bxor(first, 1), rest::binary>>)
      end)
      |> Jason.encode!()

    assert {:error, %{code: :bundle_decryption_failed}} =
             UpstreamAccountBundle.import_bundle(tampered, target_pool, scope, @password)

    unsupported =
      bundle
      |> Jason.decode!()
      |> Map.put("version", 999)
      |> Jason.encode!()

    assert {:error, %{code: :bundle_unsupported_version}} =
             UpstreamAccountBundle.import_bundle(unsupported, target_pool, scope, @password)

    downgraded_kdf =
      bundle
      |> Jason.decode!()
      |> update_in(["kdf", "t_cost"], &(&1 - 1))
      |> Jason.encode!()

    assert {:error, %{code: :bundle_unsupported_kdf}} =
             UpstreamAccountBundle.import_bundle(downgraded_kdf, target_pool, scope, @password)

    injected_header =
      bundle
      |> Jason.decode!()
      |> Map.put("owner_email", "prompt-injection@example.com")
      |> Jason.encode!()

    assert {:error, injected_error} =
             UpstreamAccountBundle.import_bundle(injected_header, target_pool, scope, @password)

    assert injected_error.code == :bundle_malformed

    assert Upstreams.list_active_pool_assignments(target_pool) == []
    refute inspect(tampered) =~ source.access_token
    refute inspect(tampered) =~ source.refresh_token
    refute inspect(injected_error) =~ source.identity.account_email
  end

  test "skips source identities without a refresh token and accepts expired access tokens with one" do
    source_pool = pool_fixture()
    skipped = active_upstream_assignment_fixture(source_pool)

    imported =
      account_fixture(source_pool, expires_at: DateTime.add(DateTime.utc_now(), -60, :second))

    target_pool = pool_fixture()
    scope = owner_scope()

    assert {:ok, bundle, receipt} = UpstreamAccountBundle.export_bundle(source_pool, @password)
    assert receipt.exported == 1
    assert receipt.skipped_missing_refresh_token == 1

    assert {:ok, %{imported: 1}} =
             UpstreamAccountBundle.import_bundle(bundle, target_pool, scope, @password)

    assert Upstreams.get_upstream_identity_by_chatgpt_account(skipped.identity.chatgpt_account_id)

    assert Upstreams.get_upstream_identity_by_chatgpt_account(
             imported.identity.chatgpt_account_id
           )
  end

  test "dry runs full validation without writes" do
    source_pool = pool_fixture()
    source = account_fixture(source_pool)
    target_pool = pool_fixture()
    scope = owner_scope()

    assert {:ok, bundle, _receipt} = UpstreamAccountBundle.export_bundle(source_pool, @password)

    assert {:ok, %{dry_run: true, valid: 1, imported: 0}} =
             UpstreamAccountBundle.import_bundle(bundle, target_pool, scope, @password,
               dry_run: true
             )

    assert Upstreams.list_active_pool_assignments(target_pool) == []
    refute inspect(bundle) =~ source.identity.account_email
  end

  test "rolls back a first created account and all side effects when the second account fails" do
    source_pool = pool_fixture()
    first = account_fixture(source_pool)
    second = account_fixture(source_pool)
    target_pool = pool_fixture()
    unrelated = active_upstream_assignment_fixture(target_pool)
    scope = owner_scope()

    assert {:ok, bundle, _receipt} = UpstreamAccountBundle.export_bundle(source_pool, @password)

    delete_export_source!(first)
    delete_export_source!(second)
    create_subject_bound_conflict!(second)

    subscribe_forwarder!(target_pool)
    before = persistence_counts()

    assert {:error, error} =
             UpstreamAccountBundle.import_bundle(bundle, target_pool, scope, @password)

    assert error.code == :bundle_import_failed
    assert persistence_counts() == before
    assert Repo.get!(UpstreamIdentity, unrelated.identity.id).status == "active"
    assert Repo.get!(PoolUpstreamAssignment, unrelated.assignment.id).status == "active"

    assert Upstreams.get_upstream_identity_by_chatgpt_account(first.identity.chatgpt_account_id) ==
             nil

    refute_receive {:forwarded_pool_event,
                    {CodexPooler.Events,
                     %CodexPooler.Events.Event{
                       reason: "upstream_account_bundle_imported"
                     }}},
                   50
  end

  test "rolls back an existing account secret update when a later account fails" do
    source_pool = pool_fixture()
    existing = account_fixture(source_pool)
    second = account_fixture(source_pool)
    target_pool = pool_fixture()
    scope = owner_scope()

    assert {:ok, bundle, _receipt} = UpstreamAccountBundle.export_bundle(source_pool, @password)

    preserved_token = "synthetic-preserved-token-#{System.unique_integer([:positive])}"

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(existing.identity, %{
               secret_kind: "access_token",
               plaintext: preserved_token
             })

    delete_export_source!(second)
    create_subject_bound_conflict!(second)

    before = persistence_counts()

    assert {:error, %{code: :bundle_import_failed} = error} =
             UpstreamAccountBundle.import_bundle(bundle, target_pool, scope, @password)

    assert persistence_counts() == before

    assert {:ok, ^preserved_token} =
             existing.identity
             |> Repo.reload!()
             |> Secrets.decrypt_active_secret("access_token")

    refute inspect(error) =~ preserved_token
    refute inspect(error) =~ existing.access_token
    refute inspect(error) =~ second.access_token
  end

  test "normal and dry-run imports enqueue no provider-capable job and create no request" do
    source_pool = pool_fixture()
    _source = account_fixture(source_pool)
    target_pool = pool_fixture()
    dry_run_pool = pool_fixture()
    scope = owner_scope()

    assert {:ok, bundle, _receipt} = UpstreamAccountBundle.export_bundle(source_pool, @password)

    before_jobs = Repo.aggregate(Oban.Job, :count)
    before_requests = Repo.aggregate(Request, :count)

    assert {:ok, %{imported: 1, dry_run: false}} =
             UpstreamAccountBundle.import_bundle(bundle, target_pool, scope, @password)

    assert {:ok, %{imported: 0, dry_run: true}} =
             UpstreamAccountBundle.import_bundle(bundle, dry_run_pool, scope, @password,
               dry_run: true
             )

    assert Repo.aggregate(Oban.Job, :count) == before_jobs
    assert Repo.aggregate(Request, :count) == before_requests
    assert Upstreams.list_active_pool_assignments(dry_run_pool) == []
  end

  test "successful import publishes only sanitized post-commit audit and PubSub metadata" do
    source_pool = pool_fixture()
    source = account_fixture(source_pool)
    target_pool = pool_fixture()
    scope = owner_scope()
    subscribe_forwarder!(target_pool)

    assert {:ok, bundle, _receipt} = UpstreamAccountBundle.export_bundle(source_pool, @password)

    assert {:ok, receipt} =
             UpstreamAccountBundle.import_bundle(bundle, target_pool, scope, @password)

    imported =
      Upstreams.get_upstream_identity_by_chatgpt_account(source.identity.chatgpt_account_id)

    assert [event] =
             Repo.all(
               from event in AuditEvent,
                 where:
                   event.action == "upstream_account.import" and
                     event.target_id == ^imported.id and event.pool_id == ^target_pool.id
             )

    assert_receive {:forwarded_pool_event,
                    {CodexPooler.Events,
                     %CodexPooler.Events.Event{
                       reason: "upstream_account_bundle_imported"
                     } = pool_event}}

    for observable <- [receipt, event.details, pool_event.payload] do
      rendered = inspect(observable)
      refute rendered =~ source.access_token
      refute rendered =~ source.refresh_token
      refute rendered =~ source.identity.account_email
    end

    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "caller-owned trusted import refuses to run outside a durable transaction" do
    source_pool = pool_fixture()
    source = account_fixture(source_pool)
    target_pool = pool_fixture()
    scope = owner_scope()
    attrs = import_attrs(source)
    before = persistence_counts()

    assert {:error, %{code: :transaction_required} = error} =
             Upstreams.import_trusted_account_in_transaction(scope, target_pool, attrs)

    assert persistence_counts() == before
    refute inspect(error) =~ source.access_token
    refute inspect(error) =~ source.refresh_token
    refute inspect(error) =~ source.identity.account_email
  end

  test "strict CLI parsers reject duplicate and contradictory destructive options" do
    duplicate_cases = [
      {&UpstreamAccountBundle.parse_export_args/1,
       ["--pool", "one", "--pool", "two", "--out", "bundle.bin"]},
      {&UpstreamAccountBundle.parse_export_args/1,
       ["--pool", "one", "--out", "a.bin", "--out", "b.bin"]},
      {&UpstreamAccountBundle.parse_import_args/1,
       ["bundle.bin", "--pool", "one", "--pool", "two"]},
      {&UpstreamAccountBundle.parse_import_args/1,
       [
         "bundle.bin",
         "--pool",
         "one",
         "--owner-email",
         "a@example.com",
         "--owner-email",
         "b@example.com"
       ]},
      {&UpstreamAccountBundle.parse_import_args/1,
       ["bundle.bin", "--pool", "one", "--dry-run", "--dry-run"]},
      {&UpstreamAccountBundle.parse_import_args/1,
       ["bundle.bin", "--pool", "one", "--dry-run", "--no-dry-run"]}
    ]

    for {parser, args} <- duplicate_cases do
      assert {:error, "duplicate or contradictory bundle task option"} = parser.(args)
    end
  end

  test "bundle files require an existing 0700 parent and are created exclusively as 0600" do
    root = private_tmp_dir!()
    secure_parent = Path.join(root, "secure")
    insecure_parent = Path.join(root, "insecure")
    missing_parent_path = Path.join([root, "missing", "bundle.bin"])
    secure_path = Path.join(secure_parent, "bundle.bin")
    insecure_path = Path.join(insecure_parent, "bundle.bin")

    File.mkdir!(secure_parent)
    File.chmod!(secure_parent, 0o700)
    File.mkdir!(insecure_parent)
    File.chmod!(insecure_parent, 0o755)

    assert {:ok, "0600"} = UpstreamAccountBundle.write_bundle_file(secure_path, "secret")
    assert file_mode(secure_path) == 0o600
    assert File.read!(secure_path) == "secret"

    assert {:error, "bundle output already exists"} =
             UpstreamAccountBundle.write_bundle_file(secure_path, "replacement")

    assert File.read!(secure_path) == "secret"

    assert {:error, "bundle output parent directory must be private mode 0700"} =
             UpstreamAccountBundle.write_bundle_file(insecure_path, "secret")

    refute File.exists?(insecure_path)

    assert {:error, "bundle output parent directory must be private mode 0700"} =
             UpstreamAccountBundle.write_bundle_file(missing_parent_path, "secret")
  end

  test "bundle reads reject insecure files, insecure parents, and symlinks" do
    root = private_tmp_dir!()
    secure_parent = Path.join(root, "secure")
    insecure_parent = Path.join(root, "insecure")
    secure_path = Path.join(secure_parent, "bundle.bin")
    insecure_file_path = Path.join(secure_parent, "insecure.bin")
    insecure_parent_path = Path.join(insecure_parent, "bundle.bin")
    symlink_path = Path.join(secure_parent, "link.bin")

    File.mkdir!(secure_parent)
    File.chmod!(secure_parent, 0o700)
    File.mkdir!(insecure_parent)
    File.chmod!(insecure_parent, 0o755)

    assert {:ok, "0600"} = UpstreamAccountBundle.write_bundle_file(secure_path, "secret")
    File.write!(insecure_file_path, "secret")
    File.chmod!(insecure_file_path, 0o644)
    File.write!(insecure_parent_path, "secret")
    File.chmod!(insecure_parent_path, 0o600)
    File.ln_s!(secure_path, symlink_path)

    assert {:ok, "secret"} = UpstreamAccountBundle.read_bundle_file(secure_path)

    for path <- [insecure_file_path, insecure_parent_path, symlink_path] do
      assert {:error, "bundle input must be a regular 0600 file in a private 0700 directory"} =
               UpstreamAccountBundle.read_bundle_file(path)
    end
  end

  test "owner resolution selects the active default owner and rejects a non-owner" do
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    %{user: operator} = operator_fixture(owner, %{"email" => unique_user_email()})
    assert {:ok, %Scope{user: selected}} = UpstreamAccountBundle.resolve_owner_scope(nil)
    assert selected.id == owner.id

    assert {:ok, %Scope{user: explicit}} =
             UpstreamAccountBundle.resolve_owner_scope(owner.email)

    assert explicit.id == owner.id

    assert {:error, "owner account cannot operate pools"} =
             UpstreamAccountBundle.resolve_owner_scope(operator.email)
  end

  test "bundle import denies a scope without access to the target pool before writes" do
    source_pool = pool_fixture()
    source = account_fixture(source_pool)
    target_pool = pool_fixture()
    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    %{user: operator} = operator_fixture(owner, %{"email" => unique_user_email()})
    denied_scope = Scope.for_user(operator)

    assert {:ok, bundle, _receipt} = UpstreamAccountBundle.export_bundle(source_pool, @password)
    before = persistence_counts()

    assert {:error, %{code: :bundle_import_denied} = error} =
             UpstreamAccountBundle.import_bundle(
               bundle,
               target_pool,
               denied_scope,
               @password
             )

    assert persistence_counts() == before
    assert Upstreams.list_active_pool_assignments(target_pool) == []
    refute inspect(error) =~ source.access_token
    refute inspect(error) =~ source.refresh_token
    refute inspect(error) =~ source.identity.account_email
  end

  defp account_fixture(pool, opts \\ []) do
    unique = System.unique_integer([:positive])
    access_token = "synthetic-access-token-#{unique}"
    refresh_token = "synthetic-refresh-token-#{unique}"

    fixture =
      active_upstream_assignment_fixture(pool, %{
        chatgpt_account_id: "acct_bundle_#{unique}",
        account_email: "bundle-#{unique}@example.com",
        account_label: "Synthetic bundle #{unique}",
        access_token: access_token,
        metadata: %{
          "access_token_expires_at" =>
            opts
            |> Keyword.get(:expires_at, DateTime.add(DateTime.utc_now(), 3600, :second))
            |> DateTime.to_iso8601()
        }
      })

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(fixture.identity, %{
               secret_kind: "refresh_token",
               plaintext: refresh_token
             })

    Map.merge(fixture, %{access_token: access_token, refresh_token: refresh_token})
  end

  defp owner_scope do
    %{user: user} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    Scope.for_user(user, ["instance_owner"])
  end

  defp delete_export_source!(source) do
    Repo.delete!(Repo.reload!(source.assignment))

    Repo.delete_all(
      from secret in EncryptedSecret, where: secret.upstream_identity_id == ^source.identity.id
    )

    Repo.delete!(Repo.reload!(source.identity))
  end

  defp create_subject_bound_conflict!(source) do
    identity =
      active_upstream_identity_fixture(%{
        chatgpt_account_id: source.identity.chatgpt_account_id,
        account_email: source.identity.account_email,
        account_label: "Synthetic conflict",
        workspace_id: source.identity.workspace_id
      })

    identity
    |> Ecto.Changeset.change(chatgpt_user_id: "subject-#{System.unique_integer([:positive])}")
    |> Repo.update!()
  end

  defp persistence_counts do
    %{
      identities: Repo.aggregate(UpstreamIdentity, :count),
      secrets: Repo.aggregate(EncryptedSecret, :count),
      assignments: Repo.aggregate(PoolUpstreamAssignment, :count),
      audits: Repo.aggregate(AuditEvent, :count),
      jobs: Repo.aggregate(Oban.Job, :count)
    }
  end

  defp import_attrs(source) do
    %{
      chatgpt_account_id: source.identity.chatgpt_account_id,
      chatgpt_user_id: source.identity.chatgpt_user_id,
      account_email: source.identity.account_email,
      account_label: source.identity.account_label,
      workspace_id: source.identity.workspace_id,
      workspace_label: source.identity.workspace_label,
      seat_type: source.identity.seat_type,
      plan_label: source.identity.plan_label,
      token: source.access_token,
      refresh_token: source.refresh_token,
      import_metadata: %{}
    }
  end

  defp private_tmp_dir! do
    path =
      Path.join(
        System.tmp_dir!(),
        "codex-pooler-bundle-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(path)
    File.chmod!(path, 0o700)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp file_mode(path) do
    {:ok, stat} = File.lstat(path)
    Bitwise.band(stat.mode, 0o777)
  end

  defp subscribe_forwarder!(pool) do
    parent = self()

    pid =
      spawn_link(fn ->
        :ok = Events.subscribe_pool(pool, ["upstreams"])
        send(parent, :pool_event_forwarder_ready)
        forward_pool_events(parent)
      end)

    assert_receive :pool_event_forwarder_ready
    on_exit(fn -> Process.exit(pid, :normal) end)
  end

  defp forward_pool_events(parent) do
    receive do
      message ->
        send(parent, {:forwarded_pool_event, message})
        forward_pool_events(parent)
    end
  end
end
