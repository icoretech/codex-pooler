defmodule CodexPooler.Dev.MeteredQuotaFixture do
  @moduledoc """
  Reference-counted, exact-ID local fixture for metered quota UI and HTTP QA.

  The durable receipt holds only an opaque fixture hash. Release derives exact
  owned IDs from that hash and validates every present row before deletion.
  """

  alias CodexPooler.Dev.MeteredQuotaFixture.{Provisioner, Receipt}
  alias CodexPooler.Repo

  @database "codex_pooler_dev"
  @default_root Path.join(["tmp", "metered-quota-fixture"])
  @default_receipt Path.join(@default_root, "receipt.json")
  @local_url "http://127.0.0.1:4000"

  @type options :: [
          environment: atom(),
          allow_test_database: boolean(),
          repo_config: keyword(),
          receipt_path: String.t(),
          allowed_receipt_root: String.t()
        ]

  @type status :: %{
          required(:status) => String.t(),
          required(:leases) => non_neg_integer(),
          required(:receipt_path) => String.t(),
          optional(:api_key_prefix) => String.t(),
          optional(:route_paths) => %{required(String.t()) => String.t() | [String.t()]},
          optional(:selector_complete) => boolean(),
          optional(:rows_present) => boolean(),
          optional(:one_time_api_key) => String.t(),
          optional(:admin_identity_route) => String.t(),
          optional(:local_url) => String.t(),
          optional(:login) => %{required(:email) => String.t(), required(:password) => String.t()},
          optional(:action) => String.t()
        }

  @spec receipt_path() :: String.t()
  def receipt_path, do: Path.expand(@default_receipt, File.cwd!())

  @spec receipt_path(options()) :: String.t()
  def receipt_path(options) do
    options
    |> Keyword.get(:receipt_path, receipt_path())
    |> Path.expand()
  end

  @spec acquire(options()) :: {:ok, status()} | {:error, String.t()}
  def acquire(options \\ []) do
    with :ok <- validate_environment(options) do
      {path, root} = resolved_paths(options)
      Receipt.with_lock(path, root, fn -> acquire_locked(path, root) end)
    end
  end

  @spec status(options()) :: {:ok, status()} | {:error, String.t()}
  def status(options \\ []) do
    with :ok <- validate_environment(options) do
      {path, root} = resolved_paths(options)

      case Receipt.read(path, root) do
        {:ok, document} -> status_document(document, path)
        :missing -> absent_status(path)
        {:error, message} -> {:error, message}
      end
    end
  end

  @spec release(options()) :: {:ok, status()} | {:error, String.t()}
  def release(options \\ []) do
    with :ok <- validate_environment(options) do
      {path, root} = resolved_paths(options)
      Receipt.with_lock(path, root, fn -> release_locked(path, root) end)
    end
  end

  @spec validate_environment(options()) :: :ok | {:error, String.t()}
  def validate_environment(options) do
    environment = Keyword.get(options, :environment, Mix.env())
    repo_config = Keyword.get(options, :repo_config, Repo.config())

    cond do
      environment == :dev and Keyword.get(repo_config, :database) == @database -> :ok
      environment == :test and Keyword.get(options, :allow_test_database, false) -> :ok
      environment != :dev -> {:error, "metered quota fixture runs only with MIX_ENV=dev"}
      true -> {:error, "metered quota fixture requires database #{@database}"}
    end
  end

  defp acquire_locked(path, root) do
    case Receipt.read(path, root) do
      {:ok, %{"state" => "ready", "leases" => leases} = document}
      when is_integer(leases) and leases > 0 ->
        increment_lease(document, leases, path, root)

      {:ok, _document} ->
        {:error, "metered quota fixture receipt is invalid or requires cleanup"}

      :missing ->
        provision_new(path, root)

      {:error, message} ->
        {:error, message}
    end
  end

  defp increment_lease(document, leases, path, root) do
    with :ok <- validate_document(document),
         {:ok, fixture_status} <- Provisioner.status(document),
         true <- fixture_status.rows_present,
         updated = Map.put(document, "leases", leases + 1),
         :ok <- Receipt.write(path, root, updated) do
      public_status(updated, path, fixture_status)
    else
      false -> {:error, "metered quota fixture receipt requires cleanup before reuse"}
      {:error, message} -> {:error, message}
    end
  end

  defp provision_new(path, root) do
    provisioned = Provisioner.prepare()
    prepared = prepared_document(provisioned)

    with :ok <- Receipt.write(path, root, prepared),
         :ok <- Provisioner.provision!(prepared, provisioned.api_key),
         ready = Map.put(prepared, "state", "ready"),
         :ok <- Receipt.write(path, root, ready) do
      acquisition_status(ready, path, provisioned)
    else
      {:error, message} -> {:error, message}
    end
  rescue
    error in RuntimeError ->
      {:error, "#{error.message}; release the retained receipt to recover exact owned ids"}

    error ->
      {:error, "metered quota fixture provisioning raised #{inspect(error.__struct__)}"}
  end

  defp status_document(document, path) do
    with :ok <- validate_document(document),
         {:ok, fixture_status} <- Provisioner.status(document) do
      public_status(document, path, fixture_status)
    end
  end

  defp release_locked(path, root) do
    case Receipt.read(path, root) do
      {:ok, %{"state" => "ready", "leases" => leases} = document}
      when is_integer(leases) and leases > 1 ->
        decrement_lease(document, leases, path, root)

      {:ok, %{"state" => state, "leases" => 1} = document}
      when state in ["prepared", "ready"] ->
        with :ok <- validate_document(document),
             :ok <- Provisioner.release(document),
             :ok <- Receipt.remove(path, root) do
          {:ok, %{status: "released", leases: 0, receipt_path: path}}
        end

      {:ok, _document} ->
        {:error, "metered quota fixture receipt has an invalid lease count"}

      :missing ->
        absent_status(path)

      {:error, message} ->
        {:error, message}
    end
  end

  defp decrement_lease(document, leases, path, root) do
    updated = Map.put(document, "leases", leases - 1)

    with :ok <- validate_document(document),
         :ok <- Receipt.write(path, root, updated),
         {:ok, fixture_status} <- Provisioner.status(updated) do
      public_status(updated, path, fixture_status)
    end
  end

  defp prepared_document(provisioned) do
    %{
      "version" => 2,
      "state" => "prepared",
      "leases" => 1,
      "fixture_hash" => provisioned.fixture_hash,
      "api_key_prefix" => provisioned.api_key_prefix,
      "owned_row_count" => provisioned.owned_row_count,
      "route_paths" => %{
        "login" => "/login",
        "admin_upstreams" => "/admin/upstreams",
        "usage" => ["/api/codex/usage", "/wham/usage", "/backend-api/wham/usage"]
      }
    }
  end

  defp validate_document(document) do
    required_keys =
      ~w(version state leases fixture_hash api_key_prefix owned_row_count route_paths)

    valid? =
      Enum.sort(Map.keys(document)) == Enum.sort(required_keys) and
        valid_document_header?(document) and valid_fixture_hash?(document["fixture_hash"]) and
        valid_api_key_prefix?(document["api_key_prefix"]) and
        valid_routes?(document["route_paths"])

    if valid?, do: :ok, else: {:error, "metered quota fixture receipt is invalid"}
  end

  defp valid_document_header?(document) do
    document["version"] == 2 and document["state"] in ["prepared", "ready"] and
      is_integer(document["leases"]) and document["leases"] >= 1 and
      document["owned_row_count"] == 12
  end

  defp valid_fixture_hash?(fixture_hash) when is_binary(fixture_hash) do
    fixture_hash =~ ~r/\A[0-9a-f]{64}\z/
  end

  defp valid_fixture_hash?(_fixture_hash), do: false

  defp valid_api_key_prefix?(prefix) when is_binary(prefix),
    do: prefix =~ ~r/\Ask-cxp-[0-9a-f]{12}\z/

  defp valid_api_key_prefix?(_prefix), do: false

  defp valid_routes?(routes) when is_map(routes) do
    routes == %{
      "login" => "/login",
      "admin_upstreams" => "/admin/upstreams",
      "usage" => ["/api/codex/usage", "/wham/usage", "/backend-api/wham/usage"]
    }
  end

  defp valid_routes?(_routes), do: false

  defp public_status(document, path, fixture_status) do
    {:ok,
     %{
       status: document["state"],
       leases: document["leases"],
       receipt_path: path,
       api_key_prefix: document["api_key_prefix"],
       route_paths: document["route_paths"],
       rows_present: fixture_status.rows_present,
       selector_complete: fixture_status.selector_complete
     }}
  end

  defp acquisition_status(document, path, provisioned) do
    {:ok, status} =
      public_status(document, path, %{rows_present: true, selector_complete: true})

    {:ok,
     Map.merge(status, %{
       one_time_api_key: provisioned.api_key,
       admin_identity_route: "/admin/upstreams/#{provisioned.identity_id}",
       local_url: @local_url,
       login: %{email: "dev-owner@example.com", password: "dev-password-123"}
     })}
  end

  defp absent_status(path) do
    {:ok,
     %{
       status: "absent",
       leases: 0,
       receipt_path: path,
       action: "run MIX_ENV=dev mix dev.metered_quota_fixture acquire --output #{path}"
     }}
  end

  defp resolved_paths(options) do
    root =
      options
      |> Keyword.get(:allowed_receipt_root, Path.expand(@default_root, File.cwd!()))
      |> Path.expand()

    path = receipt_path(options)

    {path, root}
  end
end
