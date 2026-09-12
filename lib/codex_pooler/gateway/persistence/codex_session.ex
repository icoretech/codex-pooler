defmodule CodexPooler.Gateway.Persistence.CodexSession do
  @moduledoc false
  use CodexPooler.Schema

  alias CodexPooler.Gateway.Persistence.StatusVocabulary.Session, as: SessionStatus

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
    field :owner_instance_boot_id, :string
    field :owner_lease_token, :binary_id
    field :owner_lease_expires_at, :utc_datetime_usec
    field :last_heartbeat_at, :utc_datetime_usec
    field :disconnected_at, :utc_datetime_usec
    field :closed_at, :utc_datetime_usec
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec

    # Soft routing preference carried only by the struct returned from the
    # recreation that computed it: the assignment of the session that was just
    # closed for this same (pool, api key, session key) because its owner lease
    # had expired. It is deliberately virtual. Nothing is persisted, so a later
    # request that loads this row reads nil, which is what keeps the preference
    # a one-shot hint for the recreating request instead of durable state.
    #
    # It is never written to `pool_upstream_assignment_id`: that column is the
    # durable pin that routing may filter on, and binding it before dispatch
    # would turn a preference into a filter.
    field :recreated_from_assignment_id, :binary_id, virtual: true
  end

  @spec statuses() :: [status()]
  defdelegate statuses(), to: SessionStatus

  @spec active_status() :: status()
  defdelegate active_status(), to: SessionStatus

  @spec interrupted_status() :: status()
  defdelegate interrupted_status(), to: SessionStatus

  @spec closed_status() :: status()
  defdelegate closed_status(), to: SessionStatus

  @spec reconnectable_statuses() :: [status()]
  defdelegate reconnectable_statuses(), to: SessionStatus

  @spec reconnectable?(t() | status() | nil) :: boolean()
  def reconnectable?(%__MODULE__{status: status}), do: reconnectable?(status)
  def reconnectable?(status), do: status in reconnectable_statuses()
end
