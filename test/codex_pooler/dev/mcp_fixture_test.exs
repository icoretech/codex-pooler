defmodule CodexPooler.Dev.MCPFixtureTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures

  alias CodexPooler.Dev.MCPFixture
  alias CodexPooler.InstanceSettings
  alias CodexPooler.MCP
  alias CodexPooler.MCP.{OperatorMCPKey, OperatorMCPSettings}
  alias CodexPooler.Repo

  setup do
    Repo.delete_all(OperatorMCPKey)
    Repo.delete_all(OperatorMCPSettings)
    Repo.delete_all(CodexPooler.InstanceSettings.Settings)
    InstanceSettings.reset_cache_for_test()

    on_exit(fn ->
      InstanceSettings.reset_cache_for_test()
    end)

    %{user: owner} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    owner = owner |> Ecto.Changeset.change(password_change_required: false) |> Repo.update!()
    settings = InstanceSettings.ensure_singleton!()

    {:ok, _settings} =
      InstanceSettings.update_system_settings(settings, %{"mcp" => %{"enabled" => false}})

    root =
      Path.join(
        System.tmp_dir!(),
        "codex-pooler-mcp-fixture-#{System.unique_integer([:positive])}"
      )

    path = Path.join(root, "setup.json")

    on_exit(fn -> File.rm_rf(root) end)

    %{owner: owner, path: path, options: fixture_options(path)}
  end

  test "reference-counted acquire enables gates and final release restores exact absence", %{
    owner: owner,
    path: path,
    options: options
  } do
    assert {:ok, %{status: "ready", leases: 1}} = MCPFixture.acquire(options)
    assert {:ok, receipt} = path |> File.read!() |> Jason.decode()
    raw_token = receipt["mcp_token"]
    token_id = receipt["token_id"]

    assert is_binary(raw_token)
    assert %File.Stat{mode: receipt_mode} = File.stat!(path)
    assert Bitwise.band(receipt_mode, 0o777) == 0o600
    assert %File.Stat{mode: root_mode} = File.stat!(Path.dirname(path))
    assert Bitwise.band(root_mode, 0o777) == 0o700
    assert %OperatorMCPKey{operator_id: operator_id} = Repo.get(OperatorMCPKey, token_id)
    assert operator_id == owner.id
    assert %OperatorMCPSettings{enabled: true} = Repo.get(OperatorMCPSettings, owner.id)
    assert InstanceSettings.current().mcp.enabled
    assert {:ok, %{operator: %{id: operator_id}}} = MCP.authenticate_token(raw_token)
    assert operator_id == owner.id

    assert {:ok, %{status: "ready", leases: 2}} = MCPFixture.acquire(options)
    assert Repo.aggregate(OperatorMCPKey, :count) == 1

    assert {:ok, %{status: "ready", leases: 1}} = MCPFixture.release(options)
    assert {:ok, _auth} = MCP.authenticate_token(raw_token)

    assert {:ok, %{status: "released", leases: 0}} = MCPFixture.release(options)
    refute File.exists?(path)
    refute Repo.get(OperatorMCPKey, token_id)
    refute Repo.get(OperatorMCPSettings, owner.id)
    refute InstanceSettings.current().mcp.enabled
    assert {:error, %{code: :mcp_service_disabled}} = MCP.authenticate_token(raw_token)
  end

  test "final release restores a pre-existing disabled operator setting", %{
    owner: owner,
    options: options
  } do
    original =
      %OperatorMCPSettings{operator_id: owner.id}
      |> OperatorMCPSettings.changeset(%{operator_id: owner.id, enabled: false})
      |> Repo.insert!()

    assert {:ok, %{status: "ready", leases: 1}} = MCPFixture.acquire(options)
    assert Repo.get!(OperatorMCPSettings, owner.id).enabled
    assert {:ok, %{status: "released", leases: 0}} = MCPFixture.release(options)

    restored = Repo.get!(OperatorMCPSettings, owner.id)
    refute restored.enabled
    assert restored.inserted_at == original.inserted_at
    assert restored.updated_at == original.updated_at
  end

  test "status never exposes the raw token", %{path: path, options: options} do
    assert {:ok, %{status: "absent", leases: 0}} = MCPFixture.status(options)
    assert {:ok, status} = MCPFixture.acquire(options)
    raw_token = path |> File.read!() |> Jason.decode!() |> Map.fetch!("mcp_token")

    refute inspect(status) =~ raw_token
    refute Map.has_key?(status, :mcp_token)
    assert {:ok, released} = MCPFixture.release(options)
    refute inspect(released) =~ raw_token
  end

  test "refuses non-development use without the explicit test allowance", %{path: path} do
    assert {:error, "MCP fixture runs only with MIX_ENV=dev"} =
             MCPFixture.acquire(environment: :test, receipt_path: path)
  end

  defp fixture_options(path) do
    [environment: :test, allow_test_database: true, receipt_path: path]
  end
end
