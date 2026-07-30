defmodule CodexPooler.Alerts.StatusVocabulary.Channel do
  @moduledoc false

  @channel_types ~w(email webhook)
  @states ~w(active disabled)
  @endpoint_schemes ~w(https)

  @type channel_type :: String.t()
  @type state :: String.t()
  @type endpoint_scheme :: String.t()

  @spec channel_types() :: [channel_type()]
  def channel_types, do: @channel_types

  @spec states() :: [state()]
  def states, do: @states

  @spec endpoint_schemes() :: [endpoint_scheme()]
  def endpoint_schemes, do: @endpoint_schemes

  @spec active_state() :: state()
  def active_state, do: "active"

  @spec disabled_state() :: state()
  def disabled_state, do: "disabled"
end
