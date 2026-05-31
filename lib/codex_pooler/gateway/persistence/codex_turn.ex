defmodule CodexPooler.Gateway.Persistence.CodexTurn do
  @moduledoc false
  use CodexPooler.Schema

  @statuses ~w(in_progress succeeded failed interrupted)

  @type t :: %__MODULE__{}
  @type status :: String.t()

  schema "codex_turns" do
    field :codex_session_id, :binary_id
    field :request_id, :binary_id
    field :turn_sequence, :integer
    field :transport_kind, :string
    field :status, :string
    field :error_code, :string
    field :first_visible_output_at, :utc_datetime_usec
    field :final_attempt_id, :binary_id
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end

  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @spec in_progress_status() :: status()
  def in_progress_status, do: "in_progress"

  @spec succeeded_status() :: status()
  def succeeded_status, do: "succeeded"

  @spec failed_status() :: status()
  def failed_status, do: "failed"

  @spec interrupted_status() :: status()
  def interrupted_status, do: "interrupted"

  @spec in_progress?(t() | status() | nil) :: boolean()
  def in_progress?(%__MODULE__{status: status}), do: in_progress?(status)
  def in_progress?(status), do: status == in_progress_status()
end
