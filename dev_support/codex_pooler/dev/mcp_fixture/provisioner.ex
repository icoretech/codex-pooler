defmodule CodexPooler.Dev.MCPFixture.Provisioner do
  @moduledoc false

  alias CodexPooler.Accounts
  alias CodexPooler.Accounts.User
  alias CodexPooler.Dev.MCPFixture.Snapshot
  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.Cache
  alias CodexPooler.MCP.{Material, OperatorMCPKey, OperatorMCPSettings}
  alias CodexPooler.Repo

  @spec usable_owner!() :: User.t()
  def usable_owner! do
    Accounts.list_operators()
    |> Enum.find(fn operator ->
      roles = Accounts.roles_for_user(operator)

      operator.status == "active" and not operator.password_change_required and
        "instance_owner" in roles
    end)
    |> case do
      %User{} = operator -> operator
      nil -> raise "MCP fixture requires an active local instance owner"
    end
  end

  @spec provision(map(), User.t()) :: :ok | {:error, String.t()}
  def provision(setup, %User{} = operator) when is_map(setup) do
    with {:ok, _result} <- Repo.transact(fn -> provision_transaction(setup, operator) end),
         :ok <- publish_instance_settings() do
      :ok
    else
      {:error, _reason} -> {:error, "MCP fixture provisioning transaction failed"}
    end
  rescue
    error -> {:error, "MCP fixture provisioning raised #{inspect(error.__struct__)}"}
  end

  @spec restore(map(), Ecto.UUID.t()) :: :ok | {:error, String.t()}
  def restore(snapshot, token_id) when is_map(snapshot) and is_binary(token_id) do
    with {:ok, _result} <-
           Repo.transact(fn -> {:ok, Snapshot.restore!(snapshot, token_id)} end),
         :ok <- publish_instance_settings() do
      :ok
    else
      {:error, _reason} -> {:error, "MCP fixture restoration transaction failed"}
    end
  rescue
    error -> {:error, "MCP fixture restore raised #{inspect(error.__struct__)}"}
  end

  defp provision_transaction(setup, operator) do
    enable_global_gate!()
    enable_operator_gate!(operator)
    create_token!(setup, operator)
    {:ok, :ok}
  end

  defp enable_global_gate! do
    %{num_rows: 1} =
      Repo.query!(
        """
        UPDATE instance_settings
        SET mcp = jsonb_set(mcp, '{enabled}', to_jsonb($1::boolean), true),
            lock_version = lock_version + 1,
            updated_at = NOW()
        WHERE singleton = true
        """,
        [true]
      )

    :ok
  end

  defp enable_operator_gate!(%User{id: operator_id}) do
    %OperatorMCPSettings{operator_id: operator_id}
    |> OperatorMCPSettings.changeset(%{operator_id: operator_id, enabled: true})
    |> Repo.insert!(
      on_conflict: [set: [enabled: true, updated_at: DateTime.utc_now()]],
      conflict_target: :operator_id
    )

    :ok
  end

  defp create_token!(setup, %User{id: operator_id}) do
    {:ok, key_prefix, secret} = Material.split(setup["mcp_token"])

    %OperatorMCPKey{id: setup["token_id"]}
    |> OperatorMCPKey.changeset(%{
      operator_id: operator_id,
      label: "Local MCP Smoke",
      key_prefix: key_prefix,
      key_hash: Material.hash_secret(secret)
    })
    |> Repo.insert!()

    :ok
  end

  defp publish_instance_settings do
    settings = InstanceSettings.get!()

    with {:ok, _settings} <- Cache.put(settings),
         :ok <- Cache.broadcast_update(settings) do
      :ok
    else
      _error -> {:error, "MCP fixture could not refresh instance settings cache"}
    end
  end
end
