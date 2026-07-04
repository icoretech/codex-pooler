defmodule CodexPooler.Accounts.SessionNotifier do
  @moduledoc """
  Core account-session notification topics shared by web and account contexts.
  """

  @spec disconnect_user_sessions(Ecto.UUID.t(), keyword()) :: :ok | {:error, term()}
  def disconnect_user_sessions(user_id, opts \\ []) when is_binary(user_id) do
    Phoenix.PubSub.broadcast(
      CodexPooler.PubSub,
      user_sessions_topic(user_id),
      {:disconnect_user_sessions,
       %{user_id: user_id, except_live_socket_id: Keyword.get(opts, :except_live_socket_id)}}
    )
  end

  @spec disconnect_user_session(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok | {:error, term()}
  def disconnect_user_session(user_id, session_id)
      when is_binary(user_id) and is_binary(session_id) do
    Phoenix.PubSub.broadcast(
      CodexPooler.PubSub,
      user_sessions_topic(user_id),
      {:disconnect_user_sessions, %{user_id: user_id, session_id: session_id}}
    )
  end

  @spec user_sessions_topic(Ecto.UUID.t()) :: String.t()
  def user_sessions_topic(user_id) when is_binary(user_id), do: "users:#{user_id}:sessions"

  @spec live_socket_id_for_token(binary()) :: String.t()
  def live_socket_id_for_token(token) when is_binary(token), do: user_session_topic(token)

  @spec user_session_topic(binary()) :: String.t()
  def user_session_topic(token) when is_binary(token) do
    "users_sessions:#{Base.url_encode64(token)}"
  end
end
