defmodule CodexPooler.Upstreams.TokenLinking do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Events
  alias CodexPooler.Jobs
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Lifecycle.AccountAudit
  alias CodexPooler.Upstreams.Lifecycle.IdentityLifecycle
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}
  alias CodexPooler.Upstreams.Secrets

  @active UpstreamIdentity.active_status()
  @pending UpstreamIdentity.pending_status()
  @assignment_active PoolUpstreamAssignment.active_status()
  @eligible PoolUpstreamAssignment.eligible_status()
  @health_active PoolUpstreamAssignment.active_health_status()
  @identity_mismatch_message "OAuth account does not match the selected upstream account"

  @type lifecycle_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type link_success :: %{
          required(:status) => atom(),
          required(:identity) => UpstreamIdentity.t(),
          required(:assignment) => PoolUpstreamAssignment.t(),
          required(:secret_status) => atom()
        }
  @type link_result ::
          {:ok, link_success()}
          | {:error,
             Ecto.Changeset.t() | lifecycle_error() | IdentityLifecycle.identity_conflict()}

  @spec link_tokens(Scope.t(), Pool.t(), map(), keyword()) :: link_result()
  def link_tokens(scope, pool, attrs, opts \\ [])

  def link_tokens(%Scope{} = scope, %Pool{} = pool, attrs, opts)
      when is_map(attrs) and is_list(opts) do
    attrs = normalize_link_attrs(attrs, opts)

    case validate_link_target(attrs) do
      :ok -> link_tokens_transaction(scope, pool, attrs, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  def link_tokens(_scope, _pool, _attrs, _opts),
    do: {:error, lifecycle_error(:invalid_request, "token linking request is invalid")}

  defp link_tokens_transaction(%Scope{} = scope, %Pool{} = pool, attrs, opts) do
    case Repo.transaction(fn -> persist_link_tokens(scope, pool, attrs) end) do
      {:ok, result} ->
        {:ok, result}
        |> tap_audit(scope, pool, opts)
        |> tap_quota_priming(opts)
        |> tap_upstream_change(opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp persist_link_tokens(%Scope{} = scope, %Pool{} = pool, attrs) do
    with {:ok, identity_status, identity} <- upsert_link_identity(scope, attrs),
         {:ok, _secret} <-
           Secrets.store_encrypted_secret(identity, %{
             secret_kind: "access_token",
             plaintext: attrs.token
           }),
         {:ok, _refresh_secret} <- maybe_store_refresh_token(identity, attrs),
         {:ok, assignment_status, assignment} <-
           upsert_link_assignment(scope, pool, identity, attrs) do
      %{
        status: link_result_status(identity_status, assignment_status),
        identity: Repo.reload!(identity),
        assignment: Repo.reload!(assignment),
        secret_status: Secrets.secret_status(identity)
      }
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp upsert_link_identity(%Scope{} = scope, attrs) do
    timestamp = now()

    metadata =
      %{
        attrs.actor_metadata_key => scope.user.id,
        "onboarding_method" => attrs.onboarding_method
      }
      |> Map.merge(attrs.identity_metadata || %{})

    identity_attrs =
      attrs
      |> incoming_identity_attrs()
      |> Map.merge(%{
        onboarding_method: attrs.onboarding_method,
        auth_verified_at: timestamp,
        auth_fresh_at: timestamp,
        disabled_at: nil,
        created_by_user_id: scope.user.id,
        metadata: link_identity_metadata(metadata, attrs)
      })

    case select_link_identity(attrs, identity_attrs) do
      {:error, reason} ->
        {:error, reason}

      {:ok, %UpstreamIdentity{} = identity} ->
        attrs =
          Map.update!(identity_attrs, :metadata, fn link_metadata ->
            link_metadata
            |> put_token_refresh_metadata(identity.metadata, timestamp, attrs)
            |> then(&Map.merge(identity.metadata || %{}, &1))
          end)
          |> Map.put(:account_label, identity.account_label)
          |> preserve_operator_workspace_slot(identity, attrs)

        with {:ok, active_identity} <- activate_identity_with_plan(identity, attrs) do
          {:ok, :existing, active_identity}
        end

      {:ok, nil} ->
        identity_attrs =
          Map.update!(identity_attrs, :metadata, fn link_metadata ->
            put_token_refresh_metadata(link_metadata, %{}, timestamp, attrs)
          end)

        with {:ok, identity} <-
               create_identity_with_plan(Map.put(identity_attrs, :status, @pending)),
             {:ok, active_identity} <- activate_identity_with_plan(identity, identity_attrs) do
          {:ok, :created, active_identity}
        end
    end
  end

  defp upsert_link_assignment(
         %Scope{} = scope,
         %Pool{} = pool,
         %UpstreamIdentity{} = identity,
         attrs
       ) do
    timestamp = now()

    metadata = %{
      attrs.actor_metadata_key => scope.user.id,
      "onboarding_method" => attrs.onboarding_method
    }

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
          assignment_attrs
          |> maybe_preserve_relink_assignment_label(assignment, attrs)
          |> Map.update!(:metadata, &Map.merge(assignment.metadata || %{}, &1))

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

  defp link_result_status(:created, :created), do: :created
  defp link_result_status(_identity_status, _assignment_status), do: :existing

  defp maybe_store_refresh_token(_identity, %{refresh_token: nil}), do: {:ok, nil}

  defp maybe_store_refresh_token(identity, %{refresh_token: refresh_token}) do
    Secrets.store_encrypted_secret(identity, %{
      secret_kind: "refresh_token",
      plaintext: refresh_token
    })
  end

  defp link_identity_metadata(metadata, %{access_token_expires_at: %DateTime{} = expires_at}) do
    Map.put(metadata, "access_token_expires_at", DateTime.to_iso8601(expires_at))
  end

  defp link_identity_metadata(metadata, _attrs), do: metadata

  defp put_token_refresh_metadata(link_metadata, existing_metadata, timestamp, attrs) do
    generation =
      existing_metadata
      |> token_refresh_metadata()
      |> Map.get("generation", 0)
      |> next_token_refresh_generation()

    Map.put(link_metadata || %{}, "token_refresh", %{
      "status" => "imported",
      "generation" => generation,
      "trigger_kind" => attrs.token_refresh_trigger_kind,
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

  defp trusted_plan_metadata(attrs) do
    %{plan_family: plan_family(attrs.plan_label), plan_label: attrs.plan_label}
  end

  defp tap_audit({:ok, result}, %Scope{} = scope, %Pool{} = pool, opts) do
    case Keyword.get(opts, :audit_action) do
      action when is_binary(action) ->
        {:ok, {result, pool}}
        |> AccountAudit.record_change(scope, action)

      _action ->
        {:ok, result}
    end
  end

  defp tap_quota_priming(
         {:ok, %{assignment: %PoolUpstreamAssignment{} = assignment} = result},
         opts
       ) do
    case Keyword.get(opts, :quota_trigger_kind) do
      trigger_kind when is_binary(trigger_kind) ->
        _job =
          Jobs.enqueue_assignment_priming(assignment.pool_id, assignment,
            trigger_kind: trigger_kind
          )

        {:ok, %{result | assignment: Repo.reload!(assignment)}}

      _trigger_kind ->
        {:ok, result}
    end
  end

  defp tap_quota_priming(result, _opts), do: result

  defp tap_upstream_change({:ok, result} = ok, opts) do
    case Keyword.get(opts, :broadcast_reason) do
      reason when is_binary(reason) -> broadcast_upstream_change(result, reason)
      _reason -> :ok
    end

    ok
  end

  defp tap_upstream_change(result, _opts), do: result

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

  defp normalize_link_attrs(attrs, opts) do
    %{
      chatgpt_account_id: Map.get(attrs, :chatgpt_account_id),
      account_email: Map.get(attrs, :account_email),
      account_label: Map.get(attrs, :account_label),
      workspace_id: Map.get(attrs, :workspace_id),
      workspace_label: Map.get(attrs, :workspace_label),
      seat_type: Map.get(attrs, :seat_type),
      plan_label: Map.get(attrs, :plan_label),
      token: Map.get(attrs, :token) || Map.get(attrs, :access_token),
      refresh_token: Map.get(attrs, :refresh_token),
      access_token_expires_at: Map.get(attrs, :access_token_expires_at),
      identity_metadata:
        Map.get(attrs, :import_metadata) || Map.get(attrs, :identity_metadata) || %{},
      onboarding_method:
        Keyword.get(opts, :onboarding_method, Map.get(attrs, :onboarding_method, "import")),
      actor_metadata_key: Keyword.get(opts, :actor_metadata_key, "imported_by_user_id"),
      token_refresh_trigger_kind:
        Keyword.get(opts, :token_refresh_trigger_kind, "auth_json_import"),
      target_identity_id: target_identity_id(opts)
    }
  end

  defp incoming_identity_attrs(attrs) do
    %{
      chatgpt_account_id: attrs.chatgpt_account_id,
      account_email: attrs.account_email,
      account_label: attrs.account_label,
      workspace_id: attrs.workspace_id,
      workspace_label: attrs.workspace_label,
      seat_type: attrs.seat_type
    }
    |> Map.merge(trusted_plan_metadata(attrs))
  end

  @spec validate_link_target(map()) ::
          :ok | {:error, lifecycle_error() | IdentityLifecycle.identity_conflict()}
  defp validate_link_target(%{target_identity_id: target_identity_id} = attrs)
       when is_binary(target_identity_id) do
    case select_link_identity(attrs, incoming_identity_attrs(attrs)) do
      {:ok, _identity} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_link_target(_attrs), do: :ok

  @spec select_link_identity(map(), map()) ::
          {:ok, UpstreamIdentity.t() | nil}
          | {:error, lifecycle_error() | IdentityLifecycle.identity_conflict()}
  defp select_link_identity(%{target_identity_id: target_identity_id}, identity_attrs)
       when is_binary(target_identity_id) do
    case Repo.get(UpstreamIdentity, target_identity_id) do
      %UpstreamIdentity{} = target_identity ->
        validate_target_link_identity(target_identity, identity_attrs)

      nil ->
        {:error, identity_mismatch_error()}
    end
  end

  defp select_link_identity(_attrs, identity_attrs) do
    IdentityLifecycle.select_upsert_identity(identity_attrs)
  end

  @spec validate_target_link_identity(UpstreamIdentity.t(), map()) ::
          {:ok, UpstreamIdentity.t()}
          | {:error, lifecycle_error() | IdentityLifecycle.identity_conflict()}
  defp validate_target_link_identity(%UpstreamIdentity{} = target_identity, identity_attrs) do
    with :ok <- validate_target_account(target_identity, identity_attrs),
         :ok <- validate_target_workspace(target_identity, identity_attrs) do
      {:ok, target_identity}
    end
  end

  @spec validate_target_account(UpstreamIdentity.t(), map()) ::
          :ok | {:error, lifecycle_error()}
  defp validate_target_account(%UpstreamIdentity{} = target_identity, identity_attrs) do
    target_account_id = present_string(target_identity.chatgpt_account_id)
    incoming_account_id = identity_attrs |> Map.get(:chatgpt_account_id) |> present_string()

    target_email = normalize_email(target_identity.account_email)
    incoming_email = identity_attrs |> Map.get(:account_email) |> normalize_email()

    cond do
      present_mismatch?(target_account_id, incoming_account_id) ->
        {:error, identity_mismatch_error()}

      is_binary(target_account_id) and is_nil(incoming_account_id) ->
        {:error, identity_mismatch_error()}

      is_nil(target_account_id) and present_mismatch?(target_email, incoming_email) ->
        {:error, identity_mismatch_error()}

      true ->
        :ok
    end
  end

  @spec validate_target_workspace(UpstreamIdentity.t(), map()) ::
          :ok | {:error, lifecycle_error() | IdentityLifecycle.identity_conflict()}
  defp validate_target_workspace(%UpstreamIdentity{} = target_identity, identity_attrs) do
    target_workspace_id = present_string(target_identity.workspace_id)
    incoming_workspace_id = identity_attrs |> Map.get(:workspace_id) |> present_string()
    incoming_account_id = identity_attrs |> Map.get(:chatgpt_account_id) |> present_string()

    cond do
      is_binary(target_workspace_id) and incoming_workspace_id == target_workspace_id ->
        :ok

      is_binary(target_workspace_id) and is_nil(incoming_workspace_id) and
          operator_workspace_slot?(target_identity) ->
        :ok

      is_binary(target_workspace_id) ->
        {:error, identity_mismatch_error()}

      exact_workspace_identity?(target_identity, incoming_account_id, incoming_workspace_id) ->
        {:error, identity_mismatch_error()}

      concrete_sibling_identity?(target_identity, incoming_account_id) ->
        {:error,
         identity_conflict(
           identity_attrs,
           first_concrete_sibling(target_identity, incoming_account_id)
         )}

      is_nil(incoming_workspace_id) ->
        :ok

      true ->
        :ok
    end
  end

  defp maybe_preserve_relink_assignment_label(assignment_attrs, assignment, %{
         target_identity_id: target_identity_id
       })
       when is_binary(target_identity_id) do
    Map.put(
      assignment_attrs,
      :assignment_label,
      assignment.assignment_label || assignment_attrs.assignment_label
    )
  end

  defp maybe_preserve_relink_assignment_label(assignment_attrs, _assignment, _attrs),
    do: assignment_attrs

  defp preserve_operator_workspace_slot(identity_attrs, identity, %{target_identity_id: target_id})
       when is_binary(target_id) do
    if operator_workspace_slot?(identity) and is_nil(present_string(Map.get(identity_attrs, :workspace_id))) do
      identity_attrs
      |> Map.put(:workspace_id, identity.workspace_id)
      |> Map.put(:workspace_label, identity.workspace_label)
      |> Map.put(:seat_type, identity.seat_type)
    else
      identity_attrs
    end
  end

  defp preserve_operator_workspace_slot(identity_attrs, _identity, _attrs), do: identity_attrs

  defp exact_workspace_identity?(%UpstreamIdentity{id: target_id}, account_id, workspace_id) do
    case IdentityLifecycle.get_upstream_identity_by_chatgpt_account_and_workspace(
           account_id,
           workspace_id
         ) do
      %UpstreamIdentity{id: ^target_id} -> false
      %UpstreamIdentity{} -> true
      nil -> false
    end
  end

  defp concrete_sibling_identity?(target_identity, account_id) do
    not is_nil(first_concrete_sibling(target_identity, account_id))
  end

  defp first_concrete_sibling(%UpstreamIdentity{id: target_id}, account_id) do
    account_id
    |> IdentityLifecycle.list_upstream_identities_by_chatgpt_account()
    |> Enum.find(fn
      %UpstreamIdentity{id: ^target_id} ->
        false

      %UpstreamIdentity{} = identity ->
        not is_nil(present_string(identity.workspace_id))
    end)
  end

  defp operator_workspace_slot?(%UpstreamIdentity{metadata: metadata, workspace_id: workspace_id}) do
    present_string(workspace_id) != nil and
      is_map(metadata) and metadata["workspace_slot_source"] == "operator_override"
  end

  defp target_identity_id(opts) do
    case Keyword.get(opts, :target_identity_id) do
      target_identity_id when is_binary(target_identity_id) ->
        target_identity_id

      _target_identity_id ->
        case Keyword.get(opts, :target_identity) do
          %UpstreamIdentity{id: target_identity_id} when is_binary(target_identity_id) ->
            target_identity_id

          _target_identity ->
            nil
        end
    end
  end

  defp identity_conflict(attrs, %UpstreamIdentity{} = stored_identity) do
    IdentityLifecycle.identity_conflict(attrs, stored_identity)
  end

  defp identity_conflict(attrs, _stored_identity),
    do: IdentityLifecycle.identity_conflict(attrs, nil)

  defp plan_family(nil), do: nil
  defp plan_family(label), do: normalize_plan(label)

  defp normalize_plan(plan) do
    plan
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp put_default(map, key, value) do
    case Map.get(map, key) do
      nil -> Map.put(map, key, value)
      _value -> map
    end
  end

  defp identity_mismatch_error,
    do: lifecycle_error(:identity_mismatch, @identity_mismatch_message)

  defp lifecycle_error(code, message), do: %{code: code, message: message}

  defp present_mismatch?(left, right), do: is_binary(left) and is_binary(right) and left != right

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

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
