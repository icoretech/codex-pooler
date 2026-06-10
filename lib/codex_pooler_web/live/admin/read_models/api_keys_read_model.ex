defmodule CodexPoolerWeb.Admin.ApiKeysReadModel do
  @moduledoc false

  alias CodexPooler.Access
  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounting
  alias CodexPooler.Catalog
  alias CodexPooler.Pools
  alias CodexPooler.Pools.Pool
  alias CodexPoolerWeb.Admin.ApiKeyPolicyForm
  alias CodexPoolerWeb.Admin.OptionLoaderFallback

  @type data_load_warning :: map()
  @type filters :: %{optional(String.t()) => String.t()}
  @type option :: {String.t(), Ecto.UUID.t() | String.t()}
  @type pool_lookup :: %{optional(Ecto.UUID.t()) => Pool.t()}
  @type usage_summary :: map()
  @type model_policy_summary :: %{
          required(:unavailable?) => boolean(),
          required(:unavailable_identifiers) => [String.t()],
          required(:unavailable_allowed_identifiers) => [String.t()],
          required(:enforced_unavailable?) => boolean(),
          required(:enforced_model_identifier) => String.t() | nil,
          required(:warning_label) => String.t() | nil
        }
  @type pool_group :: %{
          required(:id) => Ecto.UUID.t() | nil,
          required(:dom_id) => String.t(),
          required(:name) => String.t(),
          required(:api_keys) => [APIKey.t()],
          required(:count_label) => String.t()
        }
  @type page_state :: %{
          required(:pools) => [Pool.t()],
          required(:pool_lookup) => pool_lookup(),
          required(:api_keys) => [APIKey.t()],
          required(:filter_values) => filters(),
          required(:selected_pool) => Pool.t() | nil,
          required(:api_key_usage_summaries) => %{optional(Ecto.UUID.t()) => usage_summary()},
          required(:api_key_model_policy_summaries) => %{
            optional(Ecto.UUID.t()) => model_policy_summary()
          },
          required(:api_key_pool_groups) => [pool_group()],
          required(:pool_options) => [option()],
          required(:model_policy_filter) => String.t() | nil,
          required(:unavailable_model_policy_count) => non_neg_integer(),
          required(:data_load_warnings) => [data_load_warning()]
        }

  @spec load(term()) :: page_state()
  def load(scope), do: load(scope, %{})

  @spec load(term(), map()) :: page_state()
  def load(scope, params) do
    pools = Pools.list_visible_pools(scope)
    pool_lookup = Map.new(pools, &{&1.id, &1})
    selected_pool = selected_pool(pools, Map.get(params, "pool_id"))
    model_policy_filter = normalize_model_policy_filter(Map.get(params, "model_policy"))
    filter_values = filter_values(selected_pool, model_policy_filter)
    {api_keys, data_load_warnings} = list_api_keys(scope)
    model_policy_summaries = model_policy_summaries(pools, api_keys)
    pool_filtered_api_keys = filter_api_keys(api_keys, selected_pool)

    unavailable_model_policy_count =
      Enum.count(
        pool_filtered_api_keys,
        &model_policy_unavailable?(model_policy_summaries[&1.id])
      )

    visible_api_keys =
      filter_model_policy(pool_filtered_api_keys, model_policy_filter, model_policy_summaries)

    usage_summaries = usage_summaries(visible_api_keys)

    %{
      pools: pools,
      pool_lookup: pool_lookup,
      api_keys: visible_api_keys,
      filter_values: filter_values,
      selected_pool: selected_pool,
      api_key_usage_summaries: usage_summaries,
      api_key_model_policy_summaries: model_policy_summaries,
      api_key_pool_groups:
        pool_groups(filter_pools(pools, selected_pool), pool_lookup, visible_api_keys),
      pool_options: pool_options(pools),
      model_policy_filter: model_policy_filter,
      unavailable_model_policy_count: unavailable_model_policy_count,
      data_load_warnings: data_load_warnings
    }
  end

  @spec selected_pool([Pool.t()], term()) :: Pool.t() | nil
  def selected_pool(pools, pool_id) when is_binary(pool_id),
    do: Enum.find(pools, &(&1.id == pool_id))

  def selected_pool(_pools, _pool_id), do: nil

  @spec filter_values(Pool.t() | nil) :: filters()
  def filter_values(pool), do: filter_values(pool, nil)

  @spec filter_values(Pool.t() | nil, String.t() | nil) :: filters()
  def filter_values(pool, model_policy_filter) do
    %{}
    |> Map.put("pool_id", pool_filter_value(pool))
    |> Map.put("model_policy", model_policy_filter || "")
  end

  @spec usage_for_params(map()) :: usage_summary()
  def usage_for_params(%{"id" => api_key_id, "pool_id" => pool_id}) do
    case {blank_to_nil(api_key_id), blank_to_nil(pool_id)} do
      {nil, _pool_id} -> empty_usage()
      {_api_key_id, nil} -> empty_usage()
      {api_key_id, pool_id} -> load_api_key_usage(pool_id, api_key_id)
    end
  end

  def usage_for_params(_params), do: empty_usage()

  @spec empty_usage() :: usage_summary()
  def empty_usage do
    %{
      available?: false,
      request_count: 0,
      total_tokens: 0,
      cached_input_tokens: 0,
      limits: []
    }
  end

  @spec model_selector_state(Pool.t() | nil, map()) :: map()
  def model_selector_state(nil, _params), do: empty_model_selector_state()

  def model_selector_state(%Pool{} = pool, params) do
    pool
    |> Catalog.api_key_model_selector_state(ApiKeyPolicyForm.model_selector_attrs(params))
    |> add_enforced_model_warning(params)
  end

  @spec empty_model_selector_state() :: map()
  def empty_model_selector_state do
    %{
      catalog: %{status: :unavailable, message: "Select a Pool first", severity: :warning},
      mode: :all_models,
      options: [],
      selected_options: [],
      selected_unavailable_chips: [],
      manual_chips: [],
      selected_identifiers: [],
      manual_identifiers: [],
      warnings: [],
      enforced_unavailable_warning: nil
    }
  end

  @spec pool_options([Pool.t()]) :: [option()]
  def pool_options([]), do: [{"No active Pools available", ""}]

  def pool_options(pools) do
    Enum.map(pools, &{&1.name, &1.id})
  end

  @spec pool_groups([Pool.t()], pool_lookup(), [APIKey.t()]) :: [pool_group()]
  def pool_groups(pools, pool_lookup, api_keys) do
    api_keys_by_pool_id = Enum.group_by(api_keys, & &1.pool_id)

    known_groups =
      pools
      |> Enum.flat_map(fn pool ->
        pool_api_keys = Map.get(api_keys_by_pool_id, pool.id, [])

        if pool_api_keys == [] do
          []
        else
          [
            %{
              id: pool.id,
              dom_id: pool_dom_id(pool),
              name: pool.name,
              api_keys: pool_api_keys,
              count_label: api_key_count_label(length(pool_api_keys))
            }
          ]
        end
      end)

    unknown_api_keys =
      Enum.reject(api_keys, fn api_key -> Map.has_key?(pool_lookup, api_key.pool_id) end)

    if unknown_api_keys == [] do
      known_groups
    else
      known_groups ++
        [
          %{
            id: nil,
            dom_id: "unknown-pool",
            name: "Unknown Pool",
            api_keys: unknown_api_keys,
            count_label: api_key_count_label(length(unknown_api_keys))
          }
        ]
    end
  end

  @spec model_policy_label(nil | [String.t()]) :: String.t()
  def model_policy_label(nil), do: "All models"
  def model_policy_label([]), do: "No models"
  def model_policy_label(models), do: Enum.join(models, ", ")

  @spec model_policy_unavailable?(model_policy_summary() | nil) :: boolean()
  def model_policy_unavailable?(%{unavailable?: unavailable?}), do: unavailable?
  def model_policy_unavailable?(_summary), do: false

  @spec model_policy_warning_label(model_policy_summary() | nil) :: String.t() | nil
  def model_policy_warning_label(%{warning_label: warning_label}), do: warning_label
  def model_policy_warning_label(_summary), do: nil

  @spec unavailable_model_policy_count_label(non_neg_integer()) :: String.t()
  def unavailable_model_policy_count_label(1), do: "1 affected key"
  def unavailable_model_policy_count_label(count), do: "#{count} affected keys"

  @spec usage_present?(usage_summary() | nil) :: boolean()
  def usage_present?(usage) do
    positive_integer?(usage[:request_count]) or positive_integer?(usage[:total_tokens]) or
      positive_integer?(usage[:cached_input_tokens])
  end

  @spec row_usage_cost(usage_summary() | nil) :: String.t() | nil
  def row_usage_cost(%{total_cost_status: "priced", total_cost_usd: %Decimal{} = usd}) do
    "Cost $#{format_usd(usd)}"
  end

  def row_usage_cost(_usage), do: nil

  @spec format_integer(integer() | Decimal.t() | nil | term()) :: String.t()
  def format_integer(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  def format_integer(%Decimal{} = value),
    do: value |> Decimal.round(0) |> Decimal.to_integer() |> format_integer()

  def format_integer(nil), do: "unknown"
  def format_integer(value), do: value |> to_string() |> blank_to_nil() || "unknown"

  @spec api_key_operator_notes(APIKey.t() | term()) :: String.t() | nil
  def api_key_operator_notes(%APIKey{metadata: metadata}) when is_map(metadata) do
    metadata
    |> Map.get("operator_notes", Map.get(metadata, :operator_notes))
    |> blank_to_nil()
  end

  def api_key_operator_notes(_api_key), do: nil

  defp list_api_keys(scope) do
    case Access.list_api_keys(scope) do
      {:ok, api_keys} ->
        {api_keys, []}

      {:error, reason} ->
        empty_admin_options(:api_keys, reason, %{
          title: "API keys unavailable",
          message: "API key data could not be loaded. Empty results may be incomplete."
        })
    end
  end

  defp model_policy_summaries(pools, api_keys) do
    visible_model_identifiers_by_pool_id = visible_model_identifier_sets(pools)

    Map.new(api_keys, fn %APIKey{id: api_key_id} = api_key ->
      {api_key_id, model_policy_summary(api_key, visible_model_identifiers_by_pool_id)}
    end)
  end

  defp visible_model_identifier_sets(pools) do
    Map.new(pools, fn %Pool{id: pool_id} = pool ->
      identifiers =
        pool
        |> Catalog.list_visible_models()
        |> Enum.map(&normalize_model_identifier(&1.exposed_model_id))
        |> Enum.reject(&is_nil/1)

      {pool_id, MapSet.new(identifiers)}
    end)
  end

  defp model_policy_summary(%APIKey{} = api_key, visible_model_identifiers_by_pool_id) do
    visible_identifiers =
      Map.get(visible_model_identifiers_by_pool_id, api_key.pool_id, MapSet.new())

    unavailable_allowed_identifiers =
      api_key.allowed_model_identifiers
      |> normalize_model_identifier_list()
      |> Enum.reject(&MapSet.member?(visible_identifiers, &1))

    enforced_model_identifier = blank_to_nil(api_key.enforced_model_identifier)
    normalized_enforced_model = normalize_model_identifier(enforced_model_identifier)

    enforced_unavailable? =
      not is_nil(normalized_enforced_model) and
        not MapSet.member?(visible_identifiers, normalized_enforced_model)

    unavailable_identifiers =
      unavailable_allowed_identifiers
      |> Enum.concat(if(enforced_unavailable?, do: [normalized_enforced_model], else: []))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    %{}
    |> Map.put(:unavailable?, unavailable_identifiers != [])
    |> Map.put(:unavailable_identifiers, unavailable_identifiers)
    |> Map.put(:unavailable_allowed_identifiers, unavailable_allowed_identifiers)
    |> Map.put(:enforced_unavailable?, enforced_unavailable?)
    |> Map.put(:enforced_model_identifier, enforced_model_identifier)
    |> Map.put(
      :warning_label,
      model_policy_warning_label(
        unavailable_allowed_identifiers,
        enforced_unavailable?,
        enforced_model_identifier
      )
    )
  end

  defp model_policy_warning_label(
         _unavailable_allowed_identifiers,
         true,
         enforced_model_identifier
       ) do
    "Enforced model #{enforced_model_identifier} is unavailable"
  end

  defp model_policy_warning_label([_identifier], false, _enforced_model_identifier),
    do: "1 selected model is unavailable"

  defp model_policy_warning_label(
         unavailable_allowed_identifiers,
         false,
         _enforced_model_identifier
       )
       when unavailable_allowed_identifiers != [] do
    "#{length(unavailable_allowed_identifiers)} selected models are unavailable"
  end

  defp model_policy_warning_label(
         _unavailable_allowed_identifiers,
         false,
         _enforced_model_identifier
       ),
       do: nil

  defp usage_summaries(api_keys) do
    api_keys
    |> Enum.map(& &1.id)
    |> Accounting.list_api_key_usage_summaries()
  end

  defp filter_api_keys(api_keys, nil), do: api_keys

  defp filter_api_keys(api_keys, %Pool{id: pool_id}) do
    Enum.filter(api_keys, &(&1.pool_id == pool_id))
  end

  defp filter_model_policy(api_keys, "unavailable", model_policy_summaries) do
    Enum.filter(api_keys, &model_policy_unavailable?(model_policy_summaries[&1.id]))
  end

  defp filter_model_policy(api_keys, _model_policy_filter, _model_policy_summaries), do: api_keys

  defp filter_pools(pools, nil), do: pools
  defp filter_pools(_pools, %Pool{} = pool), do: [pool]

  defp load_api_key_usage(pool_id, api_key_id) do
    case Accounting.build_api_key_self_usage(pool_id, api_key_id) do
      {:ok, usage} -> Map.put(usage, :available?, true)
      {:error, _reason} -> empty_usage()
    end
  end

  defp pool_dom_id(pool) do
    pool.slug
    |> dom_token()
    |> case do
      "" -> dom_token(pool.id)
      dom_id -> dom_id
    end
  end

  defp api_key_count_label(1), do: "1 key"
  defp api_key_count_label(count), do: "#{count} keys"

  defp pool_filter_value(%Pool{id: pool_id}), do: pool_id
  defp pool_filter_value(_pool), do: ""

  defp normalize_model_policy_filter("unavailable"), do: "unavailable"
  defp normalize_model_policy_filter(_filter), do: nil

  defp add_enforced_model_warning(selector_state, params) when is_map(selector_state) do
    enforced_model_identifier = params |> Map.get("enforced_model_identifier") |> blank_to_nil()
    normalized_enforced_model = normalize_model_identifier(enforced_model_identifier)

    available_identifiers =
      selector_state
      |> Map.get(:options, [])
      |> Enum.map(&normalize_model_identifier(&1.identifier))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    if normalized_enforced_model &&
         not MapSet.member?(available_identifiers, normalized_enforced_model) do
      warning = %{
        code: :enforced_model_unavailable,
        severity: :warning,
        message:
          "Enforced model #{enforced_model_identifier} is not in the current routable catalog; runtime requests will fail until this is changed",
        requires_acknowledgement?: false
      }

      selector_state
      |> Map.put(:enforced_unavailable_warning, warning)
      |> Map.update(:warnings, [warning], &(&1 ++ [warning]))
    else
      Map.put(selector_state, :enforced_unavailable_warning, nil)
    end
  end

  defp normalize_model_identifier_list(nil), do: []

  defp normalize_model_identifier_list(values) when is_list(values) do
    values
    |> Enum.map(&normalize_model_identifier/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_model_identifier_list(_values), do: []

  defp normalize_model_identifier(nil), do: nil

  defp normalize_model_identifier(value) do
    value
    |> blank_to_nil()
    |> case do
      nil -> nil
      identifier -> String.downcase(identifier)
    end
  end

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp format_usd(%Decimal{} = usd) do
    usd
    |> Decimal.round(2)
    |> Decimal.to_string(:normal)
    |> fixed_decimal_places(2)
  end

  defp fixed_decimal_places(value, places) do
    case String.split(value, ".", parts: 2) do
      [whole] -> whole <> "." <> String.duplicate("0", places)
      [whole, fraction] -> whole <> "." <> String.pad_trailing(fraction, places, "0")
    end
  end

  defp dom_token(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "-")
    |> String.trim("-")
  end

  defp empty_admin_options(loader, reason, warning) do
    OptionLoaderFallback.empty_options(
      :api_keys,
      loader,
      reason,
      warning,
      [:pool_not_found, :api_key_not_found]
    )
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    value = String.trim(to_string(value))
    if value == "", do: nil, else: value
  end
end
