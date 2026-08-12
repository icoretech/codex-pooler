defmodule CodexPooler.Dev.Task14ProductObserver do
  @moduledoc """
  Bounded metadata-only Task 14 product-stage observer for local development.

  The observer is disabled until explicitly armed. It retains only clear,
  bounded technical correlators, fixed route/mode/status values, event counts,
  and a short hash of the upstream response identifier. Payloads, frame bytes,
  prompts, tokens, and credentials are never part of the telemetry contract.
  """

  @store __MODULE__.Store
  @handler_id "codex-pooler-task14-product-observer"
  @event [:codex_pooler, :gateway, :task14, :product_stage]
  @flag :task14_product_observation_enabled
  @max_requests 8
  @max_delta_count 10_000
  @bounded_id ~r/^[A-Za-z0-9_.:-]{1,120}$/
  @response_fingerprint ~r/^[0-9a-f]{12}$/

  @spec arm() :: :ok
  def arm do
    ensure_store()
    :telemetry.detach(@handler_id)
    :ok = :telemetry.attach(@handler_id, @event, &__MODULE__.handle_event/4, nil)
    Application.put_env(:codex_pooler, @flag, true)
    Agent.update(@store, fn _state -> %{} end)
  end

  @spec disarm() :: :ok
  def disarm do
    Application.put_env(:codex_pooler, @flag, false)
    :telemetry.detach(@handler_id)

    case Process.whereis(@store) do
      nil -> :ok
      _pid -> Agent.update(@store, fn _state -> %{} end)
    end
  end

  @spec armed?() :: boolean()
  def armed?, do: Application.get_env(:codex_pooler, @flag, false) == true

  @spec captures() :: map()
  def captures do
    ensure_store()
    Agent.get(@store, & &1)
  end

  @spec status() :: map()
  def status do
    %{
      "armed" => armed?(),
      "telemetryHandlers" => length(:telemetry.list_handlers(@event)),
      "captureEntries" => map_size(captures())
    }
  end

  @doc false
  def handle_event(@event, _measurements, metadata, _config) do
    with true <- armed?(),
         {:ok, observation} <- observation(metadata) do
      Agent.update(@store, &record(&1, observation))
    end

    :ok
  end

  defp observation(metadata) do
    with {:ok, request_id} <- bounded_id(metadata[:request_id]),
         {:ok, client_request_id} <- bounded_id(metadata[:client_request_id]),
         {:ok, attempt_id} <- optional_bounded_id(metadata[:attempt_id]),
         direction when direction in [:provider_to_pooler, :pooler_to_codex] <-
           metadata[:direction],
         event_type when event_type in ["response.output_text.delta", "response.completed"] <-
           metadata[:event_type],
         "backend_websocket" <- metadata[:route],
         mode when mode in ["full", "lite"] <- metadata[:mode],
         {:ok, response_fingerprint} <- response_fingerprint(metadata[:response_fingerprint]) do
      {:ok,
       %{
         request_id: request_id,
         client_request_id: client_request_id,
         attempt_id: attempt_id,
         direction: direction,
         event_type: event_type,
         route: "backend_websocket",
         mode: mode,
         response_fingerprint: response_fingerprint
       }}
    else
      _invalid -> :error
    end
  end

  defp record(state, observation) do
    request_id = observation.request_id

    if map_size(state) >= @max_requests and not Map.has_key?(state, request_id) do
      state
    else
      existing =
        Map.get(state, request_id, %{
          "clientRequestId" => observation.client_request_id,
          "requestId" => request_id,
          "attemptId" => observation.attempt_id,
          "route" => observation.route,
          "mode" => observation.mode,
          "providerDeltaCount" => 0,
          "downstreamDeltaCount" => 0
        })

      Map.put(state, request_id, merge(existing, observation))
    end
  end

  defp merge(existing, observation) do
    existing
    |> poison_mismatched_binding("clientRequestId", observation.client_request_id)
    |> poison_mismatched_binding("attemptId", observation.attempt_id)
    |> poison_mismatched_binding("route", observation.route)
    |> poison_mismatched_binding("mode", observation.mode)
    |> merge_response_fingerprint(observation.response_fingerprint)
    |> merge_event(observation.direction, observation.event_type)
  end

  defp poison_mismatched_binding(entry, key, observed) do
    case Map.fetch(entry, key) do
      {:ok, ^observed} -> entry
      :error -> Map.put(entry, key, observed)
      {:ok, _different} -> Map.put(entry, key, nil)
    end
  end

  defp merge_response_fingerprint(entry, nil), do: entry

  defp merge_response_fingerprint(entry, observed) do
    case Map.fetch(entry, "responseFingerprint") do
      :error -> Map.put(entry, "responseFingerprint", observed)
      {:ok, ^observed} -> entry
      {:ok, _different_or_poisoned} -> Map.put(entry, "responseFingerprint", nil)
    end
  end

  defp merge_event(entry, direction, "response.output_text.delta") do
    key = delta_count_key(direction)

    Map.update(entry, key, 1, fn
      count when is_integer(count) and count < @max_delta_count -> count + 1
      _overflow_or_poisoned -> nil
    end)
  end

  defp merge_event(entry, :provider_to_pooler, "response.completed"),
    do: Map.put(entry, "providerStatus", "completed")

  defp merge_event(entry, :pooler_to_codex, "response.completed"),
    do: Map.put(entry, "downstreamStatus", "delivered")

  defp delta_count_key(:provider_to_pooler), do: "providerDeltaCount"
  defp delta_count_key(:pooler_to_codex), do: "downstreamDeltaCount"

  defp bounded_id(value) when is_binary(value) do
    if String.valid?(value) and Regex.match?(@bounded_id, value), do: {:ok, value}, else: :error
  end

  defp bounded_id(_value), do: :error
  defp optional_bounded_id(nil), do: {:ok, nil}
  defp optional_bounded_id(value), do: bounded_id(value)
  defp response_fingerprint(nil), do: {:ok, nil}

  defp response_fingerprint(value) when is_binary(value) do
    if Regex.match?(@response_fingerprint, value), do: {:ok, value}, else: :error
  end

  defp response_fingerprint(_value), do: :error

  defp ensure_store do
    case Process.whereis(@store) do
      nil ->
        case Agent.start(fn -> %{} end, name: @store) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end
  end
end
