defmodule CodexPooler.Gateway.Persistence.BridgeSessionAlias do
  @moduledoc false
  use CodexPooler.Schema

  import Ecto.Changeset

  alias CodexPooler.Gateway.Persistence.StatusVocabulary.SessionAlias,
    as: SessionAliasStatus

  @alias_kinds SessionAliasStatus.alias_kinds()
  @statuses SessionAliasStatus.statuses()

  @type t :: %__MODULE__{}
  @type attrs :: map()
  @type alias_kind :: String.t()
  @type status :: String.t()

  schema "bridge_session_aliases" do
    field :codex_session_id, :binary_id
    field :pool_id, :binary_id
    field :api_key_id, :binary_id
    field :alias_kind, :string
    field :alias_hash, :binary
    field :alias_preview, :string
    field :status, :string
    field :expires_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec
    field :metadata, :map
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end

  @spec changeset(t() | Ecto.Changeset.t(), attrs()) :: Ecto.Changeset.t()
  def changeset(alias_record, attrs) do
    alias_record
    |> cast(attrs, [
      :codex_session_id,
      :pool_id,
      :api_key_id,
      :alias_kind,
      :alias_hash,
      :alias_preview,
      :status,
      :expires_at,
      :last_seen_at,
      :metadata,
      :created_at,
      :updated_at
    ])
    |> validate_required([
      :codex_session_id,
      :pool_id,
      :api_key_id,
      :alias_kind,
      :alias_hash,
      :status,
      :expires_at,
      :metadata,
      :created_at,
      :updated_at
    ])
    |> validate_inclusion(:alias_kind, @alias_kinds)
    |> validate_inclusion(:status, @statuses)
  end

  @spec alias_kinds() :: [alias_kind()]
  defdelegate alias_kinds(), to: SessionAliasStatus

  @spec statuses() :: [status()]
  defdelegate statuses(), to: SessionAliasStatus

  @spec active_status() :: status()
  defdelegate active_status(), to: SessionAliasStatus

  @spec expired_status() :: status()
  defdelegate expired_status(), to: SessionAliasStatus

  @spec replaced_status() :: status()
  defdelegate replaced_status(), to: SessionAliasStatus
end
