defmodule CodexPooler.Gateway.Persistence.CodexSession do
  @moduledoc false
  use CodexPooler.Schema

  @statuses ~w(active interrupted closed)
  @reconnectable_statuses ~w(active interrupted)

  @type t :: %__MODULE__{}
  @type status :: String.t()

  schema "codex_sessions" do
    field :pool_id, :binary_id
    field :api_key_id, :binary_id
    field :session_key, :string
    field :conversation_key, :string
    field :pool_upstream_assignment_id, :binary_id
    field :status, :string
    field :owner_instance_id, :string
    field :owner_lease_token, :binary_id
    field :owner_lease_expires_at, :utc_datetime_usec
    field :last_heartbeat_at, :utc_datetime_usec
    field :disconnected_at, :utc_datetime_usec
    field :closed_at, :utc_datetime_usec
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end

  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @spec active_status() :: status()
  def active_status, do: "active"

  @spec interrupted_status() :: status()
  def interrupted_status, do: "interrupted"

  @spec closed_status() :: status()
  def closed_status, do: "closed"

  @spec reconnectable_statuses() :: [status()]
  def reconnectable_statuses, do: @reconnectable_statuses

  @spec reconnectable?(t() | status() | nil) :: boolean()
  def reconnectable?(%__MODULE__{status: status}), do: reconnectable?(status)
  def reconnectable?(status), do: status in reconnectable_statuses()
end
