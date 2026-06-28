defmodule CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession.Persistence do
  @moduledoc false

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Runtime.Finalization.Interruption
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession.Logger, as: OwnerLogger

  @spec renew_owner_lease(map()) :: {:ok, map()} | {:error, term()}
  def renew_owner_lease(state) do
    opts = RequestOptions.for_websocket(%{})

    case state.persistence.renew_owner_token.(
           state.codex_session_id,
           state.owner_lease_token,
           opts
         ) do
      {:ok, %{owner_lease_token: owner_lease_token, owner_instance_id: owner_instance_id}} ->
        {:ok,
         %{state | owner_lease_token: owner_lease_token, owner_instance_id: owner_instance_id}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    exception -> {:error, exception}
  catch
    _kind, reason -> {:error, reason}
  end

  @spec release_owner_lease(map(), atom()) :: :ok
  def release_owner_lease(state, reason) do
    safe_persist_owner_exit(:release_owner_lease, state, reason, fn ->
      if reason == :stale_owner or not uuid?(state.codex_session_id) do
        :ok
      else
        state.persistence.release_owner_lease.(
          state.codex_session_id,
          state.owner_lease_token,
          Atom.to_string(reason)
        )
      end
    end)
  end

  @spec interrupt_codex_session(map(), atom()) :: :ok
  def interrupt_codex_session(state, reason) do
    safe_persist_owner_exit(:interrupt_codex_session, state, reason, fn ->
      if reason == :stale_owner or not uuid?(state.codex_session_id) do
        :ok
      else
        opts = interrupt_options(reason)
        state.persistence.interrupt_codex_session.(state.codex_session_id, opts)
      end
    end)
  end

  @spec recover_owner_lifecycle_leftovers(map(), atom()) :: :ok
  def recover_owner_lifecycle_leftovers(state, owner_exit_reason) do
    if uuid?(state.codex_session_id) do
      _result =
        Interruption.recover_owner_lifecycle_leftovers(
          state.codex_session_id,
          owner_exit_reason,
          interrupt_options(owner_exit_reason)
        )

      :ok
    else
      :ok
    end
  end

  defp safe_persist_owner_exit(operation, state, owner_exit_reason, fun) do
    case fun.() do
      {:error, reason} ->
        OwnerLogger.owner_exit_persistence_failure(operation, state, owner_exit_reason, reason)
        recover_owner_lifecycle_leftovers(state, owner_exit_reason)
        :ok

      _result ->
        :ok
    end
  rescue
    exception ->
      OwnerLogger.owner_exit_persistence_failure(operation, state, owner_exit_reason, exception)
      recover_owner_lifecycle_leftovers(state, owner_exit_reason)
      :ok
  catch
    _kind, reason ->
      OwnerLogger.owner_exit_persistence_failure(operation, state, owner_exit_reason, reason)
      recover_owner_lifecycle_leftovers(state, owner_exit_reason)
      :ok
  end

  defp interrupt_options(reason) do
    %{
      interrupt_reason: Atom.to_string(reason),
      reconnect_window_seconds: 300
    }
    |> RequestOptions.for_websocket()
  end

  defp uuid?(value) when is_binary(value) do
    String.match?(
      value,
      ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/
    )
  end

  defp uuid?(_value), do: false
end
