defmodule CodexPooler.Upstreams.TokenLinking do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Events
  alias CodexPooler.Jobs
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Auth.TokenRefreshMetadata
  alias CodexPooler.Upstreams.Lifecycle.AccountAudit
  alias CodexPooler.Upstreams.Lifecycle.CredentialFencing
  alias CodexPooler.Upstreams.Lifecycle.IdentityLifecycle
  alias CodexPooler.Upstreams.Lifecycle.IdentitySlotLock
  alias CodexPooler.Upstreams.PreparedAccount
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}
  alias CodexPooler.Upstreams.Secrets
  alias CodexPooler.Upstreams.StatusVocabulary.Assignment, as: AssignmentStatus
  alias CodexPooler.Upstreams.StatusVocabulary.Identity, as: IdentityStatus

  @active IdentityStatus.active_status()
  @pending IdentityStatus.pending_status()
  @assignment_active AssignmentStatus.active_status()
  @eligible AssignmentStatus.eligible_status()
  @assignment_deleted AssignmentStatus.deleted_status()
  @health_active AssignmentStatus.active_health_status()
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
    case PreparedAccount.prepare(scope, pool, attrs, opts) do
      {:ok, prepared} ->
        case validate_link_target(pool, prepared.attrs) do
          :ok -> link_prepared(scope, pool, prepared, opts)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def link_tokens(_scope, _pool, _attrs, _opts),
    do: {:error, lifecycle_error(:invalid_request, "token linking request is invalid")}

  @spec link_tokens_in_transaction(Scope.t(), Pool.t(), map(), keyword()) :: link_result()
  def link_tokens_in_transaction(scope, pool, attrs, opts \\ [])

  def link_tokens_in_transaction(%Scope{} = scope, %Pool{} = pool, attrs, opts)
      when is_map(attrs) and is_list(opts) do
    if Repo.in_transaction?() do
      case PreparedAccount.prepare(scope, pool, attrs, opts) do
        {:ok, prepared} -> link_prepared_in_transaction(scope, pool, prepared, opts)
        {:error, reason} -> {:error, reason}
      end
    else
      {:error,
       lifecycle_error(
         :transaction_required,
         "token linking requires a caller-owned transaction"
       )}
    end
  end

  def link_tokens_in_transaction(_scope, _pool, _attrs, _opts),
    do: {:error, lifecycle_error(:invalid_request, "token linking request is invalid")}

  @spec link_prepared(Scope.t(), Pool.t(), PreparedAccount.t(), keyword()) :: link_result()
  def link_prepared(%Scope{} = scope, %Pool{} = pool, %PreparedAccount{} = prepared, opts)
      when is_list(opts) do
    case Repo.transaction(fn -> persist_prepared!(scope, pool, prepared, false) end) do
      {:ok, result} -> publish_link_result(scope, pool, result, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  def link_prepared(_scope, _pool, _prepared, _opts),
    do: {:error, lifecycle_error(:invalid_request, "token linking request is invalid")}

  @spec link_prepared_in_transaction(
          Scope.t(),
          Pool.t(),
          PreparedAccount.t(),
          keyword()
        ) :: link_result()
  def link_prepared_in_transaction(scope, pool, prepared, opts \\ [])

  def link_prepared_in_transaction(
        %Scope{} = scope,
        %Pool{} = pool,
        %PreparedAccount{} = prepared,
        opts
      )
      when is_list(opts) do
    if Repo.in_transaction?() do
      {:ok, persist_prepared!(scope, pool, prepared, Keyword.get(opts, :slots_locked?, false))}
    else
      {:error,
       lifecycle_error(:transaction_required, "token linking requires a caller-owned transaction")}
    end
  end

  def link_prepared_in_transaction(_scope, _pool, _prepared, _opts),
    do: {:error, lifecycle_error(:invalid_request, "token linking request is invalid")}

  @spec publish_link_result(Scope.t(), Pool.t(), link_success(), keyword()) :: link_result()
  def publish_link_result(%Scope{} = scope, %Pool{} = pool, %{} = result, opts)
      when is_list(opts) do
    {:ok, result}
    |> tap_audit(scope, pool, opts)
    |> tap_quota_priming(opts)
    |> tap_upstream_change(opts)
  end

  def publish_link_result(_scope, _pool, _result, _opts),
    do: {:error, lifecycle_error(:invalid_request, "token linking result is invalid")}

  @spec persist_prepared(Scope.t(), Pool.t(), PreparedAccount.t(), boolean()) ::
          {:ok, link_success()} | {:error, term()}
  def persist_prepared(scope, pool, prepared, slots_locked? \\ false) do
    with {:ok, prepared} <- PreparedAccount.validate(prepared, scope, pool),
         attrs = prepared.attrs,
         :ok <- maybe_lock_slots(attrs, slots_locked?),
         :ok <- validate_link_target(pool, attrs),
         {:ok, identity_status, identity, recovery_relink?} <-
           upsert_link_identity(scope, prepared),
         {:ok, _secret} <-
           Secrets.store_encrypted_secret(identity, %{
             secret_kind: "access_token",
             plaintext: attrs.token
           }),
         {:ok, _refresh_secret} <- maybe_store_refresh_token(identity, attrs),
         {:ok, assignment_status, assignment} <-
           upsert_link_assignment(
             scope,
             pool,
             identity,
             attrs,
             nil,
             recovery_relink?
           ) do
      {:ok,
       %{
         status: link_result_status(identity_status, assignment_status),
         identity: Repo.reload!(identity),
         assignment: Repo.reload!(assignment),
         secret_status: Secrets.secret_status(identity)
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_prepared!(scope, pool, prepared, slots_locked?) do
    case persist_prepared(scope, pool, prepared, slots_locked?) do
      {:ok, result} -> result
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp maybe_lock_slots(_attrs, true), do: :ok
  defp maybe_lock_slots(attrs, false), do: IdentitySlotLock.lock_slots!([attrs]) && :ok

  defp upsert_link_identity(%Scope{} = scope, %PreparedAccount{attrs: attrs} = prepared) do
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
        credential_provenance: attrs.credential_provenance,
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
        identity = CredentialFencing.lock_credential_replacement(identity)

        with {:ok, replacement_metadata, epoch} <-
               CredentialFencing.prepare_replacement_metadata(identity),
             :ok <- PreparedAccount.evaluate(prepared, now()),
             attrs =
               existing_identity_replacement_attrs(
                 identity_attrs,
                 identity,
                 replacement_metadata,
                 timestamp,
                 prepared,
                 epoch
               ),
             {:ok, active_identity} <- activate_identity_with_plan(identity, attrs) do
          {:ok, :existing, active_identity, identity.status == "reauth_required"}
        end

      {:ok, nil} ->
        with :ok <- PreparedAccount.evaluate(prepared, now()),
             identity_attrs = new_identity_replacement_attrs(identity_attrs, prepared, timestamp),
             {:ok, identity} <-
               create_identity_with_plan(Map.put(identity_attrs, :status, @pending)),
             {:ok, active_identity} <- activate_identity_with_plan(identity, identity_attrs) do
          {:ok, :created, active_identity, false}
        end
    end
  end

  defp new_identity_replacement_attrs(identity_attrs, prepared, timestamp) do
    Map.update!(identity_attrs, :metadata, fn link_metadata ->
      link_metadata
      |> CredentialFencing.initialize_metadata()
      |> TokenRefreshMetadata.build_imported(
        prepared.expiry,
        1,
        prepared.attrs.token_refresh_trigger_kind,
        timestamp
      )
    end)
  end

  defp existing_identity_replacement_attrs(
         identity_attrs,
         identity,
         replacement_metadata,
         timestamp,
         prepared,
         epoch
       ) do
    identity_attrs
    |> Map.update!(:metadata, fn link_metadata ->
      existing_link_metadata(
        replacement_metadata,
        link_metadata,
        timestamp,
        prepared.attrs,
        prepared.expiry,
        epoch
      )
    end)
    |> maybe_preserve_missing_workspace_slot(identity)
    |> Map.put(:account_label, identity.account_label)
  end

  defp upsert_link_assignment(
         %Scope{} = scope,
         %Pool{} = pool,
         %UpstreamIdentity{} = identity,
         attrs,
         locked_assignment,
         recovery_relink?
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
      eligibility_status: relink_eligibility_status(recovery_relink?),
      cooldown_until: nil,
      disabled_at: nil,
      created_by_user_id: scope.user.id,
      updated_at: timestamp,
      metadata: metadata,
      skip_quota_priming: true
    }

    case locked_assignment || assignment_for_pool_identity(pool, identity) do
      %PoolUpstreamAssignment{status: @assignment_deleted}
      when is_binary(attrs.target_identity_id) ->
        {:error, identity_mismatch_error()}

      %PoolUpstreamAssignment{} = assignment ->
        attrs =
          assignment_attrs
          |> maybe_preserve_relink_assignment_label(assignment, attrs)
          |> Map.update!(:metadata, &Map.merge(assignment.metadata || %{}, &1))

        with {:ok, assignment} <- update_pool_assignment(assignment, attrs) do
          {:ok, :existing, assignment}
        end

      nil when is_binary(attrs.target_identity_id) ->
        {:error, identity_mismatch_error()}

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
    |> UpstreamIdentity.put_credential_provenance(attrs.credential_provenance)
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
    |> UpstreamIdentity.put_credential_provenance(attrs.credential_provenance)
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

  defp relink_eligibility_status(true), do: PoolUpstreamAssignment.ineligible_status()
  defp relink_eligibility_status(false), do: @eligible

  defp link_result_status(:created, :created), do: :created
  defp link_result_status(_identity_status, _assignment_status), do: :existing

  defp maybe_store_refresh_token(_identity, %{refresh_token: nil}), do: {:ok, nil}

  defp maybe_store_refresh_token(identity, %{refresh_token: refresh_token}) do
    Secrets.store_encrypted_secret(identity, %{
      secret_kind: "refresh_token",
      plaintext: refresh_token
    })
  end

  defp link_identity_metadata(metadata, _attrs), do: metadata

  defp existing_link_metadata(
         replacement_metadata,
         link_metadata,
         timestamp,
         attrs,
         expiry,
         epoch
       ) do
    replacement_metadata
    |> Map.merge(link_metadata || %{})
    |> TokenRefreshMetadata.build_imported(
      expiry,
      epoch,
      attrs.token_refresh_trigger_kind,
      timestamp
    )
  end

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

  defp incoming_identity_attrs(attrs) do
    %{
      chatgpt_account_id: attrs.chatgpt_account_id,
      chatgpt_user_id: attrs.chatgpt_user_id,
      account_email: attrs.account_email,
      account_label: attrs.account_label,
      workspace_id: attrs.workspace_id,
      workspace_label: attrs.workspace_label,
      seat_type: attrs.seat_type
    }
    |> Map.merge(trusted_plan_metadata(attrs))
  end

  @spec validate_link_target(Pool.t(), map()) ::
          :ok | {:error, lifecycle_error() | IdentityLifecycle.identity_conflict()}
  defp validate_link_target(%Pool{} = pool, %{target_identity_id: target_identity_id} = attrs)
       when is_binary(target_identity_id) do
    with :ok <- validate_target_pool_assignment(pool, target_identity_id),
         {:ok, _identity} <- select_link_identity(attrs, incoming_identity_attrs(attrs)) do
      :ok
    end
  end

  defp validate_link_target(_pool, _attrs), do: :ok

  @spec select_link_identity(map(), map()) ::
          {:ok, UpstreamIdentity.t() | nil}
          | {:error, lifecycle_error() | IdentityLifecycle.identity_conflict()}
  defp select_link_identity(%{target_identity_id: target_identity_id}, identity_attrs)
       when is_binary(target_identity_id) do
    select_target_link_identity(target_identity_id, identity_attrs)
  end

  defp select_link_identity(_attrs, identity_attrs) do
    IdentityLifecycle.select_upsert_identity(identity_attrs)
  end

  defp select_target_link_identity(target_identity_id, identity_attrs) do
    case Repo.get(UpstreamIdentity, target_identity_id) do
      %UpstreamIdentity{} = target_identity ->
        validate_target_link_identity(target_identity, identity_attrs)

      nil ->
        {:error, identity_mismatch_error()}
    end
  end

  @spec validate_target_pool_assignment(Pool.t(), Ecto.UUID.t()) ::
          :ok | {:error, lifecycle_error()}
  defp validate_target_pool_assignment(%Pool{id: pool_id}, target_identity_id)
       when is_binary(pool_id) and is_binary(target_identity_id) do
    if target_identity_assigned_to_pool?(pool_id, target_identity_id) do
      :ok
    else
      {:error, identity_mismatch_error()}
    end
  end

  defp validate_target_pool_assignment(_pool, _target_identity_id),
    do: {:error, identity_mismatch_error()}

  defp target_identity_assigned_to_pool?(pool_id, target_identity_id) do
    Repo.exists?(
      from assignment in PoolUpstreamAssignment,
        where:
          assignment.pool_id == ^pool_id and
            assignment.upstream_identity_id == ^target_identity_id and
            assignment.status != ^@assignment_deleted
    )
  end

  @spec validate_target_link_identity(UpstreamIdentity.t(), map()) ::
          {:ok, UpstreamIdentity.t()}
          | {:error, lifecycle_error() | IdentityLifecycle.identity_conflict()}
  defp validate_target_link_identity(%UpstreamIdentity{} = target_identity, identity_attrs) do
    with :ok <- validate_target_account(target_identity, identity_attrs),
         :ok <- validate_target_subject(target_identity, identity_attrs),
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

  @spec validate_target_subject(UpstreamIdentity.t(), map()) :: :ok | {:error, lifecycle_error()}
  defp validate_target_subject(%UpstreamIdentity{} = target_identity, identity_attrs) do
    target_subject = present_string(target_identity.chatgpt_user_id)
    incoming_subject = identity_attrs |> Map.get(:chatgpt_user_id) |> present_string()

    cond do
      is_nil(target_subject) ->
        :ok

      incoming_subject == target_subject ->
        :ok

      true ->
        {:error, identity_mismatch_error()}
    end
  end

  @spec validate_target_workspace(UpstreamIdentity.t(), map()) ::
          :ok | {:error, lifecycle_error() | IdentityLifecycle.identity_conflict()}
  defp validate_target_workspace(%UpstreamIdentity{} = target_identity, identity_attrs) do
    target_workspace_id = present_string(target_identity.workspace_id)
    incoming_workspace_id = identity_attrs |> Map.get(:workspace_id) |> present_string()
    incoming_account_id = identity_attrs |> Map.get(:chatgpt_account_id) |> present_string()

    if is_binary(target_workspace_id) do
      validate_concrete_target_workspace(
        target_identity,
        target_workspace_id,
        incoming_workspace_id,
        identity_attrs
      )
    else
      validate_legacy_target_workspace(
        target_identity,
        incoming_account_id,
        identity_attrs
      )
    end
  end

  @spec validate_concrete_target_workspace(
          UpstreamIdentity.t(),
          String.t(),
          String.t() | nil,
          map()
        ) :: :ok | {:error, lifecycle_error()}
  defp validate_concrete_target_workspace(
         %UpstreamIdentity{} = target_identity,
         target_workspace_id,
         incoming_workspace_id,
         identity_attrs
       ) do
    cond do
      incoming_workspace_id == target_workspace_id ->
        :ok

      missing_workspace_claims_compatible?(target_identity, identity_attrs) ->
        :ok

      true ->
        {:error, identity_mismatch_error()}
    end
  end

  @spec validate_legacy_target_workspace(UpstreamIdentity.t(), String.t() | nil, map()) ::
          :ok | {:error, lifecycle_error() | IdentityLifecycle.identity_conflict()}
  defp validate_legacy_target_workspace(
         %UpstreamIdentity{} = target_identity,
         incoming_account_id,
         identity_attrs
       ) do
    cond do
      exact_workspace_identity?(target_identity, identity_attrs) ->
        {:error, identity_mismatch_error()}

      concrete_sibling_identity?(target_identity, incoming_account_id) ->
        {:error,
         identity_conflict(
           identity_attrs,
           first_concrete_sibling(target_identity, incoming_account_id)
         )}

      true ->
        :ok
    end
  end

  @spec missing_workspace_claims_compatible?(UpstreamIdentity.t(), map()) :: boolean()
  defp missing_workspace_claims_compatible?(%UpstreamIdentity{} = identity, identity_attrs) do
    target_workspace_id = present_string(identity.workspace_id)
    incoming_workspace_id = identity_attrs |> Map.get(:workspace_id) |> present_string()
    stored_plan_family = stored_plan_family(identity)
    incoming_plan_family = incoming_plan_family(identity_attrs)
    stored_seat_type = present_string(identity.seat_type)
    incoming_seat_type = identity_attrs |> Map.get(:seat_type) |> present_string()

    is_binary(target_workspace_id) and is_nil(incoming_workspace_id) and
      stored_identity_proof?(identity, identity_attrs) and is_binary(incoming_plan_family) and
      is_binary(incoming_seat_type) and
      known_slot_metadata_compatible?(stored_plan_family, incoming_plan_family) and
      known_slot_metadata_compatible?(stored_seat_type, incoming_seat_type)
  end

  @spec maybe_preserve_missing_workspace_slot(map(), UpstreamIdentity.t()) :: map()
  defp maybe_preserve_missing_workspace_slot(identity_attrs, %UpstreamIdentity{} = identity) do
    if missing_workspace_claims_compatible?(identity, identity_attrs) do
      identity_attrs
      |> Map.put(:workspace_id, identity.workspace_id)
      |> Map.put(:workspace_label, identity.workspace_label)
      |> preserve_known_slot_value(:seat_type, identity.seat_type)
      |> preserve_known_slot_value(:plan_family, identity.plan_family)
      |> preserve_known_slot_value(:plan_label, identity.plan_label)
    else
      identity_attrs
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

  defp exact_workspace_identity?(%UpstreamIdentity{id: target_id}, identity_attrs) do
    account_id = identity_attrs |> Map.get(:chatgpt_account_id) |> present_string()
    workspace_id = identity_attrs |> Map.get(:workspace_id) |> present_string()
    incoming_subject = identity_attrs |> Map.get(:chatgpt_user_id) |> present_string()

    account_id
    |> IdentityLifecycle.list_upstream_identities_by_chatgpt_account()
    |> Enum.any?(fn
      %UpstreamIdentity{id: ^target_id} ->
        false

      %UpstreamIdentity{} = identity ->
        selected_workspace_sibling?(identity, workspace_id, incoming_subject)
    end)
  end

  defp selected_workspace_sibling?(%UpstreamIdentity{} = identity, workspace_id, nil) do
    present_string(identity.workspace_id) == workspace_id
  end

  defp selected_workspace_sibling?(
         %UpstreamIdentity{} = identity,
         workspace_id,
         incoming_subject
       ) do
    identity_workspace_id = present_string(identity.workspace_id)
    identity_subject = present_string(identity.chatgpt_user_id)

    identity_workspace_id == workspace_id and
      (is_nil(identity_subject) or identity_subject == incoming_subject)
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

  defp identity_conflict(attrs, %UpstreamIdentity{} = stored_identity) do
    IdentityLifecycle.identity_conflict(attrs, stored_identity)
  end

  defp identity_conflict(attrs, _stored_identity),
    do: IdentityLifecycle.identity_conflict(attrs, nil)

  @spec stored_identity_proof?(UpstreamIdentity.t(), map()) :: boolean()
  defp stored_identity_proof?(%UpstreamIdentity{} = identity, identity_attrs) do
    target_account_id = present_string(identity.chatgpt_account_id)
    incoming_account_id = identity_attrs |> Map.get(:chatgpt_account_id) |> present_string()
    target_email = normalize_email(identity.account_email)
    incoming_email = identity_attrs |> Map.get(:account_email) |> normalize_email()
    target_subject = present_string(identity.chatgpt_user_id)
    incoming_subject = identity_attrs |> Map.get(:chatgpt_user_id) |> present_string()

    (is_binary(target_account_id) and incoming_account_id == target_account_id) or
      (is_binary(target_email) and incoming_email == target_email) or
      (is_binary(target_subject) and incoming_subject == target_subject)
  end

  @spec stored_plan_family(UpstreamIdentity.t()) :: String.t() | nil
  defp stored_plan_family(%UpstreamIdentity{} = identity) do
    present_string(identity.plan_family) || plan_family(identity.plan_label)
  end

  @spec incoming_plan_family(map()) :: String.t() | nil
  defp incoming_plan_family(identity_attrs) do
    present_string(Map.get(identity_attrs, :plan_family)) ||
      plan_family(Map.get(identity_attrs, :plan_label))
  end

  @spec known_slot_metadata_compatible?(String.t() | nil, String.t() | nil) :: boolean()
  defp known_slot_metadata_compatible?(nil, _incoming), do: true
  defp known_slot_metadata_compatible?(stored, incoming), do: stored == incoming

  @spec preserve_known_slot_value(map(), atom(), term()) :: map()
  defp preserve_known_slot_value(attrs, key, value) do
    case present_string(value) do
      nil -> attrs
      stored -> Map.put(attrs, key, stored)
    end
  end

  defp plan_family(nil), do: nil
  defp plan_family(label), do: label |> normalize_plan() |> present_string()

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
