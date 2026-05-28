defmodule CodexPooler.Events.PostgresBridge do
  @moduledoc false

  use GenServer

  alias CodexPooler.Events
  alias CodexPooler.Events.Event

  require Logger

  @notifications CodexPooler.Events.PostgresNotifications

  @type state :: %{required(:listen_ref) => reference() | nil}

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec relay_payload(String.t()) :: :ok | {:error, term()}
  def relay_payload(payload) when is_binary(payload) do
    with {:ok, event} <- decode_event(payload) do
      Events.broadcast_local_event(event)
    end
  end

  @impl true
  def init(_opts) do
    listen_ref =
      @notifications
      |> Postgrex.Notifications.listen(Events.postgres_channel())
      |> listen_ref!()

    {:ok, %{listen_ref: listen_ref}}
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
    with {:ok, attrs} <- Jason.decode(payload) do
      {:ok, attrs["origin_id"] == Events.origin_id()}
    end
  end

  defp decode_event(payload) do
    with {:ok, attrs} <- Jason.decode(payload),
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

  defp decode_topics([_ | _] = topics) do
    if Enum.all?(topics, &is_binary/1), do: {:ok, topics}, else: {:error, :invalid_topics}
  end

  defp decode_topics(_topics), do: {:error, :invalid_topics}

  defp decode_payload(payload) when is_map(payload), do: {:ok, payload}
  defp decode_payload(_payload), do: {:error, :invalid_payload}

  defp decode_version(version) when is_integer(version) and version > 0, do: {:ok, version}
  defp decode_version(_version), do: {:error, :invalid_version}

  defp listen_ref!({:ok, listen_ref}), do: listen_ref
  defp listen_ref!({:eventually, listen_ref}), do: listen_ref
end
