defmodule CodexPooler.Pools.Routing do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.Audit
  alias CodexPooler.Events
  alias CodexPooler.Pools.Authorization, as: PoolAuthorization
  alias CodexPooler.Pools.{Pool, RoutingSettings}
  alias CodexPooler.Repo

  @spec get_routing_settings(Pool.t() | Ecto.UUID.t() | term()) :: RoutingSettings.t() | nil
  def get_routing_settings(%Pool{id: pool_id}), do: get_routing_settings(pool_id)

  def get_routing_settings(pool_id) when is_binary(pool_id),
    do: Repo.get(RoutingSettings, pool_id)

  def get_routing_settings(_pool_id), do: nil

  @spec routing_settings_with_defaults(Pool.t() | Ecto.UUID.t() | term()) ::
          RoutingSettings.t() | nil
  def routing_settings_with_defaults(%Pool{id: pool_id}),
    do: routing_settings_with_defaults(pool_id)

  def routing_settings_with_defaults(pool_id) when is_binary(pool_id),
    do: get_routing_settings(pool_id) || default_routing_settings(pool_id)

  def routing_settings_with_defaults(_pool_id), do: nil

  def v1_compatibility_enabled?(%Pool{id: pool_id}), do: v1_compatibility_enabled?(pool_id)

  def v1_compatibility_enabled?(pool_id) when is_binary(pool_id) do
    case routing_settings_with_defaults(pool_id) do
      %RoutingSettings{v1_compatibility_enabled: enabled} -> enabled
    end
  end

  def v1_compatibility_enabled?(_pool_id), do: true

  def ensure_routing_settings(%Pool{id: pool_id}), do: ensure_routing_settings(pool_id)

  def ensure_routing_settings(pool_id) when is_binary(pool_id) do
    settings = default_routing_settings(pool_id)

    Repo.insert(settings, on_conflict: :nothing, conflict_target: :pool_id)
    Repo.get!(RoutingSettings, pool_id)
  end

  def ensure_routing_settings(_pool_id), do: nil

  def routing_settings_by_pool_ids(pool_ids) when is_list(pool_ids) do
    pool_ids = pool_ids |> Enum.filter(&is_binary/1) |> Enum.uniq()

    settings_by_pool_id =
      case pool_ids do
        [] ->
          %{}

        _ ->
          Repo.all(
            from settings in RoutingSettings,
              where: settings.pool_id in ^pool_ids,
              select: {settings.pool_id, settings}
          )
          |> Map.new()
      end

    Enum.into(pool_ids, %{}, fn pool_id ->
      {pool_id, Map.get(settings_by_pool_id, pool_id, default_routing_settings(pool_id))}
    end)
  end

  def routing_settings_by_pool_ids(_pool_ids), do: %{}

  def update_routing_settings(scope, pool, attrs, opts \\ [])

  def update_routing_settings(%Scope{} = scope, %Pool{} = pool, attrs, opts)
      when is_map(attrs) and is_list(opts) do
    with {:ok, _decision} <-
           PoolAuthorization.require_capability(
             scope,
             PoolAuthorization.capability(:pool_operate),
             pool_id: pool.id
           ),
         %RoutingSettings{} = settings <- ensure_routing_settings(pool) do
      now = now()

      settings
      |> RoutingSettings.changeset(%{
        routing_strategy: routing_attr(attrs, "routing_strategy", settings.routing_strategy),
        bridge_ring_size:
          parse_positive_integer(
            routing_attr(attrs, "bridge_ring_size", settings.bridge_ring_size)
          ),
        sticky_websocket_sessions:
          parse_boolean(
            routing_attr(
              attrs,
              "sticky_websocket_sessions",
              settings.sticky_websocket_sessions
            )
          ),
        sticky_http_sessions:
          parse_boolean(
            routing_attr(attrs, "sticky_http_sessions", settings.sticky_http_sessions)
          ),
        prompt_cache_affinity_enabled:
          parse_boolean(
            routing_attr(
              attrs,
              "prompt_cache_affinity_enabled",
              settings.prompt_cache_affinity_enabled
            )
          ),
        v1_compatibility_enabled:
          parse_boolean(
            routing_attr(
              attrs,
              "v1_compatibility_enabled",
              settings.v1_compatibility_enabled
            )
          ),
        request_compression_enabled:
          parse_boolean(
            routing_attr(
              attrs,
              "request_compression_enabled",
              settings.request_compression_enabled
            )
          ),
        metadata: settings.metadata || %{},
        created_at: settings.created_at,
        updated_at: now
      })
      |> Repo.update()
      |> tap(fn
        {:ok, settings} ->
          record_pool_audit_event(scope, "pool.routing_update", pool, %{
            routing_strategy: settings.routing_strategy,
            bridge_ring_size: settings.bridge_ring_size,
            sticky_websocket_sessions: settings.sticky_websocket_sessions,
            sticky_http_sessions: settings.sticky_http_sessions,
            prompt_cache_affinity_enabled: settings.prompt_cache_affinity_enabled,
            request_compression_enabled: settings.request_compression_enabled
          })

          maybe_broadcast_routing_change(opts, pool, settings)

        _result ->
          :ok
      end)
    else
      nil ->
        {:error,
         PoolAuthorization.access_error(
           :routing_settings_not_found,
           "routing settings were not found"
         )}

      {:error, _reason} = error ->
        error
    end
  end

  def update_routing_settings(_scope, _pool, _attrs, _opts),
    do:
      {:error,
       PoolAuthorization.access_error(:invalid_request, "user scope and Pool are required")}

  defp default_routing_settings(pool_id) do
    now = now()

    %RoutingSettings{
      pool_id: pool_id,
      routing_strategy: "bridge_ring",
      bridge_ring_size: 3,
      sticky_websocket_sessions: true,
      sticky_http_sessions: false,
      prompt_cache_affinity_enabled: true,
      v1_compatibility_enabled: true,
      request_compression_enabled: false,
      metadata: %{},
      created_at: now,
      updated_at: now
    }
  end

  defp record_pool_audit_event(
         %Scope{user: %User{} = user},
         action,
         %Pool{} = pool,
         details
       ) do
    Audit.record_user_event(user, %{
      pool_id: pool.id,
      action: action,
      target_type: "pool",
      target_id: pool.id,
      details: Map.merge(pool_audit_details(pool), details)
    })
  end

  defp record_pool_audit_event(_scope, _action, _pool, _details), do: :ok

  defp maybe_broadcast_routing_change(opts, %Pool{} = pool, %RoutingSettings{} = settings) do
    if Keyword.get(opts, :broadcast?, true) do
      Events.broadcast_pools(pool.id, "pool_routing_settings_updated", %{
        pool_id: pool.id,
        routing_strategy: settings.routing_strategy
      })
    end
  end

  defp pool_audit_details(%Pool{} = pool) do
    %{
      pool_id: pool.id,
      slug: pool.slug,
      name: pool.name,
      status: pool.status
    }
  end

  defp routing_attr(attrs, key, default) do
    atom_key = String.to_existing_atom(key)

    cond do
      Map.has_key?(attrs, key) -> Map.get(attrs, key)
      Map.has_key?(attrs, atom_key) -> Map.get(attrs, atom_key)
      true -> default
    end
  end

  defp parse_positive_integer(value) when is_integer(value), do: value

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _other -> value
    end
  end

  defp parse_positive_integer(value), do: value

  defp parse_boolean(value) when value in [true, false], do: value
  defp parse_boolean(value) when value in ["true", "on", "1", "yes"], do: true
  defp parse_boolean(value) when value in ["false", "0", "no", ""], do: false
  defp parse_boolean(_value), do: false

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
