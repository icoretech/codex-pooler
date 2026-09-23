defmodule CodexPooler.Dev.UpstreamAccountBundleAccessOnlyTest do
  # A bundle import makes a copy of an account whose tokens stay live where the
  # account really lives. A copy that refreshes rotates the shared refresh token
  # and revokes the original (the 2026-09-23 replica incident), so a default
  # import carries only the access token. Every refresh path here starts from an
  # identity the real bundle import created and counts the provider token
  # endpoint on a loopback fake that also answers it, so a stored refresh token
  # would show up as a token-endpoint call.
  use CodexPoolerWeb.ConnCase, async: false
  use Oban.Testing, repo: CodexPooler.Repo

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [
      auth: 2,
      gateway_setup: 1,
      native_text_input: 1,
      prime_routing_quota!: 1,
      put_model_source_assignments!: 2,
      start_upstream: 1
    ]

  alias CodexPooler.Accounting.Request
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Dev.UpstreamAccountBundle
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Jobs
  alias CodexPooler.Jobs.{TokenRefreshEnqueueWorker, TokenRefreshWorker}
  alias CodexPooler.Repo
  alias CodexPooler.TestAppEnv
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Auth.CodexAuth
  alias CodexPooler.Upstreams.Schemas.{EncryptedSecret, UpstreamIdentity}
  alias CodexPooler.Upstreams.Secrets

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  @password "synthetic-bundle-password-12345"
  @endpoint_path "/backend-api/codex/responses"
  @token_path "/oauth/token"
  @usage_paths ["/backend-api/wham/usage", "/backend-api/codex/usage"]

  describe "an access-only import never calls the provider token endpoint" do
    test "gateway HTTP SSE 401 moves the copy to reauth_required", %{conn: conn} do
      upstream = start_provider(%{@endpoint_path => unauthorized(401, "invalid_api_key")})
      setup = gateway_setup(upstream)
      point_provider_defaults_at!(upstream)

      imported = import_copy!(setup.pool, expires_at: DateTime.add(DateTime.utc_now(), 3600, :second))
      prime_routing_quota!(imported.identity)
      model = put_model_source_assignments!(setup.model, [imported.assignment])

      response =
        conn
        |> auth(setup)
        |> post(@endpoint_path, %{"model" => model.exposed_model_id, "input" => native_text_input("access-only 401"), "stream" => true})

      refute response.status == 200
      assert token_endpoint_calls(upstream) == 0
      assert Enum.count(FakeUpstream.requests(upstream), &(&1.path == @endpoint_path)) == 1
      assert Repo.reload!(imported.identity).status == "reauth_required"
      assert_no_refresh_secret!(imported.identity)

      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert request.transport == "http_sse"

      assert request.request_metadata["auth_refresh"] == %{
               "status" => "reauth_required",
               "trigger_kind" => "http_upstream_auth_failure"
             }
    end

    test "usage probe 401 in a scheduled reconciliation moves the copy to reauth_required" do
      upstream = start_provider(Map.new(@usage_paths, &{&1, unauthorized(401, "invalid_api_key")}))
      point_provider_defaults_at!(upstream)
      target_pool = pool_fixture()

      # Unknown expiry is the state in which the usage probe refreshes after a
      # 401 (a known future deadline would skip the refresh on both arms).
      imported = import_copy!(target_pool, expiry: :unknown)

      assert {:ok, _job} =
               Jobs.enqueue_account_reconciliation(target_pool, imported.assignment, trigger_kind: "scheduled")

      Oban.drain_queue(queue: :jobs, with_recursion: true)

      assert Enum.any?(FakeUpstream.requests(upstream), &(&1.path in @usage_paths))
      assert token_endpoint_calls(upstream) == 0
      assert Repo.reload!(imported.identity).status == "reauth_required"
      assert_no_refresh_secret!(imported.identity)
    end

    test "the proactive refresh pass moves an expiring copy to reauth_required" do
      upstream = start_provider(%{})
      point_provider_defaults_at!(upstream)
      target_pool = pool_fixture()

      # Inside the proactive margin but not expired, so the import accepts it
      # and the scheduled pass selects it.
      imported = import_copy!(target_pool, expires_at: DateTime.add(DateTime.utc_now(), 120, :second))

      # The pass waits six hours after an identity's last update before a
      # proactive claim; age the import past that cooldown.
      {1, _rows} =
        Repo.update_all(from(identity in UpstreamIdentity, where: identity.id == ^imported.identity.id),
          set: [updated_at: DateTime.add(DateTime.utc_now(), -7, :hour)]
        )

      assert :ok = perform_job(TokenRefreshEnqueueWorker, %{})

      assert [%{args: %{"trigger_kind" => "scheduled"}}] =
               [worker: TokenRefreshWorker]
               |> all_enqueued()
               |> Enum.filter(&(&1.args["upstream_identity_id"] == imported.identity.id))

      Oban.drain_queue(queue: :jobs)

      assert token_endpoint_calls(upstream) == 0
      assert Repo.reload!(imported.identity).status == "reauth_required"
      assert_no_refresh_secret!(imported.identity)
    end

    test "reimport over a copy that already holds a refresh token revokes it" do
      upstream = start_provider(%{})
      point_provider_defaults_at!(upstream)
      source_pool = pool_fixture()
      source = account_fixture(source_pool, expires_at: DateTime.add(DateTime.utc_now(), 120, :second))
      assert {:ok, bundle, _receipt} = UpstreamAccountBundle.export_bundle(source_pool, @password)

      # The source database itself stands in for a copy that an earlier
      # refresh-carrying import left with the shared refresh token.
      assert {:ok, %{imported: 1}} =
               UpstreamAccountBundle.import_bundle(bundle, pool_fixture(), owner_scope(), @password)

      identity = Repo.reload!(source.identity)
      perform_job(TokenRefreshWorker, %{"upstream_identity_id" => identity.id, "trigger_kind" => "manual"})
      assert token_endpoint_calls(upstream) == 0
      assert Repo.reload!(identity).status == "reauth_required"
      assert_no_refresh_secret!(identity)

      assert Repo.exists?(
               from(secret in EncryptedSecret,
                 where: secret.upstream_identity_id == ^identity.id and secret.secret_kind == "refresh_token" and secret.status == "revoked"
               )
             )
    end
  end

  describe "refresh token modes" do
    test "the default import omits the refresh token and the explicit move keeps it" do
      source_pool = pool_fixture()
      source = account_fixture(source_pool, expires_at: DateTime.add(DateTime.utc_now(), 3600, :second))
      assert {:ok, bundle, %{refresh_tokens: "included"}} = UpstreamAccountBundle.export_bundle(source_pool, @password)
      delete_export_source!(source)
      scope = owner_scope()

      assert {:ok, %{imported: 1, refresh_tokens: "omitted", revoked_refresh_tokens: 0} = copy_receipt} =
               UpstreamAccountBundle.import_bundle(bundle, pool_fixture(), scope, @password)

      identity = Upstreams.get_upstream_identity_by_chatgpt_account(source.identity.chatgpt_account_id)
      assert {:ok, source.access_token} == Secrets.decrypt_active_secret(identity, "access_token")
      assert refresh_secret_count(identity) == 0

      assert {:ok, %{imported: 1, refresh_tokens: "imported", revoked_refresh_tokens: 0} = move_receipt} =
               UpstreamAccountBundle.import_bundle(bundle, pool_fixture(), scope, @password, refresh_tokens: :import)

      assert {:ok, source.refresh_token} == Secrets.decrypt_active_secret(identity, "refresh_token")

      for receipt <- [copy_receipt, move_receipt], value <- [source.access_token, source.refresh_token] do
        refute inspect(receipt) =~ value
      end
    end

    test "a dry run reports the omitted mode and writes nothing" do
      source_pool = pool_fixture()
      _source = account_fixture(source_pool, expires_at: DateTime.add(DateTime.utc_now(), 3600, :second))
      target_pool = pool_fixture()
      assert {:ok, bundle, _receipt} = UpstreamAccountBundle.export_bundle(source_pool, @password)
      secrets_before = Repo.aggregate(EncryptedSecret, :count)

      assert {:ok, %{valid: 1, imported: 0, dry_run: true, refresh_tokens: "omitted"}} =
               UpstreamAccountBundle.import_bundle(bundle, target_pool, owner_scope(), @password, dry_run: true)

      assert Repo.aggregate(EncryptedSecret, :count) == secrets_before
      assert Upstreams.list_active_pool_assignments(target_pool) == []
    end

    test "an access-token-only export never carries the refresh token and cannot be imported as a move" do
      source_pool = pool_fixture()
      with_refresh = account_fixture(source_pool, expires_at: DateTime.add(DateTime.utc_now(), 3600, :second))
      without_refresh = active_upstream_assignment_fixture(source_pool)

      assert {:ok, bundle, %{exported: 2, refresh_tokens: "omitted", skipped_missing_refresh_token: 0} = receipt} =
               UpstreamAccountBundle.export_bundle(source_pool, @password, refresh_tokens: :omit)

      refute inspect(receipt) =~ with_refresh.refresh_token
      assert Enum.map(bundle_accounts(bundle), & &1["refresh_token"]) == [nil, nil]
      delete_export_source!(with_refresh)
      delete_export_source!(without_refresh)
      scope = owner_scope()
      target_pool = pool_fixture()
      secrets_before = Repo.aggregate(EncryptedSecret, :count)

      assert {:error, %{code: :bundle_missing_refresh_token}} =
               UpstreamAccountBundle.import_bundle(bundle, target_pool, scope, @password, refresh_tokens: :import)

      assert Repo.aggregate(EncryptedSecret, :count) == secrets_before

      assert {:ok, %{imported: 2, refresh_tokens: "omitted"}} =
               UpstreamAccountBundle.import_bundle(bundle, target_pool, scope, @password)

      for source <- [with_refresh, without_refresh] do
        identity = Upstreams.get_upstream_identity_by_chatgpt_account(source.identity.chatgpt_account_id)
        assert {:ok, source.access_token} == Secrets.decrypt_active_secret(identity, "access_token")
        assert refresh_secret_count(identity) == 0
      end
    end

    test "an access-only copy rejects an expired access token before any write" do
      source_pool = pool_fixture()
      source = account_fixture(source_pool, expires_at: DateTime.add(DateTime.utc_now(), -60, :second))
      assert {:ok, bundle, _receipt} = UpstreamAccountBundle.export_bundle(source_pool, @password)
      delete_export_source!(source)
      scope = owner_scope()
      target_pool = pool_fixture()
      secrets_before = Repo.aggregate(EncryptedSecret, :count)

      for dry_run? <- [true, false] do
        assert {:error, %{code: :bundle_import_failed}} =
                 UpstreamAccountBundle.import_bundle(bundle, target_pool, scope, @password, dry_run: dry_run?)
      end

      assert Repo.aggregate(EncryptedSecret, :count) == secrets_before
      assert Upstreams.get_upstream_identity_by_chatgpt_account(source.identity.chatgpt_account_id) == nil
    end

    test "an unknown refresh token mode is rejected before the bundle is opened" do
      pool = pool_fixture()

      assert {:error, %{code: :bundle_invalid_request}} =
               UpstreamAccountBundle.import_bundle("not-a-bundle", pool, owner_scope(), @password, refresh_tokens: :include)

      assert {:error, %{code: :bundle_invalid_request}} =
               UpstreamAccountBundle.export_bundle(pool, @password, refresh_tokens: :import)
    end

    test "the CLI defaults to an access-only import and needs an explicit flag to carry the refresh token" do
      assert {:ok, %{refresh_tokens: :omit}} = UpstreamAccountBundle.parse_import_args(["b.bin", "--pool", "one"])

      assert {:ok, %{refresh_tokens: :import}} =
               UpstreamAccountBundle.parse_import_args(["b.bin", "--pool", "one", "--with-refresh-token"])

      assert {:ok, %{refresh_tokens: :include}} = UpstreamAccountBundle.parse_export_args(["--pool", "one", "--out", "b.bin"])

      assert {:ok, %{refresh_tokens: :omit}} =
               UpstreamAccountBundle.parse_export_args(["--pool", "one", "--out", "b.bin", "--access-token-only"])

      for {parser, args} <- [
            {&UpstreamAccountBundle.parse_import_args/1, ["b.bin", "--pool", "one", "--with-refresh-token", "--no-with-refresh-token"]},
            {&UpstreamAccountBundle.parse_import_args/1, ["b.bin", "--pool", "one", "--with-refresh-token", "--with-refresh-token"]},
            {&UpstreamAccountBundle.parse_export_args/1, ["--pool", "one", "--out", "b.bin", "--access-token-only", "--no-access-token-only"]}
          ] do
        assert {:error, "duplicate or contradictory bundle task option"} = parser.(args)
      end
    end
  end

  defp refresh_secret_count(identity) do
    Repo.aggregate(
      from(secret in EncryptedSecret, where: secret.upstream_identity_id == ^identity.id and secret.secret_kind == "refresh_token"),
      :count
    )
  end

  defp bundle_accounts(bundle) do
    header = CodexPooler.JSON.decode!(bundle)
    kdf = header["kdf"]
    <<tag::binary-size(16), ciphertext::binary>> = Base.decode64!(header["ciphertext"])

    key =
      @password
      |> Argon2.Base.hash_password(Base.decode64!(kdf["salt"]),
        format: :raw_hash,
        hashlen: 32,
        t_cost: kdf["t_cost"],
        m_cost: kdf["m_cost"],
        parallelism: kdf["parallelism"],
        argon2_type: 2
      )
      |> Base.decode16!(case: :lower)

    aad = header |> Map.delete("ciphertext") |> canonical_json() |> IO.iodata_to_binary()
    plaintext = :crypto.crypto_one_time_aead(:aes_256_gcm, key, Base.decode64!(header["nonce"]), ciphertext, aad, tag, false)
    CodexPooler.JSON.decode!(plaintext)["accounts"]
  end

  defp canonical_json(%{} = map) do
    [
      "{",
      map
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map_join(",", fn {key, value} -> [CodexPooler.JSON.encode!(key), ":", canonical_json(value)] end),
      "}"
    ]
  end

  defp canonical_json(value), do: CodexPooler.JSON.encode!(value)

  defp start_provider(routes) do
    start_upstream({:path_json, Map.put(routes, @token_path, {200, %{"access_token" => "synthetic-refreshed-access", "expires_in" => 3600}})})
  end

  defp unauthorized(status, code) do
    {status, %{"error" => %{"code" => code, "message" => "synthetic", "type" => "invalid_request_error"}}}
  end

  # The bundle carries no base URL, so an imported copy reaches the provider
  # through the configured defaults: point the dispatch default and the OAuth
  # issuer at the loopback fake so any refresh would be counted there.
  defp point_provider_defaults_at!(upstream) do
    TestAppEnv.restore_on_exit(:codex_upstream_base_url)
    auth_config = TestAppEnv.restore_on_exit(CodexAuth)
    Application.put_env(:codex_pooler, :codex_upstream_base_url, FakeUpstream.url(upstream))
    Application.put_env(:codex_pooler, CodexAuth, Keyword.put(auth_config, :issuer, FakeUpstream.url(upstream)))
  end

  defp token_endpoint_calls(upstream),
    do: Enum.count(FakeUpstream.requests(upstream), &(&1.path == @token_path))

  # Exports a refresh-carrying source account, removes the source rows so the
  # import creates a fresh identity as it would in another database, and
  # imports through the default (operator) path.
  defp import_copy!(target_pool, opts) do
    source_pool = pool_fixture()
    source = account_fixture(source_pool, opts)
    assert {:ok, bundle, %{exported: 1}} = UpstreamAccountBundle.export_bundle(source_pool, @password)
    delete_export_source!(source)

    assert {:ok, %{imported: 1}} =
             UpstreamAccountBundle.import_bundle(bundle, target_pool, owner_scope(), @password)

    identity = Upstreams.get_upstream_identity_by_chatgpt_account(source.identity.chatgpt_account_id)
    assert %UpstreamIdentity{status: "active"} = identity
    assert {:ok, access_token} = Secrets.decrypt_active_secret(identity, "access_token")
    assert access_token == source.access_token

    assert [assignment] =
             target_pool
             |> Upstreams.list_active_pool_assignments()
             |> Enum.filter(&(&1.upstream_identity_id == identity.id))

    %{identity: identity, assignment: assignment}
  end

  defp assert_no_refresh_secret!(identity) do
    assert {:error, %{code: :upstream_secret_not_found}} = Secrets.decrypt_active_secret(identity, "refresh_token")

    refute Repo.exists?(
             from(secret in EncryptedSecret,
               where: secret.upstream_identity_id == ^identity.id and secret.secret_kind == "refresh_token" and secret.status == "active"
             )
           )
  end

  defp account_fixture(pool, opts) do
    unique = System.unique_integer([:positive])
    access_token = "synthetic-access-token-#{unique}"

    metadata =
      case Keyword.get(opts, :expiry) do
        :unknown -> expiry_metadata(%{"state" => "unknown", "source" => "unavailable"}, nil)
        nil -> expiry_metadata(%{"state" => "known", "source" => "explicit"}, Keyword.fetch!(opts, :expires_at))
      end

    fixture =
      active_upstream_assignment_fixture(pool, %{
        chatgpt_account_id: "acct_access_only_#{unique}",
        account_email: "access-only-#{unique}@example.com",
        account_label: "Synthetic access-only #{unique}",
        access_token: access_token,
        metadata: metadata
      })

    refresh_token = "synthetic-refresh-token-#{unique}"

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(fixture.identity, %{
               secret_kind: "refresh_token",
               plaintext: refresh_token
             })

    identity =
      fixture.identity
      |> Ecto.Changeset.change()
      |> UpstreamIdentity.put_credential_provenance(:codex_chatgpt)
      |> Repo.update!()

    Map.merge(fixture, %{identity: identity, access_token: access_token, refresh_token: refresh_token})
  end

  defp expiry_metadata(marker, deadline) do
    %{
      "credential_epoch" => 2,
      "token_refresh" => %{"access_token_expiry" => Map.merge(%{"version" => 1, "credential_epoch" => 2}, marker)}
    }
    |> then(fn metadata ->
      if deadline, do: Map.put(metadata, "access_token_expires_at", DateTime.to_iso8601(deadline)), else: metadata
    end)
  end

  defp delete_export_source!(source) do
    Repo.delete!(Repo.reload!(source.assignment))
    Repo.delete_all(from secret in EncryptedSecret, where: secret.upstream_identity_id == ^source.identity.id)
    Repo.delete!(Repo.reload!(source.identity))
  end

  defp owner_scope do
    %{user: user} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    Scope.for_user(user, ["instance_owner"])
  end
end
