defmodule CodexPooler.Admin.PoolWorkflow do
  @moduledoc """
  Admin pool workflows that coordinate pool settings, upstream assignments, and API keys.
  """

  alias CodexPooler.Access
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Events
  alias CodexPooler.Pools
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams

  @type access_error :: %{required(:code) => atom(), required(:message) => String.t()}
  @type pool_result :: {:ok, Pool.t()} | {:error, Ecto.Changeset.t() | access_error()}

  @spec create_pool_with_related_settings(Scope.t(), map()) :: pool_result()
  def create_pool_with_related_settings(%Scope{} = scope, attrs) when is_map(attrs) do
    Repo.transaction(fn ->
      with {:ok, pool} <- Pools.create_pool(scope, pool_create_attrs(attrs), broadcast?: false),
           {:ok, _settings} <-
             Pools.update_routing_settings(scope, pool, routing_attrs(attrs), broadcast?: false),
           :ok <-
             Upstreams.sync_pool_assignments_for_pool_edit(
               pool,
               selected_upstream_identity_ids(attrs),
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
    |> maybe_broadcast_pool_workflow("pool_created")
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
      update_pool_with_related_settings_transaction(scope, pool_or_id, attrs)
    end)
    |> normalize_transaction_result()
    |> maybe_broadcast_pool_workflow("pool_updated")
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
           Pools.update_routing_settings(scope, pool, routing_attrs(attrs), broadcast?: false),
         :ok <-
           Upstreams.sync_pool_assignments_for_pool_edit(pool, assignment_ids,
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
           Pools.update_routing_settings(scope, pool, routing_attrs(attrs), broadcast?: false),
         :ok <-
           Upstreams.sync_pool_assignments_for_pool_edit(pool, assignment_ids,
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
      "request_compression_enabled" => Map.get(attrs, "request_compression_enabled", false)
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

  defp normalize_transaction_result({:ok, result}), do: {:ok, result}
  defp normalize_transaction_result({:error, reason}), do: {:error, reason}

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
