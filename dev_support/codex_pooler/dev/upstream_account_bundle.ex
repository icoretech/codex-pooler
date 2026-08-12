defmodule CodexPooler.Dev.UpstreamAccountBundle do
  @moduledoc false

  import Bitwise
  import Ecto.Query

  alias CodexPooler.Accounts
  alias CodexPooler.Accounts.{PlatformBootstrapState, Scope, User}
  alias CodexPooler.Pools.{Membership, Pool}
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Secrets
  alias CodexPooler.Upstreams.TokenLinking
  alias __MODULE__.{CLI, PrivateFile}

  @password_env "CODEX_POOLER_ACCOUNT_BUNDLE_PASSWORD"
  @format "codex-pooler.upstream-accounts"
  @version 1
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
    seat_type plan_label access_token refresh_token access_token_expires_at
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
         {:ok, pool} <- pool_by_slug(command.pool_slug) do
      # Dialyzer cannot see repository-backed dev rows through this boundary and
      # otherwise collapses the real success branch to `no_return`.
      case apply(__MODULE__, :export_bundle, [pool, password]) do
        {:ok, bundle, receipt} ->
          case write_bundle_file(command.out_path, bundle) do
            {:ok, mode} ->
              {:ok,
               Map.merge(receipt, %{
                 status: "exported",
                 path_mode: mode,
                 path_fingerprint: fingerprint(command.out_path)
               })}

            {:error, message} ->
              {:error, message}
          end

        {:error, %{message: message}} ->
          {:error, message}
      end
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
             [dry_run: command.dry_run?]
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

  @spec export_bundle(Pool.t(), binary()) ::
          {:ok, binary(), %{required(:exported) => non_neg_integer()}}
          | {:error, lifecycle_error()}
  def export_bundle(%Pool{} = pool, password) when is_binary(password) do
    with :ok <- validate_password(password),
         {:ok, accounts, skipped} <- export_accounts(pool),
         {:ok, bundle} <- seal_accounts(accounts, password) do
      {:ok, bundle,
       %{
         version: @version,
         account_count: length(accounts),
         exported: length(accounts),
         skipped_missing_access_token: skipped.missing_access_token,
         skipped_missing_refresh_token: skipped.missing_refresh_token
       }}
    end
  end

  def export_bundle(_pool, _password), do: {:error, lifecycle_error(:bundle_invalid_request)}

  @spec import_bundle(binary(), Pool.t(), Scope.t(), binary(), keyword()) ::
          {:ok, map()} | {:error, lifecycle_error()}
  def import_bundle(bundle, pool, scope, password, opts \\ [])

  def import_bundle(bundle, %Pool{} = pool, %Scope{} = scope, password, opts)
      when is_binary(bundle) and is_binary(password) and is_list(opts) do
    dry_run? = Keyword.get(opts, :dry_run, false)

    with :ok <- validate_password(password),
         {:ok, accounts} <- open_accounts(bundle, password),
         :ok <- validate_import_accounts(accounts),
         :ok <- validate_import_scope(accounts, pool, scope) do
      if dry_run? do
        {:ok,
         %{
           version: @version,
           account_count: length(accounts),
           valid: length(accounts),
           imported: 0,
           dry_run: true
         }}
      else
        import_accounts(accounts, pool, scope)
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
    case Repo.one(
           from pool in Pool, where: pool.slug == ^slug and pool.status == "active", limit: 1
         ) do
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

  @spec export_accounts(Pool.t()) ::
          {:ok, [account()], skip_counts()} | {:error, lifecycle_error()}
  defp export_accounts(pool) do
    pool
    |> Upstreams.list_active_pool_assignments()
    |> Enum.reduce_while({:ok, [], empty_skips()}, fn assignment, {:ok, accounts, skipped} ->
      case export_account(Upstreams.get_upstream_identity(assignment.upstream_identity_id)) do
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

  defp export_account(%{status: "active"} = identity) do
    with {:ok, access_token} <- required_secret(identity, "access_token", :missing_access_token),
         {:ok, refresh_token} <-
           required_secret(identity, "refresh_token", :missing_refresh_token) do
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
         "access_token" => access_token,
         "refresh_token" => refresh_token,
         "access_token_expires_at" => access_token_expires_at(identity.metadata)
       }}
    end
  end

  defp export_account(_identity), do: {:skip, :missing_access_token}

  defp required_secret(identity, kind, missing_reason) do
    case Secrets.decrypt_active_secret(identity, kind) do
      {:ok, secret} -> {:ok, secret}
      {:error, %{code: :upstream_secret_not_found}} -> {:skip, missing_reason}
      {:error, _reason} -> {:error, lifecycle_error(:bundle_source_secret_unavailable)}
    end
  end

  defp empty_skips, do: %{missing_access_token: 0, missing_refresh_token: 0}
  defp increment_skip(skips, key), do: Map.update!(skips, key, &(&1 + 1))

  defp access_token_expires_at(%{} = metadata) do
    case Map.get(metadata, "access_token_expires_at") do
      value when is_binary(value) -> value
      _value -> nil
    end
  end

  defp access_token_expires_at(_metadata), do: nil

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
         {:ok, plaintext} <- Jason.encode(%{"accounts" => accounts}) do
      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(
          :aes_256_gcm,
          key,
          nonce,
          plaintext,
          canonical_header(header),
          true
        )

      case Jason.encode(Map.put(header, "ciphertext", Base.encode64(tag <> ciphertext))) do
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
           decrypt(encrypted, key, nonce, canonical_header(Map.delete(header, "ciphertext"))),
         {:ok, accounts} <- decode_accounts(plaintext, header["account_count"]) do
      {:ok, accounts}
    end
  end

  defp decode_header(bundle) do
    with {:ok, %{} = header} <- Jason.decode(bundle),
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
    with {:ok, %{"accounts" => accounts}} <- Jason.decode(plaintext),
         true <- is_list(accounts),
         true <- length(accounts) == expected_count do
      {:ok, accounts}
    else
      _invalid -> {:error, lifecycle_error(:bundle_malformed)}
    end
  end

  defp validate_import_accounts(accounts) do
    if Enum.all?(accounts, &valid_account?/1) do
      :ok
    else
      {:error, lifecycle_error(:bundle_invalid_account)}
    end
  end

  defp valid_account?(%{} = account) do
    Enum.sort(Map.keys(account)) == Enum.sort(@account_keys) and
      present_string?(account["chatgpt_account_id"]) and
      present_string?(account["account_label"]) and
      present_string?(account["access_token"]) and
      present_string?(account["refresh_token"]) and
      optional_string?(account["chatgpt_user_id"]) and
      optional_string?(account["account_email"]) and
      optional_string?(account["workspace_id"]) and
      optional_string?(account["workspace_label"]) and
      optional_string?(account["seat_type"]) and
      optional_string?(account["plan_label"]) and
      optional_datetime?(account["access_token_expires_at"])
  end

  defp valid_account?(_account), do: false

  defp present_string?(value), do: is_binary(value) and byte_size(String.trim(value)) > 0
  defp optional_string?(value), do: is_nil(value) or is_binary(value)

  defp optional_datetime?(nil), do: true

  defp optional_datetime?(value) when is_binary(value) do
    match?({:ok, _datetime, _offset}, DateTime.from_iso8601(value))
  end

  defp optional_datetime?(_value), do: false

  defp import_accounts(accounts, pool, scope) do
    case Repo.transaction(fn -> import_accounts_transaction(accounts, pool, scope) end) do
      {:ok, results} ->
        publish_import_results(results, pool, scope)
        imported = length(results)

        {:ok,
         %{
           version: @version,
           account_count: imported,
           valid: imported,
           imported: imported,
           dry_run: false
         }}

      {:error, _reason} ->
        {:error, lifecycle_error(:bundle_import_failed)}
    end
  end

  defp import_accounts_transaction(accounts, pool, scope) do
    accounts
    |> Enum.reduce_while([], fn account, results ->
      case Upstreams.import_trusted_account_in_transaction(scope, pool, import_attrs(account)) do
        {:ok, result} -> {:cont, [result | results]}
        {:error, _reason} -> Repo.rollback(:bundle_import_failed)
      end
    end)
    |> Enum.reverse()
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

  defp validate_import_scope(accounts, pool, scope) do
    Enum.reduce_while(accounts, :ok, fn account, :ok ->
      case Upstreams.validate_trusted_account(scope, pool, import_attrs(account)) do
        {:ok, _attrs} -> {:cont, :ok}
        {:error, _reason} -> {:halt, {:error, lifecycle_error(:bundle_import_denied)}}
      end
    end)
  end

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
        [Jason.encode!(key), ":", canonical_json(value)]
      end),
      "}"
    ]
  end

  defp canonical_json(value), do: Jason.encode!(value)

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
