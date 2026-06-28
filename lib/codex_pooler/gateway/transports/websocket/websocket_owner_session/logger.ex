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

  @spec owner_terminated(term(), atom(), map()) :: :ok
  def owner_terminated(reason, owner_exit_reason, state) do
    owner_event(:info, "websocket owner terminated",
      codex_session_id: state.codex_session_id,
      owner_instance_id: state.owner_instance_id,
      owner_pid: self(),
      reason: Metadata.safe_reason(reason),
      owner_exit_reason: owner_exit_reason,
      request_id: state.request_id,
      downstream_epoch: downstream_epoch(state.downstream)
    )
  end

  @spec owner_exit_persistence_failure(atom(), map(), atom(), term()) :: :ok
  def owner_exit_persistence_failure(operation, state, owner_exit_reason, reason) do
    Logger.warning(
      "websocket owner exit persistence failed " <>
        "codex_session_id=#{safe_log_value(state.codex_session_id)} " <>
        "operation=#{operation} " <>
        "reason_class=#{safe_log_value(Metadata.safe_reason(reason))} " <>
        "owner_exit_reason=#{owner_exit_reason} " <>
        "recovery_hint=task_7_owner_exit_recovery"
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
