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
          required(:partition_count) => pos_integer(),
          required(:routable_selection?) => boolean(),
          required(:source) => map()
        }
  @type routable_assignment_ids_by_model_id :: %{
          optional(Ecto.UUID.t()) => MapSet.t(Ecto.UUID.t())
        }
  @type routable_assignment_ids_by_model_id_resolver :: (-> routable_assignment_ids_by_model_id())
  @type selection_opts :: [
          routable_assignment_ids_by_model_id: routable_assignment_ids_by_model_id_resolver()
        ]

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

  @spec select_canonical_sources([Model.t()], candidates_by_model_id(), selection_opts()) ::
          [selected_partition()]
  def select_canonical_sources(models, candidates_by_model_id, opts \\ [])
      when is_list(models) and is_map(candidates_by_model_id) and is_list(opts) do
    pairs_by_model =
      Enum.flat_map(models, fn
        %Model{} = model ->
          case canonical_pairs(model, Map.get(candidates_by_model_id, model.id, [])) do
            [] -> []
            pairs -> [{model, pairs}]
          end

        _model ->
          []
      end)

    routable_assignment_ids_by_model_id =
      resolve_routable_assignment_ids_by_model_id(pairs_by_model, opts)

    Enum.map(pairs_by_model, fn {model, pairs} ->
      select_anchored_partition(
        pairs,
        model,
        Map.get(routable_assignment_ids_by_model_id, model.id)
      )
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
          effective_model_serving_modes(),
          selection_opts()
        ) :: result()
  def build_canonical(
        models,
        candidates_by_model_id,
        normalized_policy,
        pricing_buckets,
        context_window_overrides,
        effective_model_serving_modes,
        opts \\ []
      ) do
    models
    |> select_canonical_sources(candidates_by_model_id, opts)
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

  # Partition selection is quota-aware: the cohort with the most routable members
  # wins, then total membership, then the oldest anchor. This lets a catalog
  # rollout converge once the new source shape becomes the routable majority
  # instead of letting one old assignment pin the model indefinitely.
  #
  # Resolving routability costs a quota read, so it is deferred until a model
  # actually has more than one partition. A pool whose accounts all advertise
  # the same source — the overwhelmingly common shape — stays read-free and
  # keeps byte-identical behavior.
  defp resolve_routable_assignment_ids_by_model_id(pairs_by_model, opts) do
    if Enum.any?(pairs_by_model, &multi_partition?/1) do
      case Keyword.get(opts, :routable_assignment_ids_by_model_id) do
        resolver when is_function(resolver, 0) ->
          resolver.()

        _missing_model_keyed_resolver ->
          %{}
      end
    else
      %{}
    end
  end

  defp multi_partition?({_model, pairs}) do
    pairs |> Enum.uniq_by(& &1.digest) |> length() > 1
  end

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

  # Selection drives BOTH the routing cap and the advertised
  # `/backend-api/codex/models` body, which is what keeps the catalog a client
  # was told about and the account that serves its turn the same partition. The
  # documented consequence is that the catalog body and its ETag can change when
  # the preferred cohort changes — a legitimate revision, not churn for its own
  # sake. The contract is recorded under the `:backend_models_etag` entry in
  # `CodexPooler.CompatibilityMatrix`.
  defp select_anchored_partition(pairs, %Model{} = model, routable_assignment_ids) do
    partitions =
      pairs
      |> Enum.group_by(& &1.digest)
      |> Map.values()
      |> Enum.sort_by(&partition_anchor_key/1)

    baseline_members = select_partition(partitions, nil)
    members = select_partition(partitions, routable_assignment_ids)
    anchor = partition_anchor(members)

    %{
      assignment_ids: members |> Enum.map(& &1.assignment_id) |> Enum.sort(),
      digest: anchor.digest,
      model: model,
      partition_count: length(partitions),
      routable_selection?: members != baseline_members,
      source: anchor.source
    }
  end

  defp select_partition(partitions, routable_assignment_ids) do
    Enum.min_by(partitions, &partition_selection_key(&1, routable_assignment_ids))
  end

  defp partition_selection_key(members, nil) do
    {-length(members), partition_anchor_key(members)}
  end

  defp partition_selection_key(members, %MapSet{} = routable_assignment_ids) do
    routable_count =
      Enum.count(members, &MapSet.member?(routable_assignment_ids, &1.assignment_id))

    {-routable_count, -length(members), partition_anchor_key(members)}
  end

  defp partition_anchor(members), do: Enum.min_by(members, &partition_pair_key/1)

  defp partition_anchor_key(members), do: members |> partition_anchor() |> partition_pair_key()

  # Structural DateTime comparison orders struct fields alphabetically (day
  # before month before year), so it is not chronological across month or year
  # boundaries. The anchor contract is the chronologically oldest assignment.
  defp partition_pair_key(pair),
    do: {DateTime.to_unix(pair.created_at, :microsecond), pair.assignment_id}

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
