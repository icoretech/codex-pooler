defmodule CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession.Persistence do
  @moduledoc false

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.SessionContinuity
  alias CodexPooler.Gateway.Runtime.Finalization.Interruption
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession.Logger, as: OwnerLogger
  alias CodexPooler.Gateway.Websocket.OwnerCleanup

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

  @spec release_owner_lease(map(), atom(), :idle_expiry | :drain_cut | nil) :: :ok
  def release_owner_lease(state, reason, owner_exit_cause) do
    safe_persist_owner_exit(:release_owner_lease, state, reason, fn ->
      if reason == :stale_owner or not uuid?(state.codex_session_id) do
        :ok
      else
        release_current_owner_lease(state, reason, owner_exit_cause)
      end
    end)
  end

  defp release_current_owner_lease(state, reason, cause) do
    state = OwnerCleanup.resolve_owner_state(state)

    if state.persistence.release_owner_lease in [
         &SessionContinuity.release_owner_lease/3,
         &SessionContinuity.release_owner_lease/4
       ] do
      Interruption.release_owner_cleanup_lease(state, Atom.to_string(reason), cause)
    else
      release_owner_lease(
        state.persistence.release_owner_lease,
        state.codex_session_id,
        state.owner_lease_token,
        Atom.to_string(reason),
        cause
      )
    end
  end

  @spec interrupt_codex_session(map(), atom()) :: :ok | {:error, term()}
  def interrupt_codex_session(state, reason) do
    state = OwnerCleanup.resolve_owner_state(state)

    if reason == :stale_owner or not uuid?(state.codex_session_id) do
      :ok
    else
      if is_nil(Map.get(state, :active_turn)) and is_nil(Map.get(state, :suspended_replay)) and
           is_nil(Map.get(state, :termination_cleanup_witness)) do
        :ok
      else
        persist_session_interruption(state, reason)
      end
    end
  rescue
    exception -> persist_interruption_failure(state, reason, exception)
  catch
    _kind, failure -> persist_interruption_failure(state, reason, failure)
  end

  defp persist_session_interruption(state, reason) do
    opts = interrupt_options(reason, state)

    case state.persistence.interrupt_codex_session.(state.codex_session_id, opts) do
      {:error, failure} -> persist_interruption_failure(state, reason, failure)
      _result -> :ok
    end
  end

  defp persist_interruption_failure(state, reason, failure) do
    OwnerLogger.owner_exit_persistence_failure(
      :interrupt_codex_session,
      state,
      reason,
      failure
    )

    {:error, failure}
  end

  @spec recover_owner_lifecycle_leftovers(map(), atom()) :: :ok
  def recover_owner_lifecycle_leftovers(state, owner_exit_reason) do
    if uuid?(state.codex_session_id) do
      _result =
        Interruption.recover_owner_lifecycle_leftovers(
          state.codex_session_id,
          owner_exit_reason,
          interrupt_options(owner_exit_reason, state)
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

  defp interrupt_options(reason, state) do
    %{
      interrupt_reason: Atom.to_string(reason),
      reconnect_window_seconds: 300,
      websocket_owner_lease_token: state.owner_lease_token
    }
    |> RequestOptions.for_websocket()
    |> OwnerCleanup.put_options(OwnerCleanup.from_owner_state(state))
  end

  defp release_owner_lease(
         release_owner_lease,
         session_id,
         owner_lease_token,
         reason,
         owner_exit_cause
       )
       when is_function(release_owner_lease, 4) do
    release_owner_lease.(session_id, owner_lease_token, reason, owner_exit_cause)
  end

  defp release_owner_lease(
         release_owner_lease,
         session_id,
         owner_lease_token,
         reason,
         _owner_exit_cause
       )
       when is_function(release_owner_lease, 3) do
    release_owner_lease.(session_id, owner_lease_token, reason)
  end

  defp uuid?(value) when is_binary(value) do
    String.match?(
      value,
      ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/
    )
  end

  defp uuid?(_value), do: false
end
