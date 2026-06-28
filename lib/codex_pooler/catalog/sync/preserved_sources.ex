defmodule CodexPooler.Catalog.Sync.PreservedSources do
  @moduledoc """
  One-sync source assignment preservation policy for catalog model metadata.
  """

  alias CodexPooler.Catalog.{Model, SyncRun}

  @missing_source_assignment_syncs "source_assignment_missing_sync_run_ids"

  @type assignment_ref :: %{required(:assignment) => %{required(:id) => String.t()}}
  @type aggregate :: %{required(:source_assignment_models) => map()}
  @type attrs :: %{
          required(:source_assignment_ids) => [String.t()],
          required(:source_assignment_models) => map(),
          required(:missing_source_assignment_syncs) => map()
        }

  @spec missing_sync_metadata_key() :: String.t()
  def missing_sync_metadata_key, do: @missing_source_assignment_syncs

  @spec assignment_attrs(Model.t() | nil, aggregate(), [assignment_ref()], SyncRun.t()) :: attrs()
  def assignment_attrs(existing, aggregate, assignments, %SyncRun{} = run) do
    observed_models = normalize_source_assignment_models(aggregate.source_assignment_models)
    observed_ids = observed_models |> Map.keys() |> MapSet.new()
    eligible_ids = assignments |> Enum.map(& &1.assignment.id) |> MapSet.new()
    previous_ids = existing_source_assignment_ids(existing)
    previous_models = existing_source_assignment_models(existing)
    previously_missing = existing_missing_source_assignment_syncs(existing)

    preserved_ids =
      Enum.filter(previous_ids, fn assignment_id ->
        MapSet.member?(eligible_ids, assignment_id) and
          not MapSet.member?(observed_ids, assignment_id) and
          not Map.has_key?(previously_missing, assignment_id)
      end)

    preserved_models =
      Map.new(preserved_ids, fn assignment_id ->
        {assignment_id, Map.get(previous_models, assignment_id, %{})}
      end)

    source_assignment_models = Map.merge(preserved_models, observed_models)
    source_assignment_ids = source_assignment_models |> Map.keys() |> Enum.sort()

    missing_source_assignment_syncs =
      Map.new(preserved_ids, fn assignment_id -> {assignment_id, run.id} end)

    %{
      source_assignment_ids: source_assignment_ids,
      source_assignment_models: source_assignment_models,
      missing_source_assignment_syncs: missing_source_assignment_syncs
    }
  end

  @spec existing_source_assignment_ids(Model.t() | nil) :: [String.t()]
  defp existing_source_assignment_ids(%Model{metadata: metadata}) when is_map(metadata) do
    metadata
    |> Map.get("source_assignment_ids", [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp existing_source_assignment_ids(_existing), do: []

  @spec existing_source_assignment_models(Model.t() | nil) :: map()
  defp existing_source_assignment_models(%Model{metadata: metadata}) when is_map(metadata) do
    metadata
    |> Map.get("source_assignment_models", %{})
    |> normalize_source_assignment_models()
  end

  defp existing_source_assignment_models(_existing), do: %{}

  @spec existing_missing_source_assignment_syncs(Model.t() | nil) :: map()
  defp existing_missing_source_assignment_syncs(%Model{metadata: metadata})
       when is_map(metadata) do
    metadata
    |> Map.get(@missing_source_assignment_syncs, %{})
    |> normalize_source_assignment_markers()
  end

  defp existing_missing_source_assignment_syncs(_existing), do: %{}

  @spec normalize_source_assignment_models(term()) :: map()
  defp normalize_source_assignment_models(models) when is_map(models) do
    Map.new(models, fn {assignment_id, model_metadata} ->
      {to_string(assignment_id), normalize_source_assignment_model(model_metadata)}
    end)
  end

  defp normalize_source_assignment_models(_models), do: %{}

  @spec normalize_source_assignment_model(term()) :: map()
  defp normalize_source_assignment_model(model_metadata) when is_map(model_metadata),
    do: model_metadata

  defp normalize_source_assignment_model(_model_metadata), do: %{}

  @spec normalize_source_assignment_markers(term()) :: map()
  defp normalize_source_assignment_markers(markers) when is_map(markers) do
    Map.new(markers, fn {assignment_id, sync_run_id} ->
      {to_string(assignment_id), sync_run_id}
    end)
  end

  defp normalize_source_assignment_markers(_markers), do: %{}
end
