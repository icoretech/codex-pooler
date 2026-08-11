defmodule CodexPooler.Gateway.Facade do
  @moduledoc """
  Fixed public and effective identities for facade gateway requests.
  """

  @public_model "gemma3"
  @effective_model "gpt-5.6-sol"
  @reasoning_effort "max"

  @spec public_model() :: String.t()
  def public_model, do: @public_model

  @spec effective_model() :: String.t()
  def effective_model, do: @effective_model

  @spec reasoning_effort() :: String.t()
  def reasoning_effort, do: @reasoning_effort
end
