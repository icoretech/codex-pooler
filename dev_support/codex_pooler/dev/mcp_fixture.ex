defmodule CodexPooler.Dev.MCPFixture do
  @moduledoc """
  Reversible local MCP gate and token fixture for the tracked smoke suite.

  One reference-counted receipt owns the exact prior global gate, operator gate,
  and disposable token. The raw token exists only in the mode-0600 receipt and
  is never returned by the Mix task.
  """

  alias CodexPooler.Dev.MCPFixture.{Provisioner, Receipt, Snapshot}
  alias CodexPooler.MCP.Material
  alias CodexPooler.Repo

  @database "codex_pooler_dev"
  @default_receipt_path Path.join(["tmp", "mcp-fixture", "setup.json"])

  @type options :: [
          environment: atom(),
          allow_test_database: boolean(),
          receipt_path: String.t(),
          repo_config: keyword()
        ]
  @type status :: %{
          required(:status) => String.t(),
          required(:leases) => non_neg_integer(),
          required(:receipt_path) => String.t()
        }

  @spec receipt_path() :: String.t()
  def receipt_path, do: Path.expand(@default_receipt_path, File.cwd!())

  @spec acquire(options()) :: {:ok, status()} | {:error, String.t()}
  def acquire(options \\ []) do
    with :ok <- validate_environment(options) do
      path = resolved_receipt_path(options)
      Receipt.with_lock(path, fn -> acquire_locked(path) end)
    end
  end

  @spec release(options()) :: {:ok, status()} | {:error, String.t()}
  def release(options \\ []) do
    with :ok <- validate_environment(options) do
      path = resolved_receipt_path(options)
      Receipt.with_lock(path, fn -> release_locked(path) end)
    end
  end

  @spec status(options()) :: {:ok, status()} | {:error, String.t()}
  def status(options \\ []) do
    path = resolved_receipt_path(options)

    case Receipt.read(path) do
      {:ok, setup} -> public_status(setup, path)
      :missing -> {:ok, %{status: "absent", leases: 0, receipt_path: path}}
      {:error, message} -> {:error, message}
    end
  end

  @spec validate_environment(options()) :: :ok | {:error, String.t()}
  def validate_environment(options) do
    environment = Keyword.get(options, :environment, Mix.env())
    repo_config = Keyword.get(options, :repo_config, Repo.config())
    allow_test_database? = Keyword.get(options, :allow_test_database, false)

    cond do
      environment == :dev and Keyword.get(repo_config, :database) == @database -> :ok
      environment == :test and allow_test_database? -> :ok
      environment != :dev -> {:error, "MCP fixture runs only with MIX_ENV=dev"}
      true -> {:error, "MCP fixture requires database #{@database}"}
    end
  end

  defp acquire_locked(path) do
    case Receipt.read(path) do
      {:ok, %{"state" => "ready", "leases" => leases} = setup}
      when is_integer(leases) and leases > 0 ->
        updated = Map.put(setup, "leases", leases + 1)
        Receipt.write!(path, updated)
        public_status(updated, path)

      {:ok, _setup} ->
        {:error, "MCP fixture receipt requires cleanup before reuse"}

      :missing ->
        provision_new(path)

      {:error, message} ->
        {:error, message}
    end
  end

  defp provision_new(path) do
    operator = Provisioner.usable_owner!()
    snapshot = Snapshot.capture!(operator.id)
    token_id = Ecto.UUID.generate()
    {token_prefix, raw_token, _key_hash} = Material.generate()

    prepared = %{
      "version" => 1,
      "state" => "prepared",
      "leases" => 1,
      "mcp_token" => raw_token,
      "token_id" => token_id,
      "token_prefix" => token_prefix,
      "snapshot" => snapshot
    }

    Receipt.write!(path, prepared)

    case Provisioner.provision(prepared, operator) do
      :ok ->
        ready = Map.put(prepared, "state", "ready")
        Receipt.write!(path, ready)
        public_status(ready, path)

      {:error, _message} = error ->
        recover_failed_provision(path, prepared, error)
    end
  rescue
    error -> {:error, "MCP fixture provisioning raised #{inspect(error.__struct__)}"}
  end

  defp release_locked(path) do
    case Receipt.read(path) do
      {:ok, %{"state" => "ready", "leases" => leases} = setup}
      when is_integer(leases) and leases > 1 ->
        updated = Map.put(setup, "leases", leases - 1)
        Receipt.write!(path, updated)
        public_status(updated, path)

      {:ok, %{"leases" => 1} = setup} ->
        with :ok <- restore_setup(setup) do
          Receipt.remove!(path)
          {:ok, %{status: "released", leases: 0, receipt_path: path}}
        end

      {:ok, _setup} ->
        {:error, "MCP fixture receipt has an invalid lease count"}

      :missing ->
        {:ok, %{status: "absent", leases: 0, receipt_path: path}}

      {:error, message} ->
        {:error, message}
    end
  end

  defp recover_failed_provision(path, setup, error) do
    case restore_setup(setup) do
      :ok ->
        Receipt.remove!(path)
        error

      {:error, _message} ->
        {:error, "MCP fixture provisioning failed; cleanup receipt retained"}
    end
  end

  defp restore_setup(%{"snapshot" => snapshot, "token_id" => token_id}) do
    Provisioner.restore(snapshot, token_id)
  end

  defp restore_setup(_setup), do: {:error, "MCP fixture receipt has no snapshot"}

  defp public_status(setup, path) do
    with state when is_binary(state) <- setup["state"],
         leases when is_integer(leases) and leases >= 0 <- setup["leases"] do
      {:ok, %{status: state, leases: leases, receipt_path: path}}
    else
      _invalid -> {:error, "MCP fixture receipt has an invalid public status"}
    end
  end

  defp resolved_receipt_path(options) do
    options
    |> Keyword.get(:receipt_path, receipt_path())
    |> Path.expand(File.cwd!())
  end
end
