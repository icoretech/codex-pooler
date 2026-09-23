defmodule CodexPooler.Catalog.SyncRun do
  @moduledoc false
  use CodexPooler.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @type attrs :: map()

  @trigger_kinds ~w(manual scheduled bootstrap reconcile)
  @statuses ~w(pending running succeeded failed cancelled)

  schema "sync_runs" do
    field :pool_id, :binary_id
    field :trigger_kind, :string
    field :status, :string
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :discovered_model_count, :integer
    field :upserted_model_count, :integer
    field :stale_marked_count, :integer
    # `sync_runs.retired_count` (`DEFAULT 0 NOT NULL`) stays in the table for
    # good: the sync never retires a model (a dropped model stays `stale`), and
    # older releases still select and insert the column during an upgrade.
    field :error_message, :string
    field :stats, :map
  end

  @spec changeset(t() | Ecto.Changeset.t(), attrs()) :: Ecto.Changeset.t()
  def changeset(sync_run, attrs) do
    sync_run
    |> cast(attrs, [
      :pool_id,
      :trigger_kind,
      :status,
      :started_at,
      :finished_at,
      :discovered_model_count,
      :upserted_model_count,
      :stale_marked_count,
      :error_message,
      :stats
    ])
    |> validate_required([
      :pool_id,
      :trigger_kind,
      :status,
      :started_at,
      :discovered_model_count,
      :upserted_model_count,
      :stale_marked_count,
      :stats
    ])
    |> validate_inclusion(:trigger_kind, @trigger_kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:discovered_model_count, greater_than_or_equal_to: 0)
    |> validate_number(:upserted_model_count, greater_than_or_equal_to: 0)
    |> validate_number(:stale_marked_count, greater_than_or_equal_to: 0)
  end
end
