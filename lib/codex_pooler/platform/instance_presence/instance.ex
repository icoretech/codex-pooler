defmodule CodexPooler.Platform.InstancePresence.Instance do
  @moduledoc """
  Presence row for one running application instance.

  The row carries the instance identity and when it last reported, nothing
  else. It is shared-state bookkeeping for recovery, not a runtime control.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:instance_id, :string, autogenerate: false}

  schema "instance_presences" do
    field :started_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end
end
