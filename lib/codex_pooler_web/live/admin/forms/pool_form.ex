defmodule CodexPoolerWeb.Admin.PoolForm do
  @moduledoc false

  import Phoenix.Component, only: [to_form: 2]

  alias CodexPooler.Access
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Pools
  alias CodexPooler.Pools.ModelServingMode
  alias CodexPooler.Pools.ModelServingOverride
  alias CodexPooler.Pools.Routing, as: PoolRouting
  alias CodexPooler.Pools.RoutingSettings
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Assignments, as: UpstreamAssignments
  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.OptionLoaderFallback

  @pool_statuses ["active", "disabled", "archived"]
  @traffic_windows ["1h", "5h", "24h", "7d"]
  @traffic_window_options [
    {"Traffic: Last 1 hour", "1h"},
    {"Traffic: Last 5 hours", "5h"},
    {"Traffic: Last 24 hours", "24h"},
    {"Traffic: Last 7 days", "7d"}
  ]
  @traffic_window_short_labels %{
    "1h" => "1h",
    "5h" => "5h",
    "24h" => "24h",
    "7d" => "7d"
  }

  @type filter_values :: %{
          required(String.t()) => String.t()
        }
  @type option :: {String.t(), String.t()}
  @type model_serving_snapshot :: %{
          required(:overrides) => [ModelServingOverride.t()],
          required(:revision) => String.t()
        }
  @type model_serving_catalog_entry :: Model.t() | {Model.t(), [Ecto.UUID.t()]}
  @type model_serving_row :: %{
          required(:index) => non_neg_integer(),
          required(:exposed_model_id) => String.t(),
          required(:display_name) => String.t(),
          required(:configured_mode) => String.t(),
          required(:effective_mode) => String.t(),
          required(:source) => String.t(),
          required(:effective_badge) => %{
            required(:label) => String.t(),
            required(:mode) => String.t()
          },
          required(:available?) => boolean(),
          required(:warning) => String.t() | nil,
          required(:dom_id) => String.t(),
          required(:identifier_name) => String.t(),
          required(:mode_name) => String.t(),
          required(:input_ids) => %{
            required(:auto) => String.t(),
            required(:lite) => String.t(),
            required(:full) => String.t()
          },
          required(:labels) => %{
            required(:fieldset) => String.t(),
            required(:auto) => String.t(),
            required(:lite) => String.t(),
            required(:full) => String.t()
          }
        }
  @type model_serving_projection :: %{
          required(:revision) => String.t(),
          required(:revision_name) => String.t(),
          required(:rows) => [model_serving_row()],
          required(:warnings) => [String.t()]
        }
  @type model_serving_submission :: %{
          required(:revision) => String.t() | nil,
          required(:rows) => [map()]
        }

  @spec filter(map() | keyword()) :: filter_values()
  def filter(attrs \\ %{}) do
    attrs = Map.new(attrs)
    status = attrs |> value_for("status", "all") |> to_string()
    traffic_window = attrs |> value_for("traffic_window", "24h") |> normalize_traffic_window()

    %{
      "query" => attrs |> value_for("query", "") |> to_string() |> String.trim(),
      "status" => if(status in ["all" | @pool_statuses], do: status, else: "all"),
      "traffic_window" => traffic_window
    }
  end

  @spec filter_form(map() | keyword()) :: Phoenix.HTML.Form.t()
  def filter_form(attrs \\ filter()) do
    attrs
    |> filter()
    |> to_form(as: :pool_filters)
  end

  @spec filter_status_options() :: [option()]
  def filter_status_options, do: [{"Status: All", "all"} | status_options()]

  @spec traffic_window_options() :: [option()]
  def traffic_window_options, do: @traffic_window_options

  @spec traffic_window_short_label(String.t()) :: String.t()
  def traffic_window_short_label(window),
    do: Map.get(@traffic_window_short_labels, normalize_traffic_window(window), "24h")

  @spec normalize_traffic_window(term()) :: String.t()
  def normalize_traffic_window(window) do
    window = to_string(window || "")
    if window in @traffic_windows, do: window, else: "24h"
  end

  def create_form(attrs \\ %{}, errors \\ []) do
    attrs
    |> create_form_attrs()
    |> to_form(as: :pool, errors: errors)
  end

  def edit_form(pool, attrs \\ %{}, errors \\ []) do
    attrs = Map.new(attrs)
    settings = PoolRouting.routing_settings_by_pool_ids([pool.id]) |> Map.fetch!(pool.id)

    %{
      "id" => pool.id,
      "name" => pool.name,
      "status" => pool.status,
      "routing_strategy" => settings.routing_strategy,
      "bridge_ring_size" => settings.bridge_ring_size,
      "sticky_websocket_sessions" => settings.sticky_websocket_sessions,
      "sticky_http_sessions" => settings.sticky_http_sessions,
      "prompt_cache_affinity_enabled" => settings.prompt_cache_affinity_enabled,
      "v1_compatibility_enabled" => settings.v1_compatibility_enabled,
      "request_compression_enabled" => settings.request_compression_enabled,
      "allow_image_generation" => settings.allow_image_generation,
      "upstream_identity_ids" => active_upstream_identity_ids(pool),
      "api_key_ids" => active_api_key_ids(pool)
    }
    |> Map.merge(attrs)
    |> normalize_multi_select("upstream_identity_ids")
    |> normalize_multi_select("api_key_ids")
    |> to_form(as: :pool_edit, errors: errors)
  end

  @spec model_serving_form(
          model_serving_snapshot(),
          [model_serving_catalog_entry()],
          map() | keyword()
        ) ::
          model_serving_projection()
  def model_serving_form(snapshot, visible_models, submitted_attrs \\ %{})
      when is_map(snapshot) and is_list(visible_models) do
    submitted_attrs = Map.new(submitted_attrs)
    rows = model_serving_rows(snapshot, visible_models, submitted_attrs)

    %{
      revision: submitted_revision(submitted_attrs, snapshot.revision),
      revision_name: "pool_model_serving[revision]",
      rows: rows,
      warnings: rows |> Enum.map(& &1.warning) |> Enum.reject(&is_nil/1)
    }
  end

  @spec model_serving_submission(map() | keyword()) :: model_serving_submission()
  def model_serving_submission(attrs) do
    attrs = Map.new(attrs)

    %{
      revision: Map.get(attrs, "revision", Map.get(attrs, :revision)),
      rows:
        attrs
        |> Map.get("rows", Map.get(attrs, :rows, %{}))
        |> submitted_rows()
    }
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
    |> UpstreamAssignments.list_pool_assignments()
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
      "v1_compatibility_enabled" => true,
      "request_compression_enabled" => false,
      "allow_image_generation" => true,
      "upstream_identity_ids" => [],
      "api_key_ids" => []
    }
    |> Map.merge(Map.new(attrs))
    |> normalize_multi_select("upstream_identity_ids")
    |> normalize_multi_select("api_key_ids")
  end

  @spec model_serving_rows(model_serving_snapshot(), [model_serving_catalog_entry()], map()) ::
          [model_serving_row()]
  defp model_serving_rows(snapshot, visible_models, submitted_attrs) do
    overrides_by_id = Map.new(snapshot.overrides, &{&1.exposed_model_id, &1})

    available_rows =
      visible_models
      |> Enum.map(&available_model_row(&1, overrides_by_id))
      |> Enum.reject(&is_nil/1)

    available_ids = MapSet.new(available_rows, & &1.exposed_model_id)

    unavailable_rows =
      snapshot.overrides
      |> Enum.reject(&MapSet.member?(available_ids, &1.exposed_model_id))
      |> Enum.map(&unavailable_model_row/1)

    submitted_modes = submitted_modes(submitted_attrs, available_ids, snapshot.overrides)

    (available_rows ++ unavailable_rows)
    |> Enum.sort_by(&{&1.available?, &1.exposed_model_id}, :desc)
    |> Enum.with_index()
    |> Enum.map(fn {row, index} ->
      row
      |> Map.put(
        :configured_mode,
        Map.get(submitted_modes, row.exposed_model_id, row.configured_mode)
      )
      |> project_model_serving_row(index)
    end)
  end

  @spec available_model_row(
          model_serving_catalog_entry(),
          %{optional(String.t()) => ModelServingOverride.t()}
        ) ::
          map() | nil
  defp available_model_row({%Model{} = model, routable_source_ids}, overrides_by_id) do
    with exposed_model_id when is_binary(exposed_model_id) <-
           ModelServingOverride.canonical_exposed_model_id(model.exposed_model_id) do
      %{
        exposed_model_id: exposed_model_id,
        display_name: model.display_name || exposed_model_id,
        metadata: model.metadata || %{},
        routable_source_ids: routable_source_ids,
        configured_mode: configured_mode(Map.get(overrides_by_id, exposed_model_id)),
        available?: true,
        warning: nil
      }
    end
  end

  defp available_model_row(%Model{} = model, overrides_by_id) do
    available_model_row({model, source_assignment_ids(model)}, overrides_by_id)
  end

  @spec unavailable_model_row(ModelServingOverride.t()) :: map()
  defp unavailable_model_row(%ModelServingOverride{} = override) do
    %{
      exposed_model_id: override.exposed_model_id,
      display_name: override.exposed_model_id,
      metadata: %{},
      routable_source_ids: [],
      configured_mode: override.mode,
      available?: false,
      warning: "#{override.exposed_model_id} is not available in the current routable catalog"
    }
  end

  @spec project_model_serving_row(map(), non_neg_integer()) :: model_serving_row()
  defp project_model_serving_row(
         %{available?: false, configured_mode: "auto"} = row,
         index
       ) do
    row
    |> Map.merge(%{
      configured_mode: "auto",
      effective_mode: "removed",
      source: "removal",
      effective_badge: %{label: "Will be removed on save", mode: "removed"}
    })
    |> model_serving_row(index)
  end

  defp project_model_serving_row(
         %{available?: false, configured_mode: mode} = row,
         index
       )
       when mode in ~w(lite full) do
    row
    |> Map.merge(%{
      configured_mode: mode,
      effective_mode: mode,
      source: "override",
      effective_badge: %{
        label: "Effective: #{String.capitalize(mode)}",
        mode: mode
      }
    })
    |> model_serving_row(index)
  end

  defp project_model_serving_row(row, index) do
    {:ok, resolution} =
      ModelServingMode.resolve(
        configured_override(row.configured_mode),
        row.metadata,
        row.routable_source_ids
      )

    row
    |> Map.merge(%{
      configured_mode: resolution.configured_mode,
      effective_mode: resolution.effective_mode,
      source: resolution.source,
      effective_badge: %{
        label: "Effective: #{String.capitalize(resolution.effective_mode)}",
        mode: resolution.effective_mode
      }
    })
    |> model_serving_row(index)
  end

  defp model_serving_row(row, index) do
    dom_id = model_serving_dom_id(row.exposed_model_id)

    %{
      index: index,
      exposed_model_id: row.exposed_model_id,
      display_name: row.display_name,
      configured_mode: row.configured_mode,
      effective_mode: row.effective_mode,
      source: row.source,
      effective_badge: row.effective_badge,
      available?: row.available?,
      warning: row.warning,
      dom_id: dom_id,
      identifier_name: "pool_model_serving[rows][#{index}][exposed_model_id]",
      mode_name: "pool_model_serving[rows][#{index}][mode]",
      input_ids: mode_input_ids(dom_id),
      labels: mode_labels(row.exposed_model_id)
    }
  end

  @spec submitted_modes(map(), MapSet.t(String.t()), [ModelServingOverride.t()]) :: %{
          optional(String.t()) => String.t()
        }
  defp submitted_modes(submitted_attrs, available_ids, overrides) do
    known_ids = Enum.reduce(overrides, available_ids, &MapSet.put(&2, &1.exposed_model_id))

    submitted_attrs
    |> Map.get("rows", Map.get(submitted_attrs, :rows, %{}))
    |> submitted_rows()
    |> Enum.reduce(%{}, fn submitted_row, modes ->
      with exposed_model_id when is_binary(exposed_model_id) <-
             ModelServingOverride.canonical_exposed_model_id(
               submitted_value(submitted_row, "exposed_model_id")
             ),
           mode when mode in ["auto", "lite", "full"] <-
             normalize_submitted_mode(submitted_value(submitted_row, "mode")),
           true <- MapSet.member?(known_ids, exposed_model_id) do
        Map.put_new(modes, exposed_model_id, mode)
      else
        _invalid_or_unknown -> modes
      end
    end)
  end

  @spec submitted_rows(term()) :: [map()]
  defp submitted_rows(rows) when is_list(rows), do: Enum.filter(rows, &is_map/1)

  defp submitted_rows(rows) when is_map(rows) do
    rows
    |> Enum.sort_by(fn {index, _row} -> sortable_row_index(index) end)
    |> Enum.map(&elem(&1, 1))
    |> Enum.filter(&is_map/1)
  end

  defp submitted_rows(_rows), do: []

  @spec submitted_revision(map(), String.t()) :: String.t()
  defp submitted_revision(attrs, default) do
    case Map.get(attrs, "revision", Map.get(attrs, :revision)) do
      revision when is_binary(revision) -> revision
      _missing -> default
    end
  end

  @spec submitted_value(map(), String.t()) :: term()
  defp submitted_value(row, "exposed_model_id"),
    do: Map.get(row, "exposed_model_id", Map.get(row, :exposed_model_id))

  defp submitted_value(row, "mode"), do: Map.get(row, "mode", Map.get(row, :mode))

  @spec normalize_submitted_mode(term()) :: String.t() | nil
  defp normalize_submitted_mode(mode) when is_binary(mode),
    do: mode |> String.trim() |> String.downcase()

  defp normalize_submitted_mode(_mode), do: nil

  @spec sortable_row_index(term()) :: {non_neg_integer(), String.t()}
  defp sortable_row_index(index) do
    case Integer.parse(to_string(index)) do
      {number, ""} -> {number, to_string(index)}
      _invalid -> {9_999_999, to_string(index)}
    end
  end

  @spec source_assignment_ids(Model.t()) :: [Ecto.UUID.t()]
  defp source_assignment_ids(%Model{} = model) do
    case get_in(model.metadata || %{}, ["source_assignment_ids"]) do
      ids when is_list(ids) -> Enum.filter(ids, &is_binary/1)
      _missing_or_invalid -> []
    end
  end

  @spec model_serving_dom_id(String.t()) :: String.t()
  @doc false
  def model_serving_dom_id(exposed_model_id) do
    token = dom_token(exposed_model_id)

    digest =
      exposed_model_id
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 8)

    "pool-model-serving-row-#{token}-#{digest}"
  end

  @spec mode_input_ids(String.t()) :: %{auto: String.t(), lite: String.t(), full: String.t()}
  defp mode_input_ids(dom_id),
    do: %{auto: dom_id <> "-auto", lite: dom_id <> "-lite", full: dom_id <> "-full"}

  @spec mode_labels(String.t()) :: %{
          fieldset: String.t(),
          auto: String.t(),
          lite: String.t(),
          full: String.t()
        }
  defp mode_labels(exposed_model_id) do
    %{
      fieldset: "Model serving mode for #{exposed_model_id}",
      auto: "Auto for #{exposed_model_id}",
      lite: "Lite for #{exposed_model_id}",
      full: "Full for #{exposed_model_id}"
    }
  end

  @spec configured_mode(ModelServingOverride.t() | nil) :: String.t()
  defp configured_mode(%ModelServingOverride{mode: mode}), do: mode
  defp configured_mode(nil), do: "auto"

  @spec configured_override(String.t()) :: String.t() | nil
  defp configured_override("auto"), do: nil
  defp configured_override(mode), do: mode

  defp normalize_multi_select(attrs, key) do
    Map.update(attrs, key, [], fn value ->
      value
      |> List.wrap()
      |> Enum.reject(&(&1 in [nil, ""]))
    end)
  end

  defp value_for(attrs, "query", default),
    do: Map.get(attrs, "query") || Map.get(attrs, :query) || default

  defp value_for(attrs, "status", default),
    do: Map.get(attrs, "status") || Map.get(attrs, :status) || default

  defp value_for(attrs, "traffic_window", default),
    do: Map.get(attrs, "traffic_window") || Map.get(attrs, :traffic_window) || default

  defp list_input_values(nil), do: []

  defp list_input_values(values) when is_list(values),
    do: values |> Enum.reject(&(&1 in [nil, ""])) |> Enum.uniq()

  defp list_input_values(value) when is_binary(value), do: if(value == "", do: [], else: [value])
  defp list_input_values(_value), do: []

  defp active_upstream_identity_ids(pool) do
    pool
    |> UpstreamAssignments.list_pool_assignments()
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
