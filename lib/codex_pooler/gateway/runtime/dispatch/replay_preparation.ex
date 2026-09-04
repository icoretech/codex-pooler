defmodule CodexPooler.Gateway.Runtime.Dispatch.ReplayPreparation do
  @moduledoc false

  alias CodexPooler.Access.APIKeys.ReasoningEffortPolicy.Decision
  alias CodexPooler.Gateway.Payloads.NativeCodexTurnMetadata
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Runtime.Dispatch.SelectedCandidateContext
  alias CodexPooler.Pools.RoutingSettings

  @metadata_key "native_replay_preparation"
  @efforts [nil | ~w(none minimal low medium high xhigh max ultra)]
  @modes %{
    "unrestricted" => :unrestricted,
    "allow_up_to" => :allow_up_to,
    "always_use" => :always_use
  }
  @snapshot_keys ~w(version configured_mode effective_mode source reasoning_mode configured_effort requested_effort applied_effort supports_reasoning_summary request_compression_enabled)

  @type snapshot :: %{required(String.t()) => String.t() | boolean() | integer() | nil}

  @spec final_window_alias_hash(RequestOptions.t(), map()) ::
          :none | {:ok, <<_::256>>} | {:error, :invalid_final_window}
  def final_window_alias_hash(
        %RequestOptions{
          native_compaction_admission: %{capability: %{phase: :final, binding: binding}},
          payload_context: %{native_codex_turn_metadata: %NativeCodexTurnMetadata{} = metadata},
          openai_compatibility: %{source_endpoint: nil}
        },
        payload
      ) do
    with true <- metadata.request_kind == :turn,
         true <- metadata.window_id_digest == binding.window_digest,
         true <- metadata.semantic_turn_key == binding.semantic_turn_key,
         {:ok, canonical} <- canonical_metadata(payload),
         window when is_binary(window) <- canonical["window_id"],
         true <- NativeCodexTurnMetadata.window_id_digest(window) == metadata.window_id_digest do
      {:ok, :crypto.hash(:sha256, String.trim(window))}
    else
      _invalid -> {:error, :invalid_final_window}
    end
  end

  def final_window_alias_hash(%RequestOptions{}, _payload), do: :none

  defp canonical_metadata(%{"client_metadata" => %{"x-codex-turn-metadata" => metadata}})
       when is_map(metadata), do: {:ok, metadata}

  defp canonical_metadata(%{"client_metadata" => %{"x-codex-turn-metadata" => metadata}})
       when is_binary(metadata), do: Jason.decode(metadata)

  defp canonical_metadata(_payload), do: {:error, :invalid_final_window}

  @spec attempt_metadata(SelectedCandidateContext.t()) :: map()
  def attempt_metadata(%SelectedCandidateContext{request_options: options} = context) do
    if eligible?(options) do
      case snapshot(context) do
        snapshot when map_size(snapshot) > 0 -> %{@metadata_key => snapshot}
        _invalid -> %{}
      end
    else
      %{}
    end
  end

  @spec restore(RequestOptions.t(), map()) ::
          {:ok, RequestOptions.t(), RoutingSettings.t()} | {:error, :invalid_replay_preparation}
  def restore(%RequestOptions{} = options, metadata) when is_map(metadata) do
    case sanitize(Map.get(metadata, @metadata_key)) do
      %{"version" => 1} = snapshot ->
        options =
          options
          |> RequestOptions.put_model_serving_mode(%{
            configured_mode: snapshot["configured_mode"],
            effective_mode: snapshot["effective_mode"],
            source: snapshot["source"]
          })
          |> RequestOptions.put_routing(
            reasoning_effort_decision: %Decision{
              mode: Map.fetch!(@modes, snapshot["reasoning_mode"]),
              configured_effort: snapshot["configured_effort"],
              requested_effort: snapshot["requested_effort"],
              applied_effort: snapshot["applied_effort"]
            },
            supports_reasoning_summary_parameter?: snapshot["supports_reasoning_summary"],
            routing_attempt_metadata:
              Map.take(
                metadata,
                ~w(model_serving_mode_configured model_serving_mode model_serving_mode_source)
              )
          )

        {:ok, options,
         %RoutingSettings{request_compression_enabled: snapshot["request_compression_enabled"]}}

      _invalid ->
        {:error, :invalid_replay_preparation}
    end
  end

  @spec sanitize(term()) :: snapshot()
  def sanitize(%{"version" => 1} = snapshot) do
    if valid_mode?(snapshot) and valid_reasoning?(snapshot) and
         is_boolean(snapshot["supports_reasoning_summary"]) and
         is_boolean(snapshot["request_compression_enabled"]) do
      Map.take(snapshot, @snapshot_keys)
    else
      %{}
    end
  end

  def sanitize(_snapshot), do: %{}

  defp eligible?(%RequestOptions{
         transport: %{transport: "websocket", websocket_owner: %{enabled?: true}},
         openai_compatibility: %{source_endpoint: nil},
         continuity: %{request_claim_key: claim, replay_claim_digest: digest},
         payload_context: %{compaction_trigger_bridge?: false}
       })
       when is_binary(claim) and is_binary(digest) and byte_size(digest) == 32,
       do: true

  defp eligible?(%RequestOptions{}), do: false

  defp snapshot(%SelectedCandidateContext{request_options: options, route_state: route_state}) do
    case {RequestOptions.model_serving_mode_snapshot(options),
          options.routing.reasoning_effort_decision} do
      {%{} = mode, %Decision{} = decision} ->
        sanitize(%{
          "version" => 1,
          "configured_mode" => mode.configured_mode,
          "effective_mode" => mode.effective_mode,
          "source" => mode.source,
          "reasoning_mode" => Atom.to_string(decision.mode),
          "configured_effort" => decision.configured_effort,
          "requested_effort" => decision.requested_effort,
          "applied_effort" => decision.applied_effort,
          "supports_reasoning_summary" =>
            options.routing.supports_reasoning_summary_parameter? != false,
          "request_compression_enabled" =>
            Map.get(route_state.routing_settings || %{}, :request_compression_enabled) == true
        })

      _invalid ->
        %{}
    end
  end

  defp valid_mode?(%{
         "configured_mode" => "auto",
         "effective_mode" => mode,
         "source" => "catalog"
       })
       when mode in ~w(lite full), do: true

  defp valid_mode?(%{"configured_mode" => mode, "effective_mode" => mode, "source" => "override"})
       when mode in ~w(lite full), do: true

  defp valid_mode?(_snapshot), do: false

  defp valid_reasoning?(snapshot) do
    Map.has_key?(@modes, snapshot["reasoning_mode"]) and
      Enum.all?(~w(configured_effort requested_effort applied_effort), fn key ->
        Map.has_key?(snapshot, key) and snapshot[key] in @efforts
      end)
  end
end
