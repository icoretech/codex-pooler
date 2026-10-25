defmodule CodexPooler.Accounting.RequestLifecycle.DeadExecutionResendRecovery do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounting.{Attempt, PreAttemptRelease, Request, RequestLifecycle}
  alias CodexPooler.Gateway.Runtime.Finalization.InterruptionOutcome
  alias CodexPooler.Repo

  @live_request_statuses ["accepted", "in_progress"]

  @type marker ::
          PreAttemptRelease.marker()
          | %{
              required(:kind) => :stream_outcome,
              required(:outcome) => String.t(),
              required(:downstream_transport) => String.t(),
              required(:upstream_transport) => String.t()
            }

  @spec recover(Request.t(), boolean(), DateTime.t()) ::
          {:ok, Request.t(), marker() | nil} | {:error, :active_predecessor}
  def recover(%Request{status: status} = request, true, now)
      when status in @live_request_statuses do
    attempt = lock_latest_attempt(request.id)

    authority = attempt && RequestLifecycle.execution_recovery_authority(attempt)

    if authority do
      result =
        case authority do
          :terminal -> RequestLifecycle.recover_dead_execution(request, attempt, now)
          :absent -> RequestLifecycle.recover_absent_execution(request, attempt, now, [])
        end

      case result do
        {:ok, :recovered} ->
          {:ok, Repo.reload!(request), recovery_marker(request, attempt)}

        {:ok, :noop} ->
          {:ok, request, nil}

        {:error, _reason} ->
          {:error, :active_predecessor}
      end
    else
      {:ok, request, nil}
    end
  end

  def recover(%Request{} = request, _scoped?, _now), do: {:ok, request, nil}

  @spec markers(map() | nil) :: [marker()]
  def markers(%{recovery_markers: markers}) when is_list(markers), do: markers
  def markers(_client_resend), do: []

  @spec put_markers(map(), map() | nil) :: map()
  def put_markers(result, client_resend) when is_map(result) do
    case markers(client_resend) do
      [] -> result
      markers -> Map.put(result, :after_commit_markers, markers)
    end
  end

  @spec emit_after_commit({:ok, map()} | {:error, term()}, boolean()) ::
          {:ok, map()} | {:error, term()}
  def emit_after_commit({:ok, %{after_commit_markers: markers} = result}, false) do
    Enum.each(markers, fn
      %{kind: :pre_attempt_release} = marker -> PreAttemptRelease.emit_marker(marker)
      marker -> InterruptionOutcome.emit(marker.downstream_transport, marker.upstream_transport)
    end)

    {:ok, Map.delete(result, :after_commit_markers)}
  end

  def emit_after_commit(result, _caller_owned_transaction?), do: result

  defp lock_latest_attempt(request_id) do
    Repo.one(
      from attempt in Attempt,
        where: attempt.request_id == ^request_id,
        order_by: [desc: attempt.attempt_number],
        limit: 1,
        lock: "FOR UPDATE"
    )
  end

  defp recovery_marker(request, attempt) do
    %{
      kind: :stream_outcome,
      outcome: "interrupted",
      downstream_transport: bounded_transport(request.transport),
      upstream_transport: bounded_transport(attempt.transport)
    }
  end

  defp bounded_transport(transport) when transport in ["http_sse", "websocket"], do: transport
  defp bounded_transport(_transport), do: "unknown"
end
