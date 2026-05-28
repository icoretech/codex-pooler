defmodule CodexPoolerWeb.Admin.PoolForm do
  @moduledoc false

  import Phoenix.Component, only: [to_form: 2]

  alias CodexPooler.Access
  alias CodexPooler.Pools
  alias CodexPooler.Pools.RoutingSettings
  alias CodexPooler.Upstreams
  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.OptionLoaderFallback

  @pool_statuses ["active", "disabled", "archived"]

  def filter(attrs \\ %{}) do
    attrs = Map.new(attrs)
    status = attrs |> Map.get("status", "all") |> to_string()

    %{
      "query" => attrs |> Map.get("query", "") |> to_string() |> String.trim(),
      "status" => if(status in ["all" | @pool_statuses], do: status, else: "all")
    }
  end

  def filter_form(attrs \\ filter()) do
    attrs
    |> filter()
    |> to_form(as: :pool_filters)
  end

  def filter_status_options, do: [{"Status: All", "all"} | status_options()]

  def create_form(attrs \\ %{}, errors \\ []) do
    attrs
    |> create_form_attrs()
    |> to_form(as: :pool, errors: errors)
  end

  def edit_form(pool, attrs \\ %{}, errors \\ []) do
    attrs = Map.new(attrs)
    settings = Pools.routing_settings_by_pool_ids([pool.id]) |> Map.fetch!(pool.id)

    %{
      "id" => pool.id,
      "name" => pool.name,
      "status" => pool.status,
      "routing_strategy" => settings.routing_strategy,
      "bridge_ring_size" => settings.bridge_ring_size,
      "sticky_websocket_sessions" => settings.sticky_websocket_sessions,
      "sticky_http_sessions" => settings.sticky_http_sessions,
      "prompt_cache_affinity_enabled" => settings.prompt_cache_affinity_enabled,
      "control_plane_analytics_forwarding_enabled" =>
        settings.control_plane_analytics_forwarding_enabled,
      "v1_compatibility_enabled" => settings.v1_compatibility_enabled,
      "upstream_identity_ids" => active_upstream_identity_ids(pool),
      "api_key_ids" => active_api_key_ids(pool)
    }
    |> Map.merge(attrs)
    |> normalize_multi_select("upstream_identity_ids")
    |> normalize_multi_select("api_key_ids")
    |> to_form(as: :pool_edit, errors: errors)
  end

  def delete_form(pool \\ nil, attrs \\ %{}) do
    pool_id = if pool, do: pool.id, else: ""

    %{"id" => pool_id, "confirmation_slug" => ""}
    |> Map.merge(Map.new(attrs))
    |> to_form(as: :pool_delete)
  end

  def upstream_identity_options(scope) do
    case Upstreams.list_upstream_identities_for_pool_management(scope, status: "active") do
      {:ok, identities} ->
        {Enum.map(identities, &upstream_identity_option/1), []}

      {:error, reason} ->
        empty_admin_options(:upstream_identity_options, reason, %{
          title: "Upstream accounts unavailable",
          message: "Upstream account options could not be loaded. Pool forms may be incomplete."
        })
    end
  end

  def load_upstream_identity_options(_scope, false), do: {[], []}
  def load_upstream_identity_options(scope, true), do: upstream_identity_options(scope)

  def load_api_key_options(_scope, false), do: {[], []}
  def load_api_key_options(scope, true), do: api_key_options(scope)

  def edit_upstream_identity_options(nil, options), do: options

  def edit_upstream_identity_options(pool, options) do
    options_by_value = Map.new(options, &{option_value(&1), &1})

    pool
    |> Upstreams.list_pool_assignments()
    |> Enum.reject(&(&1.status == "deleted"))
    |> Enum.map(&Upstreams.get_upstream_identity(&1.upstream_identity_id))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&upstream_identity_option/1)
    |> Enum.reject(&Map.has_key?(options_by_value, option_value(&1)))
    |> then(&(options ++ &1))
  end

  def routing_strategy_options do
    Enum.map(
      RoutingSettings.routing_strategies(),
      &{AdminBadges.routing_strategy_label(&1), &1}
    )
  end

  def status_options, do: Enum.map(@pool_statuses, &{status_label(&1), &1})

  def delete_title(%{status: "archived"}), do: "Delete archived Pool"
  def delete_title(_pool), do: "Archive the Pool before hard deletion"

  def changeset_errors(%Ecto.Changeset{} = changeset) do
    Enum.flat_map(changeset.errors, fn {field, errors} ->
      errors = if is_list(errors), do: errors, else: [errors]
      Enum.map(errors, &{field, &1})
    end)
  end

  def field_array_name(field), do: "#{field.name}[]"

  def selected_value?(values, value), do: value in list_input_values(values)

  def option_label(%{label: label}), do: label
  def option_label({label, _value}), do: label

  def option_value(%{value: value}), do: value
  def option_value({_label, value}), do: value

  def option_plan_label(%{plan_label: label}), do: label
  def option_plan_label(_option), do: "Plan unknown"

  def option_plan_family(%{plan_family: family}), do: family
  def option_plan_family(_option), do: nil

  def option_badge_kind(%{badge_kind: kind}), do: kind
  def option_badge_kind(_option), do: :metadata

  def option_status(%{status: status}), do: status
  def option_status(_option), do: "unknown"

  def dom_token(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "-")
    |> String.trim("-")
  end

  defp create_form_attrs(attrs) do
    %{
      "name" => "",
      "routing_strategy" => "bridge_ring",
      "bridge_ring_size" => 3,
      "sticky_websocket_sessions" => true,
      "sticky_http_sessions" => false,
      "prompt_cache_affinity_enabled" => true,
      "control_plane_analytics_forwarding_enabled" => true,
      "v1_compatibility_enabled" => true,
      "upstream_identity_ids" => [],
      "api_key_ids" => []
    }
    |> Map.merge(Map.new(attrs))
    |> normalize_multi_select("upstream_identity_ids")
    |> normalize_multi_select("api_key_ids")
  end

  defp normalize_multi_select(attrs, key) do
    Map.update(attrs, key, [], fn value ->
      value
      |> List.wrap()
      |> Enum.reject(&(&1 in [nil, ""]))
    end)
  end

  defp list_input_values(nil), do: []

  defp list_input_values(values) when is_list(values),
    do: values |> Enum.reject(&(&1 in [nil, ""])) |> Enum.uniq()

  defp list_input_values(value) when is_binary(value), do: if(value == "", do: [], else: [value])
  defp list_input_values(_value), do: []

  defp active_upstream_identity_ids(pool) do
    pool
    |> Upstreams.list_pool_assignments()
    |> Enum.reject(&(&1.status == "deleted"))
    |> Enum.map(& &1.upstream_identity_id)
  end

  defp active_api_key_ids(pool) do
    Access.api_key_ids_for_pool(pool)
  end

  defp api_key_options(scope) do
    with {:ok, pools} <- Pools.list_pools_for_management(scope),
         {:ok, api_keys} <- Access.list_api_keys(scope) do
      pool_lookup = Map.new(pools, &{&1.id, &1})
      {Enum.map(api_keys, &api_key_option(&1, pool_lookup)), []}
    else
      {:error, reason} ->
        empty_admin_options(:api_key_options, reason, %{
          title: "API key options unavailable",
          message: "API key options could not be loaded. Pool forms may be incomplete."
        })
    end
  end

  defp upstream_identity_label(identity) do
    identity.account_label || identity.chatgpt_account_id || "Upstream account"
  end

  defp upstream_identity_option(identity) do
    %{
      label: upstream_identity_label(identity),
      value: identity.id,
      plan_label: plan_label(identity),
      plan_family: plan_family(identity),
      badge_kind: :plan,
      status: identity_status(identity)
    }
  end

  defp api_key_option(api_key, pool_lookup) do
    pool = Map.get(pool_lookup, api_key.pool_id)

    %{
      label: api_key.display_name || api_key.key_prefix || "API key",
      value: api_key.id,
      plan_label: if(pool, do: pool.name, else: "Unknown Pool"),
      badge_kind: :metadata,
      status: api_key.status
    }
  end

  defp plan_label(%{plan_label: label} = identity) when is_binary(label) do
    case String.trim(label) do
      "" -> plan_family_label(identity)
      value -> value
    end
  end

  defp plan_label(%{plan_family: _family} = identity), do: plan_family_label(identity)
  defp plan_label(_identity), do: "Plan unknown"

  defp plan_family_label(%{plan_family: family}) when is_binary(family) do
    family
    |> String.trim()
    |> case do
      "" ->
        "Plan unknown"

      value ->
        value
        |> String.replace(~r/[-_]+/, " ")
        |> String.split()
        |> Enum.map_join(" ", &String.capitalize/1)
    end
  end

  defp plan_family_label(_identity), do: "Plan unknown"

  defp plan_family(%{plan_family: family}) when is_binary(family) do
    family
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp plan_family(_identity), do: nil

  defp identity_status(%{status: status}) when is_binary(status), do: status
  defp identity_status(_identity), do: "unknown"

  defp status_label("active"), do: "Active"
  defp status_label("disabled"), do: "Disabled"
  defp status_label("archived"), do: "Archived"
  defp status_label(status), do: status

  defp empty_admin_options(loader, reason, warning) do
    OptionLoaderFallback.empty_options(
      :pools,
      loader,
      reason,
      warning,
      [:pool_not_found, :api_key_not_found, :upstream_identity_not_found]
    )
  end
end
