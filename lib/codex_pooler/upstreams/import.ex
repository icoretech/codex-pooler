defmodule CodexPooler.Upstreams.Import do
  @moduledoc false

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Pools
  alias CodexPooler.Pools.Pool

  alias CodexPooler.Upstreams.Auth.CodexAuthJson
  alias CodexPooler.Upstreams.Lifecycle.IdentityLifecycle
  alias CodexPooler.Upstreams.TokenLinking

  @type lifecycle_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type import_result ::
          {:ok, map()}
          | {:error,
             Ecto.Changeset.t() | lifecycle_error() | IdentityLifecycle.identity_conflict()}

  @spec import_codex_auth_json(term(), term(), binary()) :: import_result()
  def import_codex_auth_json(scope, pool, content) do
    case CodexAuthJson.parse(content) do
      {:ok, attrs} ->
        import_trusted_auth_json_account(scope, pool, attrs)

      {:error, %{message: message}} ->
        {:error, auth_json_import_changeset(content, content: message)}
    end
  end

  defp import_trusted_auth_json_account(scope, %Pool{} = pool, attrs) when is_map(attrs) do
    attrs = normalize_import_attrs(attrs)

    case import_validation_errors(attrs) do
      [] ->
        with :ok <- require_import_pool_operate(scope, pool) do
          do_import_codex_auth_json_account(scope, pool, attrs)
        end

      errors ->
        {:error, import_identity_changeset(attrs, errors)}
    end
  end

  defp import_trusted_auth_json_account(_scope, _pool, attrs) when is_map(attrs) do
    attrs = normalize_import_attrs(attrs)

    {:error, import_identity_changeset(attrs, pool_id: "must select an active Pool")}
  end

  defp require_import_pool_operate(%Scope{} = scope, %Pool{} = pool) do
    case Pools.require_capability(scope, Pools.capability(:pool_operate), pool_id: pool.id) do
      {:ok, _decision} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_import_codex_auth_json_account(%Scope{} = scope, %Pool{} = pool, attrs) do
    TokenLinking.link_tokens(scope, pool, attrs,
      onboarding_method: "import",
      audit_action: "upstream_account.import",
      broadcast_reason: "upstream_account_imported",
      quota_trigger_kind: "account_link",
      token_refresh_trigger_kind: "auth_json_import"
    )
  end

  defp normalize_import_attrs(attrs) do
    chatgpt_account_id =
      attrs
      |> import_value(:chatgpt_account_id)
      |> Kernel.||(import_value(attrs, :account_identifier))
      |> present_string()

    account_email = attrs |> import_value(:account_email) |> normalize_email()

    %{
      chatgpt_account_id: chatgpt_account_id,
      account_identifier: chatgpt_account_id || account_email,
      account_email: account_email,
      chatgpt_user_id: attrs |> import_value(:chatgpt_user_id) |> present_string(),
      account_label: attrs |> import_value(:account_label) |> present_string(),
      workspace_id: attrs |> import_value(:workspace_id) |> present_string(),
      workspace_label: attrs |> import_value(:workspace_label) |> present_string(),
      seat_type: attrs |> import_value(:seat_type) |> present_string(),
      pool_id: attrs |> import_value(:pool_id) |> present_string(),
      plan_label: attrs |> import_value(:plan_label) |> present_string(),
      token:
        attrs
        |> import_value(:token)
        |> Kernel.||(import_value(attrs, :access_token))
        |> present_string(),
      refresh_token: attrs |> import_value(:refresh_token) |> present_string(),
      access_token_expires_at:
        attrs
        |> import_value(:access_token_expires_at)
        |> parse_optional_datetime(),
      import_metadata:
        attrs
        |> import_value(:import_metadata)
        |> normalize_import_metadata()
    }
  end

  defp import_value(attrs, key) when is_map(attrs) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp import_validation_errors(attrs) do
    []
    |> maybe_add_error(blank?(attrs.account_identifier), :account_identifier, "is required")
    |> maybe_add_error(blank?(attrs.account_label), :account_label, "is required")
    |> maybe_add_error(blank?(attrs.token), :token, "is required")
  end

  defp import_identity_changeset(attrs, errors) do
    data = %{
      account_identifier: attrs[:account_identifier],
      account_label: attrs[:account_label],
      plan_label: attrs[:plan_label],
      pool_id: attrs[:pool_id],
      token: ""
    }

    {%{},
     %{
       account_identifier: :string,
       account_label: :string,
       plan_label: :string,
       pool_id: :string,
       token: :string
     }}
    |> Ecto.Changeset.cast(data, Map.keys(data))
    |> Map.put(:action, :insert)
    |> then(fn changeset ->
      Enum.reduce(errors, changeset, fn {field, message}, changeset ->
        Ecto.Changeset.add_error(changeset, field, message)
      end)
    end)
  end

  defp auth_json_import_changeset(_content, errors) do
    data = %{content: "", pool_id: nil}

    {%{}, %{content: :string, pool_id: :string}}
    |> Ecto.Changeset.cast(data, [:content, :pool_id])
    |> Map.put(:action, :insert)
    |> then(fn changeset ->
      Enum.reduce(errors, changeset, fn {field, message}, changeset ->
        Ecto.Changeset.add_error(changeset, field, message)
      end)
    end)
  end

  defp normalize_import_metadata(%{} = metadata) do
    metadata
    |> Enum.reduce(%{}, fn
      {key, value}, acc when is_binary(key) and is_binary(value) -> Map.put(acc, key, value)
      {key, value}, acc when is_binary(key) and is_boolean(value) -> Map.put(acc, key, value)
      {key, value}, acc when is_binary(key) and is_integer(value) -> Map.put(acc, key, value)
      {_key, _value}, acc -> acc
    end)
  end

  defp normalize_import_metadata(_metadata), do: %{}

  defp maybe_add_error(errors, true, field, message), do: [{field, message} | errors]
  defp maybe_add_error(errors, false, _field, _message), do: errors

  defp parse_optional_datetime(%DateTime{} = value), do: DateTime.truncate(value, :microsecond)
  defp parse_optional_datetime(nil), do: nil

  defp parse_optional_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :microsecond)
      _invalid -> nil
    end
  end

  defp parse_optional_datetime(_value), do: nil

  defp present_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp present_string(_value), do: nil

  defp normalize_email(value) do
    value
    |> present_string()
    |> case do
      nil -> nil
      email -> String.downcase(email)
    end
  end

  defp blank?(value), do: is_nil(value) or value == ""
end
