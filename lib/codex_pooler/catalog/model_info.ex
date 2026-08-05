defmodule CodexPooler.Catalog.ModelInfo do
  @moduledoc false

  alias CodexPooler.Catalog.Model

  @type description_state :: :missing | :available | :conflicting
  @type visibility_state :: :hidden | :listed | :mixed | :unknown
  @type api_support_state :: :supported | :unsupported | :mixed | :unknown
  @type t :: %{
          required(:description) => String.t() | nil,
          required(:description_state) => description_state(),
          required(:visibility) => visibility_state(),
          required(:api_support) => api_support_state()
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
    from_metadata(model.metadata, source_assignment_ids)
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
  end

  def merge(_infos), do: @empty

  @spec present?(term()) :: boolean()
  def present?(info) when is_map(info) do
    Map.get(info, :description_state) in [:available, :conflicting] or
      Map.get(info, :visibility) in [:hidden, :mixed] or
      Map.get(info, :api_support) in [:unsupported, :mixed]
  end

  def present?(_info), do: false

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

  defp model_info?(%{
         description: description,
         description_state: description_state,
         visibility: visibility,
         api_support: api_support
       }) do
    (is_binary(description) or is_nil(description)) and
      description_state in [:missing, :available, :conflicting] and
      visibility in [:hidden, :listed, :mixed, :unknown] and
      api_support in [:supported, :unsupported, :mixed, :unknown]
  end

  defp model_info?(_info), do: false

  defp metadata_map(metadata, key) when is_map(metadata) do
    case Map.get(metadata, key) do
      value when is_map(value) -> value
      _missing_or_invalid -> %{}
    end
  end

  defp metadata_map(_metadata, _key), do: %{}
end
