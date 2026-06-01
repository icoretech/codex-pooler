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

  defstruct [
    :visible_model,
    candidates: [],
    quota_window_snapshots: %{},
    circuit_eligibility_snapshots: %{},
    routing_settings: nil,
    visible_models: [],
    extensions: %{}
  ]

  @type candidate :: CandidateEligibility.candidate()
  @type auth :: CodexPooler.Access.auth_context()
  @type quota_window_snapshots :: %{optional(Ecto.UUID.t()) => [AccountQuotaWindow.t()]}
  @type circuit_eligibility_snapshots :: %{optional(Ecto.UUID.t()) => boolean()}
  @type extensions :: %{optional(atom() | String.t()) => term()}

  @type t :: %__MODULE__{
          visible_model: Model.t(),
          candidates: [candidate()],
          quota_window_snapshots: quota_window_snapshots(),
          circuit_eligibility_snapshots: circuit_eligibility_snapshots(),
          routing_settings: RoutingSettings.t() | nil,
          visible_models: [Model.t()],
          extensions: extensions()
        }

  @type attrs :: %{
          required(:visible_model) => Model.t(),
          required(:candidates) => [candidate()],
          optional(:quota_window_snapshots) => quota_window_snapshots(),
          optional(:circuit_eligibility_snapshots) => circuit_eligibility_snapshots(),
          optional(:routing_settings) => RoutingSettings.t() | nil,
          optional(:visible_models) => [Model.t()],
          optional(:extensions) => extensions()
        }

  @spec new(attrs()) :: t()
  def new(%{visible_model: %Model{} = visible_model, candidates: candidates} = attrs)
      when is_list(candidates) do
    %__MODULE__{
      visible_model: visible_model,
      candidates: candidates,
      quota_window_snapshots: Map.get(attrs, :quota_window_snapshots, %{}),
      circuit_eligibility_snapshots: Map.get(attrs, :circuit_eligibility_snapshots, %{}),
      routing_settings: Map.get(attrs, :routing_settings),
      visible_models: Map.get(attrs, :visible_models, [visible_model]),
      extensions: Map.get(attrs, :extensions, %{})
    }
  end

  @spec put_candidates(t(), [candidate()]) :: t()
  def put_candidates(%__MODULE__{} = route_state, candidates) when is_list(candidates),
    do: %{route_state | candidates: candidates}

  @spec put_quota_window_snapshots(t(), quota_window_snapshots()) :: t()
  def put_quota_window_snapshots(%__MODULE__{} = route_state, snapshots) when is_map(snapshots),
    do: %{route_state | quota_window_snapshots: snapshots}

  @spec put_circuit_eligibility_snapshots(t(), circuit_eligibility_snapshots()) :: t()
  def put_circuit_eligibility_snapshots(%__MODULE__{} = route_state, snapshots)
      when is_map(snapshots),
      do: %{route_state | circuit_eligibility_snapshots: snapshots}

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
    |> put_circuit_eligibility_snapshots(
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

  @spec circuit_eligible?(t(), Ecto.UUID.t()) :: boolean()
  def circuit_eligible?(%__MODULE__{} = route_state, assignment_id)
      when is_binary(assignment_id) do
    Map.get(route_state.circuit_eligibility_snapshots, assignment_id, true)
  end

  defp preload_quota_window_snapshots(candidates) do
    candidates
    |> Enum.map(fn {_assignment, identity} -> identity.id end)
    |> Enum.uniq()
    |> QuotaWindows.list_quota_windows_by_identity_ids()
  end
end
