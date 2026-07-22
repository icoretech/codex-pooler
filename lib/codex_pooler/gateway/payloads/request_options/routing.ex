defmodule CodexPooler.Gateway.Payloads.RequestOptions.Routing do
  @moduledoc false

  alias CodexPooler.Access.APIKeys.ReasoningEffortPolicy.Decision
  alias CodexPooler.Gateway.Payloads.RequestOptions.ResetProbe

  @accounting_quota_decision_keys ~w(
    allowed
    summary
    routing_state
    precise_candidate_count
    credit_backed_probe_candidate_count
    weekly_probe_candidate_count
    reset_probe_candidate_count
    eligible_candidate_count
    refreshed_stale_quota
  )

  defstruct [
    :requested_model,
    :effective_model,
    :api_key_policy,
    :file_affinity_assignment_id,
    :prompt_cache_key,
    :quota_decision,
    :reset_probe,
    :reasoning_effort_decision,
    :supports_reasoning_summary_parameter?,
    :routing_attempt_metadata,
    :routing_circuit_state,
    :model_serving_mode_configured,
    :model_serving_mode,
    :model_serving_mode_source,
    :use_responses_lite?
  ]

  @type configured_model_serving_mode :: String.t()
  @type effective_model_serving_mode :: String.t()
  @type model_serving_mode_source :: String.t()
  @type model_serving_mode_snapshot :: %{
          required(:configured_mode) => configured_model_serving_mode(),
          required(:effective_mode) => effective_model_serving_mode(),
          required(:source) => model_serving_mode_source()
        }

  @type t :: %__MODULE__{
          requested_model: String.t() | nil,
          effective_model: String.t() | nil,
          api_key_policy: map() | nil,
          file_affinity_assignment_id: Ecto.UUID.t() | nil,
          prompt_cache_key: String.t() | nil,
          quota_decision: map() | nil,
          reset_probe: ResetProbe.t() | nil,
          reasoning_effort_decision: Decision.t() | nil,
          supports_reasoning_summary_parameter?: boolean(),
          routing_attempt_metadata: map() | nil,
          routing_circuit_state: term(),
          model_serving_mode_configured: configured_model_serving_mode() | nil,
          model_serving_mode: effective_model_serving_mode() | nil,
          model_serving_mode_source: model_serving_mode_source() | nil,
          use_responses_lite?: boolean()
        }

  @spec accounting_quota_decision(t()) :: map() | nil
  def accounting_quota_decision(%__MODULE__{quota_decision: decision}) when is_map(decision) do
    case Map.take(decision, @accounting_quota_decision_keys) do
      projection when map_size(projection) == 0 -> nil
      projection -> projection
    end
  end

  def accounting_quota_decision(%__MODULE__{}), do: nil

  @spec model_serving_mode_snapshot(t()) :: model_serving_mode_snapshot() | nil
  def model_serving_mode_snapshot(%__MODULE__{
        model_serving_mode_configured: nil,
        model_serving_mode: nil,
        model_serving_mode_source: nil
      }),
      do: nil

  def model_serving_mode_snapshot(%__MODULE__{} = routing) do
    %{
      configured_mode: routing.model_serving_mode_configured,
      effective_mode: routing.model_serving_mode,
      source: routing.model_serving_mode_source
    }
  end

  @spec put_model_serving_mode(t(), model_serving_mode_snapshot() | keyword()) :: t()
  def put_model_serving_mode(%__MODULE__{} = routing, snapshot)
      when is_map(snapshot) or is_list(snapshot) do
    snapshot = Map.new(snapshot)
    validated_snapshot = validate_model_serving_mode_snapshot!(snapshot)

    case model_serving_mode_snapshot(routing) do
      nil -> apply_model_serving_mode_snapshot(routing, validated_snapshot)
      ^validated_snapshot -> routing
      _existing_snapshot -> raise ArgumentError, "model serving mode snapshot is immutable"
    end
  end

  @spec update(t(), keyword()) :: t()
  def update(%__MODULE__{} = routing, updates) when is_list(updates) do
    snapshot = model_serving_mode_snapshot(routing)
    updated = struct!(routing, updates)

    unless ResetProbe.valid_transition?(routing.reset_probe, updated.reset_probe) do
      raise ArgumentError, "reset probe context is immutable"
    end

    case snapshot do
      nil ->
        case model_serving_mode_snapshot(updated) do
          nil ->
            updated

          updated_snapshot ->
            put_model_serving_mode(clear_model_serving_mode(updated), updated_snapshot)
        end

      _resolved ->
        if snapshot == model_serving_mode_snapshot(updated) and
             updated.use_responses_lite? == (updated.model_serving_mode == "lite") do
          updated
        else
          raise ArgumentError, "model serving mode snapshot is immutable"
        end
    end
  end

  defp validate_model_serving_mode_snapshot!(snapshot) do
    normalized = %{
      configured_mode: Map.get(snapshot, :configured_mode),
      effective_mode: Map.get(snapshot, :effective_mode),
      source: Map.get(snapshot, :source)
    }

    case normalized do
      %{configured_mode: "auto", effective_mode: effective_mode, source: "catalog"}
      when effective_mode in ~w(lite full) ->
        normalized

      %{configured_mode: mode, effective_mode: mode, source: "override"}
      when mode in ~w(lite full) ->
        normalized

      _invalid ->
        raise ArgumentError, "invalid model serving mode snapshot"
    end
  end

  defp apply_model_serving_mode_snapshot(routing, snapshot) do
    %{
      routing
      | model_serving_mode_configured: snapshot.configured_mode,
        model_serving_mode: snapshot.effective_mode,
        model_serving_mode_source: snapshot.source,
        use_responses_lite?: snapshot.effective_mode == "lite"
    }
  end

  defp clear_model_serving_mode(routing) do
    %{
      routing
      | model_serving_mode_configured: nil,
        model_serving_mode: nil,
        model_serving_mode_source: nil,
        use_responses_lite?: false
    }
  end
end
