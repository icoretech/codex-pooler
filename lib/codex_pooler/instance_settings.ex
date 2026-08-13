defmodule CodexPooler.InstanceSettings do
  @moduledoc """
  DB-backed singleton settings boundary for runtime and operator tunables.
  """

  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.Audit
  alias CodexPooler.InstanceSettings.{Cache, Settings}
  alias CodexPooler.Mailer
  alias CodexPooler.Mailer.Config, as: MailerConfig
  alias CodexPooler.Pools
  alias CodexPooler.Repo

  @type settings :: Settings.t()
  @type update_result :: {:ok, settings()} | {:error, Ecto.Changeset.t() | Pools.access_error()}

  @spec current() :: settings()
  def current, do: Cache.current()

  @spec get!() :: settings()
  def get! do
    Settings
    |> Repo.get!(true)
    |> Settings.mark_loaded(:database)
  end

  @spec change(settings()) :: Ecto.Changeset.t()
  def change(%Settings{} = settings), do: Settings.changeset(settings, %{})

  @spec change_current(map()) :: Ecto.Changeset.t()
  def change_current(attrs) when is_map(attrs) do
    Settings.changeset(ensure_singleton!(), attrs)
  end

  @spec ensure_singleton!() :: settings()
  def ensure_singleton! do
    settings = Settings.default()
    Repo.insert(settings, on_conflict: :nothing, conflict_target: :singleton)

    Settings
    |> Repo.get!(true)
    |> Settings.mark_loaded(:database)
  end

  @spec update(Scope.t(), map()) :: update_result()
  def update(%Scope{} = scope, attrs) when is_map(attrs) do
    with {:ok, _decision} <- Pools.require_capability(scope, Pools.capability(:pool_manage)) do
      do_update(ensure_scoped_settings(scope), put_scope(attrs, scope))
    end
  end

  @spec update_system_settings(settings(), map()) :: update_result()
  def update_system_settings(%Settings{} = settings, attrs) when is_map(attrs),
    do: do_update(settings, attrs)

  @spec update(Scope.t(), settings(), map()) :: update_result()
  def update(%Scope{} = scope, %Settings{} = settings, attrs) when is_map(attrs) do
    with {:ok, _decision} <- Pools.require_capability(scope, Pools.capability(:pool_manage)) do
      do_update(settings, put_scope(attrs, scope))
    end
  end

  @spec put_smtp_password(map(), binary()) :: map()
  def put_smtp_password(attrs, plaintext) when is_map(attrs) and is_binary(plaintext) do
    put_nested(attrs, :smtp, %{"password" => plaintext, "password_action" => "set"})
  end

  @spec preserve_smtp_password(map()) :: map()
  def preserve_smtp_password(attrs) when is_map(attrs) do
    put_nested(attrs, :smtp, %{"password" => nil, "password_action" => "preserve"})
  end

  @spec clear_smtp_password(map()) :: map()
  def clear_smtp_password(attrs) when is_map(attrs) do
    put_nested(attrs, :smtp, %{"password" => nil, "password_action" => "clear"})
  end

  @spec put_metrics_bearer_token(map(), binary()) :: map()
  def put_metrics_bearer_token(attrs, plaintext) when is_map(attrs) and is_binary(plaintext) do
    put_nested(attrs, :metrics, %{"bearer_token" => plaintext, "bearer_token_action" => "set"})
  end

  @spec preserve_metrics_bearer_token(map()) :: map()
  def preserve_metrics_bearer_token(attrs) when is_map(attrs) do
    put_nested(attrs, :metrics, %{"bearer_token" => nil, "bearer_token_action" => "preserve"})
  end

  @spec clear_metrics_bearer_token(map()) :: map()
  def clear_metrics_bearer_token(attrs) when is_map(attrs) do
    put_nested(attrs, :metrics, %{"bearer_token" => nil, "bearer_token_action" => "clear"})
  end

  @spec decrypt_smtp_password(settings()) :: {:ok, binary()} | {:error, map()}
  def decrypt_smtp_password(%Settings{} = settings), do: Settings.decrypt_smtp_password(settings)

  @spec test_smtp(map()) :: {:ok, map()} | {:error, Ecto.Changeset.t() | map()}
  def test_smtp(attrs) when is_map(attrs) do
    test_smtp(ensure_singleton!(), attrs)
  end

  @spec test_smtp(settings(), map()) :: {:ok, map()} | {:error, Ecto.Changeset.t() | map()}
  def test_smtp(%Settings{} = settings, attrs) when is_map(attrs) do
    attrs = strip_context_attrs(attrs)

    changeset = Settings.changeset(settings, attrs)

    case Ecto.Changeset.apply_action(changeset, :update) do
      {:ok, candidate} ->
        case MailerConfig.probe_options(candidate) do
          {:ok, nil} ->
            {:error, %{code: :smtp_disabled, message: "SMTP is disabled"}}

          {:ok, probe_options} ->
            Mailer.probe(probe_options)

          {:error, %{code: :invalid_mailer_config} = reason} ->
            {:error, reason}

          {:error, reason} when is_map(reason) ->
            {:error, reason}
        end

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  @spec send_smtp_test_email(map(), Scope.t()) ::
          {:ok, map()} | {:error, Ecto.Changeset.t() | map() | Pools.access_error()}
  def send_smtp_test_email(attrs, %Scope{} = scope) when is_map(attrs) do
    send_smtp_test_email(ensure_singleton!(), attrs, scope)
  end

  @spec send_smtp_test_email(settings(), map(), Scope.t()) ::
          {:ok, map()} | {:error, Ecto.Changeset.t() | map() | Pools.access_error()}
  def send_smtp_test_email(%Settings{} = settings, attrs, %Scope{} = scope) when is_map(attrs) do
    attrs = strip_context_attrs(attrs)

    changeset = Settings.changeset(settings, attrs)

    with {:ok, _decision} <- Pools.require_capability(scope, Pools.capability(:pool_manage)),
         {:ok, candidate} <- Ecto.Changeset.apply_action(changeset, :update),
         {:ok, recipient_email} <- smtp_test_operator_email(scope),
         {:ok, delivery_config} <- MailerConfig.from_settings(candidate),
         {:ok, delivery_config} <- smtp_test_delivery_config(delivery_config) do
      Mailer.send_smtp_test_email(recipient_email, delivery_config)
    else
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
      {:error, %{code: :invalid_mailer_config} = reason} -> {:error, reason}
      {:error, reason} when is_map(reason) -> {:error, reason}
    end
  end

  @spec metrics_token_matches?(settings(), binary()) :: boolean()
  def metrics_token_matches?(%Settings{} = settings, token),
    do: Settings.metrics_token_matches?(settings, token)

  @spec reset_cache_for_test() :: :ok
  def reset_cache_for_test, do: Cache.reset_for_test()

  @spec snapshot_cache_for_test() :: term()
  def snapshot_cache_for_test, do: Cache.snapshot_for_test()

  @spec restore_cache_for_test(term()) :: :ok
  def restore_cache_for_test(snapshot), do: Cache.restore_for_test(snapshot)

  defp ensure_scoped_settings(%Scope{}), do: ensure_singleton!()

  defp do_update(%Settings{} = settings, attrs) when is_map(attrs) do
    scope = extract_scope(attrs)
    attrs = attrs |> strip_context_attrs() |> put_updated_by(scope)
    before = Settings.mark_loaded(settings, :database)

    result =
      settings
      |> Settings.changeset(attrs)
      |> Repo.update(
        stale_error_field: :lock_version,
        stale_error_message: "was updated by another operator"
      )

    case result do
      {:ok, updated} ->
        updated = Settings.mark_loaded(updated, :database)
        _cache_result = Cache.put(updated)
        _ = Cache.broadcast_update(updated)
        record_update_audit(scope, before, updated)
        {:ok, updated}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp extract_scope(attrs) do
    Map.get(attrs, :current_scope) || Map.get(attrs, "current_scope") || Map.get(attrs, :scope) ||
      Map.get(attrs, "scope")
  end

  defp strip_context_attrs(attrs) do
    Map.drop(attrs, [:current_scope, "current_scope", :scope, "scope"])
  end

  defp put_scope(attrs, scope), do: Map.put(attrs, :current_scope, scope)

  defp put_updated_by(attrs, %Scope{user: %User{id: user_id}}) do
    key =
      if Enum.any?(Map.keys(attrs), &is_binary/1),
        do: "updated_by_user_id",
        else: :updated_by_user_id

    Map.put(attrs, key, user_id)
  end

  defp put_updated_by(attrs, _scope), do: attrs

  defp put_nested(attrs, group, values) do
    string_group = Atom.to_string(group)
    existing = Map.get(attrs, group) || Map.get(attrs, string_group) || %{}

    Map.put(attrs, string_group, Map.merge(existing, values))
  end

  defp smtp_test_delivery_config(nil) do
    {:error, %{code: :smtp_disabled, message: "SMTP is disabled"}}
  end

  defp smtp_test_delivery_config(%{adapter_config: [_ | _], from: from} = config)
       when is_binary(from) do
    {:ok, config}
  end

  defp smtp_test_delivery_config(_invalid) do
    {:error, %{code: :invalid_mailer_config, message: "SMTP from address must be configured"}}
  end

  defp smtp_test_operator_email(%Scope{user: %User{email: email}}) when is_binary(email) do
    case String.trim(email) do
      "" ->
        {:error,
         %{
           code: :smtp_test_email_recipient_missing,
           message: "Signed-in operator email is required for SMTP test email"
         }}

      trimmed ->
        {:ok, trimmed}
    end
  end

  defp smtp_test_operator_email(_scope) do
    {:error,
     %{
       code: :smtp_test_email_recipient_missing,
       message: "Signed-in operator email is required for SMTP test email"
     }}
  end

  defp record_update_audit(%Scope{user: %User{} = user}, before, after_update) do
    details = audit_details(before, after_update)

    if details.changed_keys == [] do
      :ok
    else
      Audit.record_user_event(user, %{
        action: "instance_settings.update",
        target_type: "instance_settings",
        target_id: nil,
        details: details
      })
    end
  end

  defp record_update_audit(_scope, _before, _after_update), do: :ok

  defp audit_details(before, after_update) do
    changed_groups =
      [
        :gateway,
        :ingress,
        :files,
        :transcription,
        :operator,
        :catalog,
        :development,
        :mcp,
        :metrics,
        :smtp
      ]
      |> Enum.filter(&(safe_group_map(before, &1) != safe_group_map(after_update, &1)))

    %{
      changed_categories: Enum.map(changed_groups, &Atom.to_string/1),
      changed_keys: changed_keys(before, after_update, changed_groups),
      credential_changes: credential_changes(before, after_update)
    }
  end

  defp changed_keys(before, after_update, groups) do
    groups
    |> Enum.flat_map(fn group ->
      before_map = safe_group_map(before, group)
      after_map = safe_group_map(after_update, group)

      (Map.keys(before_map) ++ Map.keys(after_map))
      |> Enum.uniq()
      |> Enum.filter(&(Map.get(before_map, &1) != Map.get(after_map, &1)))
      |> Enum.map(&"#{group}.#{&1}")
    end)
    |> Enum.sort()
  end

  defp safe_group_map(settings, :metrics) do
    metrics = settings.metrics || %{}

    %{
      "bearer_token_configured" => not is_nil(metrics.bearer_token_hmac_digest),
      "bearer_token_fingerprint" => metrics.bearer_token_fingerprint,
      "bearer_token_key_version" => metrics.bearer_token_key_version
    }
  end

  defp safe_group_map(settings, :smtp) do
    smtp = settings.smtp || %{}

    smtp
    |> Map.from_struct()
    |> Map.drop([
      :password,
      :password_action,
      :password_ciphertext,
      :password_nonce,
      :password_aad
    ])
    |> Map.put(:password_configured, not is_nil(smtp.password_ciphertext))
  end

  defp safe_group_map(settings, group) do
    settings
    |> Map.fetch!(group)
    |> Map.from_struct()
  end

  defp credential_changes(before, after_update) do
    %{
      metrics_auth_state:
        credential_change(
          before.metrics.bearer_token_hmac_digest,
          after_update.metrics.bearer_token_hmac_digest
        ),
      smtp_auth_state:
        credential_change(before.smtp.password_ciphertext, after_update.smtp.password_ciphertext),
      metrics_fingerprint: after_update.metrics.bearer_token_fingerprint,
      smtp_key_version: after_update.smtp.password_key_version
    }
  end

  defp credential_change(nil, nil), do: "unchanged_unset"
  defp credential_change(nil, configured) when is_binary(configured), do: "configured"
  defp credential_change(previous, nil) when is_binary(previous), do: "cleared"
  defp credential_change(previous, current) when previous == current, do: "unchanged_configured"
  defp credential_change(_previous, _current), do: "rotated"
end
