defmodule CodexPooler.Gateway.Runtime.Dispatch.RouteState do
  @moduledoc false

  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Routing.CandidateEligibility
  alias CodexPooler.Gateway.Routing.CircuitState
  alias CodexPooler.Pools.RoutingSettings
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @enforce_keys [:visible_model]
  defstruct [
    :visible_model,
    visible_model_context: %{},
    visible_models: [],
    effective_model_serving_modes: %{},
    candidate_snapshots: [],
    candidates: [],
    routing_settings: nil,
    quota_window_snapshots: %{},
    circuit_snapshots: %{},
    circuit_eligibility_snapshots: %{},
    reservation_snapshot_inputs: nil,
    extensions: %{}
  ]

  @type candidate :: CandidateEligibility.candidate()
  @type auth :: CodexPooler.Access.auth_context()
  @type visible_model_context :: %{optional(atom()) => term()}
  @type quota_window_snapshots :: %{optional(Ecto.UUID.t()) => [AccountQuotaWindow.t()]}
  @type circuit_snapshot :: CircuitState.eligibility_snapshot() | boolean()
  @type circuit_snapshots :: %{optional(Ecto.UUID.t()) => circuit_snapshot()}
  @type reservation_snapshot_inputs :: %{
          required(:pool_id) => Ecto.UUID.t(),
          required(:api_key_id) => Ecto.UUID.t(),
          required(:effective_model) => String.t(),
          required(:route_class) => String.t(),
          required(:request_class) => String.t(),
          required(:estimated_input_tokens) => non_neg_integer(),
          required(:estimated_output_tokens) => non_neg_integer(),
          required(:estimated_total_tokens) => non_neg_integer(),
          required(:quota_window_dimension_keys) => [map()]
        }
  @type extensions :: %{optional(atom() | String.t()) => term()}
  @type effective_model_serving_modes :: %{optional(String.t()) => String.t() | nil}
  @codex_models_etag_extension :codex_models_etag

  @type t :: %__MODULE__{
          visible_model: Model.t(),
          visible_model_context: visible_model_context(),
          visible_models: [Model.t()],
          effective_model_serving_modes: effective_model_serving_modes(),
          candidate_snapshots: [candidate()],
          candidates: [candidate()],
          routing_settings: RoutingSettings.t() | nil,
          quota_window_snapshots: quota_window_snapshots(),
          circuit_snapshots: circuit_snapshots(),
          circuit_eligibility_snapshots: circuit_snapshots(),
          reservation_snapshot_inputs: reservation_snapshot_inputs() | nil,
          extensions: extensions()
        }

  @type attrs :: %{
          required(:visible_model) => Model.t(),
          required(:candidates) => [candidate()],
          optional(:visible_model_context) => visible_model_context(),
          optional(:visible_models) => [Model.t()],
          optional(:effective_model_serving_modes) => effective_model_serving_modes(),
          optional(:candidate_snapshots) => [candidate()],
          optional(:routing_settings) => RoutingSettings.t() | nil,
          optional(:quota_window_snapshots) => quota_window_snapshots(),
          optional(:circuit_snapshots) => circuit_snapshots(),
          optional(:circuit_eligibility_snapshots) => circuit_snapshots(),
          optional(:reservation_snapshot_inputs) => reservation_snapshot_inputs() | nil,
          optional(:extensions) => extensions()
        }

  @spec new(attrs()) :: t()
  def new(%{visible_model: %Model{} = visible_model, candidates: candidates} = attrs)
      when is_list(candidates) do
    %__MODULE__{
      visible_model: visible_model,
      visible_model_context:
        Map.get(attrs, :visible_model_context, %{visible_model: visible_model}),
      visible_models: Map.get(attrs, :visible_models, [visible_model]),
      effective_model_serving_modes: Map.get(attrs, :effective_model_serving_modes, %{}),
      candidate_snapshots: Map.get(attrs, :candidate_snapshots, candidates),
      candidates: candidates,
      routing_settings: Map.get(attrs, :routing_settings),
      quota_window_snapshots: Map.get(attrs, :quota_window_snapshots, %{}),
      circuit_snapshots: circuit_snapshots(attrs),
      circuit_eligibility_snapshots: circuit_snapshots(attrs),
      reservation_snapshot_inputs: Map.get(attrs, :reservation_snapshot_inputs),
      extensions: Map.get(attrs, :extensions, %{})
    }
  end

  @spec put_candidates(t(), [candidate()]) :: t()
  def put_candidates(%__MODULE__{} = route_state, candidates) when is_list(candidates),
    do: %{route_state | candidates: candidates}

  @spec put_codex_models_etag(t(), String.t()) :: t()
  def put_codex_models_etag(%__MODULE__{} = route_state, etag) when is_binary(etag) do
    %{
      route_state
      | extensions: Map.put(route_state.extensions, @codex_models_etag_extension, etag)
    }
  end

  @spec codex_models_etag(t()) :: String.t() | nil
  def codex_models_etag(%__MODULE__{} = route_state) do
    case Map.get(route_state.extensions, @codex_models_etag_extension) do
      etag when is_binary(etag) -> etag
      _value -> nil
    end
  end

  @spec put_reservation_snapshot_inputs(t(), reservation_snapshot_inputs()) :: t()
  def put_reservation_snapshot_inputs(%__MODULE__{} = route_state, snapshot_inputs)
      when is_map(snapshot_inputs),
      do: %{route_state | reservation_snapshot_inputs: snapshot_inputs}

  @spec put_quota_window_snapshots(t(), quota_window_snapshots()) :: t()
  def put_quota_window_snapshots(%__MODULE__{} = route_state, snapshots) when is_map(snapshots),
    do: %{route_state | quota_window_snapshots: snapshots}

  @spec put_circuit_snapshots(t(), circuit_snapshots()) :: t()
  def put_circuit_snapshots(%__MODULE__{} = route_state, snapshots) when is_map(snapshots),
    do: %{route_state | circuit_snapshots: snapshots, circuit_eligibility_snapshots: snapshots}

  @spec put_circuit_eligibility_snapshots(t(), circuit_snapshots()) :: t()
  def put_circuit_eligibility_snapshots(%__MODULE__{} = route_state, snapshots)
      when is_map(snapshots),
      do: put_circuit_snapshots(route_state, snapshots)

  @spec preload_routing_snapshots(t(), auth(), Model.t(), RequestOptions.t()) :: t()
  def preload_routing_snapshots(
        %__MODULE__{candidates: candidates} = route_state,
        auth,
        %Model{} = model,
        %RequestOptions{} = request_options
      ) do
    route_class = RequestOptions.route_class(request_options)

    route_state
    |> put_quota_window_snapshots(preload_quota_window_snapshots(candidates))
    |> put_circuit_snapshots(
      CircuitState.eligibility_snapshots(auth, model, candidates, route_class)
    )
  end

  @spec refresh_quota_window_snapshots(t()) :: t()
  def refresh_quota_window_snapshots(%__MODULE__{candidates: candidates} = route_state) do
    put_quota_window_snapshots(route_state, preload_quota_window_snapshots(candidates))
  end

  @spec quota_windows_for_identity(t(), UpstreamIdentity.t()) :: [AccountQuotaWindow.t()]
  def quota_windows_for_identity(%__MODULE__{} = route_state, %UpstreamIdentity{id: identity_id}) do
    Map.get(route_state.quota_window_snapshots, identity_id, [])
  end

  @spec circuit_snapshot(t(), Ecto.UUID.t()) :: circuit_snapshot() | nil
  def circuit_snapshot(%__MODULE__{} = route_state, assignment_id)
      when is_binary(assignment_id) do
    Map.get(route_state.circuit_snapshots, assignment_id)
  end

  @spec circuit_eligible?(t(), Ecto.UUID.t()) :: boolean()
  def circuit_eligible?(%__MODULE__{} = route_state, assignment_id)
      when is_binary(assignment_id) do
    case circuit_snapshot(route_state, assignment_id) do
      %{eligible?: eligible?} when is_boolean(eligible?) -> eligible?
      value when is_boolean(value) -> value
      _snapshot -> true
    end
  end

  defp circuit_snapshots(attrs) do
    Map.get(attrs, :circuit_snapshots, Map.get(attrs, :circuit_eligibility_snapshots, %{}))
  end

  defp preload_quota_window_snapshots(candidates) do
    candidates
    |> Enum.map(fn {_assignment, identity} -> identity.id end)
    |> Enum.uniq()
    |> QuotaWindows.list_quota_windows_by_identity_ids()
  end
end
