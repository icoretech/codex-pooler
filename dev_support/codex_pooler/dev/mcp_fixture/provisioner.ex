defmodule CodexPooler.Dev.MCPFixture.Provisioner do
  @moduledoc false

  alias CodexPooler.Accounts
  alias CodexPooler.Accounts.{PlatformBootstrapState, User}
  alias CodexPooler.Dev.MCPFixture.Snapshot
  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.Cache
  alias CodexPooler.MCP.{Material, OperatorMCPKey, OperatorMCPSettings}
  alias CodexPooler.Repo

  @spec canonical_owner() :: {:ok, User.t()} | {:error, String.t()}
  def canonical_owner do
    case Repo.get(PlatformBootstrapState, true) do
      %PlatformBootstrapState{status: "completed", owner_user_id: owner_user_id}
      when is_binary(owner_user_id) ->
        canonical_owner(owner_user_id)

      _state ->
        {:error, "MCP fixture requires a completed platform bootstrap with a canonical owner"}
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

  defp canonical_owner(owner_user_id) do
    case Repo.get(User, owner_user_id) do
      %User{} = operator -> validate_canonical_owner(operator)
      nil -> {:error, "MCP fixture canonical bootstrap owner is missing"}
    end
  end

  defp validate_canonical_owner(%User{} = operator) do
    if operator.status == "active" and is_nil(operator.deleted_at) and
         not operator.password_change_required and
         "instance_owner" in Accounts.roles_for_user(operator) do
      {:ok, operator}
    else
      {:error,
       "MCP fixture canonical bootstrap owner is not usable: expected active, undeleted, password-ready instance owner"}
    end
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
