defmodule CodexPooler.Dev.RoutingStrategyFixture do
  @moduledoc """
  Reversible local fixture that makes Pool routing strategies observable.

  The fixture owns one synthetic `routing-strategy-smoke` Pool, at least four
  upstream identities with active assignments, one model, one API key, and the
  routing evidence that differentiates those assignments. Multiple local callers
  share a reference-counted receipt; only the final release restores the exact
  prior database state, including the exact prior `pool_routing_settings` row.

  ## Why the assignments are differentiated

  Two of the three non-default strategies degenerate to the default on a freshly
  provisioned Pool, because both fall back to the same rendezvous tie-break that
  is the default strategy's only sort key:

    * `least_recent_success` scores every assignment with no succeeded attempt
      as `0`, so an untouched Pool orders purely by rendezvous.
    * `quota_first` scores every assignment with no usable routing window as
      `0`, so an untouched Pool orders purely by rendezvous.

  A lane built on an undifferentiated Pool would therefore be green while
  proving nothing. Differentiation is part of this fixture's contract, not an
  afterthought: every assignment gets one succeeded attempt with a distinct
  `completed_at`, and one account plus one model quota window with a distinct
  remaining percent. The two keys are deliberately opposed, so the
  `quota_first` order is the exact reverse of the `least_recent_success` order
  and neither can silently collapse into the other or into the default.

  `deterministic_rotation` is the only strategy that differs generically,
  because it rotates the incoming candidate order instead of re-sorting it.

  Ring size stays at the product default of 3 while the fixture provisions four
  or more assignments, because truncation is the one situation where the
  strategies differ in the *selected* assignment rather than only in the tail.
  """

  alias CodexPooler.Dev.RoutingStrategyFixture.{Provisioner, Receipt, Snapshot}
  alias CodexPooler.Pools.RoutingSettings
  alias CodexPooler.Repo

  @database "codex_pooler_dev"
  @default_upstream_base_url "http://127.0.0.1:4057"
  @default_receipt_path Path.join(["tmp", "routing-strategy-fixture", "setup.json"])
  @default_assignments 4
  @minimum_assignments 4
  @maximum_assignments 8

  @type options :: [
          environment: atom(),
          allow_test_database: boolean(),
          allow_isolated_dev_database: boolean(),
          receipt_path: String.t(),
          upstream_base_url: String.t(),
          routing_strategy: String.t(),
          assignments: pos_integer(),
          repo_config: keyword()
        ]
  @type status :: %{
          required(:status) => String.t(),
          required(:leases) => non_neg_integer(),
          required(:receipt_path) => String.t(),
          optional(:pool_slug) => String.t(),
          optional(:routing_strategy) => String.t(),
          optional(:assignment_count) => pos_integer(),
          optional(:bridge_ring_size) => pos_integer(),
          optional(:model) => String.t()
        }

  @spec receipt_path() :: String.t()
  def receipt_path, do: Path.expand(@default_receipt_path, File.cwd!())

  @spec default_assignments() :: pos_integer()
  def default_assignments, do: @default_assignments

  @spec routing_strategies() :: [String.t()]
  def routing_strategies, do: RoutingSettings.routing_strategies()

  @spec acquire(options()) :: {:ok, status()} | {:error, String.t()}
  def acquire(options \\ []) do
    with :ok <- validate_environment(options),
         {:ok, upstream_base_url} <- upstream_base_url(options),
         {:ok, routing_strategy} <- routing_strategy(options),
         {:ok, assignments} <- assignment_count(options) do
      path = resolved_receipt_path(options)

      Receipt.with_lock(path, fn ->
        acquire_locked(path, %{
          upstream_base_url: upstream_base_url,
          routing_strategy: routing_strategy,
          assignments: assignments
        })
      end)
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
    allow_isolated_dev_database? = Keyword.get(options, :allow_isolated_dev_database, false)
    database = Keyword.get(repo_config, :database)

    cond do
      environment == :dev and database == @database ->
        :ok

      environment == :dev and allow_isolated_dev_database? and isolated_dev_database?(database) ->
        :ok

      environment == :test and allow_test_database? ->
        :ok

      environment != :dev ->
        {:error, "routing strategy fixture runs only with MIX_ENV=dev"}

      true ->
        {:error, "routing strategy fixture requires database #{@database}"}
    end
  end

  defp isolated_dev_database?(database) when is_binary(database) do
    Regex.match?(~r/^codex_pooler_relqa_[a-z0-9_]{8,63}$/, database)
  end

  defp isolated_dev_database?(_database), do: false

  defp acquire_locked(path, request) do
    case Receipt.read(path) do
      {:ok, %{"state" => "ready", "leases" => leases} = setup}
      when is_integer(leases) and leases > 0 ->
        reuse_lease(path, setup, request, leases)

      {:ok, _setup} ->
        {:error, "routing strategy fixture receipt requires cleanup before reuse"}

      :missing ->
        provision_new(path, request)

      {:error, message} ->
        {:error, message}
    end
  end

  defp reuse_lease(path, setup, request, leases) do
    cond do
      setup["upstream_base_url"] != request.upstream_base_url ->
        {:error, "routing strategy fixture is leased for another upstream origin"}

      setup["routing_strategy"] != request.routing_strategy ->
        {:error, "routing strategy fixture is leased with another routing strategy"}

      setup["assignment_count"] != request.assignments ->
        {:error, "routing strategy fixture is leased with another assignment count"}

      true ->
        updated = Map.put(setup, "leases", leases + 1)
        Receipt.write!(path, updated)
        public_status(updated, path)
    end
  end

  defp provision_new(path, request) do
    snapshot = Snapshot.capture(request.assignments)

    Receipt.write!(path, %{
      "version" => 1,
      "state" => "prepared",
      "leases" => 1,
      "upstream_base_url" => request.upstream_base_url,
      "routing_strategy" => request.routing_strategy,
      "assignment_count" => request.assignments,
      "receipt" => Receipt.encode_snapshot(snapshot)
    })

    try do
      provisioned = Provisioner.provision!(request)
      setup = ready_setup(snapshot, request, provisioned)
      Receipt.write!(path, setup)
      public_status(setup, path)
    rescue
      _exception -> recover_failed_provision(path)
    end
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
        {:error, "routing strategy fixture receipt has an invalid lease count"}

      :missing ->
        {:ok, %{status: "absent", leases: 0, receipt_path: path}}

      {:error, message} ->
        {:error, message}
    end
  end

  defp recover_failed_provision(path) do
    case Receipt.read(path) do
      {:ok, setup} ->
        case restore_setup(setup) do
          :ok ->
            Receipt.remove!(path)
            {:error, "routing strategy fixture provisioning failed and was restored"}

          {:error, _message} ->
            {:error, "routing strategy fixture provisioning failed; cleanup receipt retained"}
        end

      _missing_or_invalid ->
        {:error, "routing strategy fixture provisioning failed without a recoverable receipt"}
    end
  end

  defp restore_setup(%{"receipt" => encoded} = setup) do
    with :ok <- Snapshot.prepare_decode!(),
         {:ok, decoded} <- Receipt.decode_snapshot(encoded),
         {:ok, snapshot} <- Snapshot.parse(decoded),
         {:ok, :ok} <-
           Repo.transact(fn -> {:ok, Snapshot.restore!(snapshot, created(setup))} end) do
      :ok
    else
      :error -> {:error, "routing strategy fixture receipt snapshot is invalid"}
      {:error, _reason} -> {:error, "routing strategy fixture snapshot transaction failed"}
    end
  rescue
    error in RuntimeError -> {:error, error.message}
    error -> {:error, "routing strategy fixture restore raised #{inspect(error.__struct__)}"}
  end

  defp restore_setup(_setup), do: {:error, "routing strategy fixture receipt has no snapshot"}

  defp created(%{"created" => %{} = created}) do
    %{
      pool_id: created["pool_id"],
      routing_settings_pool_id: created["routing_settings_pool_id"],
      identity_ids: List.wrap(created["identity_ids"]),
      assignment_ids: List.wrap(created["assignment_ids"]),
      model_ids: List.wrap(created["model_ids"]),
      api_key_ids: List.wrap(created["api_key_ids"]),
      request_ids: List.wrap(created["request_ids"])
    }
  end

  defp created(_setup), do: Snapshot.empty_created()

  defp ready_setup(snapshot, request, provisioned) do
    %{
      "version" => 1,
      "state" => "ready",
      "leases" => 1,
      "upstream_base_url" => request.upstream_base_url,
      "routing_strategy" => request.routing_strategy,
      "assignment_count" => request.assignments,
      "bridge_ring_size" => provisioned.bridge_ring_size,
      "receipt" => Receipt.encode_snapshot(snapshot),
      "created" => %{
        "pool_id" => provisioned.created.pool_id,
        "routing_settings_pool_id" => provisioned.created.routing_settings_pool_id,
        "identity_ids" => provisioned.created.identity_ids,
        "assignment_ids" => provisioned.created.assignment_ids,
        "model_ids" => provisioned.created.model_ids,
        "api_key_ids" => provisioned.created.api_key_ids,
        "request_ids" => provisioned.created.request_ids
      },
      "api_key" => provisioned.api_key,
      "pool_id" => provisioned.pool_id,
      "pool_slug" => provisioned.pool_slug,
      "model" => provisioned.model
    }
  end

  defp public_status(setup, path) do
    with state when is_binary(state) <- setup["state"],
         leases when is_integer(leases) and leases >= 0 <- setup["leases"] do
      {:ok,
       %{status: state, leases: leases, receipt_path: path}
       |> put_optional(:pool_slug, setup["pool_slug"])
       |> put_optional(:routing_strategy, setup["routing_strategy"])
       |> put_optional(:assignment_count, setup["assignment_count"])
       |> put_optional(:bridge_ring_size, setup["bridge_ring_size"])
       |> put_optional(:model, setup["model"])}
    else
      _invalid -> {:error, "routing strategy fixture receipt has an invalid public status"}
    end
  end

  defp upstream_base_url(options) do
    value = Keyword.get(options, :upstream_base_url, @default_upstream_base_url)
    uri = URI.parse(value)

    if uri.scheme == "http" and uri.host in ["127.0.0.1", "localhost", "::1"] and
         is_integer(uri.port) and is_nil(uri.userinfo) and is_nil(uri.query) and
         is_nil(uri.fragment) and uri.path in [nil, "", "/"] do
      {:ok, value |> String.trim_trailing("/")}
    else
      {:error, "upstream base URL must be an origin-only loopback HTTP URL with a port"}
    end
  end

  defp routing_strategy(options) do
    strategy = Keyword.get(options, :routing_strategy, "bridge_ring")

    if strategy in routing_strategies() do
      {:ok, strategy}
    else
      {:error, "routing strategy must be one of #{Enum.join(routing_strategies(), ", ")}"}
    end
  end

  defp assignment_count(options) do
    case Keyword.get(options, :assignments, @default_assignments) do
      count
      when is_integer(count) and count >= @minimum_assignments and
             count <= @maximum_assignments ->
        {:ok, count}

      _other ->
        {:error,
         "assignments must be an integer between #{@minimum_assignments} and " <>
           "#{@maximum_assignments}; ring truncation is unreachable below " <>
           "#{@minimum_assignments}"}
    end
  end

  defp resolved_receipt_path(options) do
    case Keyword.fetch(options, :receipt_path) do
      {:ok, path} when is_binary(path) -> Path.expand(path)
      :error -> receipt_path()
    end
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end
