defmodule CodexPooler.Status.Events do
  @moduledoc "Strict, metadata-only OpenAI status invalidation events."

  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL
  alias Phoenix.PubSub

  @topic "openai_status:global"
  @postgres_channel "codex_pooler_openai_status"
  @version 1
  @fields [:event_version, :changed_count, :active_count, :aggregate_revision, :emitted_at]

  @type t :: %{
          event_version: 1,
          changed_count: non_neg_integer(),
          active_count: non_neg_integer(),
          aggregate_revision: non_neg_integer(),
          emitted_at: DateTime.t()
        }

  @spec topic() :: String.t()
  def topic, do: @topic

  @spec postgres_channel() :: String.t()
  def postgres_channel, do: @postgres_channel

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: PubSub.subscribe(CodexPooler.PubSub, @topic)

  @spec broadcast(map()) :: :ok | {:error, term()}
  def broadcast(attrs) when is_map(attrs) do
    case decode(attrs) do
      {:ok, event} ->
        # PostgreSQL NOTIFY is transactional: when this function is called
        # inside a Repo.transaction/1, the notification is delivered only
        # after commit and disappears on rollback. The supervised bridge
        # fans it out through local PubSub on every node.
        with {:ok, payload} <- encode(event),
             {:ok, _result} <-
               SQL.query(Repo, "SELECT pg_notify($1, $2)", [@postgres_channel, payload]) do
          :ok
        else
          {:error, reason} -> {:error, reason}
        end

      :ignore ->
        {:error, :invalid_event}
    end
  end

  @spec relay_payload(String.t()) :: :ok | {:error, term()}
  def relay_payload(payload) when is_binary(payload) do
    with {:ok, attrs} <- CodexPooler.JSON.decode(payload),
         {:ok, event} <- decode(attrs),
         :ok <- PubSub.broadcast(CodexPooler.PubSub, @topic, {:openai_status_updated, event}) do
      :ok
    else
      {:error, _reason} -> {:error, :invalid_event}
      :ignore -> {:error, :invalid_event}
    end
  end

  def relay_payload(_payload), do: {:error, :invalid_event}

  @spec decode(term()) :: {:ok, t()} | :ignore
  def decode(%{event_version: @version} = event), do: decode_fields(event)
  def decode(%{"event_version" => @version} = event), do: decode_fields(event)
  def decode(_), do: :ignore

  defp decode_fields(event) do
    with :ok <- validate_keys(event),
         {:ok, changed_count} <- non_negative(event, :changed_count),
         {:ok, active_count} <- non_negative(event, :active_count),
         {:ok, aggregate_revision} <- non_negative(event, :aggregate_revision),
         {:ok, emitted_at} <- emitted_at(event) do
      {:ok,
       %{
         event_version: @version,
         changed_count: changed_count,
         active_count: active_count,
         aggregate_revision: aggregate_revision,
         emitted_at: emitted_at
       }}
    else
      _ -> :ignore
    end
  end

  defp validate_keys(event) do
    keys = Map.keys(event)
    expected = @fields

    if Enum.sort(keys) == Enum.sort(expected) or
         Enum.sort(keys) == Enum.sort(Enum.map(expected, &Atom.to_string/1)) do
      :ok
    else
      :error
    end
  end

  defp non_negative(event, key) do
    value = Map.get(event, key, Map.get(event, Atom.to_string(key)))
    if is_integer(value) and value >= 0, do: {:ok, value}, else: :error
  end

  defp emitted_at(event) do
    value = Map.get(event, :emitted_at, Map.get(event, "emitted_at"))

    cond do
      match?(%DateTime{}, value) ->
        normalize_datetime(DateTime.to_iso8601(value) |> DateTime.from_iso8601())

      is_binary(value) and byte_size(value) <= 64 ->
        DateTime.from_iso8601(value) |> normalize_datetime()

      true ->
        :error
    end
  end

  defp normalize_datetime({:ok, datetime, 0}),
    do: {:ok, DateTime.truncate(datetime, :microsecond)}

  defp normalize_datetime(_), do: :error

  defp encode(event) do
    with {:ok, payload} <-
           event
           |> Map.update!(:emitted_at, &DateTime.to_iso8601/1)
           |> CodexPooler.JSON.encode(),
         true <- byte_size(payload) <= 1_024 do
      {:ok, payload}
    else
      false -> {:error, :event_too_large}
      {:error, reason} -> {:error, reason}
    end
  end
end
