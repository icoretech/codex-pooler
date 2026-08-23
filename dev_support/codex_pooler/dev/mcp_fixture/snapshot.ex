defmodule CodexPooler.Dev.MCPFixture.Snapshot do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.MCP.{OperatorMCPKey, OperatorMCPSettings}
  alias CodexPooler.Repo

  @type t :: %{
          required(String.t()) =>
            nil | boolean() | integer() | String.t() | %{required(String.t()) => term()}
        }

  @spec capture!(Ecto.UUID.t()) :: t()
  def capture!(operator_id) when is_binary(operator_id) do
    %{
      "global_gate" => capture_global_gate!(),
      "operator_id" => operator_id,
      "operator_setting" => capture_operator_setting(operator_id)
    }
  end

  @spec restore!(t(), Ecto.UUID.t()) :: :ok
  def restore!(snapshot, token_id) when is_map(snapshot) and is_binary(token_id) do
    restore_token!(token_id)
    restore_operator_gate!(snapshot)
    restore_global_gate!(snapshot)
  end

  defp capture_global_gate! do
    case Repo.query!("""
         SELECT mcp::text, lock_version, updated_at::text, updated_by_user_id::text
         FROM instance_settings
         WHERE singleton = true
         """) do
      %{rows: [[mcp, lock_version, updated_at, updated_by_user_id]]} ->
        %{
          "mcp" => Jason.decode!(mcp),
          "lock_version" => lock_version,
          "updated_at" => updated_at,
          "updated_by_user_id" => updated_by_user_id
        }

      _result ->
        raise "MCP fixture requires an existing instance settings row"
    end
  end

  defp capture_operator_setting(operator_id) do
    case Repo.get(OperatorMCPSettings, operator_id) do
      nil ->
        nil

      %OperatorMCPSettings{} = setting ->
        %{
          "enabled" => setting.enabled,
          "inserted_at" => DateTime.to_iso8601(setting.inserted_at),
          "updated_at" => DateTime.to_iso8601(setting.updated_at)
        }
    end
  end

  defp restore_token!(token_id) do
    {deleted, nil} = Repo.delete_all(from key in OperatorMCPKey, where: key.id == ^token_id)

    if deleted in [0, 1], do: :ok, else: raise("unexpected MCP fixture token cleanup count")
  end

  defp restore_operator_gate!(%{"operator_id" => operator_id, "operator_setting" => nil}) do
    Repo.delete_all(
      from setting in OperatorMCPSettings, where: setting.operator_id == ^operator_id
    )

    :ok
  end

  defp restore_operator_gate!(%{
         "operator_id" => operator_id,
         "operator_setting" => setting
       }) do
    restored = %OperatorMCPSettings{
      operator_id: operator_id,
      enabled: setting["enabled"],
      inserted_at: parse_timestamp!(setting["inserted_at"]),
      updated_at: parse_timestamp!(setting["updated_at"])
    }

    Repo.insert!(restored,
      on_conflict: {:replace, [:enabled, :inserted_at, :updated_at]},
      conflict_target: :operator_id
    )

    :ok
  end

  defp restore_global_gate!(%{"global_gate" => gate}) do
    %{num_rows: 1} =
      Repo.query!(
        """
        UPDATE instance_settings
        SET mcp = $1::jsonb,
            lock_version = $2,
            updated_at = $3::timestamptz,
            updated_by_user_id = NULLIF($4::text, '')::uuid
        WHERE singleton = true
        """,
        [
          gate["mcp"],
          gate["lock_version"],
          parse_timestamp!(gate["updated_at"]),
          gate["updated_by_user_id"] || ""
        ]
      )

    :ok
  end

  defp parse_timestamp!(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} ->
        timestamp

      {:error, _reason} ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, timestamp} -> DateTime.from_naive!(timestamp, "Etc/UTC")
          {:error, _reason} -> raise "MCP fixture receipt has an invalid timestamp"
        end
    end
  end

  defp parse_timestamp!(_value), do: raise("MCP fixture receipt has an invalid timestamp")
end
