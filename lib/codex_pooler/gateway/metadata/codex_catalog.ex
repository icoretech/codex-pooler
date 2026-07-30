defmodule CodexPooler.Gateway.Metadata.CodexCatalog do
  @moduledoc false

  alias CodexPooler.Access
  alias CodexPooler.Catalog
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Metadata.CanonicalModelSource
  alias CodexPooler.Gateway.Routing.CandidateEligibility
  alias CodexPooler.Gateway.Routing.ModelMetadata
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment

  @etag_prefix ~s(W/"cp-models-v1-)

  @type normalized_policy :: map()
  @type body :: %{required(String.t()) => [map()]}
  @type result :: %{required(:body) => body(), required(:etag) => String.t()}
  @type pricing_buckets :: Catalog.pricing_bucket_map()
  @type context_window_overrides :: ModelMetadata.context_window_overrides()
  @type effective_model_serving_modes :: %{
          optional(String.t()) => ModelMetadata.effective_model_serving_mode()
        }
  @type selected_source :: {Model.t(), map()}
  @type candidate :: CandidateEligibility.candidate()
  @type candidates_by_model_id :: %{optional(Ecto.UUID.t()) => [candidate()]}
  @type selected_partition :: %{
          required(:assignment_ids) => [Ecto.UUID.t()],
          required(:digest) => String.t(),
          required(:model) => Model.t(),
          required(:source) => map()
        }

  @spec build([Model.t()], normalized_policy()) :: result()
  def build(routable_models, normalized_policy)
      when is_list(routable_models) and is_map(normalized_policy) do
    visible_models = policy_visible_models(routable_models, normalized_policy)

    build_visible(
      visible_models,
      normalized_policy,
      Catalog.pricing_buckets_by_identifier(visible_models)
    )
  end

  @spec build([Model.t()], normalized_policy(), pricing_buckets()) :: result()
  def build(routable_models, normalized_policy, pricing_buckets)
      when is_list(routable_models) and is_map(normalized_policy) and is_map(pricing_buckets) do
    build(routable_models, normalized_policy, pricing_buckets, %{})
  end

  @spec build(
          [Model.t()],
          normalized_policy(),
          pricing_buckets(),
          context_window_overrides()
        ) :: result()
  def build(routable_models, normalized_policy, pricing_buckets, context_window_overrides)
      when is_list(routable_models) and is_map(normalized_policy) and is_map(pricing_buckets) and
             is_map(context_window_overrides) do
    routable_models
    |> policy_visible_models(normalized_policy)
    |> build_visible(normalized_policy, pricing_buckets, context_window_overrides)
  end

  @spec build(
          [Model.t()],
          normalized_policy(),
          pricing_buckets(),
          context_window_overrides(),
          effective_model_serving_modes()
        ) :: result()
  def build(
        routable_models,
        normalized_policy,
        pricing_buckets,
        context_window_overrides,
        effective_model_serving_modes
      )
      when is_list(routable_models) and is_map(normalized_policy) and is_map(pricing_buckets) and
             is_map(context_window_overrides) and is_map(effective_model_serving_modes) do
    routable_models
    |> policy_visible_models(normalized_policy)
    |> build_visible(
      normalized_policy,
      pricing_buckets,
      context_window_overrides,
      effective_model_serving_modes
    )
  end

  @spec build_selected_sources(
          [selected_source()],
          normalized_policy(),
          pricing_buckets(),
          context_window_overrides(),
          effective_model_serving_modes()
        ) :: {:ok, result()} | {:error, :invalid_model_metadata}
  def build_selected_sources(
        selected_sources,
        normalized_policy,
        pricing_buckets,
        context_window_overrides,
        effective_model_serving_modes
      )
      when is_list(selected_sources) and is_map(normalized_policy) and is_map(pricing_buckets) and
             is_map(context_window_overrides) and is_map(effective_model_serving_modes) do
    selected_sources
    |> Enum.filter(fn {%Model{} = model, _source} ->
      policy_visible_models([model], normalized_policy) != []
    end)
    |> Enum.reduce_while({:ok, []}, fn {%Model{} = model, source}, {:ok, models} ->
      mode = Map.get(effective_model_serving_modes, model.exposed_model_id, "full")

      case CanonicalModelSource.project(
             source,
             model,
             pricing_buckets,
             context_window_overrides,
             mode
           ) do
        {:ok, payload} -> {:cont, {:ok, [payload | models]}}
        {:error, :invalid_model_metadata} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, models} -> {:ok, result_from_models(models)}
      {:error, :invalid_model_metadata} = error -> error
    end
  end

  @spec select_canonical_sources([Model.t()], candidates_by_model_id()) :: [selected_partition()]
  def select_canonical_sources(models, candidates_by_model_id)
      when is_list(models) and is_map(candidates_by_model_id) do
    Enum.flat_map(models, fn
      %Model{} = model ->
        case select_model_partition(model, Map.get(candidates_by_model_id, model.id, [])) do
          nil -> []
          partition -> [partition]
        end

      _model ->
        []
    end)
  end

  @spec valid_canonical_assignment_ids(Model.t(), [candidate()]) :: [Ecto.UUID.t()]
  def valid_canonical_assignment_ids(%Model{} = model, candidates) when is_list(candidates) do
    model
    |> canonical_pairs(candidates)
    |> Enum.map(& &1.assignment_id)
    |> Enum.sort()
  end

  @spec build_selected_partitions(
          [selected_partition()],
          normalized_policy(),
          pricing_buckets(),
          context_window_overrides(),
          effective_model_serving_modes()
        ) :: {:ok, result()} | {:error, :invalid_model_metadata}
  def build_selected_partitions(
        partitions,
        normalized_policy,
        pricing_buckets,
        context_window_overrides,
        effective_model_serving_modes
      )
      when is_list(partitions) do
    selected_sources =
      Enum.flat_map(partitions, fn
        %{model: %Model{} = model, source: source} when is_map(source) -> [{model, source}]
        _partition -> []
      end)

    build_selected_sources(
      selected_sources,
      normalized_policy,
      pricing_buckets,
      context_window_overrides,
      effective_model_serving_modes
    )
  end

  @spec build_canonical(
          [Model.t()],
          candidates_by_model_id(),
          normalized_policy(),
          pricing_buckets(),
          context_window_overrides(),
          effective_model_serving_modes()
        ) :: result()
  def build_canonical(
        models,
        candidates_by_model_id,
        normalized_policy,
        pricing_buckets,
        context_window_overrides,
        effective_model_serving_modes
      ) do
    models
    |> select_canonical_sources(candidates_by_model_id)
    |> build_selected_partitions(
      normalized_policy,
      pricing_buckets,
      context_window_overrides,
      effective_model_serving_modes
    )
    |> case do
      {:ok, result} -> result
      {:error, :invalid_model_metadata} -> result_from_models([])
    end
  end

  defp build_visible(
         visible_models,
         normalized_policy,
         pricing_buckets,
         context_window_overrides \\ %{},
         effective_model_serving_modes \\ nil
       ) do
    models =
      visible_models
      |> Enum.map(
        &model_payload(
          &1,
          normalized_policy,
          pricing_buckets,
          context_window_overrides,
          effective_model_serving_modes
        )
      )
      |> Enum.sort_by(&Map.fetch!(&1, "slug"))

    result_from_models(models)
  end

  defp result_from_models(models) do
    body = %{"models" => Enum.sort_by(models, &Map.fetch!(&1, "slug"))}
    %{body: body, etag: etag(body)}
  end

  defp policy_visible_models(routable_models, normalized_policy) do
    CandidateEligibility.policy_visible_models(routable_models, normalized_policy)
  end

  defp select_model_partition(%Model{} = model, candidates) when is_list(candidates) do
    model
    |> canonical_pairs(candidates)
    |> select_anchored_partition(model)
  end

  defp select_model_partition(%Model{}, _candidates), do: nil

  defp canonical_pairs(%Model{} = model, candidates) do
    case Map.get(model.metadata || %{}, "source_assignment_models") do
      source_models when is_map(source_models) ->
        Enum.flat_map(candidates, &canonical_pair(&1, model, source_models))

      _absent_or_malformed ->
        []
    end
  end

  defp canonical_pair(
         {%PoolUpstreamAssignment{id: assignment_id, created_at: %DateTime{} = created_at},
          _identity},
         %Model{} = model,
         source_models
       )
       when is_binary(assignment_id) do
    with {:ok, _uuid} <- Ecto.UUID.cast(assignment_id),
         {:ok, source} <- Map.fetch(source_models, assignment_id),
         {:ok, canonical} <- CanonicalModelSource.canonical_source(source),
         true <- valid_source_slug?(canonical.source, model) do
      [Map.merge(canonical, %{assignment_id: assignment_id, created_at: created_at})]
    else
      _invalid -> []
    end
  end

  defp canonical_pair(_candidate, _model, _source_models), do: []

  defp valid_source_slug?(%{"slug" => slug}, %Model{exposed_model_id: exposed_model_id})
       when is_binary(slug) and is_binary(exposed_model_id),
       do: String.trim(slug) != "" and String.downcase(slug) == String.downcase(exposed_model_id)

  defp valid_source_slug?(_source, %Model{}), do: false

  defp select_anchored_partition([], %Model{}), do: nil

  defp select_anchored_partition(pairs, %Model{} = model) do
    anchor = Enum.min_by(pairs, &{&1.created_at, &1.assignment_id})
    members = Map.fetch!(Enum.group_by(pairs, & &1.digest), anchor.digest)

    %{
      assignment_ids: members |> Enum.map(& &1.assignment_id) |> Enum.sort(),
      digest: anchor.digest,
      model: model,
      source: anchor.source
    }
  end

  @spec etag(map()) :: String.t()
  def etag(body) when is_map(body) do
    digest =
      {:codex_pooler_models, 1, canonical_json(body)}
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    @etag_prefix <> digest <> ~s(")
  end

  defp model_payload(
         %Model{} = model,
         policy,
         pricing_buckets,
         context_window_overrides,
         effective_model_serving_modes
       ) do
    {reasoning_levels, reasoning_default} =
      ModelMetadata.reasoning_level_maps_and_default(model)

    reasoning_projection =
      Access.project_reasoning_effort_metadata(policy, reasoning_levels, reasoning_default)

    case effective_model_serving_modes do
      nil ->
        ModelMetadata.codex_model_payload(
          model,
          pricing_buckets,
          reasoning_projection,
          context_window_overrides
        )

      effective_modes ->
        ModelMetadata.codex_model_payload(
          model,
          pricing_buckets,
          reasoning_projection,
          context_window_overrides,
          Map.get(effective_modes, model.exposed_model_id)
        )
    end
  end

  defp canonical_json(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested_value} -> {canonical_key(key), canonical_json(nested_value)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> reject_ambiguous_keys!()
    |> then(&{:object, &1})
  end

  defp canonical_json(value) when is_list(value), do: {:array, Enum.map(value, &canonical_json/1)}
  defp canonical_json(nil), do: {:null}
  defp canonical_json(value) when is_boolean(value), do: {:boolean, value}
  defp canonical_json(value) when is_integer(value), do: {:integer, value}
  defp canonical_json(value) when is_float(value), do: {:float, value}
  defp canonical_json(value) when is_binary(value), do: {:string, value}

  defp canonical_json(value) do
    raise ArgumentError, "unsupported JSON value: #{inspect(value)}"
  end

  defp canonical_key(key) when is_binary(key), do: key
  defp canonical_key(key) when is_atom(key), do: Atom.to_string(key)

  defp canonical_key(key) do
    raise ArgumentError, "unsupported JSON object key: #{inspect(key)}"
  end

  defp reject_ambiguous_keys!(entries) do
    entries
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find(fn [{left, _}, {right, _}] -> left == right end)
    |> case do
      nil -> entries
      [{key, _}, {key, _}] -> raise ArgumentError, "ambiguous JSON object key: #{inspect(key)}"
    end
  end
end
