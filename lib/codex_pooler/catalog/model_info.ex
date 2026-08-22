defmodule CodexPooler.Catalog.ModelInfo do
  @moduledoc false

  alias CodexPooler.Catalog.Model

  @type description_state :: :missing | :available | :conflicting
  @type visibility_state :: :hidden | :listed | :mixed | :unknown
  @type api_support_state :: :supported | :unsupported | :mixed | :unknown
  @type context_profile :: %{
          required(:raw_window) => pos_integer(),
          required(:usable_window) => pos_integer(),
          required(:raw_max_window) => pos_integer(),
          required(:usable_max_window) => pos_integer(),
          required(:effective_percent) => 1..100
        }
  @type t :: %{
          required(:description) => String.t() | nil,
          required(:description_state) => description_state(),
          required(:visibility) => visibility_state(),
          required(:api_support) => api_support_state(),
          optional(:context_profiles) => [context_profile()],
          optional(:minimal_client_versions) => [String.t()],
          optional(:catalog_updated_at) => DateTime.t()
        }

  @empty %{
    description: nil,
    description_state: :missing,
    visibility: :unknown,
    api_support: :unknown
  }

  @spec empty() :: t()
  def empty, do: @empty

  @spec from_model(Model.t(), [term()]) :: t()
  def from_model(%Model{} = model, source_assignment_ids) do
    model.metadata
    |> from_metadata(source_assignment_ids)
    |> with_catalog_updated_at(model.last_seen_at)
  end

  @spec from_metadata(term(), [term()]) :: t()
  def from_metadata(metadata, source_assignment_ids) when is_list(source_assignment_ids) do
    source_models = metadata_map(metadata, "source_assignment_models")
    source_assignment_ids = normalize_source_assignment_ids(source_assignment_ids)

    sources =
      cond do
        source_assignment_ids != [] ->
          source_assignment_ids
          |> Enum.map(&Map.get(source_models, &1))
          |> Enum.filter(&is_map/1)

        map_size(source_models) > 0 ->
          source_models
          |> Map.values()
          |> Enum.filter(&is_map/1)

        true ->
          case metadata_map(metadata, "upstream_model") do
            fallback when map_size(fallback) > 0 -> [fallback]
            _missing -> []
          end
      end

    from_sources(sources)
  end

  def from_metadata(_metadata, _source_assignment_ids), do: @empty

  @spec from_sources([term()]) :: t()
  def from_sources(sources) when is_list(sources) do
    sources = Enum.filter(sources, &is_map/1)
    descriptions = sources |> Enum.map(&description/1) |> Enum.reject(&is_nil/1)

    %{
      description: shared_description(descriptions),
      description_state: description_state(descriptions),
      visibility: aggregate_source_state(sources, &visibility/1),
      api_support: aggregate_source_state(sources, &api_support/1)
    }
    |> maybe_put_context_profiles(context_profiles(sources))
    |> maybe_put_minimal_client_versions(minimal_client_versions(sources))
  end

  def from_sources(_sources), do: @empty

  @spec merge([t()]) :: t()
  def merge(infos) when is_list(infos) do
    infos = Enum.filter(infos, &model_info?/1)

    %{
      description: merged_description(infos),
      description_state: merged_description_state(infos),
      visibility: merge_projected_state(infos, :visibility),
      api_support: merge_projected_state(infos, :api_support)
    }
    |> maybe_put_context_profiles(merged_context_profiles(infos))
    |> maybe_put_minimal_client_versions(merged_minimal_client_versions(infos))
    |> with_catalog_updated_at(latest_catalog_updated_at(infos))
  end

  def merge(_infos), do: @empty

  @spec present?(term()) :: boolean()
  def present?(info) when is_map(info) do
    Map.get(info, :description_state) in [:available, :conflicting] or
      Map.get(info, :visibility) in [:hidden, :mixed] or
      Map.get(info, :api_support) in [:unsupported, :mixed] or
      Map.get(info, :context_profiles, []) != [] or
      Map.get(info, :minimal_client_versions, []) != []
  end

  def present?(_info), do: false

  @spec with_catalog_updated_at(t(), term()) :: t()
  def with_catalog_updated_at(info, %DateTime{} = updated_at) when is_map(info),
    do: Map.put(info, :catalog_updated_at, updated_at)

  def with_catalog_updated_at(info, _updated_at), do: info

  defp normalize_source_assignment_ids(ids) do
    ids
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp description(source) do
    case Map.get(source, "description") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          value -> value
        end

      _missing_or_invalid ->
        nil
    end
  end

  defp shared_description(descriptions) do
    case Enum.uniq(descriptions) do
      [description] -> description
      _missing_or_conflicting -> nil
    end
  end

  defp description_state(descriptions) do
    case descriptions |> Enum.uniq() |> length() do
      0 -> :missing
      1 -> :available
      _conflicting -> :conflicting
    end
  end

  defp visibility(source) do
    case Map.get(source, "visibility") do
      value when is_binary(value) ->
        case value |> String.trim() |> String.downcase() do
          "hide" -> :hidden
          "list" -> :listed
          _other -> :unknown
        end

      _missing_or_invalid ->
        :unknown
    end
  end

  defp api_support(source) do
    case Map.get(source, "supported_in_api") do
      true -> :supported
      false -> :unsupported
      _missing_or_invalid -> :unknown
    end
  end

  defp context_profiles(sources) do
    sources
    |> Enum.map(&context_profile/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort_by(&context_profile_sort_key/1)
  end

  defp minimal_client_versions(sources) do
    sources
    |> Enum.map(&normalized_string(Map.get(&1, "minimal_client_version")))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort(&version_before_or_equal?/2)
  end

  defp context_profile(source) do
    with context_window when is_integer(context_window) and context_window > 0 <-
           Map.get(source, "context_window") do
      max_context_window = positive_integer(source["max_context_window"]) || context_window
      max_context_window = max(context_window, max_context_window)
      effective_percent = effective_context_percent(source)

      %{
        raw_window: context_window,
        usable_window: effective_window(context_window, effective_percent),
        raw_max_window: max_context_window,
        usable_max_window: effective_window(max_context_window, effective_percent),
        effective_percent: effective_percent
      }
    else
      _missing_or_invalid -> nil
    end
  end

  defp effective_context_percent(%{"effective_context_window_percent" => percent})
       when is_integer(percent) and percent in 1..100,
       do: percent

  defp effective_context_percent(_source), do: 95

  defp effective_window(context_window, percent),
    do: max(1, div(context_window * percent, 100))

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil

  defp context_profile_sort_key(profile) do
    {
      profile.raw_window,
      profile.raw_max_window,
      profile.effective_percent,
      profile.usable_window,
      profile.usable_max_window
    }
  end

  defp maybe_put_context_profiles(info, []), do: info
  defp maybe_put_context_profiles(info, profiles), do: Map.put(info, :context_profiles, profiles)

  defp maybe_put_minimal_client_versions(info, []), do: info

  defp maybe_put_minimal_client_versions(info, versions),
    do: Map.put(info, :minimal_client_versions, versions)

  defp merged_context_profiles(infos) do
    infos
    |> Enum.flat_map(&Map.get(&1, :context_profiles, []))
    |> Enum.uniq()
    |> Enum.sort_by(&context_profile_sort_key/1)
  end

  defp merged_minimal_client_versions(infos) do
    infos
    |> Enum.flat_map(&Map.get(&1, :minimal_client_versions, []))
    |> Enum.uniq()
    |> Enum.sort(&version_before_or_equal?/2)
  end

  defp latest_catalog_updated_at(infos) do
    infos
    |> Enum.map(&Map.get(&1, :catalog_updated_at))
    |> Enum.filter(&match?(%DateTime{}, &1))
    |> Enum.max_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)
  end

  defp normalized_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp normalized_string(_value), do: nil

  defp version_before_or_equal?(left, right) do
    case {Version.parse(left), Version.parse(right)} do
      {{:ok, _left}, {:ok, _right}} -> Version.compare(left, right) != :gt
      _invalid -> left <= right
    end
  end

  defp aggregate_source_state([], _project), do: :unknown

  defp aggregate_source_state(sources, project) do
    states = Enum.map(sources, project)

    cond do
      :unknown in states -> :unknown
      states |> Enum.uniq() |> length() > 1 -> :mixed
      true -> hd(states)
    end
  end

  defp merged_description(infos) do
    if Enum.any?(infos, &(Map.fetch!(&1, :description_state) == :conflicting)) do
      nil
    else
      infos
      |> Enum.filter(&(Map.fetch!(&1, :description_state) == :available))
      |> Enum.map(&Map.fetch!(&1, :description))
      |> shared_description()
    end
  end

  defp merged_description_state(infos) do
    if Enum.any?(infos, &(Map.fetch!(&1, :description_state) == :conflicting)) do
      :conflicting
    else
      infos
      |> Enum.filter(&(Map.fetch!(&1, :description_state) == :available))
      |> Enum.map(&Map.fetch!(&1, :description))
      |> description_state()
    end
  end

  defp merge_projected_state([], _key), do: :unknown

  defp merge_projected_state(infos, key) do
    states = Enum.map(infos, &Map.fetch!(&1, key))

    cond do
      :mixed in states -> :mixed
      :unknown in states -> :unknown
      states |> Enum.uniq() |> length() > 1 -> :mixed
      true -> hd(states)
    end
  end

  defp model_info?(
         %{
           description: description,
           description_state: description_state,
           visibility: visibility,
           api_support: api_support
         } = info
       ) do
    context_profiles = Map.get(info, :context_profiles, [])

    (is_binary(description) or is_nil(description)) and
      description_state in [:missing, :available, :conflicting] and
      visibility in [:hidden, :listed, :mixed, :unknown] and
      api_support in [:supported, :unsupported, :mixed, :unknown] and
      is_list(context_profiles) and Enum.all?(context_profiles, &context_profile?/1)
  end

  defp model_info?(_info), do: false

  defp context_profile?(%{
         raw_window: raw_window,
         usable_window: usable_window,
         raw_max_window: raw_max_window,
         usable_max_window: usable_max_window,
         effective_percent: effective_percent
       }) do
    Enum.all?(
      [raw_window, usable_window, raw_max_window, usable_max_window],
      &(is_integer(&1) and &1 > 0)
    ) and
      effective_percent in 1..100
  end

  defp context_profile?(_profile), do: false

  defp metadata_map(metadata, key) when is_map(metadata) do
    case Map.get(metadata, key) do
      value when is_map(value) -> value
      _missing_or_invalid -> %{}
    end
  end

  defp metadata_map(_metadata, _key), do: %{}
end
