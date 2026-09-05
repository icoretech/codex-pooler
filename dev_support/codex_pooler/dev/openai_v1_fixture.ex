defmodule CodexPooler.Dev.OpenAIV1Fixture do
  @moduledoc """
  Reversible local fixture state for the tracked Codex Pooler smoke suite.

  The fixture owns one synthetic Pool, upstream identity, assignment, model
  set, API key, and quota snapshot. Multiple local callers share a
  reference-counted receipt; only the final release restores the exact prior
  database state.
  """

  alias CodexPooler.Dev.OpenAIV1Fixture.{Provisioner, Receipt, Snapshot}
  alias CodexPooler.Repo

  @database "codex_pooler_dev"
  @default_upstream_base_url "http://127.0.0.1:4057"
  @default_receipt_path Path.join(["tmp", "openai-v1-fixture", "setup.json"])

  @type request_compression_mode :: :preserve | :enabled
  @type options :: [
          environment: atom(),
          allow_test_database: boolean(),
          allow_isolated_dev_database: boolean(),
          receipt_path: String.t(),
          upstream_base_url: String.t(),
          request_compression: request_compression_mode(),
          repo_config: keyword()
        ]
  @type status :: %{
          required(:status) => String.t(),
          required(:leases) => non_neg_integer(),
          required(:receipt_path) => String.t(),
          optional(:pool_slug) => String.t(),
          optional(:text_model) => String.t(),
          optional(:audio_model) => String.t(),
          optional(:image_model) => String.t()
        }

  @spec receipt_path() :: String.t()
  def receipt_path, do: Path.expand(@default_receipt_path, File.cwd!())

  @spec acquire(options()) :: {:ok, status()} | {:error, String.t()}
  def acquire(options \\ []) do
    with :ok <- validate_environment(options),
         {:ok, upstream_base_url} <- upstream_base_url(options),
         {:ok, request_compression_mode} <- request_compression_mode(options) do
      path = resolved_receipt_path(options)

      Receipt.with_lock(path, fn ->
        acquire_locked(path, upstream_base_url, request_compression_mode)
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
        {:error, "OpenAI V1 fixture runs only with MIX_ENV=dev"}

      true ->
        {:error, "OpenAI V1 fixture requires database #{@database}"}
    end
  end

  defp isolated_dev_database?(database) when is_binary(database) do
    Regex.match?(~r/^codex_pooler_relqa_[a-z0-9_]{8,63}$/, database)
  end

  defp isolated_dev_database?(_database), do: false

  defp acquire_locked(path, upstream_base_url, request_compression_mode) do
    case Receipt.read(path) do
      {:ok, %{"state" => "ready", "leases" => leases} = setup}
      when is_integer(leases) and leases > 0 ->
        cond do
          setup["upstream_base_url"] != upstream_base_url ->
            {:error, "OpenAI V1 fixture is leased for another upstream origin"}

          setup["request_compression_mode"] != Atom.to_string(request_compression_mode) ->
            {:error, "OpenAI V1 fixture is leased with another request compression mode"}

          true ->
            updated = Map.put(setup, "leases", leases + 1)
            Receipt.write!(path, updated)
            public_status(updated, path)
        end

      {:ok, _setup} ->
        {:error, "OpenAI V1 fixture receipt requires cleanup before reuse"}

      :missing ->
        provision_new(path, upstream_base_url, request_compression_mode)

      {:error, message} ->
        {:error, message}
    end
  end

  defp provision_new(path, upstream_base_url, request_compression_mode) do
    snapshot = Snapshot.capture()

    Receipt.write!(path, %{
      "version" => 1,
      "state" => "prepared",
      "leases" => 1,
      "upstream_base_url" => upstream_base_url,
      "request_compression_mode" => Atom.to_string(request_compression_mode),
      "receipt" => Receipt.encode_snapshot(snapshot)
    })

    try do
      provisioned = Provisioner.provision!(upstream_base_url, request_compression_mode)
      setup = ready_setup(snapshot, upstream_base_url, request_compression_mode, provisioned)
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
        {:error, "OpenAI V1 fixture receipt has an invalid lease count"}

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
            {:error, "OpenAI V1 fixture provisioning failed and was restored"}

          {:error, _message} ->
            {:error, "OpenAI V1 fixture provisioning failed; cleanup receipt retained"}
        end

      _missing_or_invalid ->
        {:error, "OpenAI V1 fixture provisioning failed without a recoverable receipt"}
    end
  end

  defp restore_setup(%{"receipt" => encoded}) do
    with :ok <- Snapshot.prepare_decode!(),
         {:ok, decoded} <- Receipt.decode_snapshot(encoded),
         {:ok, snapshot} <- Snapshot.parse(decoded),
         {:ok, :ok} <- Repo.transact(fn -> {:ok, Snapshot.restore!(snapshot)} end) do
      :ok
    else
      :error -> {:error, "OpenAI V1 fixture receipt snapshot is invalid"}
      {:error, _reason} -> {:error, "OpenAI V1 fixture snapshot transaction failed"}
    end
  rescue
    error in RuntimeError -> {:error, error.message}
    error -> {:error, "OpenAI V1 fixture restore raised #{inspect(error.__struct__)}"}
  end

  defp restore_setup(_setup), do: {:error, "OpenAI V1 fixture receipt has no snapshot"}

  defp ready_setup(snapshot, upstream_base_url, request_compression_mode, provisioned) do
    %{
      "version" => 1,
      "state" => "ready",
      "leases" => 1,
      "upstream_base_url" => upstream_base_url,
      "request_compression_mode" => Atom.to_string(request_compression_mode),
      "receipt" => Receipt.encode_snapshot(snapshot),
      "created" => %{
        "identity_id" => if(provisioned.identity_created?, do: provisioned.identity_id),
        "pool_id" => if(provisioned.pool_created?, do: provisioned.pool_id),
        "assignment_id" => if(provisioned.assignment_created?, do: provisioned.assignment_id),
        "api_key_id" => provisioned.api_key_id
      },
      "api_key" => provisioned.api_key,
      "pool_id" => provisioned.pool_id,
      "pool_slug" => provisioned.pool_slug,
      "text_model" => provisioned.text_model,
      "audio_model" => provisioned.audio_model,
      "image_model" => provisioned.image_model
    }
  end

  defp public_status(setup, path) do
    with state when is_binary(state) <- setup["state"],
         leases when is_integer(leases) and leases >= 0 <- setup["leases"] do
      {:ok,
       %{status: state, leases: leases, receipt_path: path}
       |> put_optional(:pool_slug, setup["pool_slug"])
       |> put_optional(:text_model, setup["text_model"])
       |> put_optional(:audio_model, setup["audio_model"])
       |> put_optional(:image_model, setup["image_model"])}
    else
      _invalid -> {:error, "OpenAI V1 fixture receipt has an invalid public status"}
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

  defp request_compression_mode(options) do
    case Keyword.get(options, :request_compression, :preserve) do
      mode when mode in [:preserve, :enabled] -> {:ok, mode}
      _mode -> {:error, "request compression mode must be :preserve or :enabled"}
    end
  end

  defp resolved_receipt_path(options) do
    case Keyword.fetch(options, :receipt_path) do
      {:ok, path} when is_binary(path) -> Path.expand(path)
      :error -> receipt_path()
    end
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value) when is_binary(value), do: Map.put(map, key, value)
end
