defmodule CodexPooler.Events.PostgresBridge do
  @moduledoc false

  use GenServer

  alias CodexPooler.Events
  alias CodexPooler.Events.Event
  alias CodexPooler.Status.Events, as: StatusEvents

  require Logger

  @notifications CodexPooler.Events.PostgresNotifications
  @relisten_initial_interval_ms 100
  @relisten_max_interval_ms 5_000

  @type state :: %{
          required(:notifications) => GenServer.server(),
          required(:listen_ref) => reference() | nil,
          required(:status_listen_ref) => reference() | nil,
          required(:notifications_monitor) => reference() | nil,
          required(:relisten_token) => reference() | nil,
          required(:relisten_attempt) => non_neg_integer()
        }

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(opts) do
    opts = if Keyword.keyword?(opts), do: opts, else: []
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec relay_payload(String.t()) :: :ok | {:error, term()}
  def relay_payload(payload) when is_binary(payload) do
    with {:ok, event} <- decode_event(payload) do
      Events.broadcast_local_event(event)
    end
  end

  @impl true
  def init(opts) do
    state = %{
      notifications: Keyword.get(opts, :notifications, @notifications),
      listen_ref: nil,
      status_listen_ref: nil,
      notifications_monitor: nil,
      relisten_token: nil,
      relisten_attempt: 0
    }

    {:ok, listen(state)}
  end

  @impl true
  def handle_info(
        {:notification, _pid, listen_ref, channel, payload},
        %{listen_ref: listen_ref} = state
      ) do
    case relay_remote_notification(channel, payload) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("pool event postgres relay ignored payload: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  def handle_info(
        {:notification, _pid, listen_ref, channel, payload},
        %{status_listen_ref: listen_ref} = state
      ) do
    if channel == StatusEvents.postgres_channel() do
      case StatusEvents.relay_payload(payload) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("status postgres relay ignored payload: #{inspect(reason)}")
      end
    end

    {:noreply, state}
  end

  # The notifications process sent every notification it relayed before it
  # exited, so they are already handled by the clauses above when this arrives.
  # Its supervisor restarts it under the same name with no listeners, and
  # nothing tells a listener, so the bridge listens again itself; a restarted
  # process that is not registered yet is retried with a capped backoff.
  def handle_info({:DOWN, monitor_ref, :process, _pid, reason}, %{notifications_monitor: monitor_ref} = state) do
    Logger.warning("postgres event relay lost its notifications listener; listening again reason=#{exit_reason_label(reason)}")

    {:noreply, relisten(%{state | listen_ref: nil, status_listen_ref: nil, notifications_monitor: nil})}
  end

  def handle_info({__MODULE__, :relisten, token}, %{relisten_token: token, notifications_monitor: nil} = state) do
    {:noreply, relisten(%{state | relisten_token: nil})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp relay_remote_notification(channel, payload) do
    if channel == Events.postgres_channel() do
      relay_remote_payload(payload)
    else
      :ok
    end
  end

  defp relay_remote_payload(payload) do
    case local_origin?(payload) do
      {:ok, false} -> relay_payload(payload)
      {:ok, true} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp local_origin?(payload) do
    with {:ok, attrs} <- CodexPooler.JSON.decode(payload) do
      {:ok, attrs["origin_id"] == Events.origin_id()}
    end
  end

  defp decode_event(payload) do
    with {:ok, attrs} <- CodexPooler.JSON.decode(payload),
         {:ok, emitted_at} <- decode_emitted_at(attrs["emitted_at"]),
         {:ok, topics} <- decode_topics(attrs["topics"]),
         {:ok, payload} <- decode_payload(attrs["payload"]),
         {:ok, version} <- decode_version(attrs["version"]),
         pool_id when is_binary(pool_id) <- attrs["pool_id"],
         id when is_binary(id) <- attrs["id"],
         reason when is_binary(reason) <- attrs["reason"] do
      {:ok,
       %Event{
         version: version,
         id: id,
         pool_id: pool_id,
         topics: topics,
         reason: reason,
         emitted_at: emitted_at,
         payload: payload
       }}
    else
      nil -> {:error, :invalid_event_payload}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_event_payload}
    end
  end

  defp decode_emitted_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> {:ok, timestamp}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_emitted_at(_value), do: {:error, :invalid_emitted_at}

  defp decode_topics(topics) do
    case Events.validate_topics(topics) do
      {:ok, _validated_topics} -> {:ok, topics}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_payload(payload) when is_map(payload), do: {:ok, payload}
  defp decode_payload(_payload), do: {:error, :invalid_payload}

  defp decode_version(version) when is_integer(version) and version > 0, do: {:ok, version}
  defp decode_version(_version), do: {:error, :invalid_version}

  defp relisten(state) do
    case listen(state) do
      %{notifications_monitor: monitor_ref} = listening when is_reference(monitor_ref) ->
        Logger.info("postgres event relay listening again retries=#{state.relisten_attempt}")
        listening

      waiting ->
        waiting
    end
  end

  # One registration per channel on the current notifications process: the
  # state keeps only the refs of the last successful listen, and a listen runs
  # only while none is held, so a relayed notification is never delivered twice.
  defp listen(%{notifications_monitor: nil} = state) do
    case GenServer.whereis(state.notifications) do
      pid when is_pid(pid) -> listen_on(state, pid)
      _unavailable -> schedule_relisten(state)
    end
  end

  defp listen_on(state, pid) do
    monitor_ref = Process.monitor(pid)

    with {:ok, listen_ref} <- listen_channel(pid, Events.postgres_channel()),
         {:ok, status_listen_ref} <- listen_channel(pid, StatusEvents.postgres_channel(), listen_ref) do
      %{
        state
        | listen_ref: listen_ref,
          status_listen_ref: status_listen_ref,
          notifications_monitor: monitor_ref,
          relisten_token: nil,
          relisten_attempt: 0
      }
    else
      :error ->
        Process.demonitor(monitor_ref, [:flush])
        schedule_relisten(state)
    end
  end

  defp listen_channel(pid, channel, previous_ref \\ nil) do
    case Postgrex.Notifications.listen(pid, channel) do
      {:ok, listen_ref} -> {:ok, listen_ref}
      {:eventually, listen_ref} -> {:ok, listen_ref}
    end
  catch
    :exit, _reason ->
      _ = unlisten(pid, previous_ref)
      :error
  end

  # A listen that failed after an earlier channel succeeded drops that
  # registration, so the retry does not leave a second one behind.
  defp unlisten(_pid, nil), do: :ok

  defp unlisten(pid, listen_ref) do
    Postgrex.Notifications.unlisten(pid, listen_ref)
  catch
    :exit, _reason -> :error
  end

  defp schedule_relisten(state) do
    attempt = state.relisten_attempt + 1
    delay_ms = min(@relisten_initial_interval_ms * Integer.pow(2, min(attempt - 1, 10)), @relisten_max_interval_ms)
    token = make_ref()
    Process.send_after(self(), {__MODULE__, :relisten, token}, delay_ms)
    %{state | relisten_token: token, relisten_attempt: attempt}
  end

  defp exit_reason_label(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp exit_reason_label({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp exit_reason_label(_reason), do: "other"
end
