defmodule CodexPooler.Gateway.Runtime.Dispatch.RouteState do
  @moduledoc false

  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.ResetProbe
  alias CodexPooler.Gateway.Routing.CandidateEligibility
  alias CodexPooler.Gateway.Routing.CircuitState
  alias CodexPooler.Pools.RoutingSettings
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.RoutingQuotaSnapshot
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @enforce_keys [:visible_model]
  defstruct [
    :visible_model,
    visible_model_context: %{},
    visible_models: [],
    effective_model_serving_modes: %{},
    candidate_snapshots: [],
    saved_reset_auto_cohort: [],
    saved_reset_auto_capacity: [],
    candidates: [],
    routing_settings: nil,
    quota_snapshots: %{},
    circuit_snapshots: %{},
    circuit_eligibility_snapshots: %{},
    reservation_snapshot_inputs: nil,
    reset_probe: nil,
    extensions: %{}
  ]

  @type candidate :: CandidateEligibility.candidate()
  @type auth :: CodexPooler.Access.auth_context()
  @type visible_model_context :: %{optional(atom()) => term()}
  @type quota_snapshots :: RoutingQuotaSnapshot.snapshot_map()
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
          required(:reservation_estimate) => map(),
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
          saved_reset_auto_cohort: [candidate()],
          saved_reset_auto_capacity: [candidate()],
          candidates: [candidate()],
          routing_settings: RoutingSettings.t() | nil,
          quota_snapshots: quota_snapshots(),
          circuit_snapshots: circuit_snapshots(),
          circuit_eligibility_snapshots: circuit_snapshots(),
          reservation_snapshot_inputs: reservation_snapshot_inputs() | nil,
          reset_probe: ResetProbe.t() | nil,
          extensions: extensions()
        }

  @type attrs :: %{
          required(:visible_model) => Model.t(),
          required(:candidates) => [candidate()],
          optional(:visible_model_context) => visible_model_context(),
          optional(:visible_models) => [Model.t()],
          optional(:effective_model_serving_modes) => effective_model_serving_modes(),
          optional(:candidate_snapshots) => [candidate()],
          optional(:saved_reset_auto_cohort) => [candidate()],
          optional(:saved_reset_auto_capacity) => [candidate()],
          optional(:routing_settings) => RoutingSettings.t() | nil,
          optional(:quota_snapshots) => quota_snapshots(),
          optional(:circuit_snapshots) => circuit_snapshots(),
          optional(:circuit_eligibility_snapshots) => circuit_snapshots(),
          optional(:reservation_snapshot_inputs) => reservation_snapshot_inputs() | nil,
          optional(:reset_probe) => ResetProbe.t() | nil,
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
      saved_reset_auto_cohort: Map.get(attrs, :saved_reset_auto_cohort, candidates),
      saved_reset_auto_capacity: Map.get(attrs, :saved_reset_auto_capacity, candidates),
      candidates: candidates,
      routing_settings: Map.get(attrs, :routing_settings),
      circuit_snapshots: circuit_snapshots(attrs),
      circuit_eligibility_snapshots: circuit_snapshots(attrs),
      reservation_snapshot_inputs: Map.get(attrs, :reservation_snapshot_inputs),
      reset_probe: Map.get(attrs, :reset_probe),
      extensions: Map.get(attrs, :extensions, %{})
    }
    |> put_quota_snapshots(Map.get(attrs, :quota_snapshots, %{}))
  end

  @spec put_candidates(t(), [candidate()]) :: t()
  def put_candidates(%__MODULE__{} = route_state, candidates) when is_list(candidates),
    do: %{route_state | candidates: candidates}

  @spec put_saved_reset_auto_cohort(t(), [candidate()]) :: t()
  def put_saved_reset_auto_cohort(%__MODULE__{} = route_state, candidates)
      when is_list(candidates),
      do: %{route_state | saved_reset_auto_cohort: candidates}

  @spec put_saved_reset_auto_capacity(t(), [candidate()]) :: t()
  def put_saved_reset_auto_capacity(%__MODULE__{} = route_state, candidates)
      when is_list(candidates),
      do: %{route_state | saved_reset_auto_capacity: candidates}

  @spec put_reset_probe(t(), ResetProbe.t()) :: t()
  def put_reset_probe(%__MODULE__{} = route_state, %ResetProbe{} = reset_probe),
    do: %{route_state | reset_probe: reset_probe}

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

  @spec put_quota_snapshots(t(), quota_snapshots()) :: t()
  def put_quota_snapshots(%__MODULE__{} = route_state, snapshots) when is_map(snapshots) do
    validate_quota_snapshots!(snapshots)
    %{route_state | quota_snapshots: snapshots}
  end

  @spec put_circuit_snapshots(t(), circuit_snapshots()) :: t()
  def put_circuit_snapshots(%__MODULE__{} = route_state, snapshots) when is_map(snapshots),
    do: %{route_state | circuit_snapshots: snapshots, circuit_eligibility_snapshots: snapshots}

  @spec put_circuit_eligibility_snapshots(t(), circuit_snapshots()) :: t()
  def put_circuit_eligibility_snapshots(%__MODULE__{} = route_state, snapshots)
      when is_map(snapshots),
      do: put_circuit_snapshots(route_state, snapshots)

  @spec load_quota_snapshots([candidate()]) :: quota_snapshots()
  def load_quota_snapshots(candidates) when is_list(candidates),
    do: load_quota_snapshot(candidates)

  @spec preload_routing_snapshots(t(), auth(), Model.t(), RequestOptions.t()) :: t()
  def preload_routing_snapshots(
        %__MODULE__{} = route_state,
        auth,
        %Model{} = model,
        %RequestOptions{} = request_options
      ) do
    route_class = RequestOptions.route_class(request_options)

    routing_candidates = routing_snapshot_candidates(route_state)

    route_state
    |> maybe_load_quota_snapshot(routing_candidates)
    |> put_circuit_snapshots(
      CircuitState.eligibility_snapshots(auth, model, routing_candidates, route_class)
    )
  end

  # Canonical partition selection loads a snapshot over the wider pre-filter
  # candidate list. When that snapshot already covers every remaining candidate
  # there is nothing new to learn, so reuse it instead of reading quota twice
  # per dispatch.
  defp maybe_load_quota_snapshot(%__MODULE__{} = route_state, candidates) do
    if quota_snapshot_covers?(route_state, candidates) do
      route_state
    else
      put_quota_snapshots(route_state, load_quota_snapshot(candidates))
    end
  end

  defp quota_snapshot_covers?(%__MODULE__{quota_snapshots: snapshots}, candidates),
    do:
      snapshots != %{} and
        Enum.all?(candidates, fn {_assignment, identity} ->
          Map.has_key?(snapshots, identity.id)
        end)

  @spec refresh_quota_snapshots(t()) :: t()
  def refresh_quota_snapshots(%__MODULE__{} = route_state) do
    put_quota_snapshots(
      route_state,
      load_quota_snapshot(routing_snapshot_candidates(route_state))
    )
  end

  @doc false
  @spec refresh_quota_snapshots(t(), ([Ecto.UUID.t()], DateTime.t() -> quota_snapshots())) :: t()
  def refresh_quota_snapshots(
        %__MODULE__{} = route_state,
        loader
      )
      when is_function(loader, 2) do
    put_quota_snapshots(
      route_state,
      load_quota_snapshot(routing_snapshot_candidates(route_state), loader)
    )
  end

  @spec quota_windows_for_identity(t(), UpstreamIdentity.t()) :: [AccountQuotaWindow.t()]
  def quota_windows_for_identity(%__MODULE__{} = route_state, %UpstreamIdentity{id: identity_id}) do
    route_state
    |> quota_snapshot_for_identity!(identity_id)
    |> Map.fetch!(:raw_windows)
  end

  @spec quota_snapshot_for_identity(t(), UpstreamIdentity.t() | Ecto.UUID.t()) ::
          RoutingQuotaSnapshot.t()
  def quota_snapshot_for_identity(%__MODULE__{} = route_state, %UpstreamIdentity{id: identity_id}),
      do: quota_snapshot_for_identity!(route_state, identity_id)

  def quota_snapshot_for_identity(%__MODULE__{} = route_state, identity_id)
      when is_binary(identity_id),
      do: quota_snapshot_for_identity!(route_state, identity_id)

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

  defp load_quota_snapshot(candidates) do
    load_quota_snapshot(candidates, &QuotaWindows.load_routing_quota_snapshots/2)
  end

  defp load_quota_snapshot(candidates, loader) do
    snapshot_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    candidates
    |> Enum.map(fn {_assignment, identity} -> identity.id end)
    |> Enum.uniq()
    |> loader.(snapshot_at)
  end

  defp routing_snapshot_candidates(%__MODULE__{} = route_state) do
    (route_state.saved_reset_auto_capacity ++ route_state.candidates)
    |> Enum.uniq_by(fn {assignment, identity} -> {assignment.id, identity.id} end)
  end

  defp quota_snapshot_for_identity!(%__MODULE__{quota_snapshots: snapshots}, identity_id) do
    Map.fetch!(snapshots, identity_id)
  end

  defp validate_quota_snapshots!(snapshots) do
    valid_entries? =
      Enum.all?(snapshots, fn
        {identity_id,
         %RoutingQuotaSnapshot{upstream_identity_id: snapshot_identity_id, as_of: %DateTime{}}}
        when identity_id == snapshot_identity_id ->
          true

        _entry ->
          false
      end)

    as_of_values =
      if valid_entries? do
        snapshots |> Map.values() |> Enum.map(& &1.as_of) |> Enum.uniq()
      else
        []
      end

    if not valid_entries? or length(as_of_values) > 1 do
      raise ArgumentError, "quota snapshots must be complete identity entries from one as_of"
    end
  end
end
