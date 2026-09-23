defmodule CodexPooler.Platform.Readiness do
  @moduledoc """
  Whether this node can actually serve, as a database fact.

  One query against `schema_migrations` answers two different questions, and
  they are deliberately not treated the same way:

    * Schema state. Every migration version this image carries must be applied.
      A missing or incomplete schema is permanent until an operator acts (a
      replaced or wiped database, a migration job that never ran, a rollback),
      the node cannot serve a single request, and waiting changes nothing, so
      readiness is withdrawn immediately.

    * Connectivity. A dropped connection is usually transient and self-healing,
      and every node sees it at the same instant, so withdrawing readiness on
      the first failure turns a brief blip into a Service with no endpoints at
      all. Once this node has been ready, connectivity failures are tolerated
      for a fixed grace window before readiness is withdrawn. Before the first
      success they are not: a node that has never reached the database has
      never been in the Service, so refusing it costs no endpoints.

  The grace window is a constant rather than an operator control. It describes
  how long a probe is willing to wait for a fact it cannot yet read, and a node
  that cannot read that fact must not be configurable into claiming otherwise.

  A successful probe proves connectivity and schema together, so the schema
  check can never be starved by an unreachable database: an unreachable
  database is classified as connectivity, never as a missing schema.
  """

  use GenServer

  alias CodexPooler.Platform.TransientDatabaseError
  alias CodexPooler.Repo

  # Long enough to ride out a PostgreSQL failover or a connection-pool stall
  # (both commonly 10-30s) without withdrawing every endpoint at once, short
  # enough that a node which is genuinely cut off stops claiming to serve.
  @grace_ms 30_000
  @probe_timeout_ms 1_000

  @migrations_table "schema_migrations"

  @transient_postgres_codes TransientDatabaseError.postgres_codes()

  @ignored_migration_entries [".formatter.exs"]

  @type class :: String.t()
  @type outcome :: :ready | {:ready, :degraded, class()} | {:not_ready, class()}
  @type state :: %{ever_ready?: boolean(), last_success_ms: integer()}

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @impl true
  def init(:ok), do: {:ok, initial_state()}

  @doc """
  Reports whether this node can serve.

  Returns `:ready`, `{:ready, :degraded, class}` when a connectivity failure is
  being tolerated inside the grace window, or `{:not_ready, class}`. The class
  is a bounded, sanitized token derived from an error module name, a PostgreSQL
  error code, or a fixed vocabulary; it never carries a database message.

  `:now_ms` and `:sql_probe` exist so the grace window and the probe outcome can
  be driven directly in tests; callers in the release pass neither.
  """
  @spec check(keyword()) :: outcome()
  def check(opts \\ []) do
    now_ms = Keyword.get(opts, :now_ms, System.monotonic_time(:millisecond))

    case probe(opts) do
      :ok ->
        record_success(now_ms)
        :ready

      {:error, :schema, class} ->
        {:not_ready, class}

      {:error, :connectivity, class} ->
        if within_grace?(now_ms) do
          {:ready, :degraded, class}
        else
          {:not_ready, class}
        end
    end
  end

  @doc """
  The grace window, in milliseconds, that a connectivity failure is tolerated
  for after this node has been ready at least once.
  """
  @spec grace_ms() :: pos_integer()
  def grace_ms, do: @grace_ms

  @doc false
  @spec reset_state!() :: :ok
  def reset_state!, do: GenServer.call(__MODULE__, :reset)

  @impl true
  def handle_call(:reset, _from, _state), do: {:reply, :ok, initial_state()}

  def handle_call({:record_success, now_ms}, _from, state) do
    {:reply, :ok, %{state | ever_ready?: true, last_success_ms: now_ms}}
  end

  def handle_call({:within_grace?, now_ms}, _from, state) do
    within_grace? =
      state.ever_ready? and now_ms - state.last_success_ms <= @grace_ms

    {:reply, within_grace?, state}
  end

  # A node that has never reached the database holds no endpoint, so there is
  # nothing to protect by tolerating its failures.
  defp within_grace?(now_ms) do
    GenServer.call(__MODULE__, {:within_grace?, now_ms})
  end

  defp record_success(now_ms) do
    GenServer.call(__MODULE__, {:record_success, now_ms})
  end

  # Monotonic time is signed and its zero point is arbitrary, so the "has this
  # node ever been ready" fact is explicit rather than encoded as a sentinel.
  defp initial_state, do: %{ever_ready?: false, last_success_ms: 0}

  defp probe(opts) do
    with {:ok, versions} <- expected_versions(opts) do
      {statement, params, required} = probe_statement(versions)

      case sql_probe(opts).query(Repo, statement, params, timeout: @probe_timeout_ms) do
        {:ok, %{rows: [[count]]}} when is_integer(count) and count >= required ->
          :ok

        {:ok, %{rows: [[count]]}} when is_integer(count) ->
          {:error, :schema, "migrations_missing"}

        {:ok, _result} ->
          {:error, :schema, "migrations_unreadable"}

        {:error, reason} ->
          classify(reason)
      end
    end
  rescue
    error in DBConnection.ConnectionError ->
      {:error, :connectivity, reason_class(error)}

    error in DBConnection.EncodeError ->
      {:error, :schema, reason_class(error)}
  end

  # Applied versions this image does not know about are a newer release's
  # migrations, which are normal mid-rollout and must not unready the pods that
  # are still serving the old one, so the check is containment, not equality.
  defp probe_statement(versions) do
    {"SELECT count(*) FROM #{@migrations_table} WHERE version = ANY($1)", [versions], length(versions)}
  end

  defp classify(%DBConnection.ConnectionError{} = reason),
    do: {:error, :connectivity, reason_class(reason)}

  defp classify(%Postgrex.Error{postgres: %{code: code}})
       when code in @transient_postgres_codes,
       do: {:error, :connectivity, Atom.to_string(code)}

  defp classify(%Postgrex.Error{postgres: %{code: code}}) when is_atom(code),
    do: {:error, :schema, Atom.to_string(code)}

  defp classify(reason), do: {:error, :schema, reason_class(reason)}

  @doc """
  A bounded, sanitized token naming the kind of failure.

  Exception structs collapse to their module name and tagged reasons to their
  tag; database messages, which can quote statements and parameters, never
  reach a log line through this.
  """
  @spec reason_class(term()) :: class()
  def reason_class(%module{}) when is_atom(module), do: inspect(module)
  def reason_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  def reason_class({reason, _details}) when is_atom(reason), do: Atom.to_string(reason)
  def reason_class(_reason), do: "unknown"

  defp sql_probe(opts) do
    Keyword.get_lazy(opts, :sql_probe, fn ->
      :codex_pooler
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:sql_probe, Ecto.Adapters.SQL)
    end)
  end

  defp expected_versions(opts) do
    opts
    |> migrations_path()
    |> read_expected_versions()
  end

  defp migrations_path(opts) do
    Keyword.get_lazy(opts, :migrations_path, fn ->
      :codex_pooler
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get_lazy(:migrations_path, fn -> Ecto.Migrator.migrations_path(Repo) end)
    end)
  end

  defp read_expected_versions(path) when is_binary(path) do
    case File.ls(path) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&(&1 in @ignored_migration_entries))
        |> Enum.filter(&String.ends_with?(&1, ".exs"))
        |> parse_migration_versions()

      {:error, _reason} ->
        {:error, :schema, "migration_directory_unreadable"}
    end
  end

  defp read_expected_versions(_path),
    do: {:error, :schema, "migration_directory_invalid"}

  defp parse_migration_versions([]),
    do: {:error, :schema, "migration_files_missing"}

  defp parse_migration_versions(entries) do
    with {:ok, versions} <- Enum.reduce_while(entries, {:ok, []}, &parse_migration_version/2),
         true <- Enum.uniq(versions) == versions do
      {:ok, Enum.sort(versions)}
    else
      false -> {:error, :schema, "migration_files_malformed"}
      {:error, :malformed} -> {:error, :schema, "migration_files_malformed"}
    end
  end

  defp parse_migration_version(entry, {:ok, versions}) do
    case Regex.run(~r/\A(\d+)_.+\.exs\z/, entry, capture: :all_but_first) do
      [version] -> {:cont, {:ok, [String.to_integer(version) | versions]}}
      _other -> {:halt, {:error, :malformed}}
    end
  end
end
