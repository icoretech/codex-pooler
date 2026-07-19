defmodule CodexPooler.Gateway.Routing.CandidateEligibility do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Routing.CandidateEligibility.Quota
  alias CodexPooler.Gateway.Routing.{CircuitState, ModelMetadata}
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias CodexPooler.RouteClass
  alias CodexPooler.Upstreams.Lifecycle.IdentityRouting
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  defmodule FilterInput do
    @moduledoc false

    alias CodexPooler.Catalog.Model
    alias CodexPooler.Gateway.Payloads.RequestOptions
    alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

    @type auth :: CodexPooler.Access.auth_context()
    @type payload :: map()
    defstruct [
      :auth,
      :model,
      :endpoint,
      :payload,
      :request_options,
      :candidates,
      :route_class
    ]

    @type candidate :: {PoolUpstreamAssignment.t(), UpstreamIdentity.t()}
    @type attrs :: %{
            required(:model) => Model.t(),
            required(:endpoint) => String.t(),
            required(:payload) => payload(),
            required(:request_options) => RequestOptions.t(),
            required(:candidates) => [candidate()],
            optional(:auth) => auth()
          }

    @type t :: %__MODULE__{
            auth: auth() | nil,
            model: Model.t(),
            endpoint: String.t(),
            payload: payload(),
            request_options: RequestOptions.t(),
            candidates: [candidate()],
            route_class: String.t()
          }

    @spec new(attrs()) :: t()
    def new(attrs) when is_map(attrs) do
      endpoint = Map.fetch!(attrs, :endpoint)
      payload = Map.fetch!(attrs, :payload)
      request_options = request_options(attrs)

      %__MODULE__{
        auth: Map.get(attrs, :auth),
        model: Map.fetch!(attrs, :model),
        endpoint: endpoint,
        payload: payload,
        request_options: request_options,
        candidates: Map.fetch!(attrs, :candidates),
        route_class: request_options.transport.route_class
      }
    end

    @spec put_candidates(t(), [candidate()]) :: t()
    def put_candidates(%__MODULE__{} = input, candidates) when is_list(candidates),
      do: %{input | candidates: candidates}

    @spec put_request_options(t(), RequestOptions.t()) :: t()
    def put_request_options(%__MODULE__{} = input, %RequestOptions{} = request_options) do
      %{
        input
        | request_options: request_options,
          route_class: request_options.transport.route_class
      }
    end

    defp request_options(attrs) do
      %RequestOptions{} = request_options = Map.fetch!(attrs, :request_options)
      request_options
    end
  end

  @compact_support_key "supports_compact_responses"
  @active_model_status "active"
  @health_excluded [
    PoolUpstreamAssignment.cooldown_health_status(),
    PoolUpstreamAssignment.disabled_health_status(),
    PoolUpstreamAssignment.errored_health_status()
  ]
  @visible_identity_statuses IdentityRouting.model_routable_statuses()

  @type candidate :: {PoolUpstreamAssignment.t(), UpstreamIdentity.t()}
  @type gateway_error :: Contracts.gateway_error()
  @type quota_decision :: %{optional(String.t()) => term()}
  @type payload :: map()
  @type pool_ref :: Pool.t() | Model.t() | Ecto.UUID.t()
  @type model_visibility_hydration :: %{
          required(:visible_models) => [Model.t()],
          required(:candidates_by_model_id) => %{optional(Ecto.UUID.t()) => [candidate()]},
          required(:visible_candidates_by_model_id) => %{optional(Ecto.UUID.t()) => [candidate()]},
          required(:hydrated_at) => DateTime.t()
        }
  @type visible_model_context :: %{
          required(:requested_model) => String.t(),
          required(:effective_model) => String.t(),
          required(:visible_model) => Model.t(),
          required(:visible_models) => [Model.t()],
          required(:candidates_by_model_id) => %{optional(Ecto.UUID.t()) => [candidate()]},
          required(:visible_candidates_by_model_id) => %{optional(Ecto.UUID.t()) => [candidate()]},
          required(:candidate_snapshots) => [candidate()],
          required(:hydrated_at) => DateTime.t()
        }
  @type quota_refresh_plan :: %{
          required(:filter_input) => FilterInput.t(),
          required(:candidate_exclusions) => [map()],
          required(:refreshable_candidates) => [candidate()],
          optional(:route_state) => RouteState.t()
        }
  @type quota_filter_result ::
          {:ok, [candidate()], quota_decision()}
          | {:refreshable_quota, quota_refresh_plan()}

  @spec hydrate_model_visibility(pool_ref(), keyword()) :: model_visibility_hydration()
  def hydrate_model_visibility(pool_or_id, opts \\ []) do
    timestamp = Keyword.get(opts, :at, DateTime.utc_now() |> DateTime.truncate(:second))

    models =
      case Keyword.fetch(opts, :models) do
        {:ok, models} when is_list(models) -> models
        :error -> list_active_models(pool_id(pool_or_id))
      end

    candidates = list_visible_candidate_rows(models, timestamp)

    %{}
    |> Map.put(:visible_candidates_by_model_id, candidates_by_model_id(models, candidates))
    |> Map.put(:candidates_by_model_id, routable_candidates_by_model_id(models, candidates))
    |> Map.put(:hydrated_at, timestamp)
    |> then(fn hydration ->
      Map.put(hydration, :visible_models, visible_models(models, hydration))
    end)
  end

  @spec visible_model_context(pool_ref(), String.t()) :: visible_model_context() | nil
  def visible_model_context(pool_or_id, requested_model) when is_binary(requested_model) do
    hydration = hydrate_model_visibility(pool_or_id)
    requested = String.downcase(String.trim(requested_model))

    case Enum.find(hydration.visible_models, &(String.downcase(&1.exposed_model_id) == requested)) do
      %Model{} = model ->
        hydration
        |> Map.merge(%{
          requested_model: requested_model,
          effective_model: requested_model,
          visible_model: model,
          candidate_snapshots: Map.get(hydration.candidates_by_model_id, model.id, [])
        })

      nil ->
        nil
    end
  end

  def visible_model_context(_pool_or_id, _requested_model), do: nil

  @spec catalog_model_present?(pool_ref(), String.t()) :: boolean()
  def catalog_model_present?(pool_or_id, model_identifier) when is_binary(model_identifier) do
    canonical_identifier = model_identifier |> String.trim() |> String.downcase()

    canonical_identifier != "" and
      Repo.exists?(
        from model in Model,
          where:
            model.pool_id == ^pool_id(pool_or_id) and
              fragment("lower(btrim(?))", model.exposed_model_id) == ^canonical_identifier
      )
  end

  def catalog_model_present?(_pool_or_id, _model_identifier), do: false

  @spec policy_visible_models([Model.t()], map()) :: [Model.t()]
  def policy_visible_models(visible_models, policy) when is_list(visible_models) do
    Enum.filter(visible_models, &model_visible_to_policy?(&1, policy))
  end

  @spec model_source_identity(model_visibility_hydration(), [Model.t()]) ::
          UpstreamIdentity.t() | nil
  def model_source_identity(%{} = hydration, models) when is_list(models) do
    visible_candidates = Map.get(hydration, :visible_candidates_by_model_id, %{})

    models
    |> Enum.flat_map(&Map.get(visible_candidates, &1.id, []))
    |> Enum.uniq_by(fn {assignment, _identity} -> assignment.id end)
    |> Enum.max_by(&model_source_rank/1, fn -> nil end)
    |> case do
      {_assignment, %UpstreamIdentity{} = identity} -> identity
      nil -> nil
    end
  end

  @spec routable_candidates(Model.t()) ::
          {:ok, [candidate()]} | {:error, gateway_error()}
  def routable_candidates(%Model{} = model) do
    model
    |> hydrate_model_visibility(models: [model])
    |> routable_candidates(model)
  end

  @spec routable_candidates(model_visibility_hydration() | visible_model_context(), Model.t()) ::
          {:ok, [candidate()]} | {:error, gateway_error()}
  def routable_candidates(%{} = hydration, %Model{} = model) do
    candidates = hydrated_routable_candidates(hydration, model)

    if candidates == [],
      do:
        {:error,
         error(
           503,
           "no_eligible_backend",
           "no healthy eligible backend is currently available",
           "model"
         )},
      else: {:ok, candidates}
  end

  @spec filter_runtime_compatible_candidates(FilterInput.t()) ::
          {:ok, [candidate()]} | {:error, gateway_error()}
  def filter_runtime_compatible_candidates(%FilterInput{} = input) do
    %{
      model: model,
      endpoint: endpoint,
      payload: payload,
      request_options: request_options,
      candidates: candidates
    } = input

    requested_service_tier = requested_service_tier(payload, request_options)

    enforce_service_tier? = service_tier_requires_explicit_support?(requested_service_tier)

    candidates =
      Enum.filter(candidates, fn {assignment, _identity} ->
        assignment_compatible?(
          model,
          endpoint,
          payload,
          request_options,
          assignment,
          enforce_service_tier?
        )
      end)

    if candidates == [] do
      {:error,
       error(
         503,
         "no_compatible_backend",
         "no backend currently supports the requested model capabilities",
         "model"
       )}
    else
      {:ok, candidates}
    end
  end

  @spec maybe_filter_compact(String.t(), [candidate()]) :: {:ok, [candidate()]}
  def maybe_filter_compact("/backend-api/codex/responses/compact", candidates) do
    compact_candidates =
      Enum.filter(candidates, fn {assignment, identity} ->
        metadata_bool?(assignment.metadata, @compact_support_key) ||
          metadata_bool?(identity.metadata, @compact_support_key)
      end)

    case compact_candidates do
      [] -> {:ok, candidates}
      [_ | _] -> {:ok, compact_candidates}
    end
  end

  def maybe_filter_compact(_endpoint, candidates), do: {:ok, candidates}

  @spec filter_quota_eligible_candidates(FilterInput.t()) :: quota_filter_result()
  defdelegate filter_quota_eligible_candidates(input), to: Quota

  @spec filter_quota_eligible_candidates(FilterInput.t(), RouteState.t()) :: quota_filter_result()
  defdelegate filter_quota_eligible_candidates(input, route_state), to: Quota

  @spec quota_unavailable_error([map()], boolean()) :: {:error, gateway_error()}
  defdelegate quota_unavailable_error(exclusions, refresh_attempted?), to: Quota

  @spec quota_unavailable_error(FilterInput.t(), [map()], boolean()) :: {:error, gateway_error()}
  defdelegate quota_unavailable_error(input, exclusions, refresh_attempted?), to: Quota

  @spec filter_circuit_eligible_candidates(FilterInput.t()) ::
          {:ok, [candidate()]} | {:error, gateway_error()}
  def filter_circuit_eligible_candidates(%FilterInput{} = input) do
    %{
      auth: auth,
      model: model,
      candidates: candidates,
      route_class: route_class
    } = input

    {eligible, exclusions} =
      Enum.reduce(candidates, {[], []}, fn {assignment, identity} = candidate,
                                           {eligible, excluded} ->
        if CircuitState.eligible?(auth, model, assignment, route_class) do
          {[candidate | eligible], excluded}
        else
          {eligible,
           [
             %{
               pool_upstream_assignment_id: assignment.id,
               upstream_identity_id: identity.id,
               reasons: [%{"code" => "routing_circuit_open", "route_class" => route_class}]
             }
             | excluded
           ]}
        end
      end)

    case Enum.reverse(eligible) do
      [] ->
        {:error,
         error(
           503,
           "no_eligible_backend",
           "no healthy eligible backend is currently available",
           "model",
           %{candidate_exclusions: Enum.reverse(exclusions)}
         )}

      eligible ->
        {:ok, eligible}
    end
  end

  @spec filter_circuit_eligible_candidates(FilterInput.t(), RouteState.t()) ::
          {:ok, [candidate()]} | {:error, gateway_error()}
  def filter_circuit_eligible_candidates(%FilterInput{} = input, %RouteState{} = route_state) do
    %{candidates: candidates, route_class: route_class} = input

    {eligible, exclusions} =
      Enum.reduce(candidates, {[], []}, fn {assignment, identity} = candidate,
                                           {eligible, excluded} ->
        if RouteState.circuit_eligible?(route_state, assignment.id) do
          {[candidate | eligible], excluded}
        else
          {eligible,
           [
             %{
               pool_upstream_assignment_id: assignment.id,
               upstream_identity_id: identity.id,
               reasons: [%{"code" => "routing_circuit_open", "route_class" => route_class}]
             }
             | excluded
           ]}
        end
      end)

    case Enum.reverse(eligible) do
      [] ->
        {:error,
         error(
           503,
           "no_eligible_backend",
           "no healthy eligible backend is currently available",
           "model",
           %{candidate_exclusions: Enum.reverse(exclusions)}
         )}

      eligible ->
        {:ok, eligible}
    end
  end

  @spec payload_has_input_image?(payload()) :: boolean()
  def payload_has_input_image?(payload) do
    payload
    |> Map.get("input")
    |> has_input_image?()
  end

  defp pool_id(%Pool{id: id}), do: id
  defp pool_id(%Model{pool_id: id}), do: id
  defp pool_id(id) when is_binary(id), do: id

  defp list_active_models(pool_id) do
    Repo.all(
      from model in Model,
        where: model.pool_id == ^pool_id and model.status == ^@active_model_status,
        order_by: [asc: model.exposed_model_id]
    )
  end

  defp list_visible_candidate_rows(models, timestamp) when is_list(models) do
    assignment_ids = models |> Enum.flat_map(&source_assignment_ids/1) |> Enum.uniq()

    if assignment_ids == [] do
      []
    else
      assignment_active_status = PoolUpstreamAssignment.active_status()
      assignment_eligible_status = PoolUpstreamAssignment.eligible_status()

      Repo.all(
        from assignment in PoolUpstreamAssignment,
          join: identity in UpstreamIdentity,
          on: identity.id == assignment.upstream_identity_id,
          where:
            assignment.id in ^assignment_ids and assignment.status == ^assignment_active_status and
              assignment.eligibility_status == ^assignment_eligible_status and
              assignment.health_status not in ^@health_excluded and
              identity.status in ^@visible_identity_statuses and
              (is_nil(assignment.cooldown_until) or assignment.cooldown_until <= ^timestamp),
          order_by: [asc: assignment.created_at, asc: assignment.id],
          select: {assignment, identity}
      )
    end
  end

  defp candidates_by_model_id(models, candidates) do
    Map.new(models, fn %Model{} = model ->
      source_ids = MapSet.new(source_assignment_ids(model))

      model_candidates =
        Enum.filter(candidates, fn {assignment, _identity} ->
          MapSet.member?(source_ids, assignment.id)
        end)

      {model.id, model_candidates}
    end)
  end

  defp routable_candidates_by_model_id(models, candidates) do
    active_health_status = PoolUpstreamAssignment.active_health_status()

    candidates_by_model_id(models, candidates)
    |> Map.new(fn {model_id, model_candidates} ->
      {model_id,
       Enum.filter(model_candidates, fn {assignment, _identity} ->
         assignment.health_status == active_health_status
       end)}
    end)
  end

  defp hydrated_routable_candidates(%{} = hydration, %Model{id: id} = model) do
    candidates_by_model_id = Map.get(hydration, :candidates_by_model_id, %{})

    case Map.fetch(candidates_by_model_id, id) do
      {:ok, candidates} -> candidates
      :error -> routable_candidates_by_source_ids(hydration, model)
    end
  end

  defp routable_candidates_by_source_ids(%{} = hydration, %Model{} = model) do
    active_health_status = PoolUpstreamAssignment.active_health_status()
    source_ids = MapSet.new(source_assignment_ids(model))

    hydration
    |> Map.get(:visible_candidates_by_model_id, %{})
    |> Map.values()
    |> List.flatten()
    |> Enum.uniq_by(fn {assignment, _identity} -> assignment.id end)
    |> Enum.filter(fn {assignment, _identity} ->
      assignment.health_status == active_health_status and
        MapSet.member?(source_ids, assignment.id)
    end)
  end

  defp visible_models(models, %{visible_candidates_by_model_id: visible_candidates}) do
    Enum.filter(models, fn %Model{} = model ->
      Map.get(visible_candidates, model.id, []) != []
    end)
  end

  defp model_visible_to_policy?(%Model{} = model, policy) do
    model_allowed_by_policy?(policy, model.exposed_model_id)
  end

  defp model_allowed_by_policy?(%{allowed_model_identifiers: nil}, _model), do: true
  defp model_allowed_by_policy?(%{allowed_model_identifiers: []}, _model), do: false

  defp model_allowed_by_policy?(%{allowed_model_identifiers: allowed}, model)
       when is_binary(model) do
    normalized = model |> String.trim() |> String.downcase()
    normalized in allowed
  end

  defp model_source_rank({%PoolUpstreamAssignment{} = assignment, %UpstreamIdentity{} = identity}) do
    {model_source_plan_rank(identity), assignment.created_at, assignment.id}
  end

  defp model_source_plan_rank(%UpstreamIdentity{} = identity) do
    plan = identity.plan_family || identity.plan_label || ""

    cond do
      plan =~ ~r/enterprise|team/i -> 4
      plan =~ ~r/pro/i -> 3
      plan =~ ~r/plus/i -> 2
      plan =~ ~r/free/i -> 1
      true -> 0
    end
  end

  defp source_assignment_ids(%Model{} = model) do
    case get_in(model.metadata || %{}, ["source_assignment_ids"]) do
      ids when is_list(ids) -> ids
      _value -> []
    end
  end

  defp assignment_compatible?(
         model,
         endpoint,
         payload,
         request_options,
         assignment,
         enforce_service_tier?
       ) do
    case source_assignment_model_metadata(model, assignment) do
      %{} = metadata ->
        endpoint_compatible?(endpoint, metadata, request_options) and
          streaming_compatible?(payload, metadata) and
          image_input_compatible?(payload, metadata) and tools_compatible?(payload, metadata) and
          reasoning_compatible?(payload, metadata) and
          service_tier_compatible?(payload, request_options, metadata, enforce_service_tier?)

      _value ->
        not enforce_service_tier?
    end
  end

  defp source_assignment_model_metadata(%Model{} = model, assignment) do
    get_in(model.metadata || %{}, ["source_assignment_models", assignment.id])
  end

  defp endpoint_compatible?(
         "/backend-api/transcribe",
         _metadata,
         %RequestOptions{payload_context: %{forced_transcription_model: model}}
       )
       when is_binary(model),
       do: true

  defp endpoint_compatible?("/backend-api/transcribe", metadata, _request_options) do
    not ModelMetadata.has_capability_evidence?(metadata) or
      ModelMetadata.supports_audio_transcription?(metadata)
  end

  defp endpoint_compatible?(_endpoint, metadata, _request_options) do
    not ModelMetadata.metadata_falsey?(ModelMetadata.metadata_map(metadata, "capabilities"), [
      "responses"
    ])
  end

  defp streaming_compatible?(payload, metadata) do
    not RouteClass.streaming?(payload) or
      not ModelMetadata.streaming_explicitly_unsupported?(metadata)
  end

  defp image_input_compatible?(payload, metadata) do
    not payload_has_input_image?(payload) or not ModelMetadata.has_capability_evidence?(metadata) or
      ModelMetadata.supports_image_input?(metadata)
  end

  defp tools_compatible?(payload, metadata) do
    not payload_has_tools?(payload) or ModelMetadata.supports_tools?(metadata)
  end

  defp reasoning_compatible?(payload, metadata) do
    not payload_has_reasoning?(payload) or ModelMetadata.supports_reasoning?(metadata)
  end

  defp service_tier_compatible?(_payload, _request_options, _metadata, false), do: true

  defp service_tier_compatible?(payload, request_options, metadata, true) do
    case requested_service_tier(payload, request_options) do
      nil -> true
      tier -> service_tier_supported?(metadata, tier)
    end
  end

  defp requested_service_tier(
         _payload,
         %RequestOptions{routing: %{api_key_policy: %{enforced_service_tier: tier}}}
       )
       when is_binary(tier) do
    clean_string(tier)
  end

  defp requested_service_tier(payload, _opts) do
    payload
    |> Map.get("service_tier")
    |> clean_string()
  end

  defp service_tier_supported?(metadata, tier) do
    tier = ModelMetadata.normalize_capability_value(tier)

    if tier in ["auto", "default"] do
      true
    else
      service_tier_explicitly_supported?(metadata, tier)
    end
  end

  defp service_tier_requires_explicit_support?(tier) when is_binary(tier) do
    tier = ModelMetadata.normalize_capability_value(tier)
    tier not in ["", "auto", "default"]
  end

  defp service_tier_requires_explicit_support?(_tier), do: false

  defp service_tier_explicitly_supported?(metadata, tier) do
    service_tiers =
      metadata
      |> ModelMetadata.list_metadata("service_tiers")
      |> Enum.map(&service_tier_id/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&ModelMetadata.normalize_capability_value/1)

    speed_tiers =
      metadata
      |> ModelMetadata.list_metadata("additional_speed_tiers")
      |> Enum.map(&ModelMetadata.normalize_capability_value/1)

    tier in service_tiers or tier in speed_tiers
  end

  defp service_tier_id(%{"id" => id}) when is_binary(id), do: id
  defp service_tier_id(tier) when is_binary(tier), do: tier
  defp service_tier_id(_tier), do: nil

  defp payload_has_tools?(payload) do
    case Map.get(payload, "tools") || Map.get(payload, :tools) do
      tools when is_list(tools) -> tools != []
      _value -> false
    end
  end

  defp payload_has_reasoning?(payload) do
    case Map.get(payload, "reasoning") || Map.get(payload, :reasoning) do
      value when is_map(value) -> map_size(value) > 0
      _value -> false
    end
  end

  defp has_input_image?(%{} = value) do
    value = Map.new(value, fn {key, item_value} -> {to_string(key), item_value} end)

    case value do
      %{"type" => "input_image"} -> true
      _value -> value |> Map.values() |> Enum.any?(&has_input_image?/1)
    end
  end

  defp has_input_image?(values) when is_list(values), do: Enum.any?(values, &has_input_image?/1)
  defp has_input_image?(_value), do: false

  defp metadata_bool?(metadata, key), do: Map.get(metadata || %{}, key) == true

  defp clean_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp clean_string(_value), do: nil

  defp error(status, code, message, param), do: error(status, code, message, param, %{})

  defp error(status, code, message, param, metadata),
    do: Map.merge(%{status: status, code: code, message: message, param: param}, metadata)
end
