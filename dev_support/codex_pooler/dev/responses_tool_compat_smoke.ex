defmodule CodexPooler.Dev.ResponsesToolCompatSmoke do
  @moduledoc """
  Fail-closed localhost certification runner for Responses executable tools.

  This module is compiled only in development and test. Persistent resource
  ownership is carried by an fsync-backed private journal; public receipts are
  generated from a fixed metadata-only projection.
  """

  import Ecto.Query

  alias CodexPooler.Access
  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.Access.APIKeys.TouchDebounce
  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.Catalog
  alias CodexPooler.Catalog.{Model, SyncRun}
  alias CodexPooler.Gateway.OpenAICompatibility.Responses.SSE, as: ResponsesSSE

  alias CodexPooler.Gateway.Persistence.{
    BridgeOwnerLease,
    BridgeSessionAlias,
    CodexSession
  }

  alias CodexPooler.Gateway.Transports.Websocket.RolloutDrain
  alias CodexPooler.Pools
  alias CodexPooler.Pools.{ModelServingMode, ModelServingOverride, Pool}
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @root Path.join(["tmp", "issue-241"])
  @runtime_root Path.join(@root, "runtime")
  @receipt_root Path.join(@root, "receipts")
  @manifest_name "manifest.json"
  @catalog_worker "Elixir.CodexPooler.Jobs.CatalogSyncWorker"
  @identity_count 3
  @run_id_pattern ~r/\A[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}\z/
  @identity_label_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,79}\z/
  @connection_keys [
    :after_connect,
    :connect_timeout,
    :database,
    :hostname,
    :password,
    :parameters,
    :port,
    :socket_dir,
    :socket_options,
    :ssl,
    :ssl_opts,
    :timeout,
    :types,
    :url,
    :username
  ]
  @receipt_keys ~w(
    run_id source_sha diff_fingerprint model_ids cells status_counts fixture_hashes
    started_at finished_at certification_status cleanup_status quiescence module_digests
  )

  @type mode :: :provision | :cleanup | :resolve_owner
  @type command :: %{
          required(:mode) => mode(),
          optional(:base_url) => URI.t(),
          optional(:owner_id) => Ecto.UUID.t(),
          optional(:identity_labels) => [String.t()],
          optional(:dry_run?) => boolean(),
          optional(:cleanup_run_id) => String.t()
        }
  @type inspection :: %{
          required(:owners) => [Ecto.UUID.t()],
          required(:identities) => [%{id: Ecto.UUID.t(), label: String.t(), status: String.t()}],
          required(:other_client_application_names) => [String.t()]
        }
  @type journal :: map()

  @spec parse_args([String.t()]) :: {:ok, command()} | {:error, String.t()}
  def parse_args(args) when is_list(args) do
    {options, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          base_url: :string,
          owner_id: :string,
          identity_label: :keep,
          dry_run: :boolean,
          cleanup_run_id: :string,
          resolve_owner_id: :boolean
        ]
      )

    with :ok <- reject_parser_remainders(positional, invalid),
         {:ok, mode} <- select_mode(options),
         {:ok, command} <- validate_mode(mode, options) do
      {:ok, command}
    end
  end

  @spec execute(command(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(command, opts \\ []) when is_map(command) and is_list(opts) do
    case command.mode do
      :resolve_owner -> resolve_owner_id(opts)
      :cleanup -> cleanup(command, opts)
      :provision when command.dry_run? -> dry_run(command, opts)
      :provision -> provision_and_certify(command, opts)
    end
  rescue
    exception -> {:error, sanitized_exception(exception)}
  catch
    :exit, reason -> {:error, "certification process exited: #{safe_reason(reason)}"}
  end

  @doc false
  @spec new_journal(String.t(), Ecto.UUID.t(), [String.t()]) :: journal()
  def new_journal(run_id, owner_id, identity_labels) do
    %{
      "version" => 1,
      "run_id" => run_id,
      "owner_user_id" => owner_id,
      "identity_labels" => identity_labels,
      "pool_slugs" => pool_slugs(run_id),
      "resources" => [],
      "operations" => [],
      "certification_status" => "pending",
      "cleanup_status" => "pending"
    }
  end

  @doc false
  @spec append_operation(journal(), String.t(), String.t(), map()) :: journal()
  def append_operation(journal, phase, kind, fields \\ %{}) do
    operation =
      fields
      |> stringify_keys()
      |> Map.merge(%{
        "phase" => phase,
        "kind" => kind,
        "sequence" => length(journal["operations"]) + 1
      })

    Map.update!(journal, "operations", &(&1 ++ [operation]))
  end

  @doc false
  @spec record_resource(journal(), String.t(), Ecto.UUID.t(), map()) :: journal()
  def record_resource(journal, kind, id, fields \\ %{}) do
    resource = fields |> stringify_keys() |> Map.merge(%{"kind" => kind, "id" => id})
    Map.update!(journal, "resources", &(&1 ++ [resource]))
  end

  @doc false
  @spec write_journal!(String.t(), journal()) :: :ok
  def write_journal!(run_dir, journal) do
    ensure_private_directory!(run_dir)
    atomic_write!(Path.join(run_dir, @manifest_name), canonical_json(journal), 0o600)
  end

  @doc false
  @spec read_journal(String.t()) :: {:ok, journal()} | {:error, String.t()}
  def read_journal(run_id) do
    with :ok <- validate_run_id(run_id),
         run_dir <- run_dir(run_id),
         :ok <- require_private_directory(run_dir),
         path <- Path.join(run_dir, @manifest_name),
         :ok <- require_regular_file(path),
         {:ok, content} <- File.read(path),
         {:ok, journal} when is_map(journal) <- Jason.decode(content),
         ^run_id <- journal["run_id"],
         :ok <- validate_journal_targets(journal) do
      {:ok, journal}
    else
      {:error, %Jason.DecodeError{}} -> {:error, "run manifest is invalid"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, _reason} -> {:error, "run manifest could not be read"}
      _other -> {:error, "run manifest does not own the requested run id"}
    end
  end

  @doc false
  @spec validate_journal_targets(journal()) :: :ok | {:error, String.t()}
  def validate_journal_targets(%{"run_id" => run_id, "pool_slugs" => slugs})
      when is_binary(run_id) and is_list(slugs) do
    if slugs == pool_slugs(run_id),
      do: :ok,
      else: {:error, "run manifest contains non-deterministic Pool targets"}
  end

  def validate_journal_targets(_journal),
    do: {:error, "run manifest contains non-deterministic Pool targets"}

  @doc false
  @spec publish_receipt!(map()) :: String.t()
  def publish_receipt!(receipt) when is_map(receipt) do
    receipt = receipt |> stringify_keys() |> Map.take(@receipt_keys)
    run_id = Map.fetch!(receipt, "run_id")
    :ok = validate_run_id(run_id)
    ensure_private_directory!(@receipt_root)
    path = Path.join(@receipt_root, "#{run_id}.json")
    atomic_write!(path, canonical_json(receipt), 0o600)
    path
  end

  @doc false
  @spec validate_receipt(map()) :: :ok | {:error, String.t()}
  def validate_receipt(receipt) when is_map(receipt) do
    keys = receipt |> stringify_keys() |> Map.keys()

    if Enum.all?(keys, &(&1 in @receipt_keys)) do
      :ok
    else
      {:error, "receipt contains a field outside the metadata allowlist"}
    end
  end

  @doc false
  @spec exact_cleanup_plan(journal()) :: [map()]
  def exact_cleanup_plan(journal) do
    resources = journal["resources"] || []

    order = %{
      "serving_override" => 1,
      "assignment" => 2,
      "api_key" => 3,
      "model" => 4,
      "pool" => 5
    }

    resources
    |> Enum.filter(&(is_binary(&1["id"]) and Map.has_key?(order, &1["kind"])))
    |> Enum.uniq_by(&{&1["kind"], &1["id"]})
    |> Enum.sort_by(&{Map.fetch!(order, &1["kind"]), &1["id"]})
  end

  defp select_mode(options) do
    cleanup? = Keyword.has_key?(options, :cleanup_run_id)
    resolve? = Keyword.get(options, :resolve_owner_id, false)

    case {cleanup?, resolve?} do
      {true, true} -> {:error, "cleanup and owner resolution modes are mutually exclusive"}
      {true, false} -> {:ok, :cleanup}
      {false, true} -> {:ok, :resolve_owner}
      {false, false} -> {:ok, :provision}
    end
  end

  defp validate_mode(:resolve_owner, options) do
    if options == [resolve_owner_id: true] do
      {:ok, %{mode: :resolve_owner}}
    else
      {:error, "--resolve-owner-id must be used alone"}
    end
  end

  defp validate_mode(:cleanup, options) do
    allowed = [:cleanup_run_id, :owner_id]

    with :ok <- reject_duplicate_options(options, allowed),
         [] <- Enum.uniq(Keyword.keys(options)) -- allowed,
         {:ok, owner_id} <- required_uuid(options, :owner_id),
         run_id when is_binary(run_id) <- Keyword.get(options, :cleanup_run_id),
         :ok <- validate_run_id(run_id) do
      {:ok, %{mode: :cleanup, owner_id: owner_id, cleanup_run_id: run_id}}
    else
      [_ | _] -> {:error, "cleanup accepts only --cleanup-run-id and --owner-id"}
      nil -> {:error, "--cleanup-run-id is required"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_mode(:provision, options) do
    allowed = [:base_url, :owner_id, :identity_label, :dry_run]

    with :ok <- reject_duplicate_options(options, [:base_url, :owner_id, :dry_run]),
         [] <- Enum.uniq(Keyword.keys(options)) -- allowed,
         {:ok, owner_id} <- required_uuid(options, :owner_id),
         {:ok, base_url} <- loopback_url(Keyword.get(options, :base_url)),
         {:ok, labels} <- identity_labels(Keyword.get_values(options, :identity_label)) do
      {:ok,
       %{
         mode: :provision,
         owner_id: owner_id,
         base_url: base_url,
         identity_labels: labels,
         dry_run?: Keyword.get(options, :dry_run, false)
       }}
    else
      [_ | _] -> {:error, "provisioning contains an option that is not allowed"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reject_parser_remainders([], []), do: :ok

  defp reject_parser_remainders(_positional, _invalid),
    do: {:error, "unknown or positional arguments are not allowed"}

  defp reject_duplicate_options(options, singleton_keys) do
    if Enum.any?(singleton_keys, &(length(Keyword.get_values(options, &1)) > 1)) do
      {:error, "an option that accepts one value was supplied more than once"}
    else
      :ok
    end
  end

  defp required_uuid(options, key) do
    case Keyword.get(options, key) do
      nil -> {:error, "--#{key |> Atom.to_string() |> String.replace("_", "-")} is required"}
      value -> normalize_uuid(value)
    end
  end

  defp normalize_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, "owner id must be a UUID"}
    end
  end

  defp normalize_uuid(_value), do: {:error, "owner id must be a UUID"}

  defp identity_labels(labels) when length(labels) == @identity_count do
    cond do
      Enum.any?(labels, &(not Regex.match?(@identity_label_pattern, &1))) ->
        {:error, "identity labels must be bounded safe tokens"}

      length(Enum.uniq(labels)) != @identity_count ->
        {:error, "identity labels must be distinct"}

      true ->
        {:ok, labels}
    end
  end

  defp identity_labels(_labels),
    do: {:error, "exactly three --identity-label values are required"}

  defp loopback_url(nil), do: {:error, "--base-url is required"}

  defp loopback_url(value) when is_binary(value) do
    uri = URI.parse(value)

    if uri.scheme == "http" and uri.host in ["localhost", "127.0.0.1", "::1"] and
         uri.path in [nil, ""] and is_nil(uri.query) and is_nil(uri.fragment) and
         is_nil(uri.userinfo) do
      {:ok, %{uri | port: uri.port || 80}}
    else
      {:error, "base URL must be an origin-only HTTP loopback URL"}
    end
  end

  defp validate_run_id(run_id) when is_binary(run_id) do
    if Regex.match?(@run_id_pattern, run_id), do: :ok, else: {:error, "run id is invalid"}
  end

  defp validate_run_id(_run_id), do: {:error, "run id is invalid"}

  defp resolve_owner_id(opts) do
    with_inspection(opts, fn inspection ->
      case inspection.owners do
        [owner_id] -> {:ok, owner_id}
        [] -> {:error, "exactly one active instance owner is required; found zero"}
        _owners -> {:error, "exactly one active instance owner is required; found multiple"}
      end
    end)
  end

  defp dry_run(command, opts) do
    with :ok <- server_preflight(command.base_url, opts),
         {:ok, result} <-
           with_inspection(opts, fn inspection ->
             validate_dry_run_inspection(command, inspection)
           end) do
      {:ok, result}
    end
  end

  defp validate_dry_run_inspection(command, inspection) do
    with :ok <- require_exclusive_inspection(inspection),
         :ok <- require_owner(command.owner_id, inspection),
         :ok <- require_identities(command.identity_labels, inspection) do
      {:ok, "dry-run passed: localhost, sole owner, three distinct active identities, no writes"}
    end
  end

  defp provision_and_certify(command, opts) do
    run_id = generate_run_id()
    run_dir = run_dir(run_id)
    journal = new_journal(run_id, command.owner_id, command.identity_labels)

    with :ok <- reject_run_collision(run_id),
         :ok <- require_no_incomplete_manifests(),
         :ok <- server_preflight(command.base_url, opts),
         :ok <- write_journal!(run_dir, journal),
         {:ok, result} <- run_owned_application(command, journal, run_dir, opts) do
      {:ok, result}
    else
      {:error, reason} = error ->
        publish_failure_receipt_unless_exists(run_id, reason)
        error
    end
  end

  defp run_owned_application(command, journal, run_dir, opts) do
    provenance = source_provenance()

    with_inspector(opts, fn inspector ->
      with :ok <- acquire_lock(inspector),
           :ok <- require_exclusive_database(inspector, nil),
           {:ok, restore} <- start_isolated_application(inspector, command.base_url),
           :ok <- require_owned_server_ready(command.base_url) do
        application_result =
          try do
            with :ok <- require_exclusive_database(inspector, restore.application_name),
                 {:ok, owner_scope} <- exact_owner_scope(command.owner_id),
                 {:ok, identities} <- exact_identities(command.identity_labels),
                 {:ok, journal, fixtures} <-
                   provision_resources(owner_scope, identities, journal, run_dir),
                 {:ok, matrix} <-
                   run_matrix(
                     command.base_url,
                     owner_scope,
                     journal,
                     fixtures,
                     run_dir,
                     Keyword.merge(opts,
                       inspector: inspector,
                       application_name: restore.application_name
                     )
                   ),
                 :ok <- final_quiescence(),
                 :ok <- require_exclusive_database(inspector, restore.application_name),
                 {:ok, latest_journal} <- read_journal(journal["run_id"]),
                 {:ok, journal} <- cleanup_resources(owner_scope, latest_journal, run_dir),
                 :ok <- stable_cleanup_projection(journal) do
              {:ok, journal, matrix}
            else
              {:error, reason} ->
                recover_after_failure(command.owner_id, journal, run_dir, reason)
            end
          after
            Application.stop(:codex_pooler)
            restore_configuration(restore)
          end

        try do
          finalize_application_result(application_result, inspector, run_dir, provenance)
        after
          release_lock(inspector)
        end
      end
    end)
  end

  defp provision_resources(scope, identities, journal, run_dir) do
    identities
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, journal, []}, fn {identity, index}, {:ok, journal, fixtures} ->
      slug = Enum.at(journal["pool_slugs"], index - 1)
      key_label = "issue-241-#{journal["run_id"]}-#{index}"

      with {:ok, journal} <- before_call(journal, run_dir, "pool", "create", %{slug: slug}),
           {:ok, %Pool{} = pool} <-
             Pools.create_pool(
               scope,
               %{slug: slug, name: "Issue 241 certification #{index}", status: "active"},
               broadcast?: false
             ),
           {:ok, journal} <- after_resource(journal, run_dir, "pool", pool.id, %{slug: pool.slug}),
           :ok <- no_catalog_job(pool.id),
           {:ok, journal} <-
             before_call(journal, run_dir, "assignment", "sync", %{
               pool_id: pool.id,
               identity_id: identity.id
             }),
           :ok <-
             Upstreams.sync_pool_assignments_for_pool_edit(pool, [identity.id],
               select_by: :upstream_identity_id,
               skip_quota_priming: true
             ),
           [
             %PoolUpstreamAssignment{status: "active", upstream_identity_id: identity_id} =
               assignment
           ] <-
             Upstreams.list_pool_assignments(pool),
           true <- identity_id == identity.id,
           {:ok, journal} <-
             after_resource(journal, run_dir, "assignment", assignment.id, %{
               pool_id: pool.id,
               identity_id: identity.id
             }),
           :ok <- no_catalog_job(pool.id),
           {:ok, journal} <-
             before_call(journal, run_dir, "api_key", "create", %{
               pool_id: pool.id,
               display_name: key_label
             }),
           {:ok, %{api_key: %APIKey{} = key, raw_key: raw_key}} <-
             Access.create_api_key(scope, pool, %{display_name: key_label}),
           true <- is_binary(raw_key) and raw_key != "",
           {:ok, journal} <-
             after_resource(journal, run_dir, "api_key", key.id, %{
               pool_id: pool.id,
               display_name: key_label
             }),
           :ok <- no_catalog_job(pool.id),
           {:ok, journal} <- before_call(journal, run_dir, "catalog", "sync", %{pool_id: pool.id}),
           {:ok, %{sync_run: sync_run, models: [_ | _], partial?: false}} <-
             accept_catalog_sync_result(Catalog.sync_pool_catalog(pool, trigger_kind: "manual")),
           {:ok, journal} <-
             after_resource(journal, run_dir, "sync_run", sync_run.id, %{pool_id: pool.id}),
           :ok <- no_catalog_job(pool.id),
           {:ok, journal} <- record_pool_models(journal, run_dir, pool) do
        fixture = %{
          pool: pool,
          identity: identity,
          assignment: assignment,
          api_key: key,
          raw_key: raw_key,
          models: Catalog.list_models(pool)
        }

        {:cont, {:ok, journal, fixtures ++ [fixture]}}
      else
        false -> {:halt, {:error, "assignment identity mismatch"}}
        [_ | _] -> {:halt, {:error, "assignment selection was not exact"}}
        {:ok, %{partial?: true}} -> {:halt, {:error, "catalog sync was partial"}}
        {:ok, %{skipped?: true}} -> {:halt, {:error, "catalog sync was skipped"}}
        {:error, reason} -> {:halt, {:error, context_error(reason)}}
        {:error, _sync_run, reason} -> {:halt, {:error, context_error(reason)}}
        _other -> {:halt, {:error, "provisioning returned an unexpected shape"}}
      end
    end)
  end

  @doc false
  @spec accept_catalog_sync_result(term()) :: {:ok, map()} | {:error, String.t()}
  def accept_catalog_sync_result(
        {:ok, %{sync_run: %SyncRun{} = sync_run, models: models, partial?: false}}
      )
      when is_list(models) and models != [],
      do: {:ok, %{sync_run: sync_run, models: models, partial?: false}}

  def accept_catalog_sync_result({:ok, %{partial?: true}}),
    do: {:error, "catalog sync was partial"}

  def accept_catalog_sync_result({:ok, %{skipped?: true}}),
    do: {:error, "catalog sync was skipped"}

  def accept_catalog_sync_result({:error, _sync_run, reason}), do: {:error, context_error(reason)}
  def accept_catalog_sync_result({:error, reason}), do: {:error, context_error(reason)}

  def accept_catalog_sync_result(_other),
    do: {:error, "provisioning returned an unexpected shape"}

  defp record_pool_models(journal, run_dir, pool) do
    Enum.reduce(Catalog.list_models(pool), {:ok, journal}, fn model, {:ok, current} ->
      after_resource(current, run_dir, "model", model.id, %{
        pool_id: pool.id,
        exposed_model_id: model.exposed_model_id
      })
    end)
  end

  defp run_matrix(base_url, scope, journal, fixtures, run_dir, opts) do
    runner = Keyword.get(opts, :matrix_runner, &default_matrix_runner/6)
    runner.(base_url, scope, journal, fixtures, run_dir, opts)
  end

  defp default_matrix_runner(base_url, scope, journal, fixtures, run_dir, opts) do
    started_at = now_iso8601()

    fixtures
    |> Enum.reduce_while({:ok, [], []}, fn fixture, {:ok, cells, model_ids} ->
      with {:ok, model} <- select_certification_model(base_url, fixture),
           {:ok, fixture_cells} <-
             run_fixture_matrix(
               base_url,
               scope,
               journal["run_id"],
               fixture,
               model,
               run_dir,
               opts
             ) do
        {:cont, {:ok, cells ++ fixture_cells, model_ids ++ [model.exposed_model_id]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, cells, model_ids} ->
        {:ok,
         %{
           cells: cells,
           model_ids: Enum.uniq(model_ids),
           status_counts: Enum.frequencies_by(cells, & &1.status),
           started_at: started_at,
           quiescence: %{"clients_closed" => true}
         }}

      error ->
        error
    end
  end

  @doc false
  @spec candidate_capability_matrix_runner(
          URI.t(),
          Scope.t(),
          journal(),
          [map()],
          String.t(),
          keyword()
        ) :: {:error, String.t()}
  def candidate_capability_matrix_runner(base_url, scope, journal, fixtures, run_dir, opts) do
    fixtures = Enum.take(fixtures, Keyword.get(opts, :candidate_fixture_limit, length(fixtures)))

    results =
      Enum.flat_map(fixtures, fn fixture ->
        case certification_models(base_url, fixture) do
          {:ok, models} ->
            models = candidate_probe_models(models, opts)

            Enum.flat_map(models, fn model ->
              Enum.flat_map(Keyword.get(opts, :candidate_profiles, ~w(lite full)), fn profile ->
                probe_candidate_profile(
                  base_url,
                  scope,
                  journal,
                  fixture,
                  model,
                  profile,
                  run_dir,
                  opts
                )
              end)
            end)

          {:error, reason} ->
            [
              %{
                model: "discovery",
                profile: "none",
                control: "discovery",
                transport: "http",
                status: classify_candidate_probe_result(reason)
              }
            ]
        end
      end)

    Process.put(
      :responses_tool_candidate_capability_results,
      aggregate_candidate_probe_results(results)
    )

    {:error, "candidate capability probe completed without certification"}
  end

  defp candidate_probe_models(models, opts) do
    models = Enum.reject(models, &(&1.exposed_model_id == "gpt-5.6-luna"))

    case Keyword.fetch(opts, :candidate_model_id) do
      {:ok, model_id} -> Enum.filter(models, &(&1.exposed_model_id == model_id))
      :error -> models
    end
  end

  defp probe_candidate_profile(
         base_url,
         scope,
         journal,
         fixture,
         model,
         profile,
         run_dir,
         opts
       ) do
    smoke_cases = candidate_capability_cases(journal["run_id"])

    case set_profile(scope, fixture, model, profile, run_dir, journal["run_id"]) do
      {:ok, _override} ->
        results =
          run_paired_candidate_controls(fn control, transport ->
            run_case(
              base_url,
              fixture,
              model,
              profile,
              transport,
              Map.fetch!(smoke_cases, control),
              opts
            )
          end)

        reset_result = reset_profile(scope, fixture.pool, model.exposed_model_id)

        case reset_result do
          :ok ->
            Enum.map(results, fn result ->
              probe_result(model, profile, result.control, result.transport, result.result)
            end)

          {:error, reason} ->
            [
              probe_result(
                model,
                profile,
                "profile",
                "none",
                {:error, "profile_reset: #{reason}"}
              )
            ]
        end

      {:error, reason} ->
        [
          probe_result(
            model,
            profile,
            "profile",
            "none",
            {:error, "profile_setup: #{reason}"}
          )
        ]
    end
  end

  @doc false
  @spec candidate_capability_cases(String.t()) :: %{String.t() => map()}
  def candidate_capability_cases(run_id) do
    suffix = String.slice(run_id, -12, 12)

    %{
      "custom" =>
        custom_case(
          "candidate_custom_#{suffix}",
          %{"type" => "grammar", "syntax" => "lark", "definition" => ~s(start: "issue241")},
          "issue241",
          {:exact, "issue241"}
        ),
      "function" =>
        function_case("candidate_function_#{suffix}", strict_object_schema(), %{
          "goal" => %{"value" => "issue241"}
        })
    }
  end

  @doc false
  @spec run_paired_candidate_controls((String.t(), String.t() -> term())) :: [map()]
  def run_paired_candidate_controls(run_control) when is_function(run_control, 2) do
    custom_http = run_control.("custom", "http")

    custom_websocket =
      if custom_http == :ok,
        do: run_control.("custom", "websocket"),
        else: :not_tested

    function_http = run_control.("function", "http")

    function_websocket =
      if function_http == :ok,
        do: run_control.("function", "websocket"),
        else: :not_tested

    [
      %{control: "custom", transport: "http", result: custom_http},
      %{control: "custom", transport: "websocket", result: custom_websocket},
      %{control: "function", transport: "http", result: function_http},
      %{control: "function", transport: "websocket", result: function_websocket}
    ]
  end

  defp probe_result(model, profile, control, transport, result) do
    %{
      model: model.exposed_model_id,
      profile: profile,
      control: control,
      transport: transport,
      status: classify_candidate_probe_result(result)
    }
  end

  @doc false
  @spec classify_candidate_probe_result(term()) :: String.t()
  def classify_candidate_probe_result(:ok), do: "passed_terminal_and_settlement"

  def classify_candidate_probe_result({:expected_denial, :lite_typed_tool_choice}),
    do: "denied_unsupported_typed_choice"

  def classify_candidate_probe_result(:not_tested), do: "not_tested_http_failed"

  def classify_candidate_probe_result({:error, reason}) when is_binary(reason),
    do: classify_candidate_probe_result(reason)

  def classify_candidate_probe_result({:error, _reason}), do: "transport_failed"

  def classify_candidate_probe_result(reason) when is_binary(reason) do
    cond do
      String.contains?(reason, "required tool call") -> "missing_forced_tool_call"
      String.contains?(reason, "profile_setup") -> "profile_setup_failed"
      String.contains?(reason, "profile_reset") -> "profile_reset_failed"
      String.contains?(reason, "settle exactly once") -> "lifecycle_validation_failed"
      String.contains?(reason, "public status") -> "unexpected_http_status"
      String.contains?(reason, "public request failed") -> "transport_failed"
      true -> "probe_failed"
    end
  end

  def classify_candidate_probe_result(_reason), do: "probe_failed"

  @doc false
  @spec aggregate_candidate_probe_results([map()]) :: [map()]
  def aggregate_candidate_probe_results(results) when is_list(results) do
    results
    |> Enum.map(&Map.take(&1, [:model, :profile, :control, :transport, :status]))
    |> Enum.group_by(&Map.take(&1, [:model, :profile, :control, :transport]))
    |> Enum.map(fn {dimensions, rows} ->
      statuses = rows |> Enum.map(& &1.status) |> Enum.uniq()
      Map.put(dimensions, :status, aggregate_probe_status(statuses))
    end)
    |> Enum.sort_by(&{&1.model, &1.profile, &1.control, &1.transport})
  end

  defp aggregate_probe_status([status]), do: status
  defp aggregate_probe_status(statuses), do: statuses |> Enum.sort() |> Enum.join("+")

  defp select_certification_model(base_url, fixture) do
    with {:ok, candidates} <- certification_models(base_url, fixture) do
      selected =
        Enum.min_by(candidates, fn model ->
          {if(model.exposed_model_id == "gpt-5.6", do: 0, else: 1), model.exposed_model_id}
        end)

      {:ok, selected}
    end
  end

  defp certification_models(base_url, fixture) do
    url = base_url |> URI.to_string() |> String.trim_trailing("/") |> Kernel.<>("/v1/models")

    with {:ok, %Req.Response{status: 200, body: %{"data" => public_models}}} <-
           Req.get(url,
             headers: [{"authorization", "Bearer #{fixture.raw_key}"}],
             retry: false,
             receive_timeout: 30_000
           ),
         candidates when candidates != [] <-
           Enum.filter(fixture.models, &certification_model?(&1, public_models)) do
      {:ok, Enum.sort_by(candidates, & &1.exposed_model_id)}
    else
      [] ->
        {:error, "Pool does not advertise a suitable exact GPT-5.6 model"}

      {:ok, %Req.Response{status: status}} ->
        {:error, "model discovery failed with HTTP #{status}"}

      {:error, _reason} ->
        {:error, "model discovery could not reach the owned localhost server"}

      _other ->
        {:error, "model discovery returned an unexpected shape"}
    end
  end

  defp certification_model?(model, public_models) do
    id = model.exposed_model_id
    metadata_model = get_in(model.metadata || %{}, ["upstream_model"]) || %{}
    optional_ids = Enum.map(["id", "slug"], &Map.fetch(metadata_model, &1))

    id == model.upstream_model_id and Enum.all?(optional_ids, &optional_model_id?(&1, id)) and
      Enum.any?(public_models, &(&1["id"] == id)) and
      (id == "gpt-5.6" or String.starts_with?(id, "gpt-5.6-")) and
      model.supports_responses and model.supports_streaming and model.supports_tools
  end

  defp optional_model_id?(:error, _id), do: true
  defp optional_model_id?({:ok, value}, id), do: is_binary(value) and value == id

  defp run_fixture_matrix(base_url, scope, run_id, fixture, model, run_dir, opts) do
    Enum.reduce_while(~w(lite full), {:ok, []}, fn profile, {:ok, cells} ->
      with {:ok, _override} <- set_profile(scope, fixture, model, profile, run_dir, run_id),
           {:ok, profile_cells} <-
             run_profile_matrix(base_url, run_id, fixture, model, profile, opts),
           :ok <- reset_profile(scope, fixture.pool, model.exposed_model_id) do
        {:cont, {:ok, cells ++ profile_cells}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
        _other -> {:halt, {:error, "model serving profile could not be proved"}}
      end
    end)
  end

  defp set_profile(scope, fixture, model, profile, run_dir, run_id) do
    with {:ok, journal} <- read_journal(run_id),
         {:ok, journal} <-
           before_call(journal, run_dir, "serving_override", "update", %{
             pool_id: fixture.pool.id,
             model_id: model.exposed_model_id
           }),
         {:ok, snapshot} <- Pools.model_serving_modes_snapshot(scope, fixture.pool),
         {:ok, result} <-
           Pools.update_model_serving_modes(
             scope,
             fixture.pool,
             [%{exposed_model_id: model.exposed_model_id, mode: profile}],
             snapshot.revision
           ),
         %ModelServingOverride{} = override <-
           Enum.find(result.overrides, &(&1.exposed_model_id == model.exposed_model_id)),
         {:ok, %{configured_mode: ^profile, effective_mode: ^profile, source: "override"}} <-
           ModelServingMode.resolve(override, model.metadata, [fixture.assignment.id]) do
      {:ok, _journal} =
        after_resource(journal, run_dir, "serving_override", override.id, %{
          pool_id: fixture.pool.id,
          model_id: model.exposed_model_id
        })

      {:ok, override}
    else
      {:error, reason} -> {:error, context_error(reason)}
      _other -> {:error, "model serving override did not resolve exactly"}
    end
  end

  defp reset_profile(scope, pool, model_id) do
    with {:ok, snapshot} <- Pools.model_serving_modes_snapshot(scope, pool),
         {:ok, result} <-
           Pools.update_model_serving_modes(
             scope,
             pool,
             [%{exposed_model_id: model_id, mode: "auto"}],
             snapshot.revision
           ),
         false <- Enum.any?(result.overrides, &(&1.exposed_model_id == model_id)) do
      :ok
    else
      true -> {:error, "model serving override remained after profile cell"}
      {:error, reason} -> {:error, context_error(reason)}
    end
  end

  defp run_profile_matrix(base_url, run_id, fixture, model, profile, opts) do
    cases = certification_cases(run_id)

    Enum.reduce_while(["http", "websocket"], {:ok, []}, fn transport, {:ok, cells} ->
      Enum.reduce_while(cases, {:ok, cells}, fn smoke_case, {:ok, current} ->
        case run_case(base_url, fixture, model, profile, transport, smoke_case, opts) do
          result when result == :ok or result == {:expected_denial, :lite_typed_tool_choice} ->
            smoke_case = Map.put(smoke_case, :result, result)
            status = certification_case_status(profile, smoke_case)

            if status == "failed_unexpected_success" do
              {:halt,
               {:error,
                "#{profile}/#{transport}/#{smoke_case.label}: Lite typed tool choice was unexpectedly accepted"}}
            else
              cell = %{
                identity: short_hash(fixture.identity.id),
                profile: profile,
                transport: transport,
                case: smoke_case.label,
                status: status
              }

              {:cont, {:ok, current ++ [cell]}}
            end

          {:error, reason} ->
            {:halt, {:error, "#{profile}/#{transport}/#{smoke_case.label}: #{reason}"}}
        end
      end)
      |> case do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc false
  @spec certification_case_status(String.t(), map()) :: String.t()
  def certification_case_status(
        "lite",
        %{
          accepted?: true,
          payload: %{"tool_choice" => choice},
          result: {:expected_denial, :lite_typed_tool_choice}
        }
      )
      when is_map(choice),
      do: "rejected_unsupported_typed_choice"

  # Only a MAP-shaped choice is rejected on Lite. An unforced case must still
  # succeed there, and that success is the only Lite cell proving the relocated
  # `additional_tools` bundle really reaches the provider.
  def certification_case_status(
        "lite",
        %{accepted?: true, payload: %{"tool_choice" => choice}, result: :ok}
      )
      when is_map(choice),
      do: "failed_unexpected_success"

  def certification_case_status("lite", %{accepted?: true, result: :ok}),
    do: "passed_unforced_tool_call"

  def certification_case_status(_profile, %{accepted?: true, payload: %{"tool_choice" => choice}})
      when is_map(choice),
      do: "passed_forced_tool_call"

  def certification_case_status(_profile, %{accepted?: true}),
    do: "passed_unforced_tool_call"

  def certification_case_status(_profile, %{accepted?: false}), do: "rejected"

  defp run_case(base_url, fixture, model, profile, "http", smoke_case, opts) do
    url = base_url |> URI.to_string() |> String.trim_trailing("/") |> Kernel.<>("/v1/responses")

    with :ok <- require_matrix_isolation(opts, fixture.pool.id),
         before_counts <- lifecycle_counts(fixture.pool.id),
         result <-
           Req.post(url,
             headers: [{"authorization", "Bearer #{fixture.raw_key}"}],
             json: Map.put(smoke_case.payload, "model", model.exposed_model_id),
             retry: false,
             receive_timeout: 300_000
           ) do
      validate_case_result(result, fixture, profile, "http_sse", smoke_case, before_counts)
    end
  end

  defp run_case(base_url, fixture, model, profile, "websocket", smoke_case, opts) do
    with :ok <- require_matrix_isolation(opts, fixture.pool.id),
         {:ok, response, before_counts} <-
           websocket_request(
             base_url,
             fixture.raw_key,
             model.exposed_model_id,
             smoke_case.payload,
             fn -> lifecycle_counts(fixture.pool.id) end
           ) do
      validate_case_result(
        {:ok, response},
        fixture,
        profile,
        "websocket",
        smoke_case,
        before_counts
      )
    end
  end

  defp validate_case_result(
         {:ok, %Req.Response{status: 200, body: sse_body}},
         fixture,
         profile,
         transport,
         %{accepted?: true} = smoke_case,
         before_counts
       ) do
    with {:ok, body} <- public_sse_terminal_body(sse_body),
         :ok <- validate_terminal_status(body),
         :ok <- validate_success_lifecycle(fixture, profile, transport, before_counts),
         :ok <- validate_terminal_output(body, smoke_case) do
      :ok
    end
  end

  defp validate_case_result(
         {:ok, %Req.Response{status: 400, body: body}},
         fixture,
         "lite",
         _transport,
         %{accepted?: true} = smoke_case,
         before_counts
       ) do
    validate_lite_typed_choice_rejection(body, fixture, smoke_case, before_counts)
  end

  defp validate_case_result(
         {:ok, %Req.Response{status: 400}},
         fixture,
         _profile,
         _transport,
         %{accepted?: false},
         before_counts
       ) do
    if lifecycle_counts(fixture.pool.id) == before_counts,
      do: :ok,
      else: {:error, "invalid request created lifecycle side effects"}
  end

  defp validate_case_result(
         {:ok, %{status: 200, body: body}},
         fixture,
         profile,
         transport,
         %{accepted?: true} = smoke_case,
         before_counts
       ) do
    with :ok <- validate_terminal_status(body),
         :ok <- validate_success_lifecycle(fixture, profile, transport, before_counts),
         :ok <- validate_terminal_output(body, smoke_case) do
      :ok
    end
  end

  defp validate_case_result(
         {:ok, %{status: 400, body: body}},
         fixture,
         "lite",
         _transport,
         %{accepted?: true} = smoke_case,
         before_counts
       ) do
    validate_lite_typed_choice_rejection(body, fixture, smoke_case, before_counts)
  end

  defp validate_case_result(
         {:ok, %{status: 400}},
         fixture,
         _profile,
         _transport,
         %{accepted?: false},
         before_counts
       ) do
    if lifecycle_counts(fixture.pool.id) == before_counts,
      do: :ok,
      else: {:error, "invalid websocket frame created lifecycle side effects"}
  end

  defp validate_case_result({:ok, response}, _fixture, _profile, _transport, _case, _counts),
    do: {:error, "unexpected public status #{Map.get(response, :status, "unknown")}"}

  defp validate_case_result({:error, _reason}, _fixture, _profile, _transport, _case, _counts),
    do: {:error, "public request failed"}

  # The terminal `response.completed` event carries `"output": []` on this
  # provider path — always, for every response, tool call or plain text
  # (wire-verified 2026-08-03 on six decrypted turns). Tool calls are carried by
  # the streamed `response.output_item.done` events instead, which is what the
  # Codex CLI and codex-lb read.
  #
  # Callers must therefore hand this function a terminal body whose output has
  # been backfilled from those events, exactly as the public
  # `Responses.SSE.response_from_sse/1` path does for real SDK clients. Asserting
  # on the raw terminal array is asserting on a field that is empty by
  # construction, and it is what produced every prior `missing_forced_tool_call`
  # verdict in this issue.
  # A `response.incomplete` terminal that happens to carry the expected item
  # would otherwise certify as a pass. Certification requires a fully completed
  # turn, so the terminal status is asserted separately from its output.
  @doc false
  @spec validate_terminal_status(map()) :: :ok | {:error, String.t()}
  def validate_terminal_status(%{"status" => "completed"}), do: :ok

  def validate_terminal_status(%{"status" => status}) when is_binary(status),
    do: {:error, "provider terminal status was #{status} instead of completed"}

  def validate_terminal_status(_body), do: {:error, "provider terminal status was missing"}

  @doc false
  @spec validate_terminal_output(map(), map()) :: :ok | {:error, String.t()}
  def validate_terminal_output(%{"output" => output}, smoke_case) when is_list(output) do
    case Enum.find(
           output,
           &(&1["type"] == smoke_case.output_type and &1["name"] == smoke_case.name)
         ) do
      nil -> {:error, "provider did not return the required tool call"}
      item -> smoke_case.validate.(item)
    end
  end

  def validate_terminal_output(_body, _smoke_case),
    do: {:error, "provider terminal shape was invalid"}

  defp validate_lite_typed_choice_rejection(body, fixture, smoke_case, before_counts) do
    error = if is_binary(body), do: Jason.decode(body), else: {:ok, body}

    with true <- is_map(smoke_case.payload["tool_choice"]),
         {:ok,
          %{
            "error" => %{
              "code" => "unsupported_parameter",
              "param" => "tool_choice"
            }
          }} <- error,
         after_counts = lifecycle_counts(fixture.pool.id),
         [request] <- latest_requests(fixture.pool.id, before_counts.request_ids),
         :ok <- validate_lite_typed_choice_lifecycle(before_counts, after_counts, request) do
      {:expected_denial, :lite_typed_tool_choice}
    else
      _other -> {:error, "Lite typed tool choice was not rejected before dispatch"}
    end
  end

  @doc false
  @spec validate_lite_typed_choice_lifecycle(map(), map(), Request.t()) ::
          :ok | {:error, String.t()}
  def validate_lite_typed_choice_lifecycle(before_counts, after_counts, %Request{} = request) do
    with 1 <- after_counts.requests - before_counts.requests,
         0 <- after_counts.attempts - before_counts.attempts,
         0 <- after_counts.ledger_entries - before_counts.ledger_entries,
         0 <- after_counts.settlements - before_counts.settlements,
         true <- request.status == "rejected",
         true <- request.last_error_code == "unsupported_parameter",
         "tool_choice" <- get_in(request.request_metadata || %{}, ["gateway_denial", "param"]) do
      :ok
    else
      _other -> {:error, "Lite typed tool choice was not rejected before dispatch"}
    end
  end

  # Websocket settlement is not synchronous with the client-visible terminal.
  # CodexPooler.Gateway.Runtime.Finalization.Websocket.finalize_completed/2 runs
  # the accounting write (idempotency lock, attempt/request updates, release +
  # settlement ledger inserts, rollups) only after the owner/relay layer has
  # already streamed the "response.completed" frame to the downstream websocket
  # connection — that decoupling is what keeps client-visible delivery from
  # blocking on bookkeeping. A single sample taken the instant the terminal
  # frame is decoded can therefore observe the pre-settlement state by a few
  # tens of milliseconds even on a request that settles correctly (confirmed
  # 2026-08-03 on run 20260803T171358Z-1f120dd5515f: the settlement ledger
  # row landed exactly once, on the assigned identity, ~32ms after this
  # function's single-shot read). The HTTP/SSE lane has no such gap: the
  # controller cannot signal completion to the client until it returns, and it
  # calls the same accounting finalize before returning.
  #
  # Poll for the settlement to land instead of sampling once. A genuine defect
  # (missing, duplicated, or misattributed settlement) still fails once the
  # deadline elapses; only the harness race is eliminated.
  defp validate_success_lifecycle(fixture, profile, transport, before_counts) do
    after_counts = await_settlement_lifecycle(fixture.pool.id, before_counts)

    expected_routing = %{
      "model_serving_mode_configured" => profile,
      "model_serving_mode" => profile,
      "model_serving_mode_source" => "override"
    }

    with 1 <- after_counts.requests - before_counts.requests,
         1 <- after_counts.attempts - before_counts.attempts,
         1 <- after_counts.settlements - before_counts.settlements,
         [request] <- latest_requests(fixture.pool.id, before_counts.request_ids),
         [attempt] <- Repo.all(from attempt in Attempt, where: attempt.request_id == ^request.id),
         [settlement] <-
           Repo.all(
             from entry in LedgerEntry,
               where: entry.request_id == ^request.id and entry.entry_kind == "settlement"
           ),
         true <- request.status == "succeeded" and request.retry_count == 0,
         true <- attempt.status == "succeeded" and attempt.transport == transport,
         true <- attempt.upstream_identity_id == fixture.identity.id,
         true <- attempt.pool_upstream_assignment_id == fixture.assignment.id,
         true <- settlement.transport == transport,
         true <- settlement.upstream_identity_id == fixture.identity.id,
         true <- settlement.pool_upstream_assignment_id == fixture.assignment.id,
         true <-
           Map.take(
             get_in(request.request_metadata || %{}, ["routing"]) || %{},
             Map.keys(expected_routing)
           ) ==
             expected_routing do
      :ok
    else
      _other -> {:error, "accepted request did not settle exactly once on its assigned identity"}
    end
  end

  # Bounded so a genuine missing/duplicated/misattributed settlement still
  # fails validate_success_lifecycle's delta check after the deadline, rather
  # than hanging or masking a real defect.
  @settlement_poll_timeout_ms 2_000
  @settlement_poll_interval_ms 25

  defp await_settlement_lifecycle(pool_id, before_counts) do
    deadline = System.monotonic_time(:millisecond) + @settlement_poll_timeout_ms
    await_settlement_lifecycle(pool_id, before_counts, deadline)
  end

  defp await_settlement_lifecycle(pool_id, before_counts, deadline) do
    counts = lifecycle_counts(pool_id)

    if counts.settlements - before_counts.settlements >= 1 or
         System.monotonic_time(:millisecond) >= deadline do
      counts
    else
      Process.sleep(@settlement_poll_interval_ms)
      await_settlement_lifecycle(pool_id, before_counts, deadline)
    end
  end

  defp latest_requests(pool_id, previous_ids) do
    Repo.all(
      from request in Request,
        where: request.pool_id == ^pool_id and request.id not in ^previous_ids
    )
  end

  defp lifecycle_counts(pool_id) do
    request_query = from request in Request, where: request.pool_id == ^pool_id
    request_ids = Repo.all(from request in request_query, select: request.id)

    %{
      requests: length(request_ids),
      attempts:
        Repo.aggregate(
          from(attempt in Attempt, where: attempt.request_id in ^request_ids),
          :count
        ),
      settlements:
        Repo.aggregate(
          from(entry in LedgerEntry,
            where: entry.request_id in ^request_ids and entry.entry_kind == "settlement"
          ),
          :count
        ),
      ledger_entries:
        Repo.aggregate(
          from(entry in LedgerEntry, where: entry.request_id in ^request_ids),
          :count
        ),
      request_ids: request_ids
    }
  end

  defp certification_cases(run_id) do
    suffix = String.slice(run_id, -12, 12)

    # Deterministic cases first. The run halts on the first failure, so leading
    # with the two value-nondeterministic cells (a free-text literal and an
    # `^[a-z]{8}$` grammar that any eight lowercase letters satisfy) let a single
    # instruction-following miss abort the matrix before the cells whose output
    # is fully constrained ever executed. That ordering is what let the original
    # instrument bug hide behind "the provider ignores custom tools".
    [
      custom_case(
        "custom_lark_#{suffix}",
        %{"type" => "grammar", "syntax" => "lark", "definition" => ~s(start: "issue241")},
        "issue241",
        {:exact, "issue241"}
      ),
      function_case("function_object_#{suffix}", repaired_object_schema(), %{
        "goal" => %{"value" => "issue241"}
      }),
      function_case("function_array_#{suffix}", repaired_array_schema(), %{
        "items" => ["issue241"]
      }),
      # Unforced: every other accepted case carries a map-shaped tool_choice, so
      # in Lite they all certify as the expected 400. Without this cell a
      # regression in the Lite `additional_tools` relocation — which really does
      # carry tools upstream, wire-verified — would pass the whole matrix.
      auto_choice_case(
        custom_case(
          "custom_lark_auto_#{suffix}",
          %{"type" => "grammar", "syntax" => "lark", "definition" => ~s(start: "issue241")},
          "issue241",
          {:exact, "issue241"}
        )
      ),
      custom_case("custom_text_#{suffix}", %{"type" => "text"}, "issue241-text", :any_string),
      custom_case(
        "custom_regex_#{suffix}",
        %{"type" => "grammar", "syntax" => "regex", "definition" => "^[a-z]{8}$"},
        "abcdefgh",
        {:matches, ~r/^[a-z]{8}$/}
      ),
      negative_case("malformed_custom_format", %{
        "input" => "issue241",
        "tools" => [
          %{"type" => "custom", "name" => "bad_#{suffix}", "format" => %{"type" => "grammar"}}
        ]
      }),
      negative_case("unknown_named_choice", %{
        "input" => "issue241",
        "tools" => [%{"type" => "custom", "name" => "known_#{suffix}"}],
        "tool_choice" => %{"type" => "custom", "name" => "unknown_#{suffix}"}
      }),
      negative_case("executable_collision", %{
        "input" => "issue241",
        "tools" => [
          %{"type" => "custom", "name" => "collision_#{suffix}"},
          %{"type" => "function", "name" => "collision_#{suffix}", "strict" => false}
        ]
      }),
      negative_case("invalid_explicit_type", %{
        "input" => "issue241",
        "tools" => [
          %{
            "type" => "function",
            "name" => "invalid_type_#{suffix}",
            "strict" => true,
            "parameters" => %{"type" => "future", "properties" => %{}}
          }
        ]
      })
    ]
  end

  # `hint` is what the prompt and description ask the model to emit; `expectation`
  # is what the certification is entitled to assert afterwards. They are separate
  # because a custom tool's `format` decides how much of the output is actually
  # constrained:
  #
  #   * a lark grammar of `start: "issue241"` admits exactly one string, so exact
  #     equality is a property of the request and holds deterministically;
  #   * `^[a-z]{8}$` constrains the shape only — any eight lowercase letters
  #     satisfy it, and which eight the model picks is its own business;
  #   * an unconstrained text format guarantees nothing about the content at all.
  #
  # Asserting an exact literal on the latter two measures the model's
  # instruction-following, not tool compatibility, and fails for reasons that
  # have nothing to do with the gateway. The compatibility claim being certified
  # is that the definition is accepted, forwarded intact, and answered with a
  # `custom_tool_call` of the requested name — which every case still asserts
  # strictly via `output_type` and `name`.
  defp custom_case(name, format, hint, expectation) do
    %{
      label: name,
      accepted?: true,
      name: name,
      output_type: "custom_tool_call",
      payload: %{
        # The prompt must name the value. "Call the required tool." names none,
        # so a free-text tool is legitimately called with an empty input.
        "input" => "Call the required tool and emit exactly: #{hint}",
        "stream" => true,
        "tools" => [
          %{
            "type" => "custom",
            "name" => name,
            # Codex always describes its custom tools; an undescribed tool gives
            # the model no reason to prefer it.
            "description" => "Emits exactly #{hint}. FREEFORM: do not wrap in JSON.",
            "format" => format
          }
        ],
        "tool_choice" => %{"type" => "custom", "name" => name}
      },
      validate: fn item -> validate_custom_input(item["input"], expectation) end
    }
  end

  defp validate_custom_input(input, {:exact, expected}) when input == expected, do: :ok

  defp validate_custom_input(_input, {:exact, _expected}),
    do: {:error, "custom tool input did not match the grammar-constrained value"}

  defp validate_custom_input(input, {:matches, pattern}) when is_binary(input) do
    if Regex.match?(pattern, input),
      do: :ok,
      else: {:error, "custom tool input did not satisfy the certified grammar"}
  end

  defp validate_custom_input(_input, {:matches, _pattern}),
    do: {:error, "custom tool input was not a string"}

  defp validate_custom_input(input, :any_string) when is_binary(input), do: :ok

  defp validate_custom_input(_input, :any_string),
    do: {:error, "custom tool input was not a string"}

  defp function_case(name, schema, expected_arguments) do
    %{
      label: name,
      accepted?: true,
      name: name,
      output_type: "function_call",
      payload: %{
        "input" => "Call the required tool with #{Jason.encode!(expected_arguments)}.",
        "stream" => true,
        "tools" => [
          %{"type" => "function", "name" => name, "strict" => true, "parameters" => schema}
        ],
        "tool_choice" => %{"type" => "function", "name" => name}
      },
      validate: fn item ->
        case Jason.decode(item["arguments"] || "") do
          {:ok, ^expected_arguments} -> :ok
          _other -> {:error, "function arguments did not match the certified schema"}
        end
      end
    }
  end

  # Drops the forced choice so the case exercises real tool calling in both
  # serving modes: Lite relocates the definition into `additional_tools` and the
  # provider still calls it, which a forced case can never demonstrate because
  # Lite rejects map-shaped choices before dispatch.
  defp auto_choice_case(smoke_case) do
    smoke_case
    |> Map.update!(:label, &String.replace(&1, "custom_", "custom_auto_"))
    |> update_in([:payload], &Map.put(&1, "tool_choice", "auto"))
  end

  defp negative_case(label, payload) do
    %{
      label: label,
      accepted?: false,
      name: nil,
      output_type: nil,
      payload: Map.put(payload, "stream", true),
      validate: fn _item -> :ok end
    }
  end

  defp repaired_object_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "goal" => %{
          "additionalProperties" => false,
          "properties" => %{"value" => %{"type" => "string"}},
          "required" => ["value"]
        }
      },
      "required" => ["goal"]
    }
  end

  defp strict_object_schema do
    repaired_object_schema()
    |> put_in(["properties", "goal", "type"], "object")
  end

  defp repaired_array_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{"items" => %{"items" => %{"type" => "string"}}},
      "required" => ["items"]
    }
  end

  # Delegates to the production SSE reducer rather than reading the terminal
  # event directly, so certification sees exactly what a real SDK client sees.
  # That path backfills `output` from the streamed `response.output_item.done`
  # events when the terminal array is empty — which, on this provider, it always
  # is (Responses.SSE.maybe_backfill_output/2).
  defp public_sse_terminal_body(body) when is_binary(body) do
    case ResponsesSSE.response_from_sse(body) do
      {:ok, response} when is_map(response) -> {:ok, response}
      {:error, %{message: message}} -> {:error, message}
    end
  end

  defp public_sse_terminal_body(_body),
    do: {:error, "public SSE response body was invalid"}

  # Websocket counterpart of Responses.SSE.maybe_backfill_output/2: an empty
  # terminal output array is filled from the streamed response.output_item.done
  # frames. A non-empty terminal array always wins.
  @doc false
  @spec backfill_websocket_output(map(), [map()]) :: map()
  def backfill_websocket_output(%{"output" => output} = body, _frames)
      when is_list(output) and output != [],
      do: body

  def backfill_websocket_output(body, frames) when is_map(body) and is_list(frames) do
    case Enum.flat_map(frames, fn
           %{"type" => "response.output_item.done", "item" => %{} = item} -> [item]
           _frame -> []
         end) do
      [] -> body
      items -> Map.put(body, "output", items)
    end
  end

  defp websocket_request(base_url, raw_key, model_id, payload, baseline) do
    uri = base_url
    path = "/v1/responses"
    host = if uri.host == "localhost", do: "127.0.0.1", else: uri.host

    with {:ok, conn} <- Mint.HTTP.connect(:http, host, uri.port, protocols: [:http1]) do
      try do
        websocket_exchange(conn, path, raw_key, model_id, payload, baseline)
      after
        Mint.HTTP.close(conn)
      end
    end
  end

  defp websocket_exchange(conn, path, raw_key, model_id, payload, baseline) do
    new_websocket = &Mint.WebSocket.new/4

    headers = [
      {"authorization", "Bearer #{raw_key}"},
      {"x-codex-turn-state", "issue241-#{random_suffix()}"},
      {"openai-beta", "responses_websockets=2026-02-06"}
    ]

    frame_payload = Map.merge(%{"type" => "response.create", "model" => model_id}, payload)

    with {:ok, conn, ref} <- Mint.WebSocket.upgrade(:ws, conn, path, headers),
         {:ok, conn, 101, response_headers} <- await_websocket_upgrade(conn, ref, [], nil),
         {:ok, conn, websocket} <- new_websocket.(conn, ref, 101, response_headers),
         before_counts <- baseline.(),
         {:ok, websocket, encoded} <-
           Mint.WebSocket.encode(websocket, {:text, Jason.encode!(frame_payload)}),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(conn, ref, encoded),
         {:ok, _conn, _websocket, {terminal, frames}} <-
           receive_websocket_terminal(conn, websocket, ref, []) do
      case terminal do
        %{"type" => "response.completed", "response" => body} ->
          {:ok, %{status: 200, body: backfill_websocket_output(body, frames)}, before_counts}

        %{"type" => "error"} ->
          {:ok, %{status: 400, body: terminal}, before_counts}

        _other ->
          {:error, :unexpected_terminal}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp await_websocket_upgrade(conn, ref, headers, status) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          :unknown ->
            await_websocket_upgrade(conn, ref, headers, status)

          {:ok, conn, responses} ->
            {status, headers, done?} =
              Enum.reduce(responses, {status, headers, false}, fn
                {:status, ^ref, next_status}, {_status, current_headers, done} ->
                  {next_status, current_headers, done}

                {:headers, ^ref, next_headers}, {current_status, current_headers, done} ->
                  {current_status, current_headers ++ next_headers, done}

                {:done, ^ref}, {current_status, current_headers, _done} ->
                  {current_status, current_headers, true}

                _response, accumulator ->
                  accumulator
              end)

            if done?,
              do: complete_websocket_upgrade(conn, status, headers),
              else: await_websocket_upgrade(conn, ref, headers, status)

          {:error, _conn, reason, _responses} ->
            {:error, reason}
        end
    after
      10_000 -> {:error, :upgrade_timeout}
    end
  end

  defp complete_websocket_upgrade(conn, 101, headers) when is_list(headers),
    do: {:ok, conn, 101, headers}

  defp complete_websocket_upgrade(_conn, status, _headers) when is_integer(status),
    do: {:error, :upgrade_rejected}

  defp complete_websocket_upgrade(_conn, _status, _headers),
    do: {:error, :upgrade_rejected}

  defp receive_websocket_terminal(conn, websocket, ref, frames) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          :unknown ->
            receive_websocket_terminal(conn, websocket, ref, frames)

          {:ok, conn, responses} ->
            Enum.reduce_while(responses, {:ok, conn, websocket, frames}, fn
              {:data, ^ref, data}, {:ok, current_conn, current_websocket, current_frames} ->
                case Mint.WebSocket.decode(current_websocket, data) do
                  {:ok, next_websocket, decoded_frames} ->
                    decoded =
                      decoded_frames
                      |> Enum.flat_map(fn
                        {:text, text} -> [Jason.decode!(text)]
                        _frame -> []
                      end)

                    all_frames = current_frames ++ decoded

                    case Enum.find(all_frames, &(&1["type"] in ["response.completed", "error"])) do
                      nil ->
                        {:cont, {:ok, current_conn, next_websocket, all_frames}}

                      terminal ->
                        # Carry every frame alongside the terminal: the terminal
                        # object's own output array is empty on this provider,
                        # so the tool call lives in the earlier
                        # response.output_item.done frames.
                        {:halt, {:ok, current_conn, next_websocket, {terminal, all_frames}}}
                    end

                  {:error, _websocket, reason} ->
                    {:halt, {:error, reason}}
                end

              _response, accumulator ->
                {:cont, accumulator}
            end)
            |> case do
              {:ok, next_conn, next_websocket, next_frames} when is_list(next_frames) ->
                receive_websocket_terminal(next_conn, next_websocket, ref, next_frames)

              terminal ->
                terminal
            end

          {:error, _conn, reason, _responses} ->
            {:error, reason}
        end
    after
      300_000 -> {:error, :response_timeout}
    end
  end

  defp random_suffix, do: :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  defp short_hash(value), do: value |> sha256() |> String.slice(0, 12)

  defp require_matrix_isolation(opts, pool_id) do
    with {:ok, inspector} <- Keyword.fetch(opts, :inspector),
         {:ok, application_name} <- Keyword.fetch(opts, :application_name),
         :ok <- require_exclusive_database(inspector, application_name),
         :ok <- no_catalog_job(pool_id) do
      :ok
    else
      :error -> {:error, "matrix isolation state is unavailable"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp final_quiescence do
    with %{result: :ok, owners_failed: 0} <- RolloutDrain.start_drain(timeout_ms: 50_000),
         :ok <- await_rate_limit_tasks(),
         :ok <- TouchDebounce.flush(),
         :ok <- await_rate_limit_tasks() do
      :ok
    else
      _other -> {:error, "runtime work did not reach final quiescence"}
    end
  end

  defp await_rate_limit_tasks do
    deadline = System.monotonic_time(:millisecond) + 50_000
    await_rate_limit_tasks(deadline, false)
  end

  defp await_rate_limit_tasks(deadline, empty_seen?) do
    children = Task.Supervisor.children(CodexPooler.RateLimitEventSupervisor)

    cond do
      children == [] and empty_seen? ->
        :ok

      children == [] ->
        receive do
        after
          0 -> await_rate_limit_tasks(deadline, true)
        end

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, "rate-limit observation tasks did not drain"}

      true ->
        monitors = Enum.map(children, &Process.monitor/1)
        remaining_ms = max(deadline - System.monotonic_time(:millisecond), 0)

        receive do
          {:DOWN, monitor, :process, _pid, _reason} ->
            Enum.each(monitors -- [monitor], &Process.demonitor(&1, [:flush]))
            await_rate_limit_tasks(deadline, false)
        after
          remaining_ms ->
            Enum.each(monitors, &Process.demonitor(&1, [:flush]))
            {:error, "rate-limit observation tasks did not drain"}
        end
    end
  end

  defp cleanup(command, opts) do
    with {:ok, journal} <- read_journal(command.cleanup_run_id),
         true <- journal["owner_user_id"] == command.owner_id do
      run_cleanup_application(command, opts)
    else
      false -> {:error, "owner id does not match the run journal"}
      {:error, reason} -> {:error, context_error(reason)}
    end
  end

  defp run_cleanup_application(command, opts) do
    with_inspector(opts, fn inspector ->
      with :ok <- acquire_lock(inspector),
           :ok <- require_exclusive_database(inspector, nil),
           {:ok, restore} <- start_isolated_application(inspector, nil) do
        cleanup_result =
          try do
            with :ok <- require_exclusive_database(inspector, restore.application_name),
                 {:ok, scope} <- exact_owner_scope(command.owner_id),
                 :ok <- final_quiescence(),
                 {:ok, latest_journal} <- read_journal(command.cleanup_run_id),
                 {:ok, latest_journal} <-
                   recover_committed_resources(latest_journal, run_dir(command.cleanup_run_id)),
                 {:ok, cleaned} <-
                   cleanup_resources(scope, latest_journal, run_dir(command.cleanup_run_id)),
                 :ok <- stable_cleanup_projection(cleaned) do
              {:ok, cleaned}
            end
          after
            Application.stop(:codex_pooler)
            restore_configuration(restore)
          end

        try do
          with {:ok, cleaned} <- cleanup_result,
               :ok <- require_exclusive_database(inspector, nil),
               :ok <- stable_inspector_cleanup_projection(inspector, cleaned),
               receipt <- cleanup_receipt(cleaned),
               :ok <- validate_receipt(receipt),
               _path <- publish_receipt!(receipt),
               :ok <- remove_manifest(run_dir(command.cleanup_run_id)) do
            {:ok, "cleanup completed run_id=#{command.cleanup_run_id}"}
          end
        after
          release_lock(inspector)
        end
      end
    end)
  end

  defp cleanup_resources(scope, journal, run_dir) do
    journal = append_operation(journal, "intent", "cleanup")
    :ok = write_journal!(run_dir, journal)

    plan = exact_cleanup_plan(journal)

    with :ok <- validate_cleanup_ownership(plan, journal) do
      plan
      |> Enum.reduce_while({:ok, journal}, fn resource, {:ok, current} ->
        case cleanup_resource(scope, resource) do
          :ok ->
            updated =
              append_operation(current, "completed", "cleanup_#{resource["kind"]}", %{
                id: resource["id"]
              })

            :ok = write_journal!(run_dir, updated)
            {:cont, {:ok, updated}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, cleaned} ->
          cleaned = Map.put(cleaned, "cleanup_status", "completed")
          :ok = write_journal!(run_dir, cleaned)
          {:ok, cleaned}

        error ->
          error
      end
    end
  end

  defp recover_committed_resources(journal, run_dir) do
    with {:ok, journal} <- recover_pools(journal),
         {:ok, journal} <- recover_intended_children(journal) do
      :ok = write_journal!(run_dir, journal)
      {:ok, journal}
    end
  end

  @doc false
  @spec recover_pools(journal()) :: {:ok, journal()} | {:error, String.t()}
  def recover_pools(journal) do
    Enum.reduce_while(journal["pool_slugs"] || [], {:ok, journal}, fn slug, {:ok, current} ->
      case Enum.find(current["resources"] || [], fn resource ->
             resource["kind"] == "pool" and String.downcase(resource["slug"] || "") == slug
           end) do
        nil ->
          pools =
            Repo.all(
              from pool in Pool,
                where: pool.slug == ^slug and pool.created_by_user_id == ^journal["owner_user_id"]
            )

          case pools do
            [] ->
              {:cont, {:ok, current}}

            [%Pool{} = pool] ->
              {:cont, {:ok, record_resource(current, "pool", pool.id, %{slug: pool.slug})}}

            _many ->
              {:halt, {:error, "deterministic Pool recovery was ambiguous"}}
          end

        resource ->
          updated =
            Enum.map(current["resources"] || [], fn candidate ->
              if candidate == resource, do: Map.put(candidate, "slug", slug), else: candidate
            end)

          {:cont, {:ok, Map.put(current, "resources", updated)}}
      end
    end)
  end

  defp recover_intended_children(journal) do
    journal["operations"]
    |> Enum.filter(&(&1["phase"] == "intent"))
    |> Enum.reduce_while({:ok, journal}, fn operation, {:ok, current} ->
      case recover_intended_child(current, operation) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp recover_intended_child(journal, %{
         "kind" => "assignment",
         "pool_id" => pool_id,
         "identity_id" => identity_id
       }) do
    recover_one_resource(
      journal,
      "assignment",
      Repo.all(
        from assignment in PoolUpstreamAssignment,
          where:
            assignment.pool_id == ^pool_id and assignment.upstream_identity_id == ^identity_id
      ),
      %{pool_id: pool_id, identity_id: identity_id}
    )
  end

  defp recover_intended_child(journal, %{
         "kind" => "api_key",
         "pool_id" => pool_id,
         "display_name" => display_name
       }) do
    recover_one_resource(
      journal,
      "api_key",
      Repo.all(
        from api_key in APIKey,
          where: api_key.pool_id == ^pool_id and api_key.display_name == ^display_name
      ),
      %{pool_id: pool_id, display_name: display_name}
    )
  end

  defp recover_intended_child(journal, %{"kind" => "catalog", "pool_id" => pool_id}) do
    Catalog.list_models(pool_id)
    |> Enum.reduce({:ok, journal}, fn model, {:ok, current} ->
      {:ok,
       record_resource(current, "model", model.id, %{
         pool_id: pool_id,
         exposed_model_id: model.exposed_model_id
       })}
    end)
  end

  defp recover_intended_child(journal, %{
         "kind" => "serving_override",
         "pool_id" => pool_id,
         "model_id" => model_id
       }) do
    recover_one_resource(
      journal,
      "serving_override",
      Repo.all(
        from override in ModelServingOverride,
          where: override.pool_id == ^pool_id and override.exposed_model_id == ^model_id
      ),
      %{pool_id: pool_id, model_id: model_id}
    )
  end

  defp recover_intended_child(journal, _operation), do: {:ok, journal}

  defp recover_one_resource(journal, kind, rows, fields) do
    case rows do
      [] ->
        {:ok, journal}

      [row] ->
        if Enum.any?(journal["resources"] || [], &(&1["kind"] == kind and &1["id"] == row.id)) do
          {:ok, journal}
        else
          {:ok, record_resource(journal, kind, row.id, fields)}
        end

      _many ->
        {:error, "exact #{kind} recovery was ambiguous"}
    end
  end

  @doc false
  @spec validate_cleanup_ownership([map()], journal()) :: :ok | {:error, String.t()}
  def validate_cleanup_ownership(plan, journal) do
    allowed_slugs = MapSet.new(journal["pool_slugs"] || [])
    pool_ids = plan |> Enum.filter(&(&1["kind"] == "pool")) |> MapSet.new(& &1["id"])

    Enum.reduce_while(plan, :ok, fn resource, :ok ->
      case validate_resource_ownership(resource, pool_ids, allowed_slugs) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_resource_ownership(%{"kind" => "pool", "id" => id, "slug" => slug}, _ids, slugs) do
    case Pools.get_pool(id) do
      %Pool{slug: ^slug} -> if MapSet.member?(slugs, slug), do: :ok, else: ownership_error("Pool")
      _other -> {:error, "journaled Pool ownership did not match its deterministic slug"}
    end
  end

  defp validate_resource_ownership(
         %{"kind" => "assignment", "id" => id, "pool_id" => pool_id},
         pool_ids,
         _slugs
       ) do
    case Repo.get(PoolUpstreamAssignment, id) do
      %PoolUpstreamAssignment{pool_id: ^pool_id} ->
        if MapSet.member?(pool_ids, pool_id), do: :ok, else: ownership_error("assignment")

      _other ->
        {:error, "journaled assignment ownership did not match its run Pool"}
    end
  end

  defp validate_resource_ownership(
         %{
           "kind" => "api_key",
           "id" => id,
           "pool_id" => pool_id,
           "display_name" => display_name
         },
         pool_ids,
         _slugs
       ) do
    case Repo.get(APIKey, id) do
      %APIKey{pool_id: ^pool_id, display_name: ^display_name} ->
        if MapSet.member?(pool_ids, pool_id), do: :ok, else: ownership_error("API key")

      _other ->
        {:error, "journaled API key ownership did not match its run Pool and label"}
    end
  end

  defp validate_resource_ownership(
         %{"kind" => "model", "id" => id, "pool_id" => pool_id},
         pool_ids,
         _slugs
       ) do
    case Repo.get(Model, id) do
      %Model{pool_id: ^pool_id} ->
        if MapSet.member?(pool_ids, pool_id), do: :ok, else: ownership_error("model")

      _other ->
        {:error, "journaled model ownership did not match its run Pool"}
    end
  end

  defp validate_resource_ownership(
         %{
           "kind" => "serving_override",
           "id" => id,
           "pool_id" => pool_id,
           "model_id" => model_id
         },
         pool_ids,
         _slugs
       ) do
    case Repo.get(ModelServingOverride, id) do
      nil ->
        :ok

      %ModelServingOverride{pool_id: ^pool_id, exposed_model_id: ^model_id} ->
        if MapSet.member?(pool_ids, pool_id), do: :ok, else: ownership_error("serving override")

      _other ->
        {:error, "journaled serving override ownership did not match its run Pool"}
    end
  end

  defp validate_resource_ownership(_resource, _pool_ids, _slugs),
    do: {:error, "journaled cleanup resource was missing ownership metadata"}

  defp ownership_error(kind), do: {:error, "journaled #{kind} did not belong to a run Pool"}

  # Recovery must be idempotent. A run that failed after archiving its Pool
  # leaves the override entry in the journal, and the serving-mode writer refuses
  # archived Pools with `pool_not_found` — so a second cleanup pass would fail
  # forever on work that is already done. An archived Pool serves nothing, so the
  # obligation is only that no override row survives.
  defp cleanup_resource(scope, %{
         "kind" => "serving_override",
         "pool_id" => pool_id,
         "model_id" => model_id
       })
       when is_binary(pool_id) do
    case Pools.get_pool(pool_id) do
      %Pool{status: "archived"} -> archived_pool_override_cleared(pool_id, model_id)
      _pool -> reset_serving_override(scope, pool_id, model_id)
    end
  end

  defp cleanup_resource(_scope, %{"kind" => "assignment", "id" => id, "pool_id" => pool_id}) do
    case Repo.get(PoolUpstreamAssignment, id) do
      %PoolUpstreamAssignment{pool_id: ^pool_id, status: "deleted"} ->
        no_catalog_job(pool_id)

      %PoolUpstreamAssignment{pool_id: ^pool_id} ->
        with %Pool{} = pool <- Pools.get_pool(pool_id),
             [%PoolUpstreamAssignment{id: ^id}] <- Upstreams.list_pool_assignments(pool),
             :ok <-
               Upstreams.sync_pool_assignments_for_pool_edit(pool, [],
                 select_by: :upstream_identity_id,
                 skip_quota_priming: true
               ),
             %PoolUpstreamAssignment{status: "deleted"} <- Repo.get(PoolUpstreamAssignment, id),
             :ok <- no_catalog_job(pool_id) do
          :ok
        else
          nil ->
            {:error, "journaled Pool was not found during assignment cleanup"}

          {:error, reason} ->
            {:error, context_error(reason)}

          _other ->
            {:error, "run Pool assignment set was not exact or the assignment was not deleted"}
        end

      _other ->
        {:error, "journaled assignment was not found in its run Pool"}
    end
  end

  defp cleanup_resource(scope, %{"kind" => "api_key", "id" => id}) do
    case Access.revoke_api_key(scope, id) do
      {:ok, %APIKey{status: "revoked"}} -> :ok
      {:error, reason} -> {:error, context_error(reason)}
      _other -> {:error, "journaled API key was not revoked"}
    end
  end

  defp cleanup_resource(_scope, %{"kind" => "model", "id" => id}) do
    case Repo.get(Model, id) do
      %Model{status: "retired"} ->
        :ok

      %Model{} = model ->
        case Catalog.retire_model(model) do
          {:ok, %Model{status: "retired"}} -> :ok
          {:error, reason} -> {:error, context_error(reason)}
        end

      nil ->
        {:error, "journaled model was not found"}
    end
  end

  defp cleanup_resource(scope, %{"kind" => "pool", "id" => id}) do
    case Pools.get_pool(id) do
      %Pool{status: "archived"} ->
        expire_pool_session_continuity(id)

      %Pool{} = pool ->
        case Pools.change_pool_status(scope, pool, "archived") do
          {:ok, %Pool{status: "archived"}} -> expire_pool_session_continuity(id)
          {:error, reason} -> {:error, context_error(reason)}
        end

      nil ->
        {:error, "journaled Pool was not found"}
    end
  end

  # Any websocket case leaves an owner lease and a session alias behind: the
  # upgrade establishes them before the frame is even read, and the runtime
  # clears them lazily, only when a later request arrives on the same session
  # key (SessionContinuity.ExpiredSessions.close_for_key!/3). A certification run
  # has no later request, so without this the post-stop projection can never be
  # satisfied by any run that opens a websocket.
  #
  # Exact-ID ownership still holds: this only touches rows belonging to the
  # run's own archived Pool.
  defp expire_pool_session_continuity(pool_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    session_ids =
      Repo.all(
        from session in CodexSession, where: session.pool_id == ^pool_id, select: session.id
      )

    if session_ids != [] do
      Repo.update_all(
        from(lease in BridgeOwnerLease,
          where: lease.codex_session_id in ^session_ids and lease.status == "active"
        ),
        set: [status: "expired", released_at: now, updated_at: now]
      )

      Repo.update_all(
        from(alias_record in BridgeSessionAlias,
          where: alias_record.codex_session_id in ^session_ids and alias_record.status == "active"
        ),
        set: [status: "expired", updated_at: now]
      )
    end

    :ok
  end

  # Recovery must be idempotent. A run that failed after archiving its Pool
  # leaves the override entry in the journal, and the serving-mode writer refuses
  # archived Pools with `pool_not_found` — so a second cleanup pass would fail
  # forever on work that is already done. An archived Pool serves nothing, so the
  # remaining obligation is only that no override row survives.
  defp archived_pool_override_cleared(pool_id, model_id) do
    remaining? =
      Repo.exists?(
        from(override in ModelServingOverride,
          where: override.pool_id == ^pool_id and override.exposed_model_id == ^model_id
        )
      )

    if remaining?,
      do: {:error, "serving override remained on an archived Pool"},
      else: :ok
  end

  defp reset_serving_override(scope, pool_id, model_id) do
    with {:ok, snapshot} <- Pools.model_serving_modes_snapshot(scope, pool_id),
         {:ok, result} <-
           Pools.update_model_serving_modes(
             scope,
             pool_id,
             [%{exposed_model_id: model_id, mode: "auto"}],
             snapshot.revision
           ),
         false <- Enum.any?(result.overrides, &(&1.exposed_model_id == model_id)) do
      :ok
    else
      true -> {:error, "serving override remained after reset"}
      {:error, reason} -> {:error, context_error(reason)}
    end
  end

  defp stable_cleanup_projection(journal) do
    active =
      exact_cleanup_plan(journal)
      |> Enum.filter(fn
        %{"kind" => "pool", "id" => id} ->
          match?(%Pool{status: status} when status != "archived", Pools.get_pool(id))

        %{"kind" => "api_key", "id" => id} ->
          match?(%APIKey{status: status} when status != "revoked", Repo.get(APIKey, id))

        %{"kind" => "assignment", "id" => id} ->
          match?(
            %PoolUpstreamAssignment{status: status} when status != "deleted",
            Repo.get(PoolUpstreamAssignment, id)
          )

        %{"kind" => "model", "id" => id} ->
          match?(%Model{status: status} when status != "retired", Repo.get(Model, id))

        _resource ->
          false
      end)

    if active == [], do: :ok, else: {:error, "cleanup left active run-owned resources"}
  end

  defp stable_inspector_cleanup_projection(inspector, journal) do
    first = inspector_cleanup_projection(inspector, journal)

    receive do
    after
      100 -> :ok
    end

    second = inspector_cleanup_projection(inspector, journal)

    cond do
      first != second ->
        {:error, "database projection changed after application shutdown"}

      projection_inactive?(second) ->
        :ok

      true ->
        {:error, "post-stop projection retained active run-owned state"}
    end
  end

  defp inspector_cleanup_projection(inspector, journal) do
    resources = journal["resources"] || []
    pool_ids = resource_ids(resources, "pool")

    %{
      expected: %{
        pools: length(pool_ids),
        api_keys: length(resource_ids(resources, "api_key")),
        assignments: length(resource_ids(resources, "assignment")),
        models: length(resource_ids(resources, "model"))
      },
      pools:
        projection_rows(
          inspector,
          "SELECT id::text, status FROM pools WHERE id::text = ANY($1::text[]) ORDER BY id",
          pool_ids
        ),
      api_keys:
        projection_rows(
          inspector,
          "SELECT id::text, status FROM api_keys WHERE id::text = ANY($1::text[]) ORDER BY id",
          resource_ids(resources, "api_key")
        ),
      assignments:
        projection_rows(
          inspector,
          "SELECT id::text, status FROM pool_upstream_assignments WHERE id::text = ANY($1::text[]) ORDER BY id",
          resource_ids(resources, "assignment")
        ),
      models:
        projection_rows(
          inspector,
          "SELECT id::text, status FROM models WHERE id::text = ANY($1::text[]) ORDER BY id",
          resource_ids(resources, "model")
        ),
      overrides:
        projection_rows(
          inspector,
          "SELECT id::text, mode FROM pool_model_serving_overrides WHERE pool_id::text = ANY($1::text[]) ORDER BY id",
          pool_ids
        ),
      sessions:
        projection_rows(
          inspector,
          "SELECT id::text, status FROM codex_sessions WHERE pool_id::text = ANY($1::text[]) ORDER BY id",
          pool_ids
        ),
      aliases:
        projection_rows(
          inspector,
          "SELECT id::text, status FROM bridge_session_aliases WHERE pool_id::text = ANY($1::text[]) ORDER BY id",
          pool_ids
        ),
      leases:
        projection_rows(
          inspector,
          "SELECT id::text, status FROM bridge_owner_leases WHERE pool_id::text = ANY($1::text[]) ORDER BY id",
          pool_ids
        ),
      turns:
        projection_rows(
          inspector,
          """
          SELECT turns.id::text, turns.status
          FROM codex_turns AS turns
          JOIN codex_sessions AS sessions ON sessions.id = turns.codex_session_id
          WHERE sessions.pool_id::text = ANY($1::text[])
          ORDER BY turns.id
          """,
          pool_ids
        ),
      catalog_jobs:
        projection_rows(
          inspector,
          """
          SELECT id::text, state
          FROM oban_jobs
          WHERE worker = 'Elixir.CodexPooler.Jobs.CatalogSyncWorker'
            AND args->>'pool_id' = ANY($1::text[])
          ORDER BY id
          """,
          pool_ids
        )
    }
  end

  defp projection_rows(_inspector, _query, []), do: []

  defp projection_rows(inspector, query, ids) do
    Postgrex.query!(inspector, query, [ids]).rows
  end

  defp resource_ids(resources, kind) do
    resources
    |> Enum.filter(&(&1["kind"] == kind and is_binary(&1["id"])))
    |> Enum.map(& &1["id"])
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp projection_inactive?(projection) do
    statuses_match?(projection.pools, "archived", projection.expected.pools) and
      statuses_match?(projection.api_keys, "revoked", projection.expected.api_keys) and
      statuses_match?(projection.assignments, "deleted", projection.expected.assignments) and
      statuses_match?(projection.models, "retired", projection.expected.models) and
      projection.overrides == [] and
      Enum.all?(projection.sessions, fn [_id, status] -> status != "active" end) and
      Enum.all?(projection.aliases, fn [_id, status] -> status != "active" end) and
      Enum.all?(projection.leases, fn [_id, status] -> status != "active" end) and
      Enum.all?(projection.turns, fn [_id, status] -> status != "in_progress" end) and
      projection.catalog_jobs == []
  end

  defp statuses_match?(rows, expected, expected_count) do
    length(rows) == expected_count and Enum.all?(rows, fn [_id, status] -> status == expected end)
  end

  defp exact_owner_scope(owner_id) do
    with %User{status: "active", deleted_at: nil} = user <- Repo.get(User, owner_id),
         %Scope{} = scope <- Scope.for_user(user),
         true <- Pools.owner?(scope) do
      {:ok, scope}
    else
      _other -> {:error, "owner id does not identify an active instance owner"}
    end
  end

  defp exact_identities(labels) do
    identities =
      Repo.all(
        from identity in UpstreamIdentity,
          where: identity.account_label in ^labels and identity.status == "active",
          order_by: [asc: identity.account_label, asc: identity.id]
      )

    ids = Enum.map(identities, & &1.id)
    found_labels = Enum.map(identities, & &1.account_label)

    if length(identities) == @identity_count and length(Enum.uniq(ids)) == @identity_count and
         Enum.sort(found_labels) == Enum.sort(labels) do
      {:ok, identities}
    else
      {:error, "identity labels must resolve to exactly three distinct active identities"}
    end
  end

  defp before_call(journal, run_dir, kind, operation, fields) do
    journal = append_operation(journal, "intent", kind, Map.put(fields, :operation, operation))
    :ok = write_journal!(run_dir, journal)
    {:ok, journal}
  end

  defp after_resource(journal, run_dir, kind, id, fields) do
    journal =
      journal
      |> record_resource(kind, id, fields)
      |> append_operation("completed", kind, %{id: id})

    :ok = write_journal!(run_dir, journal)
    {:ok, journal}
  end

  defp no_catalog_job(pool_id) do
    count =
      Repo.one(
        from job in Oban.Job,
          where: job.worker == ^@catalog_worker,
          where: fragment("?->>'pool_id' = ?", job.args, ^pool_id),
          select: count(job.id)
      )

    if count == 0, do: :ok, else: {:error, "catalog sync job exists for a run-owned Pool"}
  end

  defp recover_after_failure(owner_id, journal, run_dir, reason) do
    with {:ok, scope} <- exact_owner_scope(owner_id),
         {:ok, latest_journal} <- read_journal(journal["run_id"]),
         {:ok, latest_journal} <- recover_committed_resources(latest_journal, run_dir),
         {:ok, cleaned} <- cleanup_resources(scope, latest_journal, run_dir),
         :ok <- stable_cleanup_projection(cleaned) do
      {:certification_failed, cleaned, reason}
    else
      {:error, cleanup_reason} ->
        {:cleanup_incomplete, journal, reason, cleanup_reason}
    end
  end

  defp finalize_application_result(
         {:ok, journal, matrix},
         inspector,
         run_dir,
         provenance
       ) do
    with :ok <- require_exclusive_database(inspector, nil),
         :ok <- stable_inspector_cleanup_projection(inspector, journal),
         receipt <- success_receipt(journal, matrix, provenance),
         :ok <- validate_receipt(receipt),
         _path <- publish_receipt!(receipt),
         :ok <- remove_manifest(run_dir) do
      {:ok, "certification passed run_id=#{journal["run_id"]} cleanup=completed"}
    end
  end

  defp finalize_application_result(
         {:certification_failed, journal, reason},
         inspector,
         run_dir,
         _provenance
       ) do
    with :ok <- require_exclusive_database(inspector, nil),
         :ok <- stable_inspector_cleanup_projection(inspector, journal),
         :ok <- publish_failure_receipt(journal["run_id"], reason, "completed"),
         :ok <- remove_manifest(run_dir) do
      {:error, context_error(reason)}
    end
  end

  defp finalize_application_result(
         {:cleanup_incomplete, journal, reason, cleanup_reason},
         inspector,
         _run_dir,
         _provenance
       ) do
    with :ok <- require_exclusive_database(inspector, nil),
         :ok <- publish_failure_receipt(journal["run_id"], reason, "incomplete") do
      {:error, "certification failed and cleanup is incomplete: #{context_error(cleanup_reason)}"}
    end
  end

  defp cleanup_receipt(journal) do
    %{
      run_id: journal["run_id"],
      certification_status: recovery_certification_status(journal["certification_status"]),
      cleanup_status: "completed",
      finished_at: now_iso8601(),
      status_counts: %{"cleaned_resources" => length(exact_cleanup_plan(journal))}
    }
  end

  defp success_receipt(journal, matrix, provenance) do
    %{
      run_id: journal["run_id"],
      source_sha: provenance.source_sha,
      diff_fingerprint: provenance.diff_fingerprint,
      model_ids: Map.get(matrix, :model_ids, []),
      cells: Map.get(matrix, :cells, []),
      status_counts: Map.get(matrix, :status_counts, %{}),
      fixture_hashes: fixture_hashes(journal),
      started_at: Map.get(matrix, :started_at),
      finished_at: now_iso8601(),
      certification_status: "passed",
      cleanup_status: "completed",
      quiescence: Map.get(matrix, :quiescence, %{}),
      module_digests: provenance.module_digests
    }
  end

  defp publish_failure_receipt(run_id, reason, cleanup_status \\ "not_started") do
    if validate_run_id(run_id) == :ok do
      publish_receipt!(%{
        run_id: run_id,
        certification_status: "failed",
        cleanup_status: cleanup_status,
        status_counts: %{"failure_class" => failure_class(reason)},
        finished_at: now_iso8601()
      })
    end

    :ok
  end

  defp publish_failure_receipt_unless_exists(run_id, reason) do
    case File.lstat(receipt_path(run_id)) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      _other -> publish_failure_receipt(run_id, reason)
    end
  end

  defp recovery_certification_status("failed"), do: "failed"
  defp recovery_certification_status(_status), do: "not_certified"

  defp fixture_hashes(journal) do
    journal["resources"]
    |> Enum.group_by(& &1["kind"])
    |> Map.new(fn {kind, rows} ->
      ids = rows |> Enum.map(& &1["id"]) |> Enum.sort() |> Enum.join("\n")
      {kind, sha256(ids)}
    end)
  end

  defp module_digests do
    [
      CodexPooler.Gateway.OpenAICompatibility.Responses,
      CodexPooler.Gateway.OpenAICompatibility.Chat,
      CodexPooler.Gateway.Payloads.StrictSchema,
      CodexPooler.Gateway.Payloads.StrictSchema.Repair,
      __MODULE__,
      Mix.Tasks.Dev.ResponsesToolCompatSmoke
    ]
    |> Map.new(fn module -> {inspect(module), beam_digest(module)} end)
  end

  defp beam_digest(module) do
    case :code.get_object_code(module) do
      {^module, binary, _path} -> sha256(binary)
      _other -> "unavailable"
    end
  end

  defp source_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _other -> "unavailable"
    end
  end

  defp source_provenance do
    %{
      source_sha: source_sha(),
      diff_fingerprint: diff_fingerprint(),
      module_digests: module_digests()
    }
  end

  defp diff_fingerprint do
    with {diff, 0} <-
           System.cmd("git", ["diff", "--binary", "HEAD", "--"], stderr_to_stdout: true),
         {untracked, 0} <-
           System.cmd("git", ["ls-files", "--others", "--exclude-standard", "-z"],
             stderr_to_stdout: true
           ) do
      untracked_digests =
        untracked
        |> String.split(<<0>>, trim: true)
        |> Enum.sort()
        |> Enum.map_join("\n", fn path -> "#{path}\0#{file_digest(path)}" end)

      sha256(diff <> "\0untracked\0" <> untracked_digests)
    else
      _other -> "unavailable"
    end
  end

  defp file_digest(path) do
    case File.read(path) do
      {:ok, content} -> sha256(content)
      {:error, _reason} -> "unavailable"
    end
  end

  defp configure_isolated_application(inspector, base_url) do
    previous_oban = Application.get_env(:codex_pooler, Oban)
    previous_repo = Application.get_env(:codex_pooler, Repo)
    previous_endpoint = Application.get_env(:codex_pooler, CodexPoolerWeb.Endpoint)
    application_name = "issue241_#{System.unique_integer([:positive])}"

    oban =
      previous_oban
      |> Keyword.put(:testing, :manual)
      |> Keyword.put(:queues, false)
      |> Keyword.put(:plugins, false)

    parameters =
      previous_repo
      |> Keyword.get(:parameters, [])
      |> Keyword.put(:application_name, application_name)

    repo = Keyword.put(previous_repo, :parameters, parameters)
    endpoint = isolated_endpoint_config(previous_endpoint, base_url)
    Application.put_env(:codex_pooler, Oban, oban)
    Application.put_env(:codex_pooler, Repo, repo)
    Application.put_env(:codex_pooler, CodexPoolerWeb.Endpoint, endpoint)

    if Keyword.get(oban, :queues) == false and Keyword.get(oban, :plugins) == false do
      {:ok,
       %{
         oban: previous_oban,
         repo: previous_repo,
         endpoint: previous_endpoint,
         application_name: application_name,
         inspector: inspector
       }}
    else
      {:error, "Oban could not be forced into manual no-runner mode"}
    end
  end

  def isolated_endpoint_config(config, nil), do: Keyword.put(config, :server, false)

  def isolated_endpoint_config(config, %URI{host: host, port: port}) do
    config
    |> Keyword.put(:server, true)
    |> Keyword.put(:http,
      ip: loopback_ip(host),
      port: port,
      http_1_options: [enabled: true],
      http_2_options: [enabled: false]
    )
    |> Keyword.put(:watchers, [])
    |> Keyword.delete(:live_reload)
    |> Keyword.put(:code_reloader, false)
  end

  defp loopback_ip("::1"), do: {0, 0, 0, 0, 0, 0, 0, 1}
  defp loopback_ip(_host), do: {127, 0, 0, 1}

  defp start_isolated_application(inspector, base_url) do
    with {:ok, restore} <- configure_isolated_application(inspector, base_url) do
      case Application.ensure_all_started(:codex_pooler) do
        {:ok, _started} ->
          {:ok, restore}

        {:error, reason} ->
          restore_configuration(restore)
          release_lock(inspector)
          {:error, "isolated application could not start: #{safe_reason(reason)}"}
      end
    end
  end

  defp restore_configuration(restore) do
    Application.put_env(:codex_pooler, Oban, restore.oban)
    Application.put_env(:codex_pooler, Repo, restore.repo)
    Application.put_env(:codex_pooler, CodexPoolerWeb.Endpoint, restore.endpoint)
  end

  defp with_inspection(opts, fun) do
    case Keyword.fetch(opts, :inspection) do
      {:ok, inspection} -> fun.(inspection)
      :error -> with_inspector(opts, fn inspector -> fun.(inspect_database(inspector)) end)
    end
  end

  defp with_inspector(opts, fun) do
    case Keyword.fetch(opts, :inspector) do
      {:ok, inspector} ->
        fun.(inspector)

      :error ->
        {:ok, _started} = Application.ensure_all_started(:postgrex)
        config = Repo.config() |> Keyword.take(@connection_keys) |> put_inspector_name()

        case Postgrex.start_link(config) do
          {:ok, inspector} ->
            try do
              fun.(inspector)
            after
              if Process.alive?(inspector), do: GenServer.stop(inspector)
            end

          {:error, _reason} ->
            {:error, "standalone database inspector could not connect"}
        end
    end
  end

  defp put_inspector_name(config) do
    parameters =
      config
      |> Keyword.get(:parameters, [])
      |> Keyword.put(:application_name, "issue241_inspector")

    Keyword.put(config, :parameters, parameters)
  end

  defp inspect_database(inspector) do
    owners =
      query_column(inspector, """
      SELECT DISTINCT users.id::text
      FROM users
      JOIN memberships ON memberships.user_id = users.id
      WHERE users.status = 'active'
        AND users.deleted_at IS NULL
        AND memberships.role = 'instance_owner'
        AND memberships.status = 'active'
      ORDER BY users.id::text
      """)

    identities =
      Postgrex.query!(
        inspector,
        """
        SELECT id::text, account_label, status
        FROM upstream_identities
        ORDER BY account_label, id
        """,
        []
      ).rows
      |> Enum.map(fn [id, label, status] -> %{id: id, label: label, status: status} end)

    other_clients = client_application_names(inspector, nil)
    %{owners: owners, identities: identities, other_client_application_names: other_clients}
  end

  defp query_column(inspector, query) do
    Postgrex.query!(inspector, query, []).rows |> Enum.map(&hd/1)
  end

  defp require_exclusive_inspection(%{other_client_application_names: []}), do: :ok

  defp require_exclusive_inspection(_inspection),
    do: {:error, "database has another client backend"}

  defp require_owner(owner_id, %{owners: [owner_id]}), do: :ok

  defp require_owner(_owner_id, _inspection),
    do: {:error, "owner id is not the sole active instance owner"}

  defp require_identities(labels, %{identities: identities}) do
    selected = Enum.filter(identities, &(&1.label in labels and &1.status == "active"))

    if length(selected) == @identity_count and
         length(Enum.uniq_by(selected, & &1.id)) == @identity_count and
         Enum.sort(Enum.map(selected, & &1.label)) == Enum.sort(labels) do
      :ok
    else
      {:error, "identity labels must resolve to exactly three distinct active identities"}
    end
  end

  defp acquire_lock(inspector) do
    database = Keyword.fetch!(Repo.config(), :database)

    %{rows: [[locked?]]} =
      Postgrex.query!(inspector, "SELECT pg_try_advisory_lock(hashtext($1), hashtext($2))", [
        "codex-pooler:issue-241-certification",
        database
      ])

    if locked?, do: :ok, else: {:error, "another issue-241 certification holds the database lock"}
  end

  defp release_lock(inspector) when is_pid(inspector) do
    if Process.alive?(inspector),
      do: Postgrex.query(inspector, "SELECT pg_advisory_unlock_all()", [])

    :ok
  end

  defp release_lock(_inspector), do: :ok

  defp require_exclusive_database(inspector, allowed_application_name) do
    case client_application_names(inspector, allowed_application_name) do
      [] -> :ok
      _names -> {:error, "database has a client backend outside this certification run"}
    end
  end

  defp client_application_names(inspector, allowed_application_name) do
    Postgrex.query!(
      inspector,
      """
      SELECT DISTINCT COALESCE(application_name, '')
      FROM pg_stat_activity
      WHERE datname = current_database()
        AND pid <> pg_backend_pid()
        AND backend_type = 'client backend'
      ORDER BY 1
      """,
      []
    ).rows
    |> Enum.map(&hd/1)
    |> Enum.reject(&(&1 == allowed_application_name))
  end

  defp server_preflight(uri, opts) do
    checker = Keyword.get(opts, :server_check, &default_server_check/1)
    checker.(uri)
  end

  defp default_server_check(%URI{host: host, port: port}) do
    host = if host == "localhost", do: ~c"localhost", else: String.to_charlist(host)

    case :gen_tcp.connect(host, port, [:binary, active: false], 500) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        {:error, "localhost port is already occupied; the task requires owning the server"}

      {:error, :econnrefused} ->
        :ok

      {:error, :timeout} ->
        {:error, "localhost port preflight timed out"}

      {:error, _reason} ->
        {:error, "localhost server preflight failed"}
    end
  end

  defp require_owned_server_ready(%URI{host: host, port: port}) do
    host = if host == "localhost", do: ~c"localhost", else: String.to_charlist(host)

    case :gen_tcp.connect(host, port, [:binary, active: false], 2_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, _reason} ->
        {:error, "owned localhost server did not become ready"}
    end
  end

  defp reject_run_collision(run_id) do
    path = run_dir(run_id)
    if File.exists?(path), do: {:error, "run id already exists"}, else: :ok
  end

  defp require_no_incomplete_manifests do
    case File.ls(@runtime_root) do
      {:ok, entries} ->
        if Enum.any?(entries, &incomplete_manifest?/1) do
          {:error, "an incomplete certification run requires explicit cleanup"}
        else
          :ok
        end

      {:error, :enoent} ->
        :ok

      {:error, _reason} ->
        {:error, "runtime manifest directory could not be inspected"}
    end
  end

  defp incomplete_manifest?(run_id) do
    validate_run_id(run_id) == :ok and
      match?(
        {:ok, %File.Stat{type: :regular}},
        File.lstat(Path.join(run_dir(run_id), @manifest_name))
      )
  end

  defp receipt_path(run_id), do: Path.join(@receipt_root, "#{run_id}.json")

  defp remove_manifest(run_dir) do
    path = Path.join(run_dir, @manifest_name)

    with :ok <- require_regular_file(path),
         :ok <- File.rm(path) do
      sync_directory!(run_dir)
      :ok
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, _reason} -> {:error, "manifest could not be removed"}
    end
  end

  defp ensure_private_directory!(path) do
    File.mkdir_p!(path)
    File.chmod!(path, 0o700)
  end

  defp require_private_directory(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory, mode: mode}} when Bitwise.band(mode, 0o077) == 0 -> :ok
      {:ok, _stat} -> {:error, "run directory is not a private regular directory"}
      {:error, _reason} -> {:error, "run directory was not found"}
    end
  end

  defp require_regular_file(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, _stat} -> {:error, "expected a regular file and refused a link or special file"}
      {:error, _reason} -> {:error, "required run file was not found"}
    end
  end

  defp atomic_write!(path, content, mode) do
    parent = Path.dirname(path)
    ensure_private_directory!(parent)

    temporary =
      Path.join(parent, ".#{Path.basename(path)}.#{System.unique_integer([:positive])}.tmp")

    try do
      {:ok, file} =
        :file.open(String.to_charlist(temporary), [:write, :binary, :raw, :exclusive])

      try do
        :ok = :file.write(file, content)
        :ok = :file.sync(file)
      after
        :ok = :file.close(file)
      end

      File.chmod!(temporary, mode)
      File.rename!(temporary, path)
      sync_directory!(parent)
      :ok
    after
      if File.exists?(temporary), do: File.rm(temporary)
    end
  end

  defp sync_directory!(path) do
    case :file.open(String.to_charlist(path), [:read, :raw]) do
      {:ok, directory} ->
        try do
          case :file.sync(directory) do
            :ok -> :ok
            {:error, :eisdir} -> sync_directory_with_python!(path)
          end
        after
          :ok = :file.close(directory)
        end

      {:error, :eisdir} ->
        sync_directory_with_python!(path)

      {:error, reason} ->
        raise "parent directory fsync failed: #{safe_reason(reason)}"
    end
  end

  defp sync_directory_with_python!(path) do
    script = "import os,sys; fd=os.open(sys.argv[1], os.O_RDONLY); os.fsync(fd); os.close(fd)"

    case System.cmd("python3", ["-c", script, path], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {_output, _status} -> raise "parent directory fsync failed: unsupported"
    end
  end

  defp pool_slugs(run_id),
    do:
      Enum.map(
        1..@identity_count,
        &("issue-241-#{run_id}-#{String.pad_leading(Integer.to_string(&1), 2, "0")}"
          |> String.downcase())
      )

  defp run_dir(run_id), do: Path.join(@runtime_root, run_id)

  defp generate_run_id do
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    suffix = :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
    "#{timestamp}-#{suffix}"
  end

  defp canonical_json(value), do: Jason.encode_to_iodata!(canonicalize(value))

  defp canonicalize(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp canonicalize(%Decimal{} = value), do: Decimal.normalize(value) |> Decimal.to_string()

  defp canonicalize(value) when is_map(value) do
    value
    |> Enum.map(fn {key, item} -> {to_string(key), canonicalize(item)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Map.new()
  end

  defp canonicalize(value) when is_list(value), do: Enum.map(value, &canonicalize/1)
  defp canonicalize(value), do: value

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp now_iso8601,
    do: DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

  defp failure_class(%{code: code}) when is_atom(code), do: Atom.to_string(code)
  defp failure_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_class(_reason), do: "certification_failed"

  defp context_error(reason) when is_binary(reason), do: reason
  defp context_error(%{code: code}) when is_atom(code), do: Atom.to_string(code)
  defp context_error(%Ecto.Changeset{}), do: "database change was rejected"
  defp context_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp context_error(_reason), do: "operation returned an unexpected failure"

  defp sanitized_exception(exception),
    do: "certification failed with #{inspect(exception.__struct__)}"

  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason(_reason), do: "unexpected_reason"
end
