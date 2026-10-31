defmodule CodexPooler.Alerts.ChannelManagement do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounting
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Alerts.AuditLog, as: AlertAudit
  alias CodexPooler.Alerts.Authorization
  alias CodexPooler.Alerts.Schemas.AlertChannel
  alias CodexPooler.Alerts.Schemas.AlertDeliveryAttempt
  alias CodexPooler.Pools
  alias CodexPooler.Repo

  @type access_error :: Authorization.access_error()
  @type channel_projection :: %{
          id: Ecto.UUID.t(),
          channel_type: String.t(),
          display_name: String.t(),
          state: String.t(),
          email_to: String.t() | nil,
          locale: String.t() | nil,
          endpoint_scheme: String.t() | nil,
          endpoint_host: String.t() | nil,
          endpoint_path_prefix: String.t() | nil,
          endpoint_fingerprint: String.t() | nil,
          webhook_signing_secret_key_version: non_neg_integer() | nil,
          created_by_user_id: Ecto.UUID.t(),
          disabled_at: DateTime.t() | nil,
          metadata: map(),
          created_at: DateTime.t(),
          updated_at: DateTime.t()
        }
  @type channel_result ::
          {:ok, channel_projection()} | {:error, Ecto.Changeset.t() | access_error()}

  @spec list_channels(term(), keyword()) ::
          {:ok, [channel_projection()]} | {:error, access_error()}
  def list_channels(scope, opts \\ [])

  def list_channels(%Scope{} = scope, opts) when is_list(opts) do
    {:ok,
     scope
     |> scope_query()
     |> maybe_filter_channel_state(Keyword.get(opts, :state))
     |> order_by([channel], asc: channel.created_at, asc: channel.id)
     |> Repo.all()
     |> Enum.map(&projection/1)}
  end

  def list_channels(_scope, _opts),
    do: {:error, Authorization.access_error(:invalid_request, "user scope is required")}

  @spec create_channel(term(), map()) :: channel_result()
  def create_channel(%Scope{} = scope, attrs) when is_map(attrs) do
    with {:ok, _user_id} <- Authorization.scope_user_id(scope) do
      now = now()

      %AlertChannel{}
      |> AlertChannel.changeset(channel_attrs(attrs, scope, now))
      |> Repo.insert()
      |> AlertAudit.audit_channel_create(scope)
      |> project_channel_result()
    end
  end

  def create_channel(_scope, _attrs),
    do: {:error, Authorization.access_error(:invalid_request, "user scope is required")}

  @spec update_channel(term(), AlertChannel.t() | Ecto.UUID.t(), map()) :: channel_result()
  @spec update_channel(term(), AlertChannel.t() | Ecto.UUID.t(), map(), keyword()) :: channel_result()
  def update_channel(scope, channel, attrs, opts \\ [])

  def update_channel(%Scope{} = scope, %AlertChannel{id: id}, attrs, opts) when is_map(attrs) and is_list(opts), do: update_channel(scope, id, attrs, opts)

  def update_channel(%Scope{} = scope, channel_id, attrs, opts)
      when is_binary(channel_id) and is_map(attrs) and is_list(opts) do
    case Repo.transact(fn -> update_channel_in_transaction(scope, channel_id, attrs, opts) end) do
      {:ok, {previous, updated}} ->
        {:ok, updated}
        |> AlertAudit.audit_channel_update(scope, previous, attrs)
        |> project_channel_result()

      {:error, _reason} = error ->
        error
    end
  end

  def update_channel(_scope, _channel, _attrs, _opts),
    do: {:error, Authorization.access_error(:invalid_request, "user scope is required")}

  defp update_channel_in_transaction(scope, channel_id, attrs, opts) do
    case Repo.one(from channel in AlertChannel, where: channel.id == ^channel_id, lock: "FOR UPDATE") do
      %AlertChannel{} = channel ->
        with {:ok, channel} <- authorize_access(scope, channel),
             :ok <- check_update_revision(channel, opts),
             {:ok, updated} <- channel |> AlertChannel.changeset(channel_update_attrs(attrs, now())) |> Repo.update() do
          {:ok, {channel, updated}}
        end

      nil ->
        {:error, not_found_error()}
    end
  end

  defp check_update_revision(channel, opts) do
    case Keyword.fetch(opts, :expected_updated_at) do
      :error -> :ok
      {:ok, expected} when expected == channel.updated_at -> :ok
      {:ok, _expected} -> {:error, Authorization.access_error(:stale_update, "alert channel changed since it was opened")}
    end
  end

  @spec delete_channel(term(), AlertChannel.t() | Ecto.UUID.t()) :: channel_result()
  @spec delete_channel(term(), AlertChannel.t() | Ecto.UUID.t(), keyword()) :: channel_result()
  def delete_channel(scope, channel, opts \\ [])

  def delete_channel(%Scope{} = scope, %AlertChannel{id: id}, opts) when is_list(opts),
    do: delete_channel(scope, id, opts)

  def delete_channel(%Scope{} = scope, channel_id, opts) when is_binary(channel_id) and is_list(opts) do
    result = Repo.transact(fn -> delete_channel_in_transaction(scope, channel_id, opts) end)

    result
    |> AlertAudit.audit_channel_delete(scope)
    |> project_channel_result()
  end

  def delete_channel(_scope, _channel, _opts),
    do: {:error, Authorization.access_error(:invalid_request, "user scope is required")}

  defp delete_channel_in_transaction(scope, channel_id, opts) do
    with {:ok, channel} <- locked_channel(scope, channel_id),
         :ok <- check_delete_revision(channel, opts),
         {:ok, channel} <- preserve_attempt_history(channel),
         {:ok, deleted} <- Repo.delete(channel) do
      {:ok, deleted}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp check_delete_revision(channel, opts) do
    case Keyword.fetch(opts, :expected_updated_at) do
      :error -> :ok
      {:ok, expected} when expected == channel.updated_at -> :ok
      {:ok, _expected} -> {:error, Authorization.access_error(:stale_update, "alert channel changed since it was opened")}
    end
  end

  defp locked_channel(scope, channel_id) do
    case Repo.one(from c in AlertChannel, where: c.id == ^channel_id, lock: "FOR UPDATE") do
      %AlertChannel{} = channel -> authorize_access(scope, channel)
      nil -> {:error, not_found_error()}
    end
  end

  defp preserve_attempt_history(%AlertChannel{} = channel) do
    now = now()

    Repo.update_all(
      from(attempt in AlertDeliveryAttempt, where: attempt.channel_id == ^channel.id),
      set: [
        channel_id: nil,
        channel_created_by_user_id: channel.created_by_user_id,
        channel_display_name: channel.display_name,
        channel_type: channel.channel_type,
        channel_deleted_at: now,
        updated_at: now
      ]
    )

    {:ok, channel}
  end

  @spec scope_query(Scope.t()) :: Ecto.Query.t()
  def scope_query(%Scope{} = scope) do
    query = from(channel in AlertChannel)

    if Pools.owner?(scope) do
      query
    else
      {:ok, user_id} = Authorization.scope_user_id(scope)
      from channel in query, where: channel.created_by_user_id == ^user_id
    end
  end

  @spec not_found_error() :: access_error()
  def not_found_error,
    do: Authorization.access_error(:channel_not_found, "alert channel was not found")

  defp authorize_access(%Scope{} = scope, %AlertChannel{} = channel) do
    if Pools.owner?(scope) do
      {:ok, channel}
    else
      case Authorization.scope_user_id(scope) do
        {:ok, user_id} when channel.created_by_user_id == user_id -> {:ok, channel}
        {:ok, _user_id} -> {:error, not_found_error()}
        {:error, _reason} = error -> error
      end
    end
  end

  defp channel_attrs(attrs, scope, timestamp) do
    attrs
    |> normalize_attrs(channel_attribute_keys())
    |> Map.merge(%{
      created_by_user_id: scope.user.id,
      disabled_at: disabled_at_for_state(Map.get(attrs, :state) || Map.get(attrs, "state"), timestamp),
      metadata: safe_channel_metadata(attrs),
      webhook_signing_secret_aad:
        Map.get(attrs, :webhook_signing_secret_aad) ||
          Map.get(attrs, "webhook_signing_secret_aad") || %{},
      created_at: timestamp,
      updated_at: timestamp
    })
  end

  defp channel_update_attrs(attrs, timestamp) do
    attrs
    |> normalize_attrs(channel_attribute_keys())
    |> maybe_put_channel_metadata(attrs)
    |> maybe_put_disabled_at(attrs, timestamp)
    |> Map.put(:updated_at, timestamp)
  end

  defp channel_attribute_keys do
    [
      :channel_type,
      :display_name,
      :state,
      :email_to,
      :locale,
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
      :metadata
    ]
  end

  defp normalize_attrs(attrs, keys) do
    Enum.reduce(keys, %{}, fn key, acc ->
      case Map.fetch(attrs, key) do
        {:ok, value} -> Map.put(acc, key, value)
        :error -> maybe_put_string_key(acc, attrs, key)
      end
    end)
  end

  defp maybe_put_string_key(acc, attrs, key) do
    string_key = Atom.to_string(key)

    case Map.fetch(attrs, string_key) do
      {:ok, value} -> Map.put(acc, key, value)
      :error -> acc
    end
  end

  defp maybe_put_disabled_at(attrs, raw_attrs, timestamp) do
    case Map.get(raw_attrs, :state) || Map.get(raw_attrs, "state") do
      "disabled" -> Map.put(attrs, :disabled_at, timestamp)
      "active" -> Map.put(attrs, :disabled_at, nil)
      _state -> attrs
    end
  end

  defp disabled_at_for_state("disabled", timestamp), do: timestamp
  defp disabled_at_for_state(_state, _timestamp), do: nil

  defp maybe_put_channel_metadata(attrs, raw_attrs) do
    if Map.has_key?(raw_attrs, :metadata) or Map.has_key?(raw_attrs, "metadata") do
      Map.put(attrs, :metadata, safe_channel_metadata(raw_attrs))
    else
      attrs
    end
  end

  defp safe_channel_metadata(attrs) do
    case Map.get(attrs, :metadata) || Map.get(attrs, "metadata") do
      %{} = metadata -> Accounting.sanitize_metadata(metadata)
      nil -> %{}
      other -> other
    end
  end

  defp project_channel_result({:ok, %AlertChannel{} = channel}),
    do: {:ok, projection(channel)}

  defp project_channel_result({:error, _reason} = error), do: error

  defp projection(%AlertChannel{} = channel) do
    %{
      id: channel.id,
      channel_type: channel.channel_type,
      display_name: channel.display_name,
      state: channel.state,
      email_to: channel.email_to,
      locale: channel.locale,
      endpoint_scheme: channel.endpoint_scheme,
      endpoint_host: channel.endpoint_host,
      endpoint_path_prefix: channel.endpoint_path_prefix,
      endpoint_fingerprint: channel.endpoint_fingerprint,
      webhook_signing_secret_key_version: channel.webhook_signing_secret_key_version,
      created_by_user_id: channel.created_by_user_id,
      disabled_at: channel.disabled_at,
      metadata: safe_projected_metadata(channel.metadata),
      created_at: channel.created_at,
      updated_at: channel.updated_at
    }
  end

  defp safe_projected_metadata(%{} = metadata), do: Accounting.sanitize_metadata(metadata)
  defp safe_projected_metadata(_metadata), do: %{}

  defp maybe_filter_channel_state(query, nil), do: query

  defp maybe_filter_channel_state(query, state),
    do: from(channel in query, where: channel.state == ^state)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
