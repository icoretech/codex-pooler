defmodule CodexPooler.Gateway.Routing.AffinityTelemetry do
  @moduledoc false

  # An affinity write is fenced on the row's `updated_at` event clock, and the
  # fence refuses by applying no row at all. That refusal is correct — routing
  # bookkeeping must never fail a turn whose work is already finalized — but it
  # is otherwise invisible: an accepted write and a fenced no-op return the same
  # `:ok` and leave the same absence in logs, metrics and request metadata. A
  # replica whose clock has drifted backwards therefore loses every affinity
  # write it attempts, permanently, and nothing says so.
  #
  # This counter is the whole signal. It is emitted only when the statement
  # reports zero affected rows, read from the same result that enforces the
  # fence, so it costs one pattern match on a value the write already produced.
  #
  # Deliberately absent:
  #
  #   * no log line. Both writers sit on the success path of every turn on a hot
  #     route; one line per stale completion is the noise this replaces.
  #   * no node or instance name in the payload. Per-replica attribution comes
  #     from the scrape target's pod label, which is both the right layer and
  #     the only one that keeps the label set bounded. A non-zero rate on one
  #     pod is the symptom; the pod is the answer.

  @event [:codex_pooler, :gateway, :routing, :affinity, :stale_write]
  @operations ~w(success_upsert miss_update)
  # The kinds `BridgeRing.affinity_context/5` can write to
  # `bridge_affinities.affinity_kind`. Not `prompt_cache`: that constant names
  # the locality *seed*, and prompt-cache-steered traffic still stores its row
  # under whichever of these three keyed it.
  @affinity_kinds ~w(codex_session idempotency_key request_correlation)

  @type operation :: String.t()
  @type affinity_kind :: String.t()

  @spec event() :: [atom()]
  def event, do: @event

  @spec operations() :: [operation()]
  def operations, do: @operations

  @spec affinity_kinds() :: [affinity_kind()]
  def affinity_kinds, do: @affinity_kinds

  @doc """
  Counts one affinity write that the `updated_at` fence refused.

  Always returns `:ok`. A handler that raises, throws or exits must not
  propagate into a turn that has already settled, so the emit is total and the
  labels are normalized rather than guarded.
  """
  @spec emit_stale_write(term(), term()) :: :ok
  def emit_stale_write(operation, affinity_kind) do
    try do
      :telemetry.execute(
        @event,
        %{count: 1},
        %{operation: operation(operation), affinity_kind: affinity_kind(affinity_kind)}
      )
    rescue
      _error -> :ok
    catch
      _kind, _reason -> :ok
    end

    :ok
  end

  defp operation(operation) when is_atom(operation) and not is_nil(operation) do
    operation
    |> Atom.to_string()
    |> operation()
  end

  defp operation(operation) when operation in @operations, do: operation
  defp operation(_operation), do: "unknown"

  defp affinity_kind(kind) when is_atom(kind) and not is_nil(kind) do
    kind
    |> Atom.to_string()
    |> affinity_kind()
  end

  defp affinity_kind(kind) when kind in @affinity_kinds, do: kind
  defp affinity_kind(_kind), do: "unknown"
end
