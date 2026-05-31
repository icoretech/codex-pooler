defmodule CodexPooler.Alerts.Schemas.AlertChannel do
  @moduledoc false
  use CodexPooler.Schema

  import Ecto.Changeset

  alias CodexPooler.Alerts.ChannelEndpoint
  alias CodexPooler.InstanceSettings.AppSecretCrypto

  @derive {Inspect,
           except: [
             :endpoint_url,
             :delivery_endpoint_url,
             :endpoint_url_ciphertext,
             :endpoint_url_nonce,
             :endpoint_url_aad,
             :webhook_signing_secret,
             :webhook_signing_secret_ciphertext,
             :webhook_signing_secret_nonce,
             :webhook_signing_secret_aad
           ]}

  @channel_types ~w(email webhook)
  @states ~w(active disabled)
  @endpoint_schemes ~w(https)
  @endpoint_secret_kind "alert_webhook_endpoint_url"
  @webhook_secret_kind "alert_webhook_signing_secret"

  @type t :: %__MODULE__{}
  @type attrs :: map()
  @type channel_type :: String.t()
  @type state :: String.t()
  @type endpoint_scheme :: String.t()

  schema "alert_channels" do
    field :channel_type, :string
    field :display_name, :string
    field :state, :string, default: "active"
    field :email_to, :string
    field :endpoint_url, :string, virtual: true, redact: true
    field :delivery_endpoint_url, :string, virtual: true, redact: true
    field :endpoint_scheme, :string
    field :endpoint_host, :string
    field :endpoint_path_prefix, :string
    field :endpoint_fingerprint, :string
    field :endpoint_url_ciphertext, :binary
    field :endpoint_url_nonce, :binary
    field :endpoint_url_aad, :map, default: %{}
    field :endpoint_url_key_version, :string
    field :webhook_signing_secret, :string, virtual: true, redact: true
    field :webhook_signing_secret_action, :string, virtual: true
    field :webhook_signing_secret_ciphertext, :binary
    field :webhook_signing_secret_nonce, :binary
    field :webhook_signing_secret_aad, :map, default: %{}
    field :webhook_signing_secret_key_version, :string
    field :created_by_user_id, :binary_id
    field :disabled_at, :utc_datetime_usec
    field :metadata, :map, default: %{}
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end

  @spec changeset(t() | Ecto.Changeset.t(), attrs()) :: Ecto.Changeset.t()
  def changeset(channel, attrs) do
    channel
    |> cast(attrs, [
      :channel_type,
      :display_name,
      :state,
      :email_to,
      :endpoint_url,
      :delivery_endpoint_url,
      :endpoint_scheme,
      :endpoint_host,
      :endpoint_path_prefix,
      :endpoint_fingerprint,
      :endpoint_url_ciphertext,
      :endpoint_url_nonce,
      :endpoint_url_aad,
      :endpoint_url_key_version,
      :webhook_signing_secret,
      :webhook_signing_secret_action,
      :webhook_signing_secret_ciphertext,
      :webhook_signing_secret_nonce,
      :webhook_signing_secret_aad,
      :webhook_signing_secret_key_version,
      :created_by_user_id,
      :disabled_at,
      :metadata,
      :created_at,
      :updated_at
    ])
    |> update_change(:display_name, &String.trim/1)
    |> update_change(:email_to, &normalize_optional_email/1)
    |> update_change(:endpoint_scheme, &normalize_optional_token/1)
    |> update_change(:endpoint_host, &normalize_optional_token/1)
    |> update_change(:endpoint_path_prefix, &trim_optional_string/1)
    |> update_change(:endpoint_fingerprint, &trim_optional_string/1)
    |> update_change(:endpoint_url_key_version, &trim_optional_string/1)
    |> update_change(:webhook_signing_secret_action, &normalize_optional_token/1)
    |> update_change(:webhook_signing_secret_key_version, &trim_optional_string/1)
    |> normalize_endpoint_url()
    |> apply_webhook_signing_secret()
    |> validate_required([
      :channel_type,
      :display_name,
      :state,
      :metadata,
      :created_at,
      :updated_at
    ])
    |> validate_length(:display_name, min: 1)
    |> validate_inclusion(:channel_type, @channel_types)
    |> validate_inclusion(:state, @states)
    |> validate_inclusion(:endpoint_scheme, @endpoint_schemes)
    |> validate_channel_contract()
    |> validate_endpoint_url_storage()
    |> validate_webhook_secret_storage()
    |> check_constraint(:channel_type, name: :alert_channels_channel_type_check)
    |> check_constraint(:state, name: :alert_channels_state_check)
    |> check_constraint(:endpoint_scheme, name: :alert_channels_endpoint_scheme_check)
    |> check_constraint(:metadata, name: :alert_channels_metadata_shape_check)
    |> check_constraint(:endpoint_url_aad,
      name: :alert_channels_endpoint_url_aad_shape_check
    )
    |> check_constraint(:webhook_signing_secret_aad,
      name: :alert_channels_webhook_secret_aad_shape_check
    )
  end

  @spec channel_types() :: [channel_type()]
  def channel_types, do: @channel_types

  @spec states() :: [state()]
  def states, do: @states

  @spec endpoint_schemes() :: [endpoint_scheme()]
  def endpoint_schemes, do: @endpoint_schemes

  @spec active_state() :: state()
  def active_state, do: "active"

  @spec disabled_state() :: state()
  def disabled_state, do: "disabled"

  defp normalize_endpoint_url(changeset) do
    case get_change(changeset, :endpoint_url) do
      value when is_binary(value) ->
        apply_endpoint_url_result(changeset, ChannelEndpoint.normalize_url(value))

      _missing ->
        changeset
    end
  end

  defp apply_endpoint_url_result(changeset, {:ok, endpoint_attrs}) do
    {delivery_endpoint_url, endpoint_attrs} = Map.pop(endpoint_attrs, :delivery_endpoint_url)

    changeset
    |> delete_change(:endpoint_url)
    |> put_endpoint_attrs(endpoint_attrs)
    |> put_encrypted_endpoint_url(delivery_endpoint_url)
  end

  defp apply_endpoint_url_result(changeset, {:error, :unsupported_scheme}) do
    changeset
    |> delete_change(:endpoint_url)
    |> add_error(:endpoint_url, "must use https")
  end

  defp apply_endpoint_url_result(changeset, {:error, _reason}) do
    changeset
    |> delete_change(:endpoint_url)
    |> add_error(:endpoint_url, "must be a valid https URL")
  end

  defp put_endpoint_attrs(changeset, endpoint_attrs) do
    Enum.reduce(endpoint_attrs, changeset, fn {field, endpoint_value}, acc ->
      put_change(acc, field, endpoint_value)
    end)
  end

  defp put_encrypted_endpoint_url(changeset, delivery_endpoint_url)
       when is_binary(delivery_endpoint_url) do
    case AppSecretCrypto.encrypt(delivery_endpoint_url, @endpoint_secret_kind) do
      {:ok, encrypted} ->
        changeset
        |> put_change(:endpoint_url_ciphertext, encrypted.ciphertext)
        |> put_change(:endpoint_url_nonce, encrypted.nonce)
        |> put_change(:endpoint_url_aad, encrypted.aad)
        |> put_change(:endpoint_url_key_version, encrypted.key_version)

      {:error, _reason} ->
        add_error(changeset, :endpoint_url, "could not be stored")
    end
  end

  defp put_encrypted_endpoint_url(changeset, _delivery_endpoint_url), do: changeset

  defp apply_webhook_signing_secret(changeset) do
    action = get_change(changeset, :webhook_signing_secret_action)
    secret = changeset |> get_change(:webhook_signing_secret) |> trim_optional_string()

    cond do
      action == "clear" ->
        changeset
        |> delete_change(:webhook_signing_secret)
        |> put_change(:webhook_signing_secret_ciphertext, nil)
        |> put_change(:webhook_signing_secret_nonce, nil)
        |> put_change(:webhook_signing_secret_aad, %{})
        |> put_change(:webhook_signing_secret_key_version, nil)

      is_binary(secret) ->
        case AppSecretCrypto.encrypt(secret, @webhook_secret_kind) do
          {:ok, encrypted} ->
            changeset
            |> delete_change(:webhook_signing_secret)
            |> put_change(:webhook_signing_secret_ciphertext, encrypted.ciphertext)
            |> put_change(:webhook_signing_secret_nonce, encrypted.nonce)
            |> put_change(:webhook_signing_secret_aad, encrypted.aad)
            |> put_change(:webhook_signing_secret_key_version, encrypted.key_version)

          {:error, _reason} ->
            changeset
            |> delete_change(:webhook_signing_secret)
            |> add_error(:webhook_signing_secret, "could not be stored")
        end

      true ->
        changeset
    end
  end

  defp validate_channel_contract(changeset) do
    case get_field(changeset, :channel_type) do
      "email" -> validate_email_channel(changeset)
      "webhook" -> validate_webhook_channel(changeset)
      _unknown -> changeset
    end
  end

  defp validate_email_channel(changeset) do
    changeset
    |> validate_required([:email_to])
    |> validate_format(:email_to, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
      message: "must be a valid email address"
    )
    |> validate_absent([
      :endpoint_scheme,
      :endpoint_host,
      :endpoint_path_prefix,
      :endpoint_fingerprint,
      :endpoint_url_ciphertext,
      :endpoint_url_nonce,
      :endpoint_url_key_version
    ])
  end

  defp validate_webhook_channel(changeset) do
    changeset
    |> validate_required([
      :endpoint_scheme,
      :endpoint_host,
      :endpoint_path_prefix,
      :endpoint_fingerprint
    ])
    |> validate_absent([:email_to])
    |> validate_format(:endpoint_host, ~r/^[a-z0-9.-]+$/, message: "must be a valid host")
    |> validate_format(:endpoint_path_prefix, ~r/^\//, message: "must start with /")
    |> validate_change(:endpoint_path_prefix, fn :endpoint_path_prefix, value ->
      if String.contains?(value, ["?", "#"]),
        do: [endpoint_path_prefix: "must not include query strings or fragments"],
        else: []
    end)
  end

  defp validate_absent(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, acc ->
      if present?(get_field(acc, field)) do
        add_error(acc, field, "must be blank")
      else
        acc
      end
    end)
  end

  defp validate_webhook_secret_storage(changeset) do
    ciphertext = get_field(changeset, :webhook_signing_secret_ciphertext)
    nonce = get_field(changeset, :webhook_signing_secret_nonce)
    key_version = get_field(changeset, :webhook_signing_secret_key_version)

    if Enum.any?([ciphertext, nonce, key_version], &present?/1) do
      changeset
      |> validate_required([
        :webhook_signing_secret_ciphertext,
        :webhook_signing_secret_nonce,
        :webhook_signing_secret_key_version
      ])
      |> validate_length(:webhook_signing_secret_key_version, min: 1)
    else
      changeset
    end
  end

  defp validate_endpoint_url_storage(changeset) do
    ciphertext = get_field(changeset, :endpoint_url_ciphertext)
    nonce = get_field(changeset, :endpoint_url_nonce)
    key_version = get_field(changeset, :endpoint_url_key_version)

    if Enum.any?([ciphertext, nonce, key_version], &present?/1) do
      changeset
      |> validate_required([
        :endpoint_url_ciphertext,
        :endpoint_url_nonce,
        :endpoint_url_key_version
      ])
      |> validate_length(:endpoint_url_key_version, min: 1)
    else
      changeset
    end
  end

  defp normalize_optional_email(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_optional_email(value), do: value

  defp normalize_optional_token(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_optional_token(value), do: value

  defp trim_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim_optional_string(value), do: value

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value) when is_map(value), do: map_size(value) > 0
  defp present?(value), do: not is_nil(value)
end
