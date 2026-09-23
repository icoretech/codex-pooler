defmodule CodexPooler.Dev.UpstreamAccountBundle do
  @moduledoc false

  import Bitwise
  import Ecto.Query

  alias CodexPooler.Accounts
  alias CodexPooler.Accounts.{PlatformBootstrapState, Scope, User}
  alias CodexPooler.Pools.{Membership, Pool}
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Auth.TokenRefreshMetadata
  alias CodexPooler.Upstreams.PreparedAccount
  alias CodexPooler.Upstreams.Schemas.EncryptedSecret
  alias CodexPooler.Upstreams.Secrets
  alias CodexPooler.Upstreams.TokenLinking
  alias __MODULE__.{CLI, PrivateFile}

  @password_env "CODEX_POOLER_ACCOUNT_BUNDLE_PASSWORD"
  @format "codex-pooler.upstream-accounts"
  @version 2
  @cipher "aes-256-gcm"
  @salt_bytes 16
  @nonce_bytes 12
  @tag_bytes 16
  @key_bytes 32
  @kdf %{alg: "argon2id", t_cost: 3, m_cost: 17, parallelism: 1}
  @header_keys ~w(format version kdf cipher nonce ciphertext created_at account_count)
  @kdf_keys ~w(alg t_cost m_cost parallelism salt)
  @account_keys ~w(
    chatgpt_account_id chatgpt_user_id account_email account_label workspace_id workspace_label
    seat_type plan_label credential_provenance access_token refresh_token access_token_expires_at
  )

  @type lifecycle_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type receipt :: %{
          required(:version) => pos_integer(),
          required(:account_count) => non_neg_integer(),
          required(:status) => String.t()
        }
  @type account :: map()
  @type skip_counts :: %{
          required(:missing_access_token) => non_neg_integer(),
          required(:missing_refresh_token) => non_neg_integer()
        }

  defdelegate parse_export_args(args), to: CLI
  defdelegate parse_import_args(args), to: CLI
  defdelegate require_dev_environment(), to: CLI
  defdelegate write_bundle_file(path, bundle), to: PrivateFile, as: :write
  defdelegate read_bundle_file(path), to: PrivateFile, as: :read

  @spec run_export([String.t()]) :: {:ok, receipt()} | {:error, String.t()}
  def run_export(args) when is_list(args) do
    with :ok <- require_dev_environment(),
         {:ok, command} <- parse_export_args(args),
         {:ok, password} <- password_from_environment(),
         {:ok, pool} <- pool_by_slug(command.pool_slug),
         # Dialyzer cannot see repository-backed dev rows through this boundary and
         # otherwise collapses the real success branch to `no_return`.
         {:ok, bundle, receipt} <-
           apply(__MODULE__, :export_bundle, [pool, password, [refresh_tokens: command.refresh_tokens]]),
         {:ok, mode} <- write_bundle_file(command.out_path, bundle) do
      {:ok,
       Map.merge(receipt, %{
         status: "exported",
         path_mode: mode,
         path_fingerprint: fingerprint(command.out_path)
       })}
    else
      {:error, %{message: message}} -> {:error, message}
      {:error, message} when is_binary(message) -> {:error, message}
    end
  end

  @spec run_import([String.t()]) :: {:ok, receipt()} | {:error, String.t()}
  def run_import(args) when is_list(args) do
    with :ok <- require_dev_environment(),
         {:ok, command} <- parse_import_args(args),
         {:ok, password} <- password_from_environment(),
         {:ok, pool} <- pool_by_slug(command.pool_slug),
         {:ok, scope} <- resolve_owner_scope(command.owner_email),
         {:ok, bundle} <- read_bundle_file(command.path) do
      # Keep the same narrow opaque boundary as export; direct callers and tests
      # still use the typed public function without indirection.
      case apply(__MODULE__, :import_bundle, [
             bundle,
             pool,
             scope,
             password,
             [dry_run: command.dry_run?, refresh_tokens: command.refresh_tokens]
           ]) do
        {:ok, receipt} ->
          {:ok,
           Map.merge(receipt, %{
             status: if(command.dry_run?, do: "validated", else: "imported"),
             path_mode: bundle_mode(command.path),
             path_fingerprint: fingerprint(command.path)
           })}

        {:error, %{message: message}} ->
          {:error, message}
      end
    end
  end

  # `refresh_tokens: :omit` writes every account with a null refresh token, so
  # the refresh token never leaves the source database; the default keeps it.
  @spec export_bundle(Pool.t(), binary(), keyword()) ::
          {:ok, binary(), %{required(:exported) => non_neg_integer()}}
          | {:error, lifecycle_error()}
  def export_bundle(pool, password, opts \\ [])

  def export_bundle(%Pool{} = pool, password, opts) when is_binary(password) and is_list(opts) do
    with :ok <- validate_password(password),
         {:ok, refresh_tokens} <- refresh_token_mode(opts, [:include, :omit], :include),
         {:ok, accounts, skipped} <- export_accounts(pool, refresh_tokens),
         {:ok, bundle} <- seal_accounts(accounts, password) do
      {:ok, bundle,
       %{
         version: @version,
         account_count: length(accounts),
         exported: length(accounts),
         refresh_tokens: refresh_token_label(refresh_tokens),
         skipped_missing_access_token: skipped.missing_access_token,
         skipped_missing_refresh_token: skipped.missing_refresh_token
       }}
    end
  end

  def export_bundle(_pool, _password, _opts), do: {:error, lifecycle_error(:bundle_invalid_request)}

  # An import is a copy of accounts that stay live where they came from. A copy
  # that refreshes rotates the shared refresh token and revokes it at the
  # source, so the default `refresh_tokens: :omit` links only the access token
  # and revokes any refresh token the target identity still holds; the copy
  # then needs reauth when the access token stops working. `:import` is the
  # explicit move that carries the refresh token.
  @spec import_bundle(binary(), Pool.t(), Scope.t(), binary(), keyword()) ::
          {:ok, map()} | {:error, lifecycle_error()}
  def import_bundle(bundle, pool, scope, password, opts \\ [])

  def import_bundle(bundle, %Pool{} = pool, %Scope{} = scope, password, opts)
      when is_binary(bundle) and is_binary(password) and is_list(opts) do
    if Repo.in_transaction?() do
      {:error, lifecycle_error(:bundle_import_failed)}
    else
      dry_run? = Keyword.get(opts, :dry_run, false)

      with :ok <- validate_password(password),
           {:ok, refresh_tokens} <- refresh_token_mode(opts, [:omit, :import], :omit),
           {:ok, accounts} <- open_accounts(bundle, password),
           :ok <- validate_import_accounts(accounts, refresh_tokens),
           accounts = omit_refresh_tokens(accounts, refresh_tokens),
           {:ok, prepared_accounts} <- prepare_import_accounts(accounts, pool, scope, refresh_tokens) do
        import_prepared_accounts(prepared_accounts, pool, scope, dry_run?, refresh_tokens)
      end
    end
  end

  def import_bundle(_bundle, _pool, _scope, _password, _opts),
    do: {:error, lifecycle_error(:bundle_invalid_request)}

  defp password_from_environment do
    case System.get_env(@password_env) do
      password when is_binary(password) and byte_size(password) >= 16 -> {:ok, password}
      _password -> {:error, "#{@password_env} must be at least 16 bytes"}
    end
  end

  defp pool_by_slug(slug) do
    case Repo.one(from pool in Pool, where: pool.slug == ^slug and pool.status == "active", limit: 1) do
      %Pool{} = pool -> {:ok, pool}
      nil -> {:error, "active pool was not found"}
    end
  end

  @spec resolve_owner_scope(String.t() | nil) :: {:ok, Scope.t()} | {:error, String.t()}
  def resolve_owner_scope(nil), do: default_owner_scope()

  def resolve_owner_scope(owner_email) when is_binary(owner_email) do
    case Accounts.get_user_by_email(owner_email) do
      %User{} = user -> scope_for_owner(user)
      nil -> {:error, "owner account was not found"}
    end
  end

  def resolve_owner_scope(_owner_email), do: {:error, "owner account was not found"}

  defp default_owner_scope do
    owner =
      Repo.one(
        from state in PlatformBootstrapState,
          join: user in User,
          on: user.id == state.owner_user_id,
          join: membership in Membership,
          on: membership.user_id == user.id,
          where: state.singleton == true and state.status == "completed",
          where: membership.role == "instance_owner" and membership.status == "active",
          where: is_nil(user.deleted_at),
          select: user,
          limit: 1
      )

    case owner do
      %User{} = user -> scope_for_owner(user)
      nil -> {:error, "active instance owner was not found"}
    end
  end

  defp scope_for_owner(%User{} = user) do
    %Scope{roles: roles} = scope = Scope.for_user(user)

    if "instance_owner" in roles,
      do: {:ok, scope},
      else: {:error, "owner account cannot operate pools"}
  end

  @spec export_accounts(Pool.t(), :include | :omit) ::
          {:ok, [account()], skip_counts()} | {:error, lifecycle_error()}
  defp export_accounts(pool, refresh_tokens) do
    pool
    |> Upstreams.list_active_pool_assignments()
    |> Enum.reduce_while({:ok, [], empty_skips()}, fn assignment, {:ok, accounts, skipped} ->
      identity = Upstreams.get_upstream_identity(assignment.upstream_identity_id)

      case export_account(identity, refresh_tokens) do
        {:ok, account} ->
          {:cont, {:ok, [account | accounts], skipped}}

        {:skip, :missing_access_token} ->
          {:cont, {:ok, accounts, increment_skip(skipped, :missing_access_token)}}

        {:skip, :missing_refresh_token} ->
          {:cont, {:ok, accounts, increment_skip(skipped, :missing_refresh_token)}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, accounts, skipped} -> {:ok, Enum.reverse(accounts), skipped}
      {:error, _error} = error -> error
    end
  end

  defp export_account(%{status: "active"} = identity, refresh_tokens) do
    with {:ok, access_token} <- required_secret(identity, "access_token", :missing_access_token),
         {:ok, refresh_token} <- export_refresh_token(identity, refresh_tokens) do
      {:ok,
       %{
         "chatgpt_account_id" => identity.chatgpt_account_id,
         "chatgpt_user_id" => identity.chatgpt_user_id,
         "account_email" => identity.account_email,
         "account_label" => identity.account_label,
         "workspace_id" => identity.workspace_id,
         "workspace_label" => identity.workspace_label,
         "seat_type" => identity.seat_type,
         "plan_label" => identity.plan_label,
         "credential_provenance" => identity.credential_provenance,
         "access_token" => access_token,
         "refresh_token" => refresh_token,
         "access_token_expires_at" => trusted_access_token_expires_at(identity.metadata)
       }}
    end
  end

  defp export_account(_identity, _refresh_tokens), do: {:skip, :missing_access_token}

  # An omitted refresh token is never decrypted.
  defp export_refresh_token(_identity, :omit), do: {:ok, nil}

  defp export_refresh_token(identity, :include),
    do: required_secret(identity, "refresh_token", :missing_refresh_token)

  defp refresh_token_mode(opts, allowed, default) do
    case Keyword.get(opts, :refresh_tokens, default) do
      mode when is_atom(mode) and not is_nil(mode) ->
        if mode in allowed, do: {:ok, mode}, else: {:error, lifecycle_error(:bundle_invalid_request)}

      _mode ->
        {:error, lifecycle_error(:bundle_invalid_request)}
    end
  end

  defp refresh_token_label(:omit), do: "omitted"
  defp refresh_token_label(:include), do: "included"
  defp refresh_token_label(:import), do: "imported"

  defp required_secret(identity, kind, missing_reason) do
    case Secrets.decrypt_active_secret(identity, kind) do
      {:ok, secret} -> {:ok, secret}
      {:error, %{code: :upstream_secret_not_found}} -> {:skip, missing_reason}
      {:error, _reason} -> {:error, lifecycle_error(:bundle_source_secret_unavailable)}
    end
  end

  defp empty_skips, do: %{missing_access_token: 0, missing_refresh_token: 0}
  defp increment_skip(skips, key), do: Map.update!(skips, key, &(&1 + 1))

  defp trusted_access_token_expires_at(%{} = metadata) do
    case get_in(metadata, ["token_refresh", "access_token_expiry"]) do
      %{} ->
        case TokenRefreshMetadata.project_access_token_expiry(metadata) do
          %{state: :known, deadline: %DateTime{} = deadline} -> DateTime.to_iso8601(deadline)
          _expiry -> nil
        end

      _markerless ->
        nil
    end
  end

  defp trusted_access_token_expires_at(_metadata), do: nil

  @spec seal_accounts([account()], binary()) :: {:ok, binary()} | {:error, lifecycle_error()}
  defp seal_accounts(accounts, password) do
    salt = :crypto.strong_rand_bytes(@salt_bytes)
    nonce = :crypto.strong_rand_bytes(@nonce_bytes)
    created_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    header = %{
      "format" => @format,
      "version" => @version,
      "kdf" => stringified_kdf(salt),
      "cipher" => @cipher,
      "nonce" => Base.encode64(nonce),
      "created_at" => created_at,
      "account_count" => length(accounts)
    }

    with {:ok, key} <- derive_key(password, salt, @kdf),
         {:ok, plaintext} <- CodexPooler.JSON.encode(%{"accounts" => accounts}) do
      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(
          :aes_256_gcm,
          key,
          nonce,
          plaintext,
          canonical_header(header),
          true
        )

      case CodexPooler.JSON.encode(Map.put(header, "ciphertext", Base.encode64(tag <> ciphertext))) do
        {:ok, bundle} -> {:ok, bundle}
        {:error, _reason} -> {:error, lifecycle_error(:bundle_encoding_failed)}
      end
    else
      {:error, _reason} -> {:error, lifecycle_error(:bundle_encoding_failed)}
    end
  end

  defp open_accounts(bundle, password) do
    with {:ok, header} <- decode_header(bundle),
         {:ok, kdf} <- decode_kdf(header),
         {:ok, salt} <- decode_salt(kdf),
         {:ok, nonce} <- decode_exact64(header["nonce"], @nonce_bytes),
         {:ok, encrypted} <- decode_encrypted(header["ciphertext"]),
         {:ok, key} <- derive_key(password, salt, kdf),
         {:ok, plaintext} <-
           decrypt(encrypted, key, nonce, canonical_header(Map.delete(header, "ciphertext"))) do
      decode_accounts(plaintext, header["account_count"])
    end
  end

  defp decode_header(bundle) do
    with {:ok, %{} = header} <- CodexPooler.JSON.decode(bundle),
         true <- Enum.sort(Map.keys(header)) == Enum.sort(@header_keys),
         true <- header["format"] == @format,
         true <- header["cipher"] == @cipher,
         true <- is_integer(header["account_count"]) and header["account_count"] >= 0,
         {:ok, _datetime, _offset} <- DateTime.from_iso8601(header["created_at"]) do
      if header["version"] == @version do
        {:ok, header}
      else
        {:error, lifecycle_error(:bundle_unsupported_version)}
      end
    else
      {:ok, _other} -> {:error, lifecycle_error(:bundle_malformed)}
      false -> {:error, lifecycle_error(:bundle_malformed)}
      {:error, _reason} -> {:error, lifecycle_error(:bundle_malformed)}
    end
  end

  defp decode_kdf(%{"kdf" => %{} = kdf}) do
    with true <- Enum.sort(Map.keys(kdf)) == Enum.sort(@kdf_keys),
         true <- kdf["alg"] == "argon2id",
         true <- kdf["t_cost"] == @kdf.t_cost,
         true <- kdf["m_cost"] == @kdf.m_cost,
         true <- kdf["parallelism"] == @kdf.parallelism,
         {:ok, salt} <- decode_exact64(kdf["salt"], @salt_bytes) do
      {:ok, Map.put(kdf, "salt", salt)}
    else
      false -> {:error, lifecycle_error(:bundle_unsupported_kdf)}
      {:error, _reason} -> {:error, lifecycle_error(:bundle_malformed)}
    end
  end

  defp decode_kdf(_header), do: {:error, lifecycle_error(:bundle_malformed)}

  defp decode_salt(kdf) do
    case Map.fetch(kdf, "salt") do
      {:ok, salt} when is_binary(salt) and byte_size(salt) == @salt_bytes -> {:ok, salt}
      _value -> {:error, lifecycle_error(:bundle_malformed)}
    end
  end

  defp decode_encrypted(ciphertext) do
    with {:ok, encrypted} <- Base.decode64(ciphertext),
         true <- byte_size(encrypted) > @tag_bytes do
      {:ok, encrypted}
    else
      _invalid -> {:error, lifecycle_error(:bundle_malformed)}
    end
  end

  defp decode_exact64(value, expected_size) when is_binary(value) do
    with {:ok, decoded} <- Base.decode64(value),
         true <- byte_size(decoded) == expected_size do
      {:ok, decoded}
    else
      _invalid -> {:error, lifecycle_error(:bundle_malformed)}
    end
  end

  defp decode_exact64(_value, _expected_size), do: {:error, lifecycle_error(:bundle_malformed)}

  defp decrypt(<<tag::binary-size(@tag_bytes), ciphertext::binary>>, key, nonce, aad) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, ciphertext, aad, tag, false) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      :error -> {:error, lifecycle_error(:bundle_decryption_failed)}
    end
  end

  defp decrypt(_encrypted, _key, _nonce, _aad), do: {:error, lifecycle_error(:bundle_malformed)}

  defp decode_accounts(plaintext, expected_count) do
    with {:ok, %{"accounts" => accounts}} <- CodexPooler.JSON.decode(plaintext),
         true <- is_list(accounts),
         true <- length(accounts) == expected_count do
      {:ok, accounts}
    else
      _invalid -> {:error, lifecycle_error(:bundle_malformed)}
    end
  end

  defp validate_import_accounts(accounts, refresh_tokens) do
    cond do
      not Enum.all?(accounts, &valid_account?/1) ->
        {:error, lifecycle_error(:bundle_invalid_account)}

      refresh_tokens == :import and not Enum.all?(accounts, &present_string?(&1["refresh_token"])) ->
        {:error, lifecycle_error(:bundle_missing_refresh_token)}

      true ->
        :ok
    end
  end

  # Drop the refresh token as soon as the bundle shape is validated, so neither
  # preparation nor persistence ever receives it.
  defp omit_refresh_tokens(accounts, :omit),
    do: Enum.map(accounts, &Map.put(&1, "refresh_token", nil))

  defp omit_refresh_tokens(accounts, :import), do: accounts

  defp valid_account?(%{} = account) do
    valid_account_keys?(account) and valid_account_values?(account)
  end

  defp valid_account?(_account), do: false

  defp valid_account_keys?(account),
    do: Enum.sort(Map.keys(account)) == Enum.sort(@account_keys)

  defp valid_account_values?(account) do
    Enum.all?([
      present_string?(account["chatgpt_account_id"]) and
        present_string?(account["account_label"]),
      present_string?(account["access_token"]) and optional_present_string?(account["refresh_token"]),
      optional_string?(account["chatgpt_user_id"]) and
        optional_string?(account["account_email"]),
      optional_string?(account["workspace_id"]) and
        optional_string?(account["workspace_label"]),
      optional_string?(account["seat_type"]) and optional_string?(account["plan_label"]),
      valid_credential_provenance?(account["credential_provenance"]),
      optional_datetime?(account["access_token_expires_at"])
    ])
  end

  defp present_string?(value), do: is_binary(value) and byte_size(String.trim(value)) > 0
  defp optional_string?(value), do: is_nil(value) or is_binary(value)
  defp optional_present_string?(value), do: is_nil(value) or present_string?(value)

  defp valid_credential_provenance?(value), do: value in [nil, "codex_chatgpt_oauth"]

  defp optional_datetime?(nil), do: true

  defp optional_datetime?(value) when is_binary(value) do
    match?({:ok, _datetime, _offset}, DateTime.from_iso8601(value))
  end

  defp optional_datetime?(_value), do: false

  defp import_prepared_accounts([], _pool, _scope, dry_run?, refresh_tokens) do
    {:ok, empty_import_receipt(dry_run?, refresh_tokens)}
  end

  defp import_prepared_accounts(prepared_accounts, pool, scope, true, refresh_tokens) do
    validate_import_accounts_transaction(prepared_accounts, pool, scope, refresh_tokens)
  end

  defp import_prepared_accounts(prepared_accounts, pool, scope, false, refresh_tokens) do
    import_accounts(prepared_accounts, pool, scope, refresh_tokens)
  end

  defp empty_import_receipt(dry_run?, refresh_tokens) do
    %{
      version: @version,
      account_count: 0,
      valid: 0,
      imported: 0,
      dry_run: dry_run?,
      refresh_tokens: refresh_token_label(refresh_tokens),
      revoked_refresh_tokens: 0
    }
  end

  defp import_accounts(prepared_accounts, pool, scope, refresh_tokens) do
    case persist_import_accounts(prepared_accounts, pool, scope, refresh_tokens) do
      {:ok, {results, revoked}} ->
        publish_import_results(results, pool, scope)
        imported = length(results)

        {:ok,
         %{
           version: @version,
           account_count: imported,
           valid: imported,
           imported: imported,
           dry_run: false,
           refresh_tokens: refresh_token_label(refresh_tokens),
           revoked_refresh_tokens: revoked
         }}

      {:error, _reason} ->
        {:error, lifecycle_error(:bundle_import_failed)}
    end
  end

  # This deliberately wraps only the transaction invocation. Publication stays
  # outside this boundary so unexpected publication failures remain visible and
  # a database failure can never publish a partially persisted bundle.
  defp persist_import_accounts(prepared_accounts, pool, scope, refresh_tokens) do
    Repo.transaction(fn -> import_accounts_transaction(prepared_accounts, pool, scope, refresh_tokens) end)
  rescue
    _exception in [Postgrex.Error, Ecto.ConstraintError] -> {:error, :persistence_failed}
  end

  defp import_accounts_transaction(prepared_accounts, pool, scope, refresh_tokens) do
    case TokenLinking.link_prepared_batch_in_transaction(scope, pool, prepared_accounts) do
      {:ok, results} -> {results, revoke_copied_refresh_tokens(results, refresh_tokens)}
      {:error, _reason} -> Repo.rollback(:bundle_import_failed)
    end
  end

  # Linking without a refresh token leaves an older one active, for example
  # one an earlier refresh-carrying import stored in this copy. Revoke it in the
  # same transaction so the copy cannot refresh at all.
  defp revoke_copied_refresh_tokens(_results, :import), do: 0

  defp revoke_copied_refresh_tokens(results, :omit) do
    identity_ids = Enum.map(results, & &1.identity.id)

    {revoked, _rows} =
      Repo.update_all(
        from(secret in EncryptedSecret,
          where: secret.upstream_identity_id in ^identity_ids and secret.secret_kind == "refresh_token" and secret.status == "active"
        ),
        set: [status: "revoked", superseded_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)]
      )

    revoked
  end

  defp validate_import_accounts_transaction(prepared_accounts, pool, scope, refresh_tokens) do
    case validate_import_accounts_transaction_result(prepared_accounts, pool, scope) do
      {:ok, count} ->
        {:ok,
         %{
           version: @version,
           account_count: count,
           valid: count,
           imported: 0,
           dry_run: true,
           refresh_tokens: refresh_token_label(refresh_tokens),
           revoked_refresh_tokens: 0
         }}

      {:error, _reason} ->
        {:error, lifecycle_error(:bundle_import_failed)}
    end
  end

  defp validate_import_accounts_transaction_result(prepared_accounts, pool, scope) do
    Repo.transaction(fn ->
      case TokenLinking.validate_prepared_batch_in_transaction(scope, pool, prepared_accounts) do
        {:ok, count} -> count
        {:error, _reason} -> Repo.rollback(:bundle_import_failed)
      end
    end)
  rescue
    _exception in [Postgrex.Error, Ecto.ConstraintError] -> {:error, :persistence_failed}
  end

  defp publish_import_results(results, pool, scope) do
    Enum.each(results, fn result ->
      _published =
        TokenLinking.publish_link_result(scope, pool, result,
          audit_action: "upstream_account.import",
          broadcast_reason: "upstream_account_bundle_imported"
        )
    end)
  end

  # Expiry is evaluated here for both normal and dry-run imports: the batch
  # validation behind a dry run does not evaluate it, and an access-only copy
  # rejects an expired access token it could never refresh.
  defp prepare_import_accounts(accounts, pool, scope, refresh_tokens) do
    evaluated_at = DateTime.utc_now()

    accounts
    |> Enum.reduce_while({:ok, []}, fn account, {:ok, prepared} ->
      with {:ok, %PreparedAccount{} = entry} <-
             prepare_bundle_account(scope, pool, import_attrs(account), refresh_tokens),
           :ok <- PreparedAccount.evaluate(entry, evaluated_at) do
        {:cont, {:ok, [entry | prepared]}}
      else
        {:error, reason} -> {:halt, {:error, preparation_error(reason)}}
      end
    end)
    |> case do
      {:ok, prepared} -> {:ok, Enum.reverse(prepared)}
      {:error, _reason} = error -> error
    end
  end

  defp prepare_bundle_account(scope, pool, attrs, :omit),
    do: Upstreams.prepare_access_only_bundle_account(scope, pool, attrs)

  defp prepare_bundle_account(scope, pool, attrs, :import),
    do: Upstreams.prepare_bundle_account(scope, pool, attrs)

  # Bundle parsing and account-shape validation own their existing public
  # errors. Once preparation reaches identity selection, only authorization is
  # a denial; conflicts, malformed persisted epochs, and any other preparation
  # failure are deliberately opaque lifecycle failures.
  defp preparation_error(%{code: code}) when code in [:capability_denied, :pool_not_found],
    do: lifecycle_error(:bundle_import_denied)

  defp preparation_error(_reason), do: lifecycle_error(:bundle_import_failed)

  defp import_attrs(account) do
    %{
      chatgpt_account_id: account["chatgpt_account_id"],
      chatgpt_user_id: account["chatgpt_user_id"],
      account_email: account["account_email"],
      account_label: account["account_label"],
      workspace_id: account["workspace_id"],
      workspace_label: account["workspace_label"],
      seat_type: account["seat_type"],
      plan_label: account["plan_label"],
      token: account["access_token"],
      refresh_token: account["refresh_token"],
      credential_provenance: account["credential_provenance"],
      access_token_expires_at: account["access_token_expires_at"],
      import_metadata: %{}
    }
  end

  defp derive_key(password, salt, kdf) do
    with hash when is_binary(hash) <-
           Argon2.Base.hash_password(password, salt,
             format: :raw_hash,
             hashlen: @key_bytes,
             t_cost: kdf_value(kdf, "t_cost"),
             m_cost: kdf_value(kdf, "m_cost"),
             parallelism: kdf_value(kdf, "parallelism"),
             argon2_type: 2
           ),
         {:ok, key} <- Base.decode16(hash, case: :lower),
         true <- byte_size(key) == @key_bytes do
      {:ok, key}
    else
      _invalid -> {:error, lifecycle_error(:bundle_kdf_failed)}
    end
  rescue
    _exception -> {:error, lifecycle_error(:bundle_kdf_failed)}
  end

  defp kdf_value(%{t_cost: value}, "t_cost"), do: value
  defp kdf_value(%{m_cost: value}, "m_cost"), do: value
  defp kdf_value(%{parallelism: value}, "parallelism"), do: value
  defp kdf_value(%{"t_cost" => value}, "t_cost"), do: value
  defp kdf_value(%{"m_cost" => value}, "m_cost"), do: value
  defp kdf_value(%{"parallelism" => value}, "parallelism"), do: value

  defp canonical_header(header) do
    header
    |> canonical_json()
    |> IO.iodata_to_binary()
  end

  defp canonical_json(%{} = map) do
    [
      "{",
      map
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map_join(",", fn {key, value} ->
        [CodexPooler.JSON.encode!(key), ":", canonical_json(value)]
      end),
      "}"
    ]
  end

  defp canonical_json(value), do: CodexPooler.JSON.encode!(value)

  defp stringified_kdf(salt) do
    @kdf
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> Map.put("salt", Base.encode64(salt))
  end

  defp bundle_mode(path) do
    case File.stat(path) do
      {:ok, stat} ->
        stat.mode |> band(0o777) |> Integer.to_string(8) |> String.pad_leading(4, "0")

      {:error, _reason} ->
        "unknown"
    end
  end

  defp validate_password(password) when byte_size(password) >= 16, do: :ok
  defp validate_password(_password), do: {:error, lifecycle_error(:bundle_password_invalid)}

  defp fingerprint(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower) |> binary_part(0, 12)

  defp lifecycle_error(code), do: %{code: code, message: "upstream account bundle #{code}"}
end
