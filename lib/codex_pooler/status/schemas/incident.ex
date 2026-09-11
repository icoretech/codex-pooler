defmodule CodexPooler.Status.Schemas.Incident do
  @moduledoc false
  use CodexPooler.Schema
  import Ecto.Changeset

  @statuses ~w(Investigating Identified Monitoring Resolved Unknown)
  @type t :: %__MODULE__{}

  schema "openai_status_incidents" do
    field :guid, :string
    field :title, :string
    field :status, :string
    field :summary, :string, default: ""
    field :component, :string
    field :link, :string
    field :published_at, :utc_datetime_usec
    field :first_seen_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec
    field :resolved_at, :utc_datetime_usec
    field :retired_at, :utc_datetime_usec
    field :omission_count, :integer, default: 0
    field :revision, :integer, default: 1
    field :content_hash, :string
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end

  def changeset(incident, attrs) do
    incident
    |> cast(attrs, __schema__(:fields))
    |> update_change(:guid, &String.trim/1)
    |> update_change(:title, &String.trim/1)
    |> update_change(:status, &String.trim/1)
    |> validate_required([
      :guid,
      :title,
      :status,
      :link,
      :published_at,
      :first_seen_at,
      :last_seen_at,
      :omission_count,
      :revision,
      :content_hash,
      :created_at,
      :updated_at
    ])
    |> validate_length(:guid, min: 1, max: 512)
    |> validate_length(:title, min: 1, max: 4_000)
    |> validate_length(:status, min: 1, max: 32)
    |> validate_length(:summary, max: 4_000)
    |> validate_length(:component, max: 512)
    |> validate_length(:link, min: 1, max: 2_048)
    |> validate_length(:content_hash, min: 1, max: 128)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:omission_count, greater_than_or_equal_to: 0, less_than_or_equal_to: 3)
    |> validate_number(:revision, greater_than_or_equal_to: 1)
    |> unique_constraint(:guid, name: :openai_status_incidents_guid_uq)
  end
end
