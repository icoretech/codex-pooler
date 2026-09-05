defmodule CodexPooler.Accounting.RequestClientRetryLink do
  @moduledoc false
  use CodexPooler.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "request_client_retry_links" do
    field :predecessor_request_id, :binary_id
    field :successor_request_id, :binary_id
    field :created_at, :utc_datetime_usec
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(link, attrs) do
    changeset = cast(link, attrs, [:predecessor_request_id, :successor_request_id, :created_at])

    changeset
    |> validate_required([:predecessor_request_id, :successor_request_id, :created_at])
    |> validate_distinct_requests()
    |> unique_constraint(:predecessor_request_id,
      name: :request_client_retry_links_predecessor_request_id_uq
    )
    |> unique_constraint(:successor_request_id,
      name: :request_client_retry_links_successor_request_id_uq
    )
    |> foreign_key_constraint(:predecessor_request_id,
      name: :request_client_retry_links_predecessor_request_id_fkey
    )
    |> foreign_key_constraint(:successor_request_id,
      name: :request_client_retry_links_successor_request_id_fkey
    )
    |> check_constraint(:successor_request_id,
      name: :request_client_retry_links_distinct_requests_check
    )
  end

  defp validate_distinct_requests(changeset) do
    if get_field(changeset, :predecessor_request_id) ==
         get_field(changeset, :successor_request_id) do
      add_error(changeset, :successor_request_id, "must differ from predecessor request")
    else
      changeset
    end
  end
end
