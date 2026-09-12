defmodule CodexPooler.Platform.InstancePresence.Instance do
  @moduledoc """
  Presence row for one running VM.

  The row carries the instance identity — node name, boot id, and the composite
  key the two form — and when that VM started and last reported, nothing else.
  It is shared-state bookkeeping for recovery, not a runtime control.

  `node_name` and `boot_id` are null on rows written before incarnations
  existed. Such a row names no incarnation, so nothing joins it and it ages out
  through ordinary retention.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:instance_id, :string, autogenerate: false}

  schema "instance_presences" do
    field :node_name, :string
    field :boot_id, :string
    field :started_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end
end
