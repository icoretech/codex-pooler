defmodule CodexPooler.Dev.CodexCompactionSmokeFixture do
  @moduledoc """
  Run-scoped local fixture for released Codex same-turn automatic compaction.
  """

  import Ecto.Query

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Dev.CodexCompactionSmokeFixture.{Journal, Provisioner}
  alias CodexPooler.Gateway.Persistence.{BridgeOwnerLease, CodexSession, CodexTurn}
  alias CodexPooler.Pools.{ModelServingOverride, Pool}
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.{EncryptedSecret, PoolUpstreamAssignment, UpstreamIdentity}

  @default_root Path.join(["tmp", "codex-compaction-smoke"])
  @run_id_pattern ~r/\A[a-z0-9][a-z0-9-]{0,79}\z/

  @type options :: keyword()

  @spec parse_args([String.t()]) :: {:ok, atom(), options()} | {:error, String.t()}
  def parse_args(args) do
    case OptionParser.parse(args,
           strict: [
             run_id: :string,
             upstream_base_url: :string,
             serving_mode: :string,
             upstream_frame_count: :integer,
             duplicate_error_count: :integer
           ]
         ) do
      {options, ["acquire"], []} ->
        validate_args(:acquire, options)

      {options, ["status"], []} ->
        validate_args(:status, options)

      {options, ["release"], []} ->
        validate_args(:release, options)

      {options, ["receipt"], []} ->
        validate_args(:receipt, options)

      {options, ["cache-receipt"], []} ->
        validate_args(:cache_receipt, options)

      _invalid ->
        {:error,
         "use acquire --run-id RUN_ID --upstream-base-url ORIGIN [--serving-mode full|lite], status/release --run-id RUN_ID, receipt --run-id RUN_ID --upstream-frame-count N --duplicate-error-count N, or cache-receipt --run-id RUN_ID"}
    end
  end

  @spec acquire(options()) :: {:ok, map()} | {:error, String.t()}
  def acquire(options) do
    with :ok <- validate_environment(options),
         {:ok, run_id} <- fetch_run_id(options),
         {:ok, origin} <- fetch_origin(options) do
      paths = paths(options, run_id)

      case Journal.read_journal(paths, run_id) do
        {:ok, _journal} -> {:error, "fixture journal requires release before acquire"}
        {:error, :missing} -> provision(paths, run_id, origin, options)
        {:error, _reason} -> {:error, "fixture journal is unsafe or invalid"}
      end
    end
  end

  @spec status(options()) :: {:ok, map()} | {:error, String.t()}
  def status(options) do
    with {:ok, run_id} <- fetch_run_id(options) do
      paths = paths(options, run_id)

      case Journal.read_journal(paths, run_id) do
        {:ok, journal} -> {:ok, public_status(journal)}
        {:error, :missing} -> {:ok, %{status: "absent", run_id: run_id}}
        {:error, _reason} -> {:error, "fixture journal is unsafe or invalid"}
      end
    end
  end

  @spec release(options()) :: {:ok, map()} | {:error, String.t()}
  def release(options) do
    with :ok <- validate_environment(options),
         {:ok, run_id} <- fetch_run_id(options) do
      paths = paths(options, run_id)

      case Journal.read_journal(paths, run_id) do
        {:ok, journal} -> cleanup(paths, journal)
        {:error, :missing} -> {:ok, %{status: "absent", run_id: run_id}}
        {:error, _reason} -> {:error, "fixture journal is unsafe or invalid"}
      end
    end
  end

  @spec receipt(options()) :: {:ok, map()} | {:error, String.t()}
  def receipt(options) do
    with :ok <- validate_environment(options),
         {:ok, run_id} <- fetch_run_id(options),
         {:ok, journal} <- read_ready_journal(options, run_id) do
      request_query = from request in Request, where: request.pool_id == ^journal["pool_id"]
      request_ids = Repo.all(from request in request_query, select: request.id)

      turns =
        Repo.all(
          from turn in CodexTurn,
            where: turn.request_id in ^request_ids,
            order_by: [asc: turn.turn_sequence],
            select: {turn.request_id, turn.codex_session_id, turn.turn_sequence}
        )

      correlations =
        Repo.all(
          from request in request_query,
            join: turn in CodexTurn,
            on: turn.request_id == request.id,
            order_by: [asc: turn.turn_sequence],
            select: request.correlation_id
        )

      {:ok,
       %{
         status: "closed",
         request_count: length(request_ids),
         attempt_count:
           Repo.aggregate(
             from(attempt in Attempt, where: attempt.request_id in ^request_ids),
             :count
           ),
         codex_turn_count: length(turns),
         settlement_count:
           Repo.aggregate(
             from(entry in LedgerEntry,
               where: entry.request_id in ^request_ids and entry.entry_kind == "settlement"
             ),
             :count
           ),
         turn_sequences: Enum.map(turns, &elem(&1, 2)),
         upstream_frame_count: Keyword.fetch!(options, :upstream_frame_count),
         duplicate_error_count: Keyword.fetch!(options, :duplicate_error_count),
         logical_turn_fingerprints:
           turns |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.map(&fingerprint/1),
         request_fingerprints: Enum.map(correlations, &fingerprint/1)
       }}
    end
  end

  @doc """
  Metadata-only per-request cache-fidelity projection for the websocket to
  client-authored HTTP SSE fallback certification (issue 371 / findings 116 T12).

  This is additive to `receipt/1` and intentionally reports the per-generation
  transport, usage status, and NULL-preserving ledger token facts the exact
  client cache-metadata receipt binds. It never persists new production
  metadata: `provider_cached_field_present` / `parser_cached_field_present`
  are derived by the harness receipt, not here. Cached input tokens stay
  three-valued (NULL when the provider omitted the field, 0 when present and
  zero) exactly as the ledger records them.
  """
  @spec cache_receipt(options()) :: {:ok, map()} | {:error, String.t()}
  def cache_receipt(options) do
    with :ok <- validate_environment(options),
         {:ok, run_id} <- fetch_run_id(options),
         {:ok, journal} <- read_ready_journal(options, run_id) do
      pool_id = journal["pool_id"]

      generations =
        Repo.all(
          from request in Request,
            left_join: turn in CodexTurn,
            on: turn.request_id == request.id,
            where: request.pool_id == ^pool_id,
            order_by: [asc: request.admitted_at],
            select: %{
              request_id: request.id,
              requested_model: request.requested_model,
              transport: request.transport,
              status: request.status,
              usage_status: request.usage_status,
              codex_session_id: turn.codex_session_id,
              turn_sequence: turn.turn_sequence
            }
        )
        |> Enum.map(&cache_receipt_generation/1)

      {:ok,
       %{
         status: "closed",
         fidelity_scope: "metadata_fidelity_websocket_to_http_sse_fallback",
         provider_cache_allocation_claimed: false,
         generation_count: length(generations),
         generations: generations
       }}
    end
  end

  defp cache_receipt_generation(row) do
    settlement =
      Repo.one(
        from entry in LedgerEntry,
          where: entry.request_id == ^row.request_id and entry.entry_kind == "settlement",
          order_by: [desc: entry.id],
          limit: 1,
          select: %{
            input_tokens: entry.input_tokens,
            cached_input_tokens: entry.cached_input_tokens,
            output_tokens: entry.output_tokens,
            total_tokens: entry.total_tokens,
            usage_status: entry.usage_status
          }
      )

    attempt =
      Repo.one(
        from attempt in Attempt,
          where: attempt.request_id == ^row.request_id,
          order_by: [desc: attempt.attempt_number],
          limit: 1,
          select: %{
            transport: attempt.transport,
            status: attempt.status,
            usage_status: attempt.usage_status,
            pool_upstream_assignment_id: attempt.pool_upstream_assignment_id,
            upstream_model_id: attempt.upstream_model_id,
            response_metadata: attempt.response_metadata
          }
      )

    %{
      transport: row.transport,
      status: row.status,
      usage_status: row.usage_status,
      turn_sequence: row.turn_sequence,
      requested_model: row.requested_model,
      upstream_model: attempt && attempt.upstream_model_id,
      attempt_transport: attempt && attempt.transport,
      attempt_status: attempt && attempt.status,
      pool_upstream_assignment_id: attempt && fingerprint(attempt.pool_upstream_assignment_id),
      codex_session_fingerprint: fingerprint(row.codex_session_id),
      usage_observation_classification: usage_observation_classification(attempt),
      # NULL-preserving: nil means the provider omitted the field entirely,
      # 0 means it was present and zero. Never coalesce one into the other.
      ledger_input_tokens: settlement && settlement.input_tokens,
      ledger_cached_input_tokens: settlement && settlement.cached_input_tokens,
      ledger_cached_input_tokens_present:
        not is_nil(settlement) and not is_nil(settlement.cached_input_tokens),
      ledger_output_tokens: settlement && settlement.output_tokens,
      ledger_total_tokens: settlement && settlement.total_tokens,
      settlement_present: not is_nil(settlement)
    }
  end

  defp usage_observation_classification(nil), do: nil

  defp usage_observation_classification(%{response_metadata: metadata}) when is_map(metadata) do
    get_in(metadata, ["usage_observation", "classification"])
  end

  defp usage_observation_classification(_attempt), do: nil

  @spec with_isolated_config(String.t(), (String.t() -> result)) :: result when result: var
  def with_isolated_config(run_id, function) when is_function(function, 1) do
    previous = %{
      endpoint: Application.get_env(:codex_pooler, CodexPoolerWeb.Endpoint),
      oban: Application.get_env(:codex_pooler, Oban),
      repo: Application.get_env(:codex_pooler, Repo)
    }

    application_name = "codex_compaction_smoke_#{run_id}"
    endpoint = previous.endpoint |> Keyword.put(:server, false) |> Keyword.put(:watchers, [])
    oban = previous.oban |> Keyword.put(:queues, false) |> Keyword.put(:plugins, false)

    parameters =
      previous.repo
      |> Keyword.get(:parameters, [])
      |> Keyword.put(:application_name, application_name)

    repo = Keyword.put(previous.repo, :parameters, parameters)

    Application.put_env(:codex_pooler, CodexPoolerWeb.Endpoint, endpoint)
    Application.put_env(:codex_pooler, Oban, oban)
    Application.put_env(:codex_pooler, Repo, repo)

    try do
      function.(application_name)
    after
      Application.put_env(:codex_pooler, CodexPoolerWeb.Endpoint, previous.endpoint)
      Application.put_env(:codex_pooler, Oban, previous.oban)
      Application.put_env(:codex_pooler, Repo, previous.repo)
    end
  end

  defp provision(paths, run_id, origin, options) do
    journal = Journal.prepared(run_id)
    :ok = Journal.write_journal(paths, journal)

    persist_journal = fn updated ->
      :ok = Journal.write_journal(paths, updated)
      updated
    end

    provisioned =
      Provisioner.provision!(run_id, origin, journal, persist_journal,
        interrupt_after: Keyword.get(options, :interrupt_after),
        serving_mode: Keyword.get(options, :serving_mode)
      )

    journal = Map.put(provisioned.journal, "state", "prepared")
    :ok = Journal.write_journal(paths, journal)

    secret =
      Journal.secret(
        run_id,
        provisioned.raw_key,
        provisioned.api_key.id,
        provisioned.pool.id,
        Provisioner.model()
      )

    :ok = Journal.write_secret(paths, secret)

    if Keyword.get(options, :interrupt_after) == :provision do
      {:error, "fixture interrupted after provisioning"}
    else
      ready = Journal.ready(journal)
      :ok = Journal.write_journal(paths, ready)
      {:ok, public_status(ready)}
    end
  rescue
    _exception -> {:error, "fixture provisioning failed; release the retained journal"}
  end

  defp cleanup(paths, journal) do
    Provisioner.cleanup!(journal)
    cancel_pending_reconciliation(journal)
    require_postconditions(journal)
    Journal.remove_secret(paths)
    Journal.remove_all(paths)
    {:ok, %{status: "released", run_id: journal["run_id"]}}
  rescue
    _exception -> {:error, "fixture cleanup incomplete; metadata journal retained"}
  end

  defp cancel_pending_reconciliation(%{
         "pool_id" => pool_id,
         "assignment_id" => assignment_id,
         "identity_id" => identity_id
       })
       when is_binary(pool_id) and is_binary(assignment_id) and is_binary(identity_id) do
    {:ok, _count} =
      Oban.cancel_all_jobs(
        from job in Oban.Job,
          where: job.worker == "CodexPooler.Jobs.AccountReconciliationWorker",
          where: job.args["pool_id"] == ^pool_id,
          where: job.args["pool_upstream_assignment_id"] == ^assignment_id,
          where: job.args["upstream_identity_id"] == ^identity_id,
          where: job.state in ["available", "scheduled", "retryable"]
      )

    :ok
  end

  defp cancel_pending_reconciliation(_journal), do: :ok

  defp require_postconditions(journal) do
    pool_id = journal["pool_id"]
    run_id = journal["run_id"]

    active_jobs =
      Repo.aggregate(
        from(job in Oban.Job,
          where:
            fragment("?::text", job.args) |> ilike(^"%#{run_id}%") or
              fragment("?::text", job.args) |> ilike(^"%#{pool_id}%"),
          where: job.state in ["available", "scheduled", "executing", "retryable"]
        ),
        :count
      )

    if active_jobs != 0 or active_resources?(journal),
      do: raise("run-owned resource remained active")

    :ok
  end

  defp active_resources?(journal) do
    Enum.any?([
      pool_active?(journal["pool_id"]),
      api_key_active?(journal["api_key_id"]),
      model_active?(journal["model_id"]),
      assignment_active?(journal["assignment_id"]),
      identity_active?(journal["identity_id"]),
      identity_secret_active?(journal["identity_id"]),
      serving_override_active?(journal["pool_id"]),
      owner_lease_active?(journal["pool_id"]),
      session_active?(journal["pool_id"]),
      turn_active?(journal["pool_id"])
    ])
  end

  defp pool_active?(nil), do: false

  defp pool_active?(pool_id),
    do: match?(%Pool{status: status} when status != "archived", Repo.get(Pool, pool_id))

  defp api_key_active?(nil), do: false

  defp api_key_active?(api_key_id),
    do: match?(%APIKey{status: status} when status != "revoked", Repo.get(APIKey, api_key_id))

  defp model_active?(nil), do: false

  defp model_active?(model_id),
    do: match?(%Model{status: status} when status != "retired", Repo.get(Model, model_id))

  defp assignment_active?(nil), do: false

  defp assignment_active?(assignment_id),
    do:
      match?(
        %PoolUpstreamAssignment{status: status} when status != "deleted",
        Repo.get(PoolUpstreamAssignment, assignment_id)
      )

  defp identity_active?(nil), do: false

  defp identity_active?(identity_id),
    do:
      match?(
        %UpstreamIdentity{status: status} when status != "disabled",
        Repo.get(UpstreamIdentity, identity_id)
      )

  defp identity_secret_active?(nil), do: false

  defp identity_secret_active?(identity_id),
    do:
      Repo.exists?(
        from secret in EncryptedSecret, where: secret.upstream_identity_id == ^identity_id
      )

  defp serving_override_active?(nil), do: false

  defp serving_override_active?(pool_id),
    do: Repo.exists?(from override in ModelServingOverride, where: override.pool_id == ^pool_id)

  defp owner_lease_active?(nil), do: false

  defp owner_lease_active?(pool_id),
    do:
      Repo.exists?(
        from lease in BridgeOwnerLease,
          where: lease.pool_id == ^pool_id and lease.status == "active"
      )

  defp session_active?(nil), do: false

  defp session_active?(pool_id),
    do:
      Repo.exists?(
        from session in CodexSession,
          where: session.pool_id == ^pool_id and session.status == "active"
      )

  defp turn_active?(nil), do: false

  defp turn_active?(pool_id),
    do:
      Repo.exists?(
        from turn in CodexTurn,
          join: session in CodexSession,
          on: session.id == turn.codex_session_id,
          where: session.pool_id == ^pool_id and turn.status == "in_progress"
      )

  defp public_status(journal) do
    %{
      status: journal["state"],
      run_id: journal["run_id"],
      pool_id: journal["pool_id"],
      identity_id: journal["identity_id"],
      assignment_id: journal["assignment_id"],
      model: Provisioner.model()
    }
  end

  defp validate_args(action, options) do
    with {:ok, run_id} <- fetch_run_id(options),
         :ok <- exact_option_keys(action, options),
         :ok <- maybe_validate_origin(action, options) do
      {:ok, action, Keyword.put(options, :run_id, run_id)}
    end
  end

  defp exact_option_keys(:acquire, options) do
    keys = Enum.sort(Keyword.keys(options))
    serving_mode = Keyword.get(options, :serving_mode)

    cond do
      keys not in [[:run_id, :upstream_base_url], [:run_id, :serving_mode, :upstream_base_url]] ->
        {:error, "acquire requires exact options"}

      not is_nil(serving_mode) and serving_mode not in ["full", "lite"] ->
        {:error, "serving mode must be full or lite"}

      true ->
        :ok
    end
  end

  defp exact_option_keys(:cache_receipt, options) do
    if Keyword.keys(options) == [:run_id],
      do: :ok,
      else: {:error, "cache-receipt accepts only --run-id"}
  end

  defp exact_option_keys(:receipt, options) do
    expected = [:duplicate_error_count, :run_id, :upstream_frame_count]

    if Enum.sort(Keyword.keys(options)) == expected and
         non_negative_integer?(options[:upstream_frame_count]) and
         non_negative_integer?(options[:duplicate_error_count]),
       do: :ok,
       else: {:error, "receipt requires exact non-negative count options"}
  end

  defp exact_option_keys(_action, options) do
    if Keyword.keys(options) == [:run_id],
      do: :ok,
      else: {:error, "status and release accept only --run-id"}
  end

  defp maybe_validate_origin(:acquire, options),
    do:
      fetch_origin(options)
      |> elem(0)
      |> then(&if &1 == :ok, do: :ok, else: {:error, "invalid upstream origin"})

  defp maybe_validate_origin(_action, _options), do: :ok

  defp read_ready_journal(options, run_id) do
    case Journal.read_journal(paths(options, run_id), run_id) do
      {:ok, %{"state" => "ready"} = journal} -> {:ok, journal}
      {:ok, _journal} -> {:error, "fixture is not ready"}
      {:error, _reason} -> {:error, "fixture journal is unsafe or invalid"}
    end
  end

  defp fingerprint(value) when is_binary(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp non_negative_integer?(value), do: is_integer(value) and value >= 0

  defp fetch_run_id(options) do
    case Keyword.get(options, :run_id) do
      run_id when is_binary(run_id) ->
        if Regex.match?(@run_id_pattern, run_id),
          do: {:ok, run_id},
          else: {:error, "invalid run id"}

      _other ->
        {:error, "--run-id is required"}
    end
  end

  defp fetch_origin(options) do
    value = Keyword.get(options, :upstream_base_url)
    uri = if is_binary(value), do: URI.parse(value), else: %URI{}

    if uri.scheme == "http" and uri.host in ["127.0.0.1", "localhost", "::1"] and
         is_integer(uri.port) and uri.path in [nil, "", "/"] and is_nil(uri.query) and
         is_nil(uri.fragment) and is_nil(uri.userinfo) do
      {:ok, String.trim_trailing(value, "/")}
    else
      {:error, "upstream base URL must be an origin-only loopback HTTP URL"}
    end
  end

  defp validate_environment(options) do
    environment = Keyword.get(options, :environment, Mix.env())
    allow_test? = Keyword.get(options, :allow_test_database, false)

    if environment == :dev or (environment == :test and allow_test?),
      do: :ok,
      else: {:error, "fixture runs only with MIX_ENV=dev"}
  end

  defp paths(options, run_id) do
    parent = Keyword.get(options, :root, Path.expand(@default_root, File.cwd!()))
    Journal.paths(parent, run_id)
  end
end
