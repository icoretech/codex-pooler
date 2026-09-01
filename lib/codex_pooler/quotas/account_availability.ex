defmodule CodexPooler.Quotas.AccountAvailability do
  @moduledoc """
  Semantic account-availability observation parsed from a provider usage payload.

  This value deliberately carries no provider payload fields. `basis` and
  `account_windows` are transient parser facts; persistence stores only `state`.
  """

  @enforce_keys [:state, :basis, :account_windows]
  defstruct [:state, :basis, :account_windows]

  @states [:available, :blocked, :unknown]
  @bases [:affirmative, :blocker, :conflict, :no_proof]
  @account_window_states [:present, :absent, :unknown]

  @type state :: :available | :blocked | :unknown
  @type basis :: :affirmative | :blocker | :conflict | :no_proof
  @type account_windows :: :present | :absent | :unknown
  @type t :: %__MODULE__{
          state: state(),
          basis: basis(),
          account_windows: account_windows()
        }

  @spec new(state(), basis(), account_windows()) :: {:ok, t()} | {:error, :invalid_observation}
  def new(state, basis, account_windows)
      when state in @states and basis in @bases and account_windows in @account_window_states do
    if consistent?(state, basis) do
      {:ok, %__MODULE__{state: state, basis: basis, account_windows: account_windows}}
    else
      {:error, :invalid_observation}
    end
  end

  def new(_state, _basis, _account_windows), do: {:error, :invalid_observation}

  @spec new!(state(), basis(), account_windows()) :: t()
  def new!(state, basis, account_windows) do
    case new(state, basis, account_windows) do
      {:ok, observation} ->
        observation

      {:error, :invalid_observation} ->
        raise ArgumentError, "invalid account availability observation"
    end
  end

  defp consistent?(:available, :affirmative), do: true
  defp consistent?(:blocked, :blocker), do: true
  defp consistent?(:unknown, basis) when basis in [:conflict, :no_proof], do: true
  defp consistent?(_state, _basis), do: false
end
