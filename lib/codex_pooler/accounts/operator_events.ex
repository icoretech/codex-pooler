defmodule CodexPooler.Accounts.OperatorEvents do
  @moduledoc false

  alias Phoenix.PubSub

  @pubsub CodexPooler.PubSub
  @message_tag __MODULE__
  @topic "accounts:operators"

  @type event :: %{
          required(:reason) => String.t(),
          required(:payload) => map(),
          required(:emitted_at) => DateTime.t()
        }

  @spec subscribe_updates() :: :ok | {:error, term()}
  def subscribe_updates, do: PubSub.subscribe(@pubsub, @topic)

  @spec broadcast_update(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_update(reason, payload \\ %{}) when is_binary(reason) and is_map(payload) do
    event = %{
      reason: reason,
      payload: Map.new(payload, fn {key, value} -> {to_string(key), value} end),
      emitted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }

    PubSub.broadcast_from(@pubsub, self(), @topic, {@message_tag, event})
  end
end
