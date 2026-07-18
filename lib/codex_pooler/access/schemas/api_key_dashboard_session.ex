defmodule CodexPooler.Access.APIKeyDashboardSession do
  @moduledoc false
  use CodexPooler.Schema

  import Ecto.Changeset

  @derive {Inspect, except: [:token_hash]}
  @token_hash_bytes 32

  @type attrs :: %{
          optional(:token_hash) => binary() | nil,
          optional(:expires_at) => DateTime.t() | nil
        }
  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          api_key_id: Ecto.UUID.t() | nil,
          token_hash: binary() | nil,
          expires_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  schema "api_key_dashboard_sessions" do
    belongs_to :api_key, CodexPooler.Access.APIKey
    field :token_hash, :binary
    field :expires_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @spec changeset(t() | Ecto.Changeset.t(), attrs()) :: Ecto.Changeset.t()
  def changeset(session, attrs) do
    session
    |> cast(attrs, [:token_hash, :expires_at])
    |> validate_required([:api_key_id, :token_hash, :expires_at])
    |> validate_change(:token_hash, &validate_token_hash/2)
    |> unique_constraint(:token_hash, name: :api_key_dashboard_sessions_token_hash_uq)
    |> foreign_key_constraint(:api_key_id,
      name: :api_key_dashboard_sessions_api_key_id_fkey
    )
    |> check_constraint(:token_hash,
      name: :api_key_dashboard_sessions_token_hash_shape_check
    )
  end

  defp validate_token_hash(:token_hash, token_hash)
       when is_binary(token_hash) and byte_size(token_hash) == @token_hash_bytes,
       do: []

  defp validate_token_hash(:token_hash, _token_hash),
    do: [token_hash: "must be a 32-byte digest"]
end
