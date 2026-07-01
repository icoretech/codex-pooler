defmodule CodexPooler.Access.APIKey do
  @moduledoc false
  use CodexPooler.Schema

  import Ecto.Changeset

  @derive {Inspect, except: [:key_hash]}
  @reasoning_efforts ~w(none minimal low medium high xhigh max ultra)
  @service_tiers ~w(auto default flex priority scale)

  @type t :: %__MODULE__{}
  @type attrs :: map()

  schema "api_keys" do
    field :pool_id, :binary_id
    field :display_name, :string
    field :key_prefix, :string
    field :key_hash, :binary
    field :status, :string
    field :expires_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec
    field :allowed_model_identifiers, {:array, :string}
    field :enforced_model_identifier, :string
    field :enforced_reasoning_effort, :string
    field :enforced_service_tier, :string
    field :metadata, :map, default: %{}
    field :created_by_user_id, :binary_id
    field :created_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
  end

  @spec changeset(t() | Ecto.Changeset.t(), attrs()) :: Ecto.Changeset.t()
  def changeset(api_key, attrs) do
    api_key
    |> cast(attrs, [
      :pool_id,
      :display_name,
      :key_prefix,
      :key_hash,
      :status,
      :expires_at,
      :last_used_at,
      :allowed_model_identifiers,
      :enforced_model_identifier,
      :enforced_reasoning_effort,
      :enforced_service_tier,
      :metadata,
      :created_by_user_id,
      :created_at,
      :revoked_at
    ])
    |> update_change(:display_name, &String.trim/1)
    |> update_change(:allowed_model_identifiers, &normalize_model_identifiers/1)
    |> update_change(:enforced_model_identifier, &normalize_model_identifier/1)
    |> update_change(:metadata, &normalize_metadata/1)
    |> validate_required([:pool_id, :display_name, :key_prefix, :key_hash, :status])
    |> validate_inclusion(:status, ["active", "paused", "revoked"])
    |> validate_string_list(:allowed_model_identifiers)
    |> validate_model_identifier(:enforced_model_identifier)
    |> validate_inclusion(:enforced_reasoning_effort, @reasoning_efforts)
    |> validate_inclusion(:enforced_service_tier, @service_tiers)
    |> validate_metadata_shape()
    |> unique_constraint(:key_prefix, name: :api_keys_prefix_uq)
    |> unique_constraint(:key_hash, name: :api_keys_hash_uq)
  end

  defp normalize_model_identifiers(nil), do: nil

  defp normalize_model_identifiers(values) when is_list(values) do
    Enum.map(values, fn
      value when is_binary(value) -> String.trim(value)
      value -> value
    end)
  end

  defp normalize_model_identifiers(value), do: value

  defp normalize_model_identifier(nil), do: nil

  defp normalize_model_identifier(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_model_identifier(value), do: value

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}

  defp validate_string_list(changeset, field) do
    validate_change(changeset, field, fn ^field, values ->
      if is_list(values) and Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")) do
        []
      else
        [{field, "must be a list of non-empty strings"}]
      end
    end)
  end

  defp validate_model_identifier(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_binary(value) and String.trim(value) == value and
           not Regex.match?(~r/[[:space:][:cntrl:]]/, value) do
        []
      else
        [{field, "must be a non-empty model identifier without whitespace"}]
      end
    end)
  end

  defp validate_metadata_shape(changeset) do
    validate_change(changeset, :metadata, fn :metadata, metadata ->
      cond do
        not is_map(metadata) ->
          [metadata: "must be a map"]

        not metadata_labels_valid?(Map.get(metadata, "labels", Map.get(metadata, :labels, []))) ->
          [metadata: "labels must be a list of strings"]

        not metadata_notes_valid?(
          Map.get(metadata, "operator_notes", Map.get(metadata, :operator_notes))
        ) ->
          [metadata: "operator_notes must be a string"]

        true ->
          []
      end
    end)
  end

  defp metadata_labels_valid?(labels) when is_list(labels), do: Enum.all?(labels, &is_binary/1)
  defp metadata_labels_valid?(_labels), do: false

  defp metadata_notes_valid?(nil), do: true
  defp metadata_notes_valid?(notes), do: is_binary(notes)
end
