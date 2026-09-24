defmodule CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession.Logger do
  @moduledoc false

  require Logger

  alias CodexPooler.Gateway.Runtime.Finalization.Metadata

  @spec owner_started(pid(), keyword()) :: :ok
  def owner_started(pid, opts) do
    owner_event(:info, "websocket owner started",
      codex_session_id: Keyword.get(opts, :codex_session_id),
      owner_instance_id: Keyword.get(opts, :owner_instance_id),
      owner_pid: pid,
      request_id: Keyword.get(opts, :request_id)
    )
  end

  @spec owner_reused(pid(), keyword()) :: :ok
  def owner_reused(pid, opts) do
    owner_event(:info, "websocket owner reused",
      codex_session_id: Keyword.get(opts, :codex_session_id),
      owner_instance_id: Keyword.get(opts, :owner_instance_id),
      owner_pid: pid,
      request_id: Keyword.get(opts, :request_id)
    )
  end

  @spec owner_stale_replaced(pid(), keyword()) :: :ok
  def owner_stale_replaced(pid, opts) do
    owner_event(:info, "websocket owner stale replaced",
      codex_session_id: Keyword.get(opts, :codex_session_id),
      owner_instance_id: Keyword.get(opts, :owner_instance_id),
      owner_pid: pid,
      request_id: Keyword.get(opts, :request_id)
    )
  end

  @spec owner_start_failed(term(), keyword()) :: :ok
  def owner_start_failed(reason, opts) do
    owner_event(:warning, "websocket owner start failed",
      codex_session_id: Keyword.get(opts, :codex_session_id),
      owner_instance_id: Keyword.get(opts, :owner_instance_id),
      reason: Metadata.safe_reason(reason),
      request_id: Keyword.get(opts, :request_id)
    )
  end

  @spec owner_lookup_missed(binary(), atom(), pid() | nil, keyword()) :: :ok
  def owner_lookup_missed(codex_session_id, reason, pid, metadata) do
    owner_event(:info, "websocket owner lookup missed",
      codex_session_id: codex_session_id,
      owner_instance_id: Keyword.get(metadata, :owner_instance_id),
      owner_pid: pid,
      reason: reason,
      request_id: Keyword.get(metadata, :request_id)
    )
  end

  @spec owner_renewal_stale(term(), map()) :: :ok
  def owner_renewal_stale(reason, state) do
    owner_event(:warning, "websocket owner renewal stale",
      codex_session_id: state.codex_session_id,
      owner_instance_id: state.owner_instance_id,
      owner_pid: self(),
      reason: Metadata.safe_reason(reason),
      request_id: state.request_id
    )
  end

  @spec owner_renewal_failed(term(), map()) :: :ok
  def owner_renewal_failed(reason, state) do
    owner_event(:warning, "websocket owner renewal failed",
      codex_session_id: state.codex_session_id,
      owner_instance_id: state.owner_instance_id,
      owner_pid: self(),
      reason: Metadata.safe_reason(reason),
      request_id: state.request_id
    )
  end

  @spec owner_terminated(term(), atom(), :idle_expiry | :drain_cut | nil, map()) :: :ok
  def owner_terminated(reason, owner_exit_reason, owner_exit_cause, state) do
    owner_event(:info, "websocket owner terminated",
      codex_session_id: state.codex_session_id,
      owner_instance_id: state.owner_instance_id,
      owner_pid: self(),
      reason: Metadata.safe_reason(reason),
      owner_exit_reason: owner_exit_reason,
      owner_exit_cause: owner_exit_cause,
      request_id: state.request_id,
      downstream_epoch: downstream_epoch(state.downstream)
    )
  end

  # A different turn from the session's next socket retired the armed
  # pre-visible replay (findings#206 row 206-348); `disposition` is `closed`
  # when this call settled the interrupted request and `noop` when it was
  # already settled (the entitlement expired first).
  @spec replay_superseded(map(), map(), pos_integer(), :closed | :noop) :: :ok
  def replay_superseded(state, armed, downstream_epoch, disposition) do
    owner_event(:info, "websocket owner replay superseded",
      codex_session_id: state.codex_session_id,
      owner_instance_id: state.owner_instance_id,
      owner_pid: self(),
      request_id: Map.get(armed.lifecycle, :request_id),
      predecessor_epoch: armed.predecessor_epoch,
      downstream_epoch: downstream_epoch,
      disposition: disposition
    )
  end

  # The socket that inherited a running visible turn at its attach sent another
  # request, and the owner cancelled that turn as the socket's close would
  # (findings#206 row 206-362).
  @spec inherited_turn_taken_over(map(), pos_integer()) :: :ok
  def inherited_turn_taken_over(state, downstream_epoch) do
    owner_event(:info, "websocket owner inherited turn taken over",
      codex_session_id: state.codex_session_id,
      owner_instance_id: state.owner_instance_id,
      owner_pid: self(),
      downstream_epoch: downstream_epoch
    )
  end

  # The retry of a collected compaction whose socket had closed took it over
  # before that socket's own detach arrived, and was attached in its place
  # (findings#206 row 206-454).
  @spec closed_socket_collection_taken_over(map(), pos_integer(), pos_integer()) :: :ok
  def closed_socket_collection_taken_over(state, closed_epoch, downstream_epoch) do
    owner_event(:info, "websocket owner closed socket collection taken over",
      codex_session_id: state.codex_session_id,
      owner_instance_id: state.owner_instance_id,
      owner_pid: self(),
      closed_downstream_epoch: closed_epoch,
      downstream_epoch: downstream_epoch
    )
  end

  @spec owner_exit_persistence_failure(atom(), map(), atom(), term()) :: :ok
  # A later turn of the session (an HTTP fallback the owner never held) was
  # already running when the owner exited, so the owner-scoped interrupt stood
  # down on purpose and the lease stays with that turn: routine, not a failure
  # (findings#225, row 225-85).
  def owner_exit_persistence_failure(operation, state, owner_exit_reason, :superseded_owner_cleanup) do
    Logger.info(
      "websocket owner exit persistence superseded " <>
        "codex_session_id=#{safe_log_value(state.codex_session_id)} " <>
        "operation=#{operation} " <>
        "owner_exit_reason=#{owner_exit_reason} " <>
        "reason_code=replacement_turn_active"
    )

    :ok
  end

  def owner_exit_persistence_failure(operation, state, owner_exit_reason, reason) do
    Logger.warning(
      "websocket owner exit persistence failed " <>
        "codex_session_id=#{safe_log_value(state.codex_session_id)} " <>
        "operation=#{operation} " <>
        "reason_class=#{safe_log_value(Metadata.safe_reason(reason))} " <>
        "owner_exit_reason=#{owner_exit_reason} " <>
        "recovery_hint=owner_exit_recovery"
    )

    :ok
  end

  defp owner_event(level, message, metadata) do
    log_line =
      metadata
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{safe_log_value(value)}" end)

    Logger.log(level, message <> " " <> log_line)
  end

  defp downstream_epoch(%{epoch: epoch}) when is_integer(epoch), do: epoch
  defp downstream_epoch(_downstream), do: nil

  defp safe_log_value(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_log_value(value) when is_integer(value), do: Integer.to_string(value)
  defp safe_log_value(value) when is_pid(value), do: inspect(value)

  defp safe_log_value(value) when is_binary(value) do
    value
    |> String.replace(~r/[^a-zA-Z0-9_.:-]+/, "_")
    |> String.slice(0, 120)
    |> case do
      "" -> "unknown"
      sanitized -> sanitized
    end
  end

  defp safe_log_value(_value), do: "unknown"
end
