defmodule CodexPooler.Pools.ModelServingMode do
  @moduledoc false

  alias CodexPooler.Pools.ModelServingOverride

  @type configured_mode :: String.t()
  @type effective_mode :: String.t()
  @type resolution_source :: String.t()
  @type resolution :: %{
          required(:configured_mode) => configured_mode(),
          required(:effective_mode) => effective_mode(),
          required(:source) => resolution_source()
        }

  @spec resolve(ModelServingOverride.t() | String.t() | nil, map(), [Ecto.UUID.t()]) ::
          {:ok, resolution()} | :no_runtime_model
  def resolve(_configured_mode, _metadata, []), do: :no_runtime_model

  def resolve(%ModelServingOverride{mode: mode}, metadata, routable_source_ids),
    do: resolve(mode, metadata, routable_source_ids)

  def resolve(mode, _metadata, _routable_source_ids) when mode in ~w(lite full) do
    {:ok, %{configured_mode: mode, effective_mode: mode, source: "override"}}
  end

  def resolve(nil, metadata, routable_source_ids)
      when is_map(metadata) and is_list(routable_source_ids) do
    effective_mode =
      case Map.get(metadata, "source_assignment_models", :absent) do
        source_models when is_map(source_models) ->
          if any_source_lite?(source_models, routable_source_ids), do: "lite", else: "full"

        _absent_or_malformed ->
          if Map.get(metadata, "use_responses_lite") == true, do: "lite", else: "full"
      end

    {:ok, %{configured_mode: "auto", effective_mode: effective_mode, source: "catalog"}}
  end

  def resolve(nil, _metadata, _routable_source_ids) do
    {:ok, %{configured_mode: "auto", effective_mode: "full", source: "catalog"}}
  end

  defp any_source_lite?(source_models, routable_source_ids) do
    Enum.any?(routable_source_ids, fn source_id ->
      case Map.get(source_models, source_id) do
        source_metadata when is_map(source_metadata) ->
          Map.get(source_metadata, "use_responses_lite") == true

        _missing_or_malformed ->
          false
      end
    end)
  end
end
