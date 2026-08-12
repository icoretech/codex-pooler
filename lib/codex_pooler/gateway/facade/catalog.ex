defmodule CodexPooler.Gateway.Facade.Catalog do
  @moduledoc """
  Resolves the one fixed facade target and projects provider-neutral catalogs.

  The resolution retains real model and assignment evidence for operator-side
  accounting. Only the explicit OpenAI and Codex projections cross the public
  boundary.
  """

  alias CodexPooler.Catalog
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Facade
  alias CodexPooler.Gateway.Facade.Policy
  alias CodexPooler.Gateway.Metadata.CodexCatalog
  alias CodexPooler.Gateway.Payloads.RequestOptions.Persona
  alias CodexPooler.Gateway.Routing.CandidateEligibility
  alias CodexPooler.Gateway.Routing.ModelMetadata
  alias CodexPooler.Gateway.Routing.PartitionRoutability

  @safe_modalities ~w(text image audio)
  @safe_shell_types ~w(shell_command command)
  @safe_truncation_modes ~w(bytes tokens)
  @safe_reasoning_summary_formats ~w(auto concise detailed json)
  @safe_tool_modes ~w(default code_mode_only)
  @safe_service_tier_ids ~w(auto default priority fast flex)
  @safe_speed_tiers ~w(fast)

  @type candidate :: CandidateEligibility.candidate()
  @type resolution :: %{
          required(:available?) => boolean(),
          required(:hydration) => CandidateEligibility.model_visibility_hydration(),
          required(:model) => Model.t() | nil,
          required(:models) => [Model.t()],
          required(:candidates_by_model_id) => %{optional(Ecto.UUID.t()) => [candidate()]},
          required(:routable_assignment_ids_by_model_id) => %{
            optional(Ecto.UUID.t()) => MapSet.t(Ecto.UUID.t())
          },
          required(:source_identity) => CodexPooler.Upstreams.Schemas.UpstreamIdentity.t() | nil
        }

  @spec resolve(map(), map()) :: resolution()
  def resolve(auth, policy) when is_map(auth) and is_map(policy) do
    resolve(auth, policy, CandidateEligibility.hydrate_model_visibility(auth.pool))
  end

  @spec resolve(map(), map(), CandidateEligibility.model_visibility_hydration()) :: resolution()
  def resolve(auth, policy, hydration)
      when is_map(auth) and is_map(policy) and is_map(hydration) do
    resolve(auth, policy, hydration, nil)
  end

  @spec resolve(
          map(),
          map(),
          CandidateEligibility.model_visibility_hydration(),
          PartitionRoutability.routable_assignment_ids_by_model_id() | nil
        ) :: resolution()
  def resolve(auth, policy, hydration, routable_assignment_ids_by_model_id)
      when is_map(auth) and is_map(policy) and is_map(hydration) and
             (is_map(routable_assignment_ids_by_model_id) or
                is_nil(routable_assignment_ids_by_model_id)) do
    model = fixed_target_model(hydration.visible_models)
    candidates_by_model_id = Map.get(hydration, :candidates_by_model_id, %{})

    routable_assignment_ids_by_model_id =
      case {model, routable_assignment_ids_by_model_id} do
        {%Model{}, %{} = supplied} ->
          supplied

        {%Model{}, nil} ->
          PartitionRoutability.routable_assignment_ids_by_model_id(
            [model],
            candidates_by_model_id
          )

        {nil, _supplied} ->
          %{}
      end

    available? =
      match?(%Model{}, model) and
        Policy.authorize(policy, Persona.fixed(:metadata)) == :ok and
        target_policy_visible?(model, policy) and
        target_routable?(model, candidates_by_model_id, routable_assignment_ids_by_model_id)

    models = if available?, do: [model], else: []

    %{
      available?: available?,
      hydration: hydration,
      model: if(available?, do: model, else: nil),
      models: models,
      candidates_by_model_id: candidates_by_model_id,
      routable_assignment_ids_by_model_id: routable_assignment_ids_by_model_id,
      source_identity: CandidateEligibility.model_source_identity(hydration, models)
    }
  end

  @spec openai_body(resolution(), map()) :: map()
  def openai_body(%{models: models}, context_window_overrides)
      when is_list(models) and is_map(context_window_overrides) do
    pricing_buckets = Catalog.pricing_buckets_by_identifier(models)

    %{
      "object" => "list",
      "data" => Enum.map(models, &openai_model(&1, pricing_buckets, context_window_overrides))
    }
  end

  @spec openai_detail(resolution(), map()) :: map() | nil
  def openai_detail(%{model: %Model{} = model}, context_window_overrides)
      when is_map(context_window_overrides) do
    pricing_buckets = Catalog.pricing_buckets_by_identifier([model])
    openai_model(model, pricing_buckets, context_window_overrides)
  end

  def openai_detail(%{model: nil}, context_window_overrides)
      when is_map(context_window_overrides),
      do: nil

  @spec codex_catalog(resolution(), map(), map()) :: %{body: map(), etag: String.t()}
  def codex_catalog(%{models: models}, context_window_overrides, effective_serving_modes)
      when is_list(models) and is_map(context_window_overrides) and
             is_map(effective_serving_modes) do
    pricing_buckets = Catalog.pricing_buckets_by_identifier(models)

    projected_models =
      Enum.map(models, fn %Model{} = model ->
        model
        |> ModelMetadata.codex_model_payload(
          pricing_buckets,
          nil,
          context_window_overrides,
          Map.get(effective_serving_modes, model.exposed_model_id)
        )
        |> project_codex_model()
      end)

    body = %{"models" => projected_models}
    %{body: body, etag: CodexCatalog.etag(body)}
  end

  defp fixed_target_model(models) when is_list(models) do
    target = canonical(Facade.effective_model())
    Enum.find(models, &(canonical(&1.exposed_model_id) == target))
  end

  defp target_policy_visible?(%Model{} = model, policy) do
    CandidateEligibility.policy_visible_models([model], policy) == [model]
  end

  defp target_routable?(%Model{} = model, candidates_by_model_id, routable_by_model_id) do
    candidates = Map.get(candidates_by_model_id, model.id, [])
    routable_ids = Map.get(routable_by_model_id, model.id, MapSet.new())
    candidates != [] and MapSet.size(routable_ids) > 0
  end

  defp openai_model(%Model{} = model, pricing_buckets, context_window_overrides) do
    metadata =
      model
      |> ModelMetadata.metadata()
      |> ModelMetadata.apply_context_window_policy(
        model,
        pricing_buckets,
        context_window_overrides
      )

    %{
      "id" => Facade.public_model(),
      "object" => "model",
      "created" => created_at(model),
      "owned_by" => "ollama",
      "permission" => [],
      "input_modalities" => safe_modalities(ModelMetadata.input_modalities(metadata)),
      "display_name" => Facade.public_model(),
      "supports_streaming" => model.supports_streaming == true,
      "supports_tools" => model.supports_tools == true,
      "supports_reasoning" => model.supports_reasoning == true
    }
    |> maybe_put_positive_integer("context_length", Map.get(metadata, "context_window"))
  end

  defp project_codex_model(source) do
    %{
      "slug" => Facade.public_model(),
      "display_name" => Facade.public_model(),
      "description" => Facade.public_model(),
      "default_reasoning_level" => Facade.reasoning_effort(),
      "supported_reasoning_levels" => [
        %{"effort" => Facade.reasoning_effort(), "description" => "Maximum"}
      ],
      "shell_type" =>
        safe_enum(Map.get(source, "shell_type"), @safe_shell_types, "shell_command"),
      "visibility" => "list",
      "base_instructions" => "",
      "truncation_policy" => safe_truncation_policy(Map.get(source, "truncation_policy")),
      "include_skills_usage_instructions" =>
        boolean(Map.get(source, "include_skills_usage_instructions"), false),
      "supports_parallel_tool_calls" =>
        boolean(Map.get(source, "supports_parallel_tool_calls"), true),
      "input_modalities" => safe_modalities(Map.get(source, "input_modalities")),
      "supported_in_api" => true,
      "supports_responses" => true,
      "supports_streaming" => boolean(Map.get(source, "supports_streaming"), true),
      "supports_tools" => boolean(Map.get(source, "supports_tools"), true),
      "supports_reasoning" => true,
      "use_responses_lite" => boolean(Map.get(source, "use_responses_lite"), false)
    }
    |> maybe_put_boolean("supports_image_detail_original", source)
    |> maybe_put_boolean("prefer_websockets", source)
    |> maybe_put_boolean("supports_reasoning_summary_parameter", source)
    |> maybe_put_boolean("supports_reasoning_summaries", source)
    |> maybe_put_boolean("supports_search_tool", source)
    |> maybe_put_boolean("support_verbosity", source)
    |> maybe_put_positive_integer("context_window", Map.get(source, "context_window"))
    |> maybe_put_positive_integer("max_context_window", Map.get(source, "max_context_window"))
    |> maybe_put_positive_integer(
      "auto_compact_token_limit",
      Map.get(source, "auto_compact_token_limit")
    )
    |> maybe_put_positive_integer(
      "effective_context_window_percent",
      Map.get(source, "effective_context_window_percent")
    )
    |> maybe_put_enum(
      "reasoning_summary_format",
      Map.get(source, "reasoning_summary_format"),
      @safe_reasoning_summary_formats
    )
    |> maybe_put_enum("tool_mode", Map.get(source, "tool_mode"), @safe_tool_modes)
    |> maybe_put_enum(
      "default_service_tier",
      Map.get(source, "default_service_tier"),
      @safe_service_tier_ids
    )
    |> maybe_put_safe_service_tiers(Map.get(source, "service_tiers"))
    |> maybe_put_safe_speed_tiers(Map.get(source, "additional_speed_tiers"))
  end

  defp safe_modalities(modalities) when is_list(modalities) do
    modalities
    |> Enum.filter(&(&1 in @safe_modalities))
    |> Enum.uniq()
    |> case do
      [] -> ["text"]
      safe -> safe
    end
  end

  defp safe_modalities(_modalities), do: ["text"]

  defp safe_truncation_policy(%{"mode" => mode, "limit" => limit})
       when mode in @safe_truncation_modes and is_integer(limit) and limit > 0 do
    %{"mode" => mode, "limit" => limit}
  end

  defp safe_truncation_policy(_policy), do: %{"mode" => "bytes", "limit" => 10_000}

  defp maybe_put_safe_service_tiers(payload, tiers) when is_list(tiers) do
    safe =
      tiers
      |> Enum.flat_map(fn
        %{"id" => id} when id in @safe_service_tier_ids ->
          [%{"id" => id, "name" => public_tier_name(id)}]

        _tier ->
          []
      end)
      |> Enum.uniq_by(& &1["id"])

    if safe == [], do: payload, else: Map.put(payload, "service_tiers", safe)
  end

  defp maybe_put_safe_service_tiers(payload, _tiers), do: payload

  defp maybe_put_safe_speed_tiers(payload, tiers) when is_list(tiers) do
    safe = tiers |> Enum.filter(&(&1 in @safe_speed_tiers)) |> Enum.uniq()
    if safe == [], do: payload, else: Map.put(payload, "additional_speed_tiers", safe)
  end

  defp maybe_put_safe_speed_tiers(payload, _tiers), do: payload

  defp maybe_put_positive_integer(payload, key, value) when is_integer(value) and value > 0,
    do: Map.put(payload, key, value)

  defp maybe_put_positive_integer(payload, _key, _value), do: payload

  defp maybe_put_boolean(payload, key, source) do
    case Map.get(source, key) do
      value when is_boolean(value) -> Map.put(payload, key, value)
      _value -> payload
    end
  end

  defp maybe_put_enum(payload, key, value, allowed) do
    if value in allowed, do: Map.put(payload, key, value), else: payload
  end

  defp safe_enum(value, allowed, fallback), do: if(value in allowed, do: value, else: fallback)
  defp boolean(value, _fallback) when is_boolean(value), do: value
  defp boolean(_value, fallback), do: fallback

  defp public_tier_name("priority"), do: "Priority"
  defp public_tier_name("fast"), do: "Fast"
  defp public_tier_name("flex"), do: "Flex"
  defp public_tier_name(id), do: String.capitalize(id)

  defp created_at(%Model{first_seen_at: %DateTime{} = first_seen_at}),
    do: DateTime.to_unix(first_seen_at, :second)

  defp created_at(%Model{}), do: 0

  defp canonical(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp canonical(_value), do: nil
end
