defmodule CodexPooler.Gateway.Persistence.SessionContinuity.OwnerWitness do
  @moduledoc false

  alias CodexPooler.Gateway.Persistence.CodexSession

  @enforce_keys [:session_id, :lease_token]
  defstruct [:session_id, :lease_token]

  @type t :: %__MODULE__{
          session_id: Ecto.UUID.t(),
          lease_token: Ecto.UUID.t()
        }

  @spec new(CodexSession.t()) :: {:ok, t()} | {:error, :invalid_owner_witness}
  def new(%CodexSession{id: session_id, owner_lease_token: lease_token})
      when is_binary(session_id) and is_binary(lease_token) do
    with {:ok, session_id} <- Ecto.UUID.cast(session_id),
         {:ok, lease_token} <- Ecto.UUID.cast(lease_token) do
      {:ok, %__MODULE__{session_id: session_id, lease_token: lease_token}}
    else
      :error -> {:error, :invalid_owner_witness}
    end
  end

  def new(%CodexSession{}), do: {:error, :invalid_owner_witness}
end

defimpl Inspect,
  for: CodexPooler.Gateway.Persistence.SessionContinuity.OwnerWitness do
  import Inspect.Algebra

  def inspect(_witness, _opts), do: concat(["#OwnerWitness<redacted>"])
end
