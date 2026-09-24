defmodule CodexPooler.Gateway.Metadata.CodexCatalog do
  @moduledoc false

  alias CodexPooler.Catalog
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Metadata.CanonicalModelSource
  alias CodexPooler.Gateway.Metadata.CatalogRepresentation
  alias CodexPooler.Gateway.Metadata.CodexModelDecodeContract
  alias CodexPooler.Gateway.Payloads.ReasoningEffort
  alias CodexPooler.Gateway.Routing.CandidateEligibility
  alias CodexPooler.Gateway.Routing.ModelMetadata
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment

  @etag_prefix ~s(W/"cp-models-v1-)
  @known_reasoning_efforts ~w(none minimal low medium high xhigh max ultra)
  @reasoning_level_keys ~w(reasoning_efforts supported_reasoning_levels)

  @type normalized_policy :: map()
  @type body :: %{required(String.t()) => [map()]}
  @type undecodable_model :: %{required(:slug) => String.t(), required(:fields) => [String.t()]}
  @type result :: %{
          required(:body) => body(),
          required(:etag) => String.t(),
          required(:undecodable_models) => [undecodable_model()]
        }
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
          routable_assignment_ids_by_model_id: routable_assignment_ids_by_model_id_resolver(),
          representation: CatalogRepresentation.t()
        ]

  @spec build_selected_sources(
          [selected_source()],
          normalized_policy(),
          pricing_buckets(),
          context_window_overrides(),
          effective_model_serving_modes(),
          CatalogRepresentation.t()
        ) :: {:ok, result()} | {:error, :invalid_model_metadata}
  def build_selected_sources(
        selected_sources,
        normalized_policy,
        pricing_buckets,
        context_window_overrides,
        effective_model_serving_modes,
        representation \\ :verbatim
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
      {:ok, models} -> {:ok, result_from_models(models, representation)}
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
          effective_model_serving_modes(),
          CatalogRepresentation.t()
        ) :: {:ok, result()} | {:error, :invalid_model_metadata}
  def build_selected_partitions(
        partitions,
        normalized_policy,
        pricing_buckets,
        context_window_overrides,
        effective_model_serving_modes,
        representation \\ :verbatim
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
      effective_model_serving_modes,
      representation
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
    representation = Keyword.get(opts, :representation, :verbatim)

    models
    |> select_canonical_sources(candidates_by_model_id, opts)
    |> build_selected_partitions(
      normalized_policy,
      pricing_buckets,
      context_window_overrides,
      effective_model_serving_modes,
      representation
    )
    |> case do
      {:ok, result} -> result
      {:error, :invalid_model_metadata} -> result_from_models([], representation)
    end
  end

  defp result_from_models(models, representation) do
    {models, undecodable_models} =
      models
      |> Enum.map(&CatalogRepresentation.apply_to_model(&1, representation))
      |> Enum.sort_by(&Map.fetch!(&1, "slug"))
      |> reject_undecodable(representation)

    # The ETag is the digest of the representation actually served, so a
    # client holding one representation never matches the other's token.
    body = %{"models" => models}
    %{body: body, etag: etag(body), undecodable_models: undecodable_models}
  end

  # One entry the client cannot decode makes it discard the whole catalog, so
  # for a client whose decode contract is known the entry is left out instead;
  # the model stays routable and the client keeps every other entry.
  defp reject_undecodable(models, :decode_checked) do
    {decodable, undecodable} =
      models
      |> Enum.map(&{&1, CodexModelDecodeContract.violations(&1)})
      |> Enum.split_with(fn {_model, fields} -> fields == [] end)

    {Enum.map(decodable, &elem(&1, 0)), Enum.map(undecodable, fn {model, fields} -> %{slug: Map.fetch!(model, "slug"), fields: fields} end)}
  end

  defp reject_undecodable(models, _representation), do: {models, []}

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
    if Enum.any?(pairs_by_model, &selection_requires_routability?/1) do
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

  defp selection_requires_routability?({_model, pairs} = pair_group) do
    multi_partition?(pair_group) or
      pairs |> Enum.uniq_by(&reasoning_projection_signature/1) |> length() > 1
  end

  defp reasoning_projection_signature(pair) do
    levels =
      pair.source
      |> ModelMetadata.metadata_reasoning_levels()
      |> Enum.sort_by(&reasoning_level_sort_key/1)

    {reasoning_source_default(pair.source), levels}
  end

  defp reasoning_source_default(source) do
    case Map.get(source, "default_reasoning_level") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> ReasoningEffort.normalize_known(trimmed) || trimmed
        end

      _value ->
        nil
    end
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
         {%PoolUpstreamAssignment{id: assignment_id, created_at: %DateTime{} = created_at}, _identity},
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
    capability_families =
      pairs
      |> Enum.group_by(& &1.reasoning_agnostic_digest)
      |> Map.values()
      |> Enum.sort_by(&partition_anchor_key/1)

    baseline_members = select_partition(capability_families, nil)
    members = select_partition(capability_families, routable_assignment_ids)
    anchor = partition_anchor(members)

    %{
      assignment_ids: members |> Enum.map(& &1.assignment_id) |> Enum.sort(),
      digest: anchor.digest,
      model: model,
      partition_count: length(capability_families),
      routable_selection?: members != baseline_members,
      source: reasoning_union_source(anchor, members, routable_assignment_ids)
    }
  end

  defp select_partition(partitions, routable_assignment_ids) do
    Enum.min_by(partitions, &partition_selection_key(&1, routable_assignment_ids))
  end

  defp partition_selection_key(members, nil) do
    {-length(members), partition_anchor_key(members)}
  end

  defp partition_selection_key(members, %MapSet{} = routable_assignment_ids) do
    routable_count = partition_routable_count(members, routable_assignment_ids)

    {-routable_count, -length(members), partition_anchor_key(members)}
  end

  defp partition_routable_count(members, %MapSet{} = routable_assignment_ids) do
    Enum.count(members, &MapSet.member?(routable_assignment_ids, &1.assignment_id))
  end

  defp reasoning_union_source(anchor, family_pairs, routable_assignment_ids) do
    source_pairs = routable_family_pairs(family_pairs, routable_assignment_ids)

    if one_reasoning_projection?(family_pairs) do
      anchor.source
    else
      union_reasoning_source(anchor, source_pairs)
    end
  end

  defp one_reasoning_projection?(source_pairs) do
    source_pairs
    |> Enum.uniq_by(&reasoning_projection_signature/1)
    |> length() == 1
  end

  defp union_reasoning_source(anchor, source_pairs) do
    base_source =
      Map.drop(anchor.source, ["default_reasoning_level" | @reasoning_level_keys])

    reasoning_levels =
      source_pairs
      |> Enum.sort_by(&partition_pair_key/1)
      |> Enum.flat_map(&ModelMetadata.metadata_reasoning_levels(&1.source))
      |> Enum.uniq()
      |> Enum.sort_by(&reasoning_level_sort_key/1)

    case reasoning_levels do
      [] ->
        base_source

      [_ | _] ->
        levels = Enum.map(reasoning_levels, &%{"effort" => &1, "description" => &1})

        base_source
        |> Map.put("supported_reasoning_levels", levels)
        |> Map.put(
          "default_reasoning_level",
          reasoning_union_default(source_pairs, reasoning_levels)
        )
    end
  end

  defp reasoning_union_default(source_pairs, reasoning_levels) do
    source_pairs
    |> Enum.sort_by(&partition_pair_key/1)
    |> Enum.find_value(&reasoning_default(&1.source, reasoning_levels))
    |> case do
      nil -> List.first(reasoning_levels)
      default -> default
    end
  end

  defp reasoning_level_sort_key(effort) do
    case Enum.find_index(@known_reasoning_efforts, &(&1 == effort)) do
      nil -> {1, effort}
      index -> {0, index}
    end
  end

  defp reasoning_default(source, reasoning_levels) do
    case Map.get(source, "default_reasoning_level") do
      value when is_binary(value) ->
        normalized = ReasoningEffort.normalize_known(value) || String.trim(value)
        if normalized in reasoning_levels, do: normalized

      _value ->
        nil
    end
  end

  defp routable_family_pairs(family_pairs, %MapSet{} = routable_assignment_ids) do
    routable =
      Enum.filter(family_pairs, &MapSet.member?(routable_assignment_ids, &1.assignment_id))

    case routable do
      [] -> family_pairs
      [_ | _] -> routable
    end
  end

  defp routable_family_pairs(family_pairs, _routable_assignment_ids), do: family_pairs

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
