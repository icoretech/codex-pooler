defmodule CodexPooler.Upstreams.Secrets do
  @moduledoc """
  Encrypted upstream secret lifecycle and storage helpers.
  """

  import Ecto.Query

  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.EncryptedSecret
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias CodexPooler.Upstreams.SecretBox
  alias CodexPooler.Upstreams.StatusVocabulary.Identity, as: IdentityStatus

  @active "active"
  @deleted IdentityStatus.deleted_status()
  @refresh_due IdentityStatus.refresh_due_status()
  @reauth_required IdentityStatus.reauth_required_status()
  @superseded "superseded"
  @type lifecycle_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type identity_ref :: UpstreamIdentity.t() | Ecto.UUID.t()
  @type secret_result ::
          {:ok, EncryptedSecret.t() | binary()} | {:error, Ecto.Changeset.t() | lifecycle_error()}

  @spec secret_status(identity_ref()) ::
          :present | :missing | :expired | :refresh_due | :reauth_required
  def secret_status(identity_or_id) do
    case normalize_identity(identity_or_id) do
      %UpstreamIdentity{status: @reauth_required} ->
        :reauth_required

      %UpstreamIdentity{status: @refresh_due} ->
        :refresh_due

      %UpstreamIdentity{status: @deleted} ->
        :missing

      %UpstreamIdentity{} = identity ->
        cond do
          secret_expired?(identity.metadata) -> :expired
          active_secret?(identity.id, "access_token") -> :present
          true -> :missing
        end

      nil ->
        :missing
    end
  end

  @spec upsert_encrypted_secret(identity_ref(), map()) :: secret_result()
  def upsert_encrypted_secret(identity_or_id, attrs) when is_map(attrs) do
    case normalize_identity(identity_or_id) do
      %UpstreamIdentity{} = identity ->
        now = now()
        attrs = atomize_attrs(attrs)
        secret_kind = attrs |> Map.fetch!(:secret_kind) |> normalize_token()

        Repo.transaction(fn ->
          Repo.update_all(
            from(secret in EncryptedSecret,
              where:
                secret.upstream_identity_id == ^identity.id and secret.secret_kind == ^secret_kind and
                  secret.status == ^@active
            ),
            set: [status: @superseded, superseded_at: now]
          )

          changeset =
            EncryptedSecret.changeset(
              %EncryptedSecret{},
              attrs
              |> Map.put(:upstream_identity_id, identity.id)
              |> Map.put(:secret_kind, secret_kind)
              |> put_default(:aad, %{})
              |> put_default(:status, @active)
              |> put_default(:created_at, now)
            )

          # Reason: insert failure must rollback the encrypted-secret transaction.
          # credo:disable-for-next-line Credo.Check.Refactor.Nesting
          case Repo.insert(changeset) do
            {:ok, secret} -> secret
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end)
        |> case do
          {:ok, secret} -> {:ok, secret}
          {:error, reason} -> {:error, reason}
        end

      nil ->
        {:error, lifecycle_error(:upstream_identity_not_found, "upstream identity was not found")}
    end
  end

  @spec store_encrypted_secret(identity_ref(), map()) :: secret_result()
  def store_encrypted_secret(identity_or_id, attrs) when is_map(attrs) do
    with %UpstreamIdentity{} = identity <- normalize_identity(identity_or_id),
         {:ok, plaintext} <- plaintext_secret(attrs),
         {:ok, encrypted_attrs} <- encrypt_upstream_secret(identity, attrs, plaintext) do
      upsert_encrypted_secret(identity, encrypted_attrs)
    else
      nil ->
        {:error, lifecycle_error(:upstream_identity_not_found, "upstream identity was not found")}

      {:error, _reason} = error ->
        error
    end
  end

  @spec decrypt_active_secret(identity_ref(), String.t()) ::
          {:ok, binary()} | {:error, lifecycle_error()}
  def decrypt_active_secret(identity_or_id, secret_kind) when is_binary(secret_kind) do
    identity_id = identity_id(identity_or_id)
    normalized_kind = normalize_token(secret_kind)

    secret =
      Repo.one(
        from secret in EncryptedSecret,
          where:
            secret.upstream_identity_id == ^identity_id and secret.secret_kind == ^normalized_kind and
              secret.status == ^@active,
          order_by: [desc: secret.created_at],
          limit: 1
      )

    case secret do
      %EncryptedSecret{} ->
        decrypt_upstream_secret(secret)

      nil ->
        {:error,
         lifecycle_error(:upstream_secret_not_found, "active upstream secret was not found")}
    end
  end

  @spec list_active_encrypted_secrets(identity_ref()) :: [EncryptedSecret.t()]
  def list_active_encrypted_secrets(identity_or_id) do
    case identity_id(identity_or_id) do
      identity_id when is_binary(identity_id) ->
        Repo.all(
          from secret in EncryptedSecret,
            where: secret.upstream_identity_id == ^identity_id and secret.status == ^@active,
            order_by: [asc: secret.secret_kind]
        )

      nil ->
        []
    end
  end

  @doc false
  @spec lock_encrypted_secrets(Ecto.UUID.t()) :: [EncryptedSecret.t()]
  def lock_encrypted_secrets(identity_id) when is_binary(identity_id) do
    Repo.all(
      from secret in EncryptedSecret,
        where: secret.upstream_identity_id == ^identity_id,
        order_by: [asc: secret.id],
        lock: "FOR UPDATE"
    )
  end

  @spec validate_upstream_secret_key!(binary() | nil) :: :ok
  def validate_upstream_secret_key!(configured_key) do
    SecretBox.validate_secret_key!(configured_key)
  end

  @spec revoke_active_secrets(Ecto.UUID.t(), DateTime.t()) :: {non_neg_integer(), nil | [term()]}
  def revoke_active_secrets(identity_id, timestamp) do
    Repo.update_all(
      from(secret in EncryptedSecret,
        where: secret.upstream_identity_id == ^identity_id and secret.status == ^@active
      ),
      set: [status: "revoked", superseded_at: timestamp]
    )
  end

  defp active_secret?(identity_id, secret_kind) do
    secret_kind = normalize_token(secret_kind)

    Repo.exists?(
      from secret in EncryptedSecret,
        where:
          secret.upstream_identity_id == ^identity_id and secret.secret_kind == ^secret_kind and
            secret.status == ^@active
    )
  end

  defp secret_expired?(metadata) when is_map(metadata) do
    metadata
    |> Map.get("access_token_expires_at", Map.get(metadata, "secret_expires_at"))
    |> parse_optional_datetime()
    |> case do
      %DateTime{} = expires_at -> DateTime.compare(expires_at, now()) != :gt
      nil -> false
    end
  end

  defp secret_expired?(_metadata), do: false

  defp encrypt_upstream_secret(%UpstreamIdentity{} = identity, attrs, plaintext) do
    attrs = atomize_attrs(attrs)
    secret_kind = attrs |> Map.fetch!(:secret_kind) |> normalize_token()

    aad =
      %{
        "algorithm" => "AES-256-GCM",
        "key_env" => SecretBox.configured_key_env(),
        "upstream_identity_id" => identity.id,
        "secret_kind" => secret_kind
      }
      |> maybe_put_key_version(Map.get(attrs, :key_version))

    with {:ok, encrypted} <- SecretBox.encrypt_fields(plaintext, aad) do
      {:ok,
       attrs
       |> Map.drop([:plaintext, :secret, "plaintext", "secret"])
       |> Map.merge(%{
         secret_kind: secret_kind,
         key_version: encrypted.key_version,
         ciphertext: encrypted.ciphertext,
         nonce: encrypted.nonce,
         aad: encrypted.aad
       })}
    end
  end

  defp decrypt_upstream_secret(%EncryptedSecret{} = secret) do
    case SecretBox.decrypt_fields(%{
           ciphertext: secret.ciphertext,
           nonce: secret.nonce,
           aad: secret.aad
         }) do
      {:ok, plaintext} ->
        {:ok, plaintext}

      {:error, %{code: :upstream_secret_decryption_failed}} ->
        {:error,
         lifecycle_error(
           :upstream_secret_decryption_failed,
           "upstream secret could not be decrypted"
         )}

      {:error, %{code: :upstream_secret_invalid_ciphertext}} ->
        {:error,
         lifecycle_error(
           :upstream_secret_invalid_ciphertext,
           "upstream secret ciphertext is invalid"
         )}

      {:error, _reason} = error ->
        error
    end
  end

  defp plaintext_secret(attrs) do
    attrs = atomize_attrs(attrs)

    case Map.get(attrs, :plaintext) || Map.get(attrs, :secret) do
      plaintext when is_binary(plaintext) and byte_size(plaintext) > 0 ->
        {:ok, plaintext}

      _value ->
        {:error,
         lifecycle_error(
           :upstream_secret_plaintext_required,
           "plaintext upstream secret is required"
         )}
    end
  end

  defp parse_optional_datetime(%DateTime{} = datetime), do: datetime

  defp parse_optional_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _invalid -> nil
    end
  end

  defp parse_optional_datetime(_value), do: nil

  defp normalize_identity(%UpstreamIdentity{id: id}), do: Repo.get(UpstreamIdentity, id)
  defp normalize_identity(id) when is_binary(id), do: Repo.get(UpstreamIdentity, id)
  defp normalize_identity(_id), do: nil

  defp identity_id(%UpstreamIdentity{id: id}), do: id
  defp identity_id(id) when is_binary(id), do: id
  defp identity_id(_id), do: nil

  defp atomize_attrs(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {key, value} when is_binary(key) -> {String.to_existing_atom(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp put_default(map, key, value) do
    case Map.get(map, key) do
      nil -> Map.put(map, key, value)
      _value -> map
    end
  end

  defp normalize_token(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_token(value), do: value

  defp maybe_put_key_version(aad, nil), do: aad
  defp maybe_put_key_version(aad, key_version), do: Map.put(aad, "key_version", key_version)

  defp lifecycle_error(code, message), do: %{code: code, message: message}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
