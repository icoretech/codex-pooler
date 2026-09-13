defmodule CodexPooler.Upstreams.PreparedImportWitnessTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Pools
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.PreparedAccount
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias CodexPooler.Upstreams.SecretBox

  import CodexPooler.AccountsFixtures, only: [bootstrap_owner_fixture: 0]

  @tag :pin
  test "generic prepared accounts retain their unchecked redacted carrier semantics" do
    scope = owner_scope()

    {:ok, pool} =
      Pools.create_pool(scope, %{slug: unique_slug(), name: "Prepared import witness"})

    attrs = %{
      chatgpt_account_id: "acct_#{System.unique_integer([:positive])}",
      chatgpt_user_id: "user_#{System.unique_integer([:positive])}",
      account_email: "generic-#{System.unique_integer([:positive])}@example.com",
      account_label: "Generic prepared account",
      token: "generic-access-token"
    }

    assert {:ok, prepared} = PreparedAccount.prepare(scope, pool, attrs, [])
    assert prepared.attrs.token == "generic-access-token"
    assert prepared.policy == :reject_expired
    assert inspect(prepared) == "#PreparedAccount<:redacted>"
  end

  @tag :red
  test "trusted import preparation carries a separately validated import witness" do
    scope = owner_scope()

    {:ok, pool} =
      Pools.create_pool(scope, %{slug: unique_slug(), name: "Prepared import witness"})

    attrs = trusted_attrs()

    assert {:ok, %{import_witness: witness} = prepared} =
             CodexPooler.Upstreams.prepare_trusted_account(scope, pool, attrs)

    assert witness.incoming.chatgpt_account_id == prepared.attrs.chatgpt_account_id
    assert witness.persisted == :absent
    assert {:ok, ^prepared} = PreparedAccount.validate(prepared, scope, pool)
  end

  @tag :red_coherent_forgery
  test "an invented persisted witness with the old recomputed digest is rejected" do
    scope = owner_scope()

    {:ok, pool} =
      Pools.create_pool(scope, %{slug: unique_slug(), name: "Prepared import witness"})

    assert {:ok, prepared} =
             CodexPooler.Upstreams.prepare_trusted_account(scope, pool, trusted_attrs())

    invented_persisted = %{
      identity_id: Ecto.UUID.generate(),
      chatgpt_account_id: "invented-account",
      workspace_id: "invented-workspace",
      chatgpt_user_id: "invented-subject",
      account_email: "invented@example.com",
      credential_epoch: 9,
      status: "deleted"
    }

    forged =
      prepared
      |> put_in([Access.key(:import_witness), Access.key(:persisted)], invented_persisted)
      |> Map.put(:import_binding, old_unkeyed_binding(prepared, invented_persisted))

    assert {:error, %{code: :invalid_request}} = PreparedAccount.validate(forged, scope, pool)
  end

  @tag :red_public_signing_oracle
  test "the public signing oracle cannot mint a coherent forged import witness" do
    scope = owner_scope()

    {:ok, pool} =
      Pools.create_pool(scope, %{slug: unique_slug(), name: "Prepared import witness"})

    assert {:ok, prepared} =
             CodexPooler.Upstreams.prepare_trusted_account(scope, pool, trusted_attrs())

    invented_persisted = %{
      identity_id: Ecto.UUID.generate(),
      chatgpt_account_id: "oracle-account",
      workspace_id: "oracle-workspace",
      chatgpt_user_id: "oracle-subject",
      account_email: "oracle@example.com",
      credential_epoch: 11,
      status: "deleted"
    }

    forged =
      prepared
      |> put_in([Access.key(:import_witness), Access.key(:persisted)], invented_persisted)
      |> Map.put(:policy, :bundle_recovery)

    case public_witness_signing_attempt(forged) do
      {:ok, seal} ->
        forged = %{forged | import_binding: seal}
        assert {:error, %{code: :invalid_request}} = PreparedAccount.validate(forged, scope, pool)

      :unavailable ->
        assert :unavailable == public_witness_signing_attempt(forged)
    end
  end

  @tag :red_public_attach_oracle
  test "the public witness attachment API cannot mint a caller-chosen persisted witness" do
    scope = owner_scope()

    {:ok, pool} =
      Pools.create_pool(scope, %{slug: unique_slug(), name: "Prepared import witness"})

    assert {:ok, unchecked} = PreparedAccount.prepare(scope, pool, trusted_attrs(), [])

    invented_identity = %UpstreamIdentity{
      id: Ecto.UUID.generate(),
      chatgpt_account_id: "attached-account",
      chatgpt_user_id: "attached-subject",
      account_email: "attached@example.com",
      workspace_id: "attached-workspace",
      account_label: "Attached identity",
      status: "deleted",
      metadata: %{"credential_epoch" => 13}
    }

    case public_witness_attachment_attempt(unchecked, invented_identity) do
      {:ok, prepared} ->
        assert {:error, %{code: :invalid_request}} =
                 PreparedAccount.validate(prepared, scope, pool)

      :unavailable ->
        assert :unavailable == public_witness_attachment_attempt(unchecked, invented_identity)
    end
  end

  test "direct auth.json, trusted, caller-owned trusted, and bundle preparation are opt-in witnesses" do
    scope = owner_scope()

    {:ok, pool} =
      Pools.create_pool(scope, %{slug: unique_slug(), name: "Prepared import witness"})

    attrs = trusted_attrs()

    assert {:ok, direct} =
             CodexPooler.Upstreams.prepare_codex_auth_json_account(
               scope,
               pool,
               auth_json_fixture(attrs)
             )

    assert {:ok, trusted} = CodexPooler.Upstreams.prepare_trusted_account(scope, pool, attrs)
    assert {:ok, bundle} = CodexPooler.Upstreams.prepare_bundle_account(scope, pool, attrs)

    for prepared <- [direct, trusted, bundle] do
      assert %{incoming: incoming, persisted: :absent} = prepared.import_witness
      assert incoming.chatgpt_account_id == attrs.chatgpt_account_id
      assert {:ok, ^prepared} = PreparedAccount.validate(prepared, scope, pool)
    end

    assert {:ok, {:ok, %{identity: identity}}} =
             Repo.transaction(fn ->
               CodexPooler.Upstreams.import_trusted_account_in_transaction(scope, pool, attrs)
             end)

    assert identity.chatgpt_account_id == attrs.chatgpt_account_id
  end

  test "import witnesses preserve persisted canonical evidence separately from incoming claims" do
    scope = owner_scope()

    {:ok, pool} =
      Pools.create_pool(scope, %{slug: unique_slug(), name: "Prepared import witness"})

    identity =
      insert_identity(%{
        chatgpt_account_id: "stored-account",
        chatgpt_user_id: "stored-subject",
        account_email: "stored@example.com",
        workspace_id: "stored-workspace",
        account_label: "Stored identity",
        status: "pending",
        metadata: %{"credential_epoch" => 7}
      })

    attrs =
      Map.merge(trusted_attrs(), %{
        chatgpt_account_id: identity.chatgpt_account_id,
        chatgpt_user_id: identity.chatgpt_user_id,
        account_email: identity.account_email,
        workspace_id: identity.workspace_id
      })

    assert {:ok, %{import_witness: witness}} =
             CodexPooler.Upstreams.prepare_trusted_account(scope, pool, attrs)

    assert witness.incoming.account_email == "stored@example.com"
    assert witness.incoming.chatgpt_user_id == "stored-subject"

    assert witness.persisted == %{
             identity_id: identity.id,
             chatgpt_account_id: "stored-account",
             chatgpt_user_id: "stored-subject",
             account_email: "stored@example.com",
             workspace_id: "stored-workspace",
             credential_epoch: 7,
             status: "pending"
           }
  end

  test "legacy missing epoch is canonicalized and malformed persisted epochs reject with zero writes" do
    scope = owner_scope()

    {:ok, pool} =
      Pools.create_pool(scope, %{slug: unique_slug(), name: "Prepared import witness"})

    baseline_count = Repo.aggregate(UpstreamIdentity, :count)

    legacy =
      insert_identity(%{
        chatgpt_account_id: "legacy-account",
        account_email: "legacy@example.com",
        account_label: "Legacy identity",
        status: "active",
        metadata: %{}
      })

    assert {:ok, %{import_witness: %{persisted: %{credential_epoch: 1}}}} =
             CodexPooler.Upstreams.prepare_trusted_account(
               scope,
               pool,
               Map.put(trusted_attrs(), :chatgpt_account_id, legacy.chatgpt_account_id)
             )

    for malformed_epoch <- [nil, "7", %{}, 0, -1] do
      identity =
        insert_identity(%{
          chatgpt_account_id: "malformed-#{System.unique_integer([:positive])}",
          account_email: "malformed-#{System.unique_integer([:positive])}@example.com",
          account_label: "Malformed identity",
          status: "active",
          metadata: %{"credential_epoch" => malformed_epoch}
        })

      assert {:error, %{code: :invalid_credential_epoch}} =
               CodexPooler.Upstreams.prepare_trusted_account(
                 scope,
                 pool,
                 Map.put(trusted_attrs(), :chatgpt_account_id, identity.chatgpt_account_id)
               )

      assert {:error, %{code: :invalid_credential_epoch}} =
               CodexPooler.Upstreams.prepare_bundle_account(
                 scope,
                 pool,
                 Map.put(trusted_attrs(), :chatgpt_account_id, identity.chatgpt_account_id)
               )
    end

    assert Repo.aggregate(UpstreamIdentity, :count) == baseline_count + 6
  end

  test "selection conflicts reject import preparation before any write" do
    scope = owner_scope()

    {:ok, pool} =
      Pools.create_pool(scope, %{slug: unique_slug(), name: "Prepared import witness"})

    identity =
      insert_identity(%{
        chatgpt_account_id: "conflict-account",
        chatgpt_user_id: "bound-subject",
        account_email: "conflict@example.com",
        workspace_id: "conflict-workspace",
        account_label: "Conflict identity",
        status: "active",
        metadata: %{"credential_epoch" => 3}
      })

    attrs =
      Map.merge(trusted_attrs(), %{
        chatgpt_account_id: identity.chatgpt_account_id,
        account_email: identity.account_email,
        chatgpt_user_id: nil,
        workspace_id: identity.workspace_id
      })

    identity_count = Repo.aggregate(UpstreamIdentity, :count)

    assert {:error, {:identity_conflict, :workspace_identity_mismatch, _safe_conflict}} =
             CodexPooler.Upstreams.prepare_trusted_account(scope, pool, attrs)

    assert Repo.aggregate(UpstreamIdentity, :count) == identity_count
  end

  test "forged witnesses are rejected without exposing secrets or caller input" do
    scope = owner_scope()

    {:ok, pool} =
      Pools.create_pool(scope, %{slug: unique_slug(), name: "Prepared import witness"})

    attrs = trusted_attrs()
    submitted_auth_json = "auth-json-sentinel"
    submitted_path = "/tmp/import-witness-sentinel.json"

    original_attrs = attrs
    assert {:ok, prepared} = CodexPooler.Upstreams.prepare_trusted_account(scope, pool, attrs)
    assert attrs == original_attrs

    forged =
      put_in(
        prepared.import_binding,
        "forged-witness-binding"
      )

    assert {:error, error} = PreparedAccount.validate(forged, scope, pool)
    {:ok, other_pool} = Pools.create_pool(scope, %{slug: unique_slug(), name: "Other pool"})

    assert {:error, %{code: :invalid_request}} =
             PreparedAccount.validate(prepared, scope, other_pool)

    for mismatched <- [
          put_in(prepared.attrs.account_label, "mismatched immutable attrs"),
          %{prepared | expiry: :mismatched_expiry},
          %{prepared | policy: :bundle_recovery}
        ] do
      assert {:error, %{code: :invalid_request}} =
               PreparedAccount.validate(mismatched, scope, pool)
    end

    error_text = inspect(error)
    prepared_text = inspect(prepared)

    for sensitive <- [
          attrs.token,
          attrs.refresh_token,
          submitted_auth_json,
          submitted_path,
          attrs.account_email
        ] do
      refute error_text =~ sensitive
      refute prepared_text =~ sensitive
    end
  end

  test "sealed import witnesses validate on the shared configured key and reject key rotation" do
    previous = Application.fetch_env!(:codex_pooler, CodexPoolerWeb.Endpoint)
    on_exit(fn -> restore_endpoint_config(previous) end)

    Application.put_env(
      :codex_pooler,
      CodexPoolerWeb.Endpoint,
      Keyword.put(previous, :secret_key_base, "prepared-import-witness-key")
    )

    scope = owner_scope()

    {:ok, pool} =
      Pools.create_pool(scope, %{slug: unique_slug(), name: "Prepared import witness"})

    assert {:ok, prepared} =
             CodexPooler.Upstreams.prepare_trusted_account(scope, pool, trusted_attrs())

    assert {:ok, ^prepared} = PreparedAccount.validate(prepared, scope, pool)

    Application.put_env(
      :codex_pooler,
      CodexPoolerWeb.Endpoint,
      Keyword.put(previous, :secret_key_base, "prepared-import-witness-rotated-key")
    )

    assert {:error, %{code: :invalid_request}} = PreparedAccount.validate(prepared, scope, pool)
  end

  test "public imports preserve invalid upstream secret key errors after witness preparation" do
    previous = Application.get_env(:codex_pooler, CodexPooler.Upstreams)
    on_exit(fn -> restore_upstream_config(previous) end)

    Application.put_env(:codex_pooler, CodexPooler.Upstreams,
      upstream_secret_key: "invalid",
      upstream_secret_key_version: "invalid"
    )

    scope = owner_scope()

    {:ok, pool} =
      Pools.create_pool(scope, %{slug: unique_slug(), name: "Prepared import witness"})

    assert {:error, %{code: :upstream_secret_key_invalid}} =
             CodexPooler.Upstreams.import_trusted_account(scope, pool, trusted_attrs())
  end

  test "invalid configured secret key base rejects import witness preparation" do
    previous = Application.fetch_env!(:codex_pooler, CodexPoolerWeb.Endpoint)
    on_exit(fn -> restore_endpoint_config(previous) end)

    Application.put_env(
      :codex_pooler,
      CodexPoolerWeb.Endpoint,
      Keyword.put(previous, :secret_key_base, "")
    )

    scope = owner_scope()

    {:ok, pool} =
      Pools.create_pool(scope, %{slug: unique_slug(), name: "Prepared import witness"})

    assert {:error, %{code: :invalid_request}} =
             CodexPooler.Upstreams.prepare_trusted_account(scope, pool, trusted_attrs())
  end

  defp trusted_attrs do
    %{
      chatgpt_account_id: "acct_#{System.unique_integer([:positive])}",
      chatgpt_user_id: "user_#{System.unique_integer([:positive])}",
      account_email: "trusted-#{System.unique_integer([:positive])}@example.com",
      account_label: "Trusted prepared account",
      token: "trusted-access-token",
      refresh_token: "trusted-refresh-token",
      credential_provenance: "codex_chatgpt_oauth"
    }
  end

  defp auth_json_fixture(attrs) do
    %{
      "auth_mode" => "chatgpt",
      "tokens" => %{
        "id_token" =>
          jwt_token(%{
            "email" => attrs.account_email,
            "https://api.openai.com/auth" => %{
              "chatgpt_account_id" => attrs.chatgpt_account_id,
              "chatgpt_user_id" => attrs.chatgpt_user_id
            }
          }),
        "access_token" => jwt_token(%{"exp" => future_unix()}),
        "refresh_token" => attrs.refresh_token,
        "account_id" => attrs.chatgpt_account_id
      }
    }
    |> CodexPooler.JSON.encode!()
  end

  defp jwt_token(payload) do
    encode = &Base.url_encode64(CodexPooler.JSON.encode!(&1), padding: false)
    Enum.join([encode.(%{"alg" => "none", "typ" => "JWT"}), encode.(payload), "sig"], ".")
  end

  defp future_unix, do: DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_unix()

  defp old_unkeyed_binding(prepared, persisted) do
    {:import_witness, prepared.scope_user_id, prepared.pool_id, prepared.attrs, prepared.expiry,
     prepared.policy, persisted}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp public_witness_signing_attempt(prepared) do
    payload =
      {"codex_pooler.upstreams.import_witness", 1, SecretBox.configured_key_version(),
       prepared.scope_user_id, prepared.pool_id, prepared.attrs, prepared.expiry, prepared.policy,
       prepared.import_witness.incoming, prepared.import_witness.persisted}
      |> :erlang.term_to_binary([:deterministic])

    if function_exported?(SecretBox, :hmac_digest, 1) do
      Function.capture(SecretBox, :hmac_digest, 1).(payload)
    else
      :unavailable
    end
  end

  defp public_witness_attachment_attempt(prepared, identity) do
    if function_exported?(PreparedAccount, :attach_import_witness, 2) do
      Function.capture(PreparedAccount, :attach_import_witness, 2).(prepared, identity)
    else
      :unavailable
    end
  end

  defp unique_slug, do: "prepared-import-#{System.unique_integer([:positive])}"

  defp insert_identity(attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %UpstreamIdentity{
      chatgpt_account_id: attrs.chatgpt_account_id,
      chatgpt_user_id: Map.get(attrs, :chatgpt_user_id),
      account_email: attrs.account_email,
      account_label: attrs.account_label,
      workspace_id: Map.get(attrs, :workspace_id),
      onboarding_method: "import",
      status: attrs.status,
      headers_profile_version: 1,
      created_at: now,
      updated_at: now,
      metadata: attrs.metadata
    }
    |> Repo.insert!()
  end

  defp owner_scope do
    %{user: user} = bootstrap_owner_fixture()
    Scope.for_user(user)
  end

  defp restore_upstream_config(nil),
    do: Application.delete_env(:codex_pooler, CodexPooler.Upstreams)

  defp restore_upstream_config(previous),
    do: Application.put_env(:codex_pooler, CodexPooler.Upstreams, previous)

  defp restore_endpoint_config(previous),
    do: Application.put_env(:codex_pooler, CodexPoolerWeb.Endpoint, previous)
end
