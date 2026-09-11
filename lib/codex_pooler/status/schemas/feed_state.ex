defmodule CodexPooler.Status.Schemas.FeedState do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:singleton, :boolean, autogenerate: false}
  @type t :: %__MODULE__{}

  schema "openai_status_feed_states" do
    field :etag, :string
    field :last_modified, :string
    field :last_success_at, :utc_datetime_usec
    field :last_attempt_at, :utc_datetime_usec
    field :last_error_code, :string
    field :last_error_at, :utc_datetime_usec
    field :active_count, :integer, default: 0
    field :aggregate_revision, :integer, default: 0
    field :cap_pressure, :string, default: "none"
    field :content_hash, :string
    field :updated_at, :utc_datetime_usec
  end

  def changeset(state, attrs) do
    state
    |> cast(attrs, __schema__(:fields))
    |> validate_required([:singleton, :active_count, :aggregate_revision, :updated_at])
    |> validate_number(:active_count, greater_than_or_equal_to: 0)
    |> validate_number(:aggregate_revision, greater_than_or_equal_to: 0)
    |> validate_inclusion(:cap_pressure, ~w(none active_over_cap terminal_exhausted))
    |> validate_length(:etag, max: 512)
    |> validate_length(:last_modified, max: 128)
    |> validate_length(:last_error_code, max: 80)
    |> validate_length(:content_hash, max: 128)
    |> check_constraint(:singleton, name: :openai_status_feed_states_singleton_check)
  end
end
