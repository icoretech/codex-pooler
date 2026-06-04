defmodule CodexPooler.Upstreams.Import do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Events
  alias CodexPooler.Jobs
  alias CodexPooler.Pools
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo

  alias CodexPooler.Upstreams.Auth.CodexAuthJson
  alias CodexPooler.Upstreams.Lifecycle.AccountAudit
  alias CodexPooler.Upstreams.Lifecycle.IdentityLifecycle
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}
  alias CodexPooler.Upstreams.Secrets
  @active UpstreamIdentity.active_status()
  @pending UpstreamIdentity.pending_status()
  @assignment_active PoolUpstreamAssignment.active_status()
  @eligible PoolUpstreamAssignment.eligible_status()
  @health_active PoolUpstreamAssignment.active_health_status()

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
    Repo.transaction(fn ->
      with {:ok, identity_status, identity} <- upsert_import_identity(scope, attrs),
           {:ok, _secret} <-
             Secrets.store_encrypted_secret(identity, %{
               secret_kind: "access_token",
               plaintext: attrs.token
             }),
           {:ok, _refresh_secret} <- maybe_store_import_refresh_token(identity, attrs),
           {:ok, assignment_status, assignment} <- upsert_import_assignment(scope, pool, identity) do
        %{
          status: import_result_status(identity_status, assignment_status),
          identity: Repo.reload!(identity),
          assignment: Repo.reload!(assignment),
          secret_status: Secrets.secret_status(identity)
        }
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, result} ->
        {:ok, {result, pool}}
        |> AccountAudit.record_change(scope, "upstream_account.import")
        |> tap_import_quota_priming()
        |> tap_upstream_change("upstream_account_imported")

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp upsert_import_identity(%Scope{} = scope, attrs) do
    timestamp = now()

    metadata =
      Map.merge(
        %{"imported_by_user_id" => scope.user.id, "onboarding_method" => "import"},
        attrs.import_metadata || %{}
      )

    identity_attrs =
      %{
        chatgpt_account_id: attrs.chatgpt_account_id,
        account_email: attrs.account_email,
        account_label: attrs.account_label,
        workspace_id: attrs.workspace_id,
        workspace_label: attrs.workspace_label,
        seat_type: attrs.seat_type,
        onboarding_method: "import",
        auth_verified_at: timestamp,
        auth_fresh_at: timestamp,
        disabled_at: nil,
        created_by_user_id: scope.user.id,
        metadata: import_identity_metadata(metadata, attrs)
      }
      |> Map.merge(trusted_import_plan_metadata(attrs))

    case IdentityLifecycle.select_upsert_identity(identity_attrs) do
      {:error, reason} ->
        {:error, reason}

      {:ok, %UpstreamIdentity{} = identity} ->
        attrs =
          Map.update!(identity_attrs, :metadata, fn import_metadata ->
            import_metadata
            |> put_imported_token_refresh_metadata(identity.metadata, timestamp)
            |> then(&Map.merge(identity.metadata || %{}, &1))
          end)

        with {:ok, active_identity} <- activate_identity_with_plan(identity, attrs) do
          {:ok, :existing, active_identity}
        end

      {:ok, nil} ->
        identity_attrs =
          Map.update!(identity_attrs, :metadata, fn import_metadata ->
            put_imported_token_refresh_metadata(import_metadata, %{}, timestamp)
          end)

        with {:ok, identity} <-
               create_identity_with_plan(Map.put(identity_attrs, :status, @pending)),
             {:ok, active_identity} <- activate_identity_with_plan(identity, identity_attrs) do
          {:ok, :created, active_identity}
        end
    end
  end

  defp upsert_import_assignment(%Scope{} = scope, %Pool{} = pool, %UpstreamIdentity{} = identity) do
    timestamp = now()
    metadata = %{"imported_by_user_id" => scope.user.id, "onboarding_method" => "import"}

    assignment_attrs = %{
      assignment_label: identity.account_label,
      status: @assignment_active,
      health_status: @health_active,
      eligibility_status: @eligible,
      cooldown_until: nil,
      disabled_at: nil,
      created_by_user_id: scope.user.id,
      updated_at: timestamp,
      metadata: metadata,
      skip_quota_priming: true
    }

    case assignment_for_pool_identity(pool, identity) do
      %PoolUpstreamAssignment{} = assignment ->
        attrs =
          Map.update!(assignment_attrs, :metadata, &Map.merge(assignment.metadata || %{}, &1))

        with {:ok, assignment} <- update_pool_assignment(assignment, attrs) do
          {:ok, :existing, assignment}
        end

      nil ->
        with {:ok, assignment} <- create_pool_assignment(pool, identity, assignment_attrs) do
          {:ok, :created, assignment}
        end
    end
  end

  defp create_identity_with_plan(attrs) when is_map(attrs) do
    now = now()

    attrs
    |> put_default(:headers_profile_version, 1)
    |> put_default(:metadata, %{})
    |> put_default(:created_at, now)
    |> put_default(:updated_at, now)
    |> then(&UpstreamIdentity.changeset(%UpstreamIdentity{}, &1))
    |> Repo.insert()
  end

  defp activate_identity_with_plan(%UpstreamIdentity{} = identity, attrs) do
    timestamp = now()

    attrs =
      attrs
      |> Map.merge(%{
        status: @active,
        auth_verified_at: Map.get(attrs, :auth_verified_at, timestamp),
        auth_fresh_at: Map.get(attrs, :auth_fresh_at, timestamp),
        disabled_at: nil,
        updated_at: timestamp
      })

    identity
    |> UpstreamIdentity.changeset(attrs)
    |> Repo.update()
  end

  defp create_pool_assignment(%Pool{} = pool, %UpstreamIdentity{} = identity, attrs) do
    now = now()

    attrs =
      attrs
      |> Map.put(:pool_id, pool.id)
      |> Map.put(:upstream_identity_id, identity.id)
      |> put_default(:status, PoolUpstreamAssignment.pending_status())
      |> put_default(:health_status, PoolUpstreamAssignment.unknown_health_status())
      |> put_default(:eligibility_status, PoolUpstreamAssignment.ineligible_status())
      |> put_default(:metadata, %{})
      |> put_default(:created_at, now)
      |> put_default(:updated_at, now)

    %PoolUpstreamAssignment{}
    |> PoolUpstreamAssignment.changeset(attrs)
    |> Repo.insert()
  end

  defp update_pool_assignment(%PoolUpstreamAssignment{} = assignment, attrs) do
    attrs = Map.put(attrs, :updated_at, Map.get(attrs, :updated_at, now()))

    assignment
    |> PoolUpstreamAssignment.changeset(attrs)
    |> Repo.update()
  end

  defp assignment_for_pool_identity(%Pool{id: pool_id}, %UpstreamIdentity{id: identity_id}) do
    Repo.one(
      from assignment in PoolUpstreamAssignment,
        where: assignment.pool_id == ^pool_id and assignment.upstream_identity_id == ^identity_id,
        limit: 1
    )
  end

  defp import_result_status(:created, :created), do: :created
  defp import_result_status(_identity_status, _assignment_status), do: :existing

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

  defp maybe_store_import_refresh_token(_identity, %{refresh_token: nil}), do: {:ok, nil}

  defp maybe_store_import_refresh_token(identity, %{refresh_token: refresh_token}) do
    Secrets.store_encrypted_secret(identity, %{
      secret_kind: "refresh_token",
      plaintext: refresh_token
    })
  end

  defp import_identity_metadata(metadata, %{access_token_expires_at: %DateTime{} = expires_at}) do
    Map.put(metadata, "access_token_expires_at", DateTime.to_iso8601(expires_at))
  end

  defp import_identity_metadata(metadata, _attrs), do: metadata

  defp put_imported_token_refresh_metadata(import_metadata, existing_metadata, timestamp) do
    generation =
      existing_metadata
      |> token_refresh_metadata()
      |> Map.get("generation", 0)
      |> next_token_refresh_generation()

    Map.put(import_metadata || %{}, "token_refresh", %{
      "status" => "imported",
      "generation" => generation,
      "trigger_kind" => "auth_json_import",
      "imported_at" => DateTime.to_iso8601(timestamp)
    })
  end

  defp token_refresh_metadata(%{} = metadata) do
    case Map.get(metadata, "token_refresh") do
      %{} = token_refresh -> token_refresh
      _value -> %{}
    end
  end

  defp token_refresh_metadata(_metadata), do: %{}

  defp next_token_refresh_generation(generation) when is_integer(generation) and generation >= 0,
    do: generation + 1

  defp next_token_refresh_generation(_generation), do: 1

  defp trusted_import_plan_metadata(attrs) do
    %{plan_family: plan_family(attrs.plan_label), plan_label: attrs.plan_label}
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

  defp plan_family(nil), do: nil
  defp plan_family(label), do: normalize_plan(label)

  defp normalize_plan(plan) do
    plan
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp parse_optional_datetime(%DateTime{} = value), do: DateTime.truncate(value, :microsecond)
  defp parse_optional_datetime(nil), do: nil

  defp parse_optional_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :microsecond)
      _invalid -> nil
    end
  end

  defp parse_optional_datetime(_value), do: nil

  defp tap_upstream_change({:ok, result} = ok, reason) do
    broadcast_upstream_change(result, reason)
    ok
  end

  defp tap_upstream_change(result, _reason), do: result

  defp tap_import_quota_priming(
         {:ok, %{assignment: %PoolUpstreamAssignment{} = assignment} = result}
       ) do
    _job =
      Jobs.enqueue_assignment_priming(assignment.pool_id, assignment,
        trigger_kind: "account_link"
      )

    {:ok, %{result | assignment: Repo.reload!(assignment)}}
  end

  defp tap_import_quota_priming(result), do: result

  defp broadcast_upstream_change(%{assignment: %PoolUpstreamAssignment{} = assignment}, reason) do
    Events.broadcast_upstreams(assignment.pool_id, reason, %{
      assignment_id: assignment.id,
      upstream_identity_id: assignment.upstream_identity_id,
      upstream_status: assignment_status_identity_id(assignment),
      assignment_status: assignment.status
    })
  end

  defp broadcast_upstream_change(_result, _reason), do: :ok

  defp assignment_status_identity_id(%PoolUpstreamAssignment{upstream_identity_id: identity_id}) do
    case Repo.get(UpstreamIdentity, identity_id) do
      %UpstreamIdentity{} = identity -> identity.status
      nil -> nil
    end
  end

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

  defp put_default(map, key, value) do
    case Map.get(map, key) do
      nil -> Map.put(map, key, value)
      _value -> map
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
