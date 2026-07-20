defmodule CodexPooler.Pools.ModelServingOverride do
  @moduledoc false
  use CodexPooler.Schema

  import Ecto.Changeset

  @modes ~w(lite full)
  @max_exposed_model_id_length 255

  @type t :: %__MODULE__{}
  @type attrs :: map()

  schema "pool_model_serving_overrides" do
    field :pool_id, :binary_id
    field :exposed_model_id, :string
    field :mode, :string
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end

  @spec modes() :: [String.t()]
  def modes, do: @modes

  @spec canonical_exposed_model_id(term()) :: String.t() | nil
  def canonical_exposed_model_id(value) when is_binary(value) do
    canonical = value |> String.trim() |> String.downcase()

    if canonical != "" and
         length(String.codepoints(canonical)) <= @max_exposed_model_id_length do
      canonical
    end
  end

  def canonical_exposed_model_id(_value), do: nil

  @spec changeset(t() | Ecto.Changeset.t(), attrs()) :: Ecto.Changeset.t()
  def changeset(override, attrs) do
    override
    |> cast(attrs, [:exposed_model_id, :mode])
    |> update_change(:exposed_model_id, &canonical_exposed_model_id/1)
    |> update_change(:mode, &normalize_mode/1)
    |> validate_required([:pool_id, :exposed_model_id, :mode, :created_at, :updated_at])
    |> validate_length(:exposed_model_id, count: :codepoints, max: @max_exposed_model_id_length)
    |> validate_inclusion(:mode, @modes)
    |> check_constraint(:exposed_model_id,
      name: :pool_model_serving_overrides_exposed_model_id_check
    )
    |> check_constraint(:mode, name: :pool_model_serving_overrides_mode_check)
    |> foreign_key_constraint(:pool_id)
    |> unique_constraint(:exposed_model_id,
      name: :pool_model_serving_overrides_pool_model_uq
    )
  end

  defp normalize_mode(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_mode(value), do: value
end
