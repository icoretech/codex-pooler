defmodule CodexPooler.Admin.PoolWorkflow do
  @moduledoc """
  Admin pool workflows that coordinate pool settings, upstream assignments, and API keys.
  """

  require Logger

  alias CodexPooler.Access
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Accounts.User
  alias CodexPooler.Audit
  alias CodexPooler.Events
  alias CodexPooler.Jobs
  alias CodexPooler.Pools
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Pools.Routing, as: PoolRouting
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Assignments, as: UpstreamAssignments

  @assignment_selection_keys ~w(upstream_identity_ids upstream_assignment_ids)
  @catalog_sync_trigger_kind "manual"
  @pool_active "active"

  @type access_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type pool_result :: {:ok, Pool.t()} | {:error, Ecto.Changeset.t() | access_error()}

  @spec create_pool_with_related_settings(Scope.t(), map()) :: pool_result()
  def create_pool_with_related_settings(%Scope{} = scope, attrs) when is_map(attrs) do
    Repo.transaction(fn ->
      with {:ok, pool} <- Pools.create_pool(scope, pool_create_attrs(attrs), broadcast?: false),
           {:ok, _settings} <-
             PoolRouting.update_routing_settings(scope, pool, routing_attrs(attrs), broadcast?: false),
           :ok <-
             sync_pool_assignments_audited(scope, pool, selected_upstream_identity_ids(attrs),
               select_by: :upstream_identity_id,
               skip_quota_priming: true
             ),
           :ok <-
             Access.assign_api_keys_to_pool(scope, pool, selected_api_key_ids_from_attrs(attrs)) do
        pool
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> normalize_transaction_result()
    |> invalidate_notifications_after_create()
    |> maybe_broadcast_pool_workflow("pool_created")
    |> maybe_enqueue_assignment_catalog_sync(attrs)
  end

  def create_pool_with_related_settings(_scope, _attrs),
    do: {:error, access_error(:invalid_request, "user scope is required")}

  @spec update_pool_with_related_settings(
          Scope.t(),
          Pool.t() | Ecto.UUID.t(),
          map()
        ) ::
          pool_result()
  def update_pool_with_related_settings(%Scope{} = scope, pool_or_id, attrs) when is_map(attrs) do
    Repo.transaction(fn ->
      previous_status = committed_pool_status(pool_or_id)
      {update_pool_with_related_settings_transaction(scope, pool_or_id, attrs), previous_status}
    end)
    |> normalize_transaction_result()
    |> invalidate_notifications_after_status_change()
    |> maybe_broadcast_pool_workflow("pool_updated")
    |> maybe_enqueue_assignment_catalog_sync(attrs)
  end

  def update_pool_with_related_settings(_scope, _pool_or_id, _attrs),
    do: {:error, access_error(:invalid_request, "user scope is required")}

  defp update_pool_with_related_settings_transaction(scope, pool_or_id, attrs) do
    case validate_pool_edit_attrs(attrs) do
      :ok ->
        api_key_ids = selected_api_key_ids_from_attrs(attrs)

        if Map.get(attrs, "status") == "active" do
          update_active_pool_with_related_settings(scope, pool_or_id, attrs, api_key_ids)
        else
          update_inactive_pool_with_related_settings(scope, pool_or_id, attrs, api_key_ids)
        end

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp update_active_pool_with_related_settings(scope, pool_or_id, attrs, api_key_ids) do
    {assignment_ids, select_by} = selected_pool_assignment_targets(attrs)

    with {:ok, pool} <-
           Pools.update_pool(scope, pool_or_id, pool_edit_attrs(attrs), broadcast?: false),
         {:ok, _settings} <-
           PoolRouting.update_routing_settings(scope, pool, routing_attrs(attrs), broadcast?: false),
         :ok <-
           sync_pool_assignments_audited(scope, pool, assignment_ids,
             select_by: select_by,
             skip_quota_priming: true
           ),
         :ok <- Access.assign_api_keys_to_pool(scope, pool, api_key_ids) do
      pool
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp update_inactive_pool_with_related_settings(scope, pool_or_id, attrs, api_key_ids) do
    {assignment_ids, select_by} = selected_pool_assignment_targets(attrs)

    with %Pool{} = pool <- admin_pool_for_assignment(pool_or_id),
         :ok <- Access.assign_api_keys_to_pool(scope, pool, api_key_ids),
         {:ok, _settings} <-
           PoolRouting.update_routing_settings(scope, pool, routing_attrs(attrs), broadcast?: false),
         :ok <-
           sync_pool_assignments_audited(scope, pool, assignment_ids,
             select_by: select_by,
             skip_quota_priming: true
           ),
         {:ok, pool} <- Pools.update_pool(scope, pool, pool_edit_attrs(attrs), broadcast?: false) do
      pool
    else
      nil -> Repo.rollback(access_error(:pool_not_found, "pool was not found"))
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # Adding or removing an upstream account in the Pool editor is audited in the transaction that
  # changes the assignment, one event per account (findings#206 row 206-554).
  defp sync_pool_assignments_audited(scope, pool, selected_ids, opts) do
    live_before = live_pool_assignments(pool)

    with :ok <- UpstreamAssignments.sync_pool_assignments_for_pool_edit(pool, selected_ids, opts) do
      live_after = live_pool_assignments(pool)

      added = Enum.reject(live_after, fn {id, _assignment} -> Map.has_key?(live_before, id) end)
      removed = Enum.reject(live_before, fn {id, _assignment} -> Map.has_key?(live_after, id) end)

      changes = Enum.map(added, &{"pool.assignment_add", &1}) ++ Enum.map(removed, &{"pool.assignment_remove", &1})
      Enum.reduce_while(changes, :ok, &record_assignment_change(scope, pool, &1, &2))
    end
  end

  defp record_assignment_change(scope, pool, {action, {_id, assignment}}, :ok) do
    case record_assignment_audit_event(scope, pool, action, assignment) do
      {:ok, _event} -> {:cont, :ok}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp live_pool_assignments(pool) do
    pool
    |> UpstreamAssignments.list_pool_assignments()
    |> Enum.reject(&(&1.status == "deleted"))
    |> Map.new(&{&1.id, &1})
  end

  defp record_assignment_audit_event(%Scope{user: %User{} = user}, %Pool{} = pool, action, assignment) do
    Audit.record_user_event(user, %{
      pool_id: pool.id,
      action: action,
      target_type: "upstream_identity",
      target_id: assignment.upstream_identity_id,
      details: %{
        pool_id: pool.id,
        pool_name: pool.name,
        pool_upstream_assignment_id: assignment.id,
        upstream_identity_id: assignment.upstream_identity_id,
        label: assignment.assignment_label,
        status: assignment.status
      }
    })
  end

  defp record_assignment_audit_event(%Scope{}, _pool, _action, _assignment), do: {:ok, :no_user}

  defp admin_pool_for_assignment(%Pool{} = pool), do: pool
  defp admin_pool_for_assignment(id) when is_binary(id), do: Pools.get_pool(id)
  defp admin_pool_for_assignment(_pool_or_id), do: nil

  defp validate_pool_edit_attrs(attrs) do
    name = attrs |> Map.get("name", "") |> to_string() |> String.trim()

    if name == "" do
      {:error, %{message: "name can't be blank"}}
    else
      :ok
    end
  end

  defp pool_create_attrs(attrs) do
    name = attrs |> Map.get("name", "") |> to_string() |> String.trim()

    %{
      "name" => name,
      "slug" => generate_pool_slug(name)
    }
  end

  defp generate_pool_slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp pool_edit_attrs(attrs) do
    %{
      "name" => attrs |> Map.get("name", "") |> to_string() |> String.trim(),
      "status" => Map.get(attrs, "status")
    }
  end

  defp routing_attrs(attrs) do
    %{
      "routing_strategy" => Map.get(attrs, "routing_strategy", "bridge_ring"),
      "bridge_ring_size" => Map.get(attrs, "bridge_ring_size", 3),
      "sticky_websocket_sessions" => Map.get(attrs, "sticky_websocket_sessions", true),
      "sticky_http_sessions" => Map.get(attrs, "sticky_http_sessions", false),
      "prompt_cache_affinity_enabled" => Map.get(attrs, "prompt_cache_affinity_enabled", true),
      "v1_compatibility_enabled" => Map.get(attrs, "v1_compatibility_enabled", true),
      "request_compression_enabled" => Map.get(attrs, "request_compression_enabled", false),
      "allow_image_generation" => Map.get(attrs, "allow_image_generation", true)
    }
  end

  defp selected_upstream_identity_ids(attrs), do: selected_ids(attrs, "upstream_identity_ids")
  defp selected_assignment_ids(attrs), do: selected_ids(attrs, "upstream_assignment_ids")

  defp selected_pool_assignment_targets(attrs) do
    if Map.has_key?(attrs, "upstream_identity_ids") do
      {selected_upstream_identity_ids(attrs), :upstream_identity_id}
    else
      {selected_assignment_ids(attrs), :assignment_id}
    end
  end

  defp selected_ids(attrs, key) do
    attrs
    |> Map.get(key, [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp selected_api_key_ids_from_attrs(attrs) do
    attrs
    |> Map.get("api_key_ids", [])
    |> List.wrap()
    |> selected_ids()
  end

  defp selected_ids(ids) do
    ids
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  # The status the Pool had before this transaction changed it, read inside it.
  defp committed_pool_status(%Pool{id: pool_id}), do: committed_pool_status(pool_id)

  defp committed_pool_status(pool_id) do
    case Pools.get_pool(pool_id) do
      %Pool{status: status} -> status
      nil -> nil
    end
  end

  # Pools.update_pool/4 runs with `broadcast?: false` inside the transaction,
  # so the notification centers hear of a status change only after the commit.
  defp invalidate_notifications_after_status_change({:ok, {%Pool{} = pool, previous_status}}) do
    :ok = Pools.invalidate_notifications_after_status_change(previous_status, pool)
    {:ok, pool}
  end

  defp invalidate_notifications_after_status_change({:error, _reason} = error), do: error

  defp invalidate_notifications_after_create({:ok, %Pool{} = pool} = created) do
    :ok = Pools.invalidate_notifications_after_status_change(nil, pool)
    created
  end

  defp invalidate_notifications_after_create({:error, _reason} = error), do: error

  defp normalize_transaction_result({:ok, result}), do: {:ok, result}
  defp normalize_transaction_result({:error, reason}), do: {:error, reason}

  @spec maybe_enqueue_assignment_catalog_sync(pool_result(), map()) :: pool_result()
  defp maybe_enqueue_assignment_catalog_sync(
         {:ok, %Pool{status: @pool_active} = pool} = result,
         attrs
       ) do
    if assignment_selection_attrs?(attrs) do
      case Jobs.enqueue_catalog_sync(pool, trigger_kind: @catalog_sync_trigger_kind) do
        {:ok, _job} ->
          result

        {:error, reason} ->
          log_catalog_sync_enqueue_failure(pool, reason)
          result
      end
    else
      result
    end
  end

  defp maybe_enqueue_assignment_catalog_sync(result, _attrs), do: result

  @spec assignment_selection_attrs?(map()) :: boolean()
  defp assignment_selection_attrs?(attrs) when is_map(attrs) do
    Enum.any?(@assignment_selection_keys, &Map.has_key?(attrs, &1))
  end

  @spec log_catalog_sync_enqueue_failure(Pool.t(), term()) :: :ok
  defp log_catalog_sync_enqueue_failure(%Pool{} = pool, reason) do
    reason = catalog_sync_enqueue_failure_code(reason)

    Logger.warning(fn ->
      "pool assignment catalog sync enqueue failed pool_id=#{pool.id} " <>
        "trigger_kind=#{@catalog_sync_trigger_kind} reason=#{reason}"
    end)
  end

  @spec catalog_sync_enqueue_failure_code(term()) :: String.t()
  defp catalog_sync_enqueue_failure_code(%Ecto.Changeset{}), do: "invalid_job"
  defp catalog_sync_enqueue_failure_code(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp maybe_broadcast_pool_workflow({:ok, %Pool{} = pool} = result, reason) do
    Events.broadcast_pools(pool.id, reason, %{
      pool_id: pool.id,
      status: pool.status
    })

    result
  end

  defp maybe_broadcast_pool_workflow(result, _reason), do: result

  defp access_error(code, message), do: %{code: code, message: message}
end
