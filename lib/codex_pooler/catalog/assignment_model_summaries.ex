defmodule CodexPooler.Catalog.AssignmentModelSummaries do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Catalog.Model
  alias CodexPooler.Catalog.Sync.PreservedSources
  alias CodexPooler.Repo

  @active "active"
  @capabilities [:responses, :streaming, :tools, :reasoning]

  @type authorization_tuple :: {Ecto.UUID.t(), Ecto.UUID.t()}
  @type capability_value :: boolean() | :unknown
  @type capabilities :: %{
          required(:responses) => capability_value(),
          required(:streaming) => capability_value(),
          required(:tools) => capability_value(),
          required(:reasoning) => capability_value()
        }
  @type provenance :: :observed | :preserved
  @type summary :: %{
          required(:pool_id) => Ecto.UUID.t(),
          required(:assignment_id) => Ecto.UUID.t(),
          required(:exposed_model_id) => String.t(),
          required(:capabilities) => capabilities(),
          required(:provenance) => provenance()
        }
  @type model_projection :: %{
          required(:pool_id) => Ecto.UUID.t(),
          required(:exposed_model_id) => String.t(),
          required(:metadata) => map()
        }

  @spec list(term()) :: [summary()]
  def list(authorized_assignments) do
    case normalize_authorized_assignments(authorized_assignments) do
      {:ok, [_ | _] = authorized} -> list_authorized(authorized)
      _empty_or_invalid -> []
    end
  end

  defp list_authorized(authorized) do
    authorized_set = MapSet.new(authorized)
    pool_ids = authorized |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    Model
    |> where([model], model.pool_id in ^pool_ids and model.status == ^@active)
    |> order_by([model], asc: model.pool_id, asc: model.exposed_model_id, asc: model.id)
    |> select([model], %{
      pool_id: model.pool_id,
      exposed_model_id: model.exposed_model_id,
      metadata: model.metadata
    })
    |> Repo.all()
    |> Enum.flat_map(&summaries_for_model(&1, authorized_set))
  end

  @spec summaries_for_model(model_projection(), MapSet.t(authorization_tuple())) :: [summary()]
  defp summaries_for_model(model, authorized_set) do
    source_models = metadata_map(model.metadata, "source_assignment_models")
    preserved = metadata_map(model.metadata, PreservedSources.missing_sync_metadata_key())

    source_models
    |> Enum.flat_map(fn
      {assignment_id, source_metadata}
      when is_binary(assignment_id) and is_map(source_metadata) ->
        tuple = {model.pool_id, assignment_id}

        if MapSet.member?(authorized_set, tuple) do
          [
            %{
              pool_id: model.pool_id,
              assignment_id: assignment_id,
              exposed_model_id: model.exposed_model_id,
              capabilities: capabilities(source_metadata),
              provenance:
                if(Map.has_key?(preserved, assignment_id), do: :preserved, else: :observed)
            }
          ]
        else
          []
        end

      _malformed ->
        []
    end)
    |> Enum.sort_by(&{&1.assignment_id, &1.exposed_model_id})
  end

  @spec capabilities(map()) :: capabilities()
  defp capabilities(source_metadata) do
    nested = metadata_map(source_metadata, "capabilities")

    Map.new(@capabilities, fn capability ->
      direct_key = "supports_#{capability}"
      nested_key = Atom.to_string(capability)

      value =
        case Map.fetch(source_metadata, direct_key) do
          {:ok, value} -> boolean_or_unknown(value)
          :error -> nested |> Map.get(nested_key) |> boolean_or_unknown()
        end

      {capability, value}
    end)
  end

  defp normalize_authorized_assignments(assignments) when is_list(assignments) do
    with {:ok, normalized} <- normalize_authorization_entries(assignments) do
      {:ok, normalized |> Enum.uniq() |> Enum.sort()}
    end
  end

  defp normalize_authorized_assignments(_assignments), do: :error

  defp normalize_authorization_entries(assignments) do
    Enum.reduce_while(assignments, {:ok, []}, fn
      {pool_id, assignment_id}, {:ok, normalized}
      when is_binary(pool_id) and is_binary(assignment_id) ->
        with {:ok, pool_id} <- Ecto.UUID.cast(pool_id),
             {:ok, assignment_id} <- Ecto.UUID.cast(assignment_id) do
          {:cont, {:ok, [{pool_id, assignment_id} | normalized]}}
        else
          :error -> {:halt, :error}
        end

      _invalid, _normalized ->
        {:halt, :error}
    end)
  end

  defp metadata_map(metadata, key) when is_map(metadata) do
    case Map.get(metadata, key) do
      value when is_map(value) -> value
      _value -> %{}
    end
  end

  defp metadata_map(_metadata, _key), do: %{}
  defp boolean_or_unknown(value) when is_boolean(value), do: value
  defp boolean_or_unknown(_value), do: :unknown
end
