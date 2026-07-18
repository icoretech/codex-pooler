defmodule CodexPooler.Access.DashboardSessions.Principal do
  @moduledoc """
  Canonical API-key dashboard authority with an explicit safe display projection.

  The principal never carries the submitted API key, browser-session token, or
  an operator account scope.
  """

  @enforce_keys [:api_key_id, :pool_id, :display_name, :key_prefix]
  defstruct [:api_key_id, :pool_id, :display_name, :key_prefix]

  @type t :: %__MODULE__{
          api_key_id: Ecto.UUID.t(),
          pool_id: Ecto.UUID.t(),
          display_name: String.t(),
          key_prefix: String.t()
        }

  @spec new(%{
          required(:api_key_id) => Ecto.UUID.t(),
          required(:pool_id) => Ecto.UUID.t(),
          required(:display_name) => String.t(),
          required(:key_prefix) => String.t()
        }) :: t()
  def new(%{
        api_key_id: api_key_id,
        pool_id: pool_id,
        display_name: display_name,
        key_prefix: key_prefix
      }) do
    %__MODULE__{
      api_key_id: api_key_id,
      pool_id: pool_id,
      display_name: display_name,
      key_prefix: key_prefix
    }
  end
end
