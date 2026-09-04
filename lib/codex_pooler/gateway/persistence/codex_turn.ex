defmodule CodexPooler.Gateway.Persistence.CodexTurn do
  @moduledoc false
  use CodexPooler.Schema

  alias CodexPooler.Gateway.Persistence.StatusVocabulary.Turn, as: TurnStatus

  @type t :: %__MODULE__{}
  @type status :: String.t()

  schema "codex_turns" do
    field :codex_session_id, :binary_id
    field :request_id, :binary_id
    field :turn_sequence, :integer
    field :transport_kind, :string
    field :status, :string
    field :error_code, :string
    field :semantic_turn_digest, :binary
    field :first_visible_output_at, :utc_datetime_usec
    field :final_attempt_id, :binary_id
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end

  @spec statuses() :: [status()]
  defdelegate statuses(), to: TurnStatus

  @spec in_progress_status() :: status()
  defdelegate in_progress_status(), to: TurnStatus

  @spec succeeded_status() :: status()
  defdelegate succeeded_status(), to: TurnStatus

  @spec failed_status() :: status()
  defdelegate failed_status(), to: TurnStatus

  @spec interrupted_status() :: status()
  defdelegate interrupted_status(), to: TurnStatus

  @spec in_progress?(t() | status() | nil) :: boolean()
  def in_progress?(%__MODULE__{status: status}), do: in_progress?(status)
  def in_progress?(status), do: status == in_progress_status()
end
