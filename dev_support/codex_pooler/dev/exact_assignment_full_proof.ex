defmodule CodexPooler.Dev.ExactAssignmentFullProof do
  @moduledoc """
  Self-contained loopback proof that Pooler routes Full-mode traffic cleanly.

  One bounded control: provision a synthetic task-owned loopback identity,
  Pool, assignment, API key, and Full serving override through the existing
  trusted lifecycles; route one HTTP SSE and one websocket request through the
  locally booted Pooler to the in-process gateway perf fake upstream; prove the
  durable request/attempt rows and the fake's metadata-only wire capture
  resolve to the same synthetic upstream-request-id fingerprint with
  configured/effective Full, retry 0, and no Responses Lite marker on either
  transport; then hard-delete every journaled row and read back zero.

  Rollback is registered before the first write: the journal reuses the
  `ResponsesToolCompatSmoke` journal/cleanup-plan helpers, and `--cleanup-run-id`
  replays the same exact-id cleanup at any point. Development-only; loopback
  only; no provider, Docker, or external network. Receipts are metadata-only:
  counts, booleans, bounded ids, and 12-character fingerprints.
  """

  import Ecto.Query

  alias CodexPooler.Access
  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request, RequestLogFact}
  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Catalog
  alias CodexPooler.Catalog.{Model, PricingSnapshot, SyncRun}
  alias CodexPooler.Dev.GatewayPerfFakeUpstream, as: FakeUpstream
  alias CodexPooler.Dev.ResponsesToolCompatSmoke, as: Journal

  alias CodexPooler.Gateway.Persistence.{
    BridgeAffinity,
    BridgeDemotion,
    BridgeOwnerLease,
    BridgeSessionAlias,
    CodexSession,
    CodexTurn,
    IdempotencyKey,
    RoutingCircuitState
  }

  alias CodexPooler.Gateway.Routing.CandidateEligibility

  alias CodexPooler.Pools
  alias CodexPooler.Pools.{ModelServingOverride, Pool, RoutingSettings}
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.Schemas.{EncryptedSecret, PoolUpstreamAssignment, UpstreamIdentity}
  alias CodexPooler.Upstreams.TokenLinking

  @runtime_root Path.join(["tmp", "issue-241", "runtime"])
  @model_id "gateway-perf-full"
  @responses_endpoint "/backend-api/codex/responses"
  @lite_http_header "x-openai-internal-codex-responses-lite"
  @lite_websocket_metadata_key "ws_request_header_x_openai_internal_codex_responses_lite"
  @websocket_probe_metadata_key "todo9_probe"
  @pooler_port 4000
  @request_budget 3
  @traffic_deadline_ms 45_000
  @row_poll_timeout_ms 20_000
  @safe_scope "loopback-fake"
  @run_id_pattern ~r/\A[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}\z/

  @type command ::
          %{
            required(:mode) => :proof,
            required(:owner_id) => Ecto.UUID.t(),
            required(:dry_run?) => boolean()
          }
          | %{
              required(:mode) => :cleanup,
              required(:owner_id) => Ecto.UUID.t(),
              required(:run_id) => String.t(),
              required(:dry_run?) => boolean()
            }
  @type journal :: map()

  @spec run([String.t()]) :: {:ok, map()} | {:error, String.t()}
  def run(args) when is_list(args) do
    with {:ok, command} <- parse_args(args), do: execute(command)
  end

  @spec parse_args([String.t()]) :: {:ok, command()} | {:error, String.t()}
  def parse_args(args) do
    {options, positional, invalid} =
      OptionParser.parse(args,
        strict: [cleanup_run_id: :string, owner_id: :string, dry_run: :boolean, scope: :string]
      )

    with :ok <- reject_parser_remainders(positional, invalid),
         :ok <- reject_duplicate_options(args, options),
         :ok <- require_safe_scope(options),
         {:ok, owner_id} <- required_owner_id(options),
         {:ok, command} <- command_from_options(options, owner_id) do
      {:ok, command}
    end
  end

  @spec execute(command(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def execute(command, opts \\ []) when is_map(command) and is_list(opts) do
    case command do
      %{dry_run?: true} -> preflight(command, opts)
      %{mode: :cleanup, run_id: run_id, owner_id: owner_id} -> cleanup_run(run_id, owner_id)
      %{mode: :proof, owner_id: owner_id} -> proof_run(owner_id, opts)
      _other -> {:error, "exact assignment proof command is invalid"}
    end
  rescue
    exception -> {:error, failure("unexpected_exception", exception)}
  end

  @doc false
  @spec cleanup_journal(journal(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def cleanup_journal(journal, opts \\ []) when is_map(journal) and is_list(opts),
    do: execute_cleanup(journal, opts)

  @doc false
  @spec rollback_journal(journal(), String.t(), keyword()) :: {:error, String.t()}
  def rollback_journal(journal, reason, opts \\ [])
      when is_map(journal) and is_binary(reason) and is_list(opts) do
    case execute_cleanup(journal, opts) do
      {:ok, _receipt} ->
        {:error, failure("proof_failed_rolled_back", reason)}

      {:error, cleanup_reason} ->
        {:error, failure("proof_rollback_failed", {reason, cleanup_reason})}
    end
  end

  @doc false
  @spec verify_loopback_fake(FakeUpstream.server()) :: :ok | {:error, String.t()}
  def verify_loopback_fake(%{url: url, profiles: profiles, run_id: run_id})
      when is_binary(url) and is_list(profiles) and is_binary(run_id) do
    uri = URI.parse(url)

    if uri.scheme == "http" and uri.host in ["127.0.0.1", "localhost", "::1"] and
         is_integer(uri.port) and uri.port > 0 and is_nil(uri.userinfo) and
         uri.path in [nil, ""] and is_nil(uri.query) and is_nil(uri.fragment) and
         profiles == [Enum.find(FakeUpstream.profiles(), &(&1["name"] == "opencode-text-ok"))] and
         valid_run_id?(run_id) do
      :ok
    else
      {:error, "fake upstream must be the verified loopback Full profile"}
    end
  end

  def verify_loopback_fake(_fake),
    do: {:error, "fake upstream must be the verified loopback Full profile"}

  defp reject_parser_remainders([], []), do: :ok

  defp reject_parser_remainders(_positional, _invalid),
    do: {:error, "unknown or positional arguments are not allowed"}

  defp reject_duplicate_options(args, options) do
    duplicate? =
      Enum.any?([:cleanup_run_id, :owner_id, :dry_run, :scope], fn key ->
        option_occurrences(args, key) > 1 or length(Keyword.get_values(options, key)) > 1
      end)

    if duplicate? do
      {:error, "an option that accepts one value was supplied more than once"}
    else
      :ok
    end
  end

  defp option_occurrences(args, key) do
    option = "--" <> (key |> Atom.to_string() |> String.replace("_", "-"))
    Enum.count(args, &(&1 == option or String.starts_with?(&1, option <> "=")))
  end

  defp require_safe_scope(options) do
    if Keyword.get(options, :scope) == @safe_scope do
      :ok
    else
      {:error, "--scope #{@safe_scope} is required"}
    end
  end

  defp required_owner_id(options) do
    case Keyword.get(options, :owner_id) do
      nil -> {:error, "--owner-id is required"}
      owner_id -> normalize_uuid(owner_id)
    end
  end

  defp command_from_options(options, owner_id) do
    dry_run? = Keyword.get(options, :dry_run, false)

    case Keyword.get(options, :cleanup_run_id) do
      nil ->
        {:ok, %{mode: :proof, owner_id: owner_id, dry_run?: dry_run?}}

      run_id ->
        with :ok <- validate_run_id(run_id) do
          {:ok, %{mode: :cleanup, owner_id: owner_id, run_id: run_id, dry_run?: dry_run?}}
        end
    end
  end

  defp normalize_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, "owner id must be a UUID"}
    end
  end

  defp normalize_uuid(_value), do: {:error, "owner id must be a UUID"}

  defp validate_run_id(run_id) when is_binary(run_id) do
    if valid_run_id?(run_id), do: :ok, else: {:error, "run id is invalid"}
  end

  defp validate_run_id(_run_id), do: {:error, "run id is invalid"}
  defp valid_run_id?(run_id) when is_binary(run_id), do: Regex.match?(@run_id_pattern, run_id)

  # This intentionally performs only deterministic parsing and local-port checks.
  # It never starts the application, writes a journal, or calls an upstream.
  defp preflight(%{mode: :proof}, opts) do
    port_check = Keyword.get(opts, :port_check, &require_port_free/1)

    with :ok <- port_check.(@pooler_port),
         true <- Enum.any?(FakeUpstream.profiles(), &(&1["name"] == "opencode-text-ok")) do
      {:ok, %{"mode" => "dry_run", "scope" => @safe_scope, "writes" => false}}
    else
      false -> {:error, "required loopback Full fake profile is unavailable"}
      {:error, reason} -> {:error, failure("preflight_failed", reason)}
    end
  end

  defp preflight(%{mode: :cleanup, run_id: run_id, owner_id: owner_id}, _opts) do
    with {:ok, journal} <- Journal.read_journal(run_id),
         :ok <- verify_journal_owner(journal, owner_id) do
      {:ok,
       %{
         "mode" => "dry_run_cleanup",
         "scope" => @safe_scope,
         "owned_cleanup_ids" => length(Journal.exact_cleanup_plan(journal)),
         "writes" => false
       }}
    end
  end

  # ── Registered rollback: replay the exact-id cleanup for a journaled run. ──

  defp cleanup_run(run_id, owner_id) do
    with {:ok, journal} <- Journal.read_journal(run_id),
         :ok <- verify_journal_owner(journal, owner_id),
         {:ok, _apps} <- start_owned_application(),
         {:ok, journal} <- Journal.recover_pools(journal),
         {:ok, receipt} <- execute_cleanup(journal, remove_run_dir?: true) do
      {:ok, Map.put(receipt, "mode", "cleanup")}
    end
  end

  # ── The bounded proof control. ──

  defp proof_run(owner_id, opts) do
    run_id = generate_run_id()
    run_dir = Path.join(@runtime_root, run_id)
    identity_label = "todo9-exact-assignment-#{run_id}"
    port_check = Keyword.get(opts, :port_check, &require_port_free/1)

    with :ok <- validate_execution_options(opts),
         :ok <- port_check.(@pooler_port),
         {:ok, apps} <- start_owned_application(),
         {:ok, scope} <- owner_scope(owner_id),
         journal = Journal.new_journal(run_id, scope.user.id, [identity_label]),
         # Rollback is registered before the first database write: the journal
         # is durable on disk and `--cleanup-run-id` replays it from here on.
         :ok <- Journal.write_journal!(run_dir, journal),
         {:ok, ^journal} <- Journal.read_journal(run_id),
         {:ok, fake} <- start_fake_upstream(run_id),
         :ok <- verify_loopback_fake(fake) do
      try do
        result = execute_proof(scope, journal, run_dir, fake, identity_label, opts)

        case result do
          {:ok, receipt} ->
            {:ok, receipt}

          {:error, reason} ->
            rollback(run_id, reason, opts)
        end
      rescue
        exception ->
          rollback(run_id, exception, opts)
      after
        FakeUpstream.stop(fake)
        stop_owned_application(apps)
      end
    end
  end

  defp rollback(run_id, reason, opts) do
    cleanup_result =
      with {:ok, journal} <- Journal.read_journal(run_id),
           {:ok, journal} <- Journal.recover_pools(journal),
           {:ok, receipt} <- execute_cleanup(journal, remove_run_dir?: true) do
        {:ok, receipt}
      end

    case cleanup_result do
      {:ok, receipt} ->
        notify_rollback(opts, receipt)
        {:error, failure("proof_failed_rolled_back", reason)}

      {:error, cleanup_reason} ->
        {:error, failure("proof_rollback_failed", {reason, cleanup_reason})}
    end
  end

  defp verify_journal_owner(%{"owner_user_id" => owner_id}, owner_id), do: :ok

  defp verify_journal_owner(_journal, _owner_id),
    do: {:error, "run manifest owner does not match --owner-id"}

  defp execute_proof(scope, journal, run_dir, fake, identity_label, opts) do
    with {:ok, journal, pool} <- provision_pool(scope, journal, run_dir),
         :ok <- maybe_inject_failure(journal, opts),
         {:ok, journal, identity, assignment} <-
           provision_identity(scope, journal, run_dir, pool, identity_label, fake.url),
         :ok <- maybe_inject_failure(journal, opts),
         {:ok, journal, _quota_window} <- provision_routeable_quota(journal, run_dir, identity),
         :ok <- maybe_inject_failure(journal, opts),
         {:ok, journal, api_key, raw_key} <- provision_api_key(scope, journal, run_dir, pool),
         :ok <- maybe_inject_failure(journal, opts),
         {:ok, journal, model} <- provision_catalog(scope, journal, run_dir, pool),
         :ok <- maybe_inject_failure(journal, opts),
         {:ok, journal, _pricing_snapshot} <- provision_pricing_snapshot(journal, run_dir, model),
         :ok <- maybe_inject_failure(journal, opts),
         {:ok, journal, _override} <- provision_serving_override(scope, journal, run_dir, pool),
         :ok <- maybe_inject_failure(journal, opts),
         :ok <- verify_routeability_preconditions(model, assignment, identity),
         correlator = "todo9-exact-" <> random_suffix(),
         {:ok, http_proof} <- routed_http_control(raw_key, correlator),
         {:ok, websocket_proof} <- routed_websocket_control(raw_key, correlator),
         {:ok, journal, rows} <-
           collect_row_evidence(journal, run_dir, correlator, pool, identity, assignment, model),
         {:ok, wire} <- collect_wire_evidence(fake.url, rows),
         {:ok, negative} <- lite_negative_control(fake.url),
         {:ok, cleanup_receipt} <- execute_cleanup(journal, remove_run_dir?: true) do
      {:ok,
       %{
         "mode" => "proof",
         "run_id" => journal["run_id"],
         "model" => @model_id,
         "correlator" => correlator,
         "request_budget" => @request_budget,
         "api_key_prefix_len" => byte_size(api_key.display_name),
         "http" => http_proof,
         "websocket" => websocket_proof,
         "rows" => rows.receipt,
         "wire" => wire,
         "lite_negative_control" => negative,
         "cleanup" => cleanup_receipt
       }}
    end
  end

  defp validate_execution_options(opts) do
    case Keyword.get(opts, :inject_failure_after_owned_rows) do
      nil -> :ok
      count when is_integer(count) and count > 0 -> :ok
      _other -> {:error, "injected failure count must be a positive integer"}
    end
  end

  defp maybe_inject_failure(journal, opts) do
    owned_row_count = length(journal["resources"] || [])

    case Keyword.get(opts, :inject_failure_after_owned_rows) do
      nil -> :ok
      target when owned_row_count >= target -> {:error, :injected_failure}
      _target -> :ok
    end
  end

  defp notify_rollback(opts, receipt) do
    case Keyword.get(opts, :rollback_observer) do
      pid when is_pid(pid) -> send(pid, {:exact_assignment_full_proof, :rollback, receipt})
      _other -> :ok
    end
  end

  # ── Provisioning through existing trusted lifecycles, journaled first. ──

  defp provision_pool(scope, journal, run_dir) do
    slug = journal["pool_slugs"] |> List.first()

    with {:ok, journal} <- intent(journal, run_dir, "pool", "create", %{slug: slug}),
         {:ok, %Pool{} = pool} <-
           %Pool{}
           |> Pool.changeset(%{
             slug: slug,
             name: "Todo 9 exact-assignment Full proof",
             status: "active",
             created_by_user_id: scope.user.id,
             created_at: DateTime.utc_now(),
             updated_at: DateTime.utc_now()
           })
           |> Repo.insert(),
         {:ok, journal} <- completed(journal, run_dir, "pool", pool.id, %{slug: pool.slug}) do
      {:ok, journal, pool}
    else
      {:error, reason} -> {:error, "pool provisioning failed: #{safe_reason(reason)}"}
    end
  end

  defp provision_identity(scope, journal, run_dir, pool, identity_label, fake_url) do
    attrs = %{
      chatgpt_account_id: identity_label,
      account_label: identity_label,
      plan_label: "Pro",
      token: "todo9-dummy-token-" <> random_suffix(),
      access_token_expires_at: DateTime.add(DateTime.utc_now(), 2 * 60 * 60, :second),
      identity_metadata: %{"base_url" => fake_url}
    }

    # Deliberately no audit_action, quota_trigger_kind, or broadcast_reason:
    # nothing may enqueue background or upstream-bound work for this synthetic
    # identity. The dummy token is non-sensitive by construction.
    with {:ok, journal} <- intent(journal, run_dir, "identity", "link", %{label: identity_label}),
         {:ok, %{identity: identity, assignment: assignment, secret_status: _status}} <-
           TokenLinking.link_tokens(scope, pool, attrs, onboarding_method: "import"),
         {:ok, journal} <-
           completed(journal, run_dir, "identity", identity.id, %{label: identity_label}),
         {:ok, journal} <-
           intent(journal, run_dir, "assignment", "link", %{
             pool_id: pool.id,
             identity_id: identity.id
           }),
         {:ok, journal} <-
           completed(journal, run_dir, "assignment", assignment.id, %{
             pool_id: pool.id,
             identity_id: identity.id
           }) do
      {:ok, journal, identity, assignment}
    else
      {:error, reason} -> {:error, "identity provisioning failed: #{safe_reason(reason)}"}
    end
  end

  defp provision_api_key(scope, journal, run_dir, pool) do
    display_name = "todo9-proof-#{journal["run_id"]}"

    with {:ok, journal} <-
           intent(journal, run_dir, "api_key", "create", %{
             pool_id: pool.id,
             display_name: display_name
           }),
         {:ok, %{api_key: %APIKey{} = api_key, raw_key: raw_key}} <-
           Access.create_api_key(scope, pool, %{display_name: display_name}),
         true <- is_binary(raw_key) and raw_key != "",
         {:ok, journal} <-
           completed(journal, run_dir, "api_key", api_key.id, %{
             pool_id: pool.id,
             display_name: display_name
           }) do
      {:ok, journal, api_key, raw_key}
    else
      false -> {:error, "API key provisioning returned no raw key"}
      {:error, reason} -> {:error, "API key provisioning failed: #{safe_reason(reason)}"}
    end
  end

  # This is static task-owned evidence, not a quota refresh/priming trigger:
  # it gives the routing filter one fresh, non-exhausted account window while
  # explicitly suppressing broadcasts and deleting it with the synthetic
  # identity. Without it, the real gateway correctly rejects an account whose
  # quota has never been observed before attempting any upstream dispatch.
  defp provision_routeable_quota(journal, run_dir, identity) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs = %{
      quota_key: "account",
      window_kind: "primary",
      window_minutes: 300,
      used_percent: Decimal.new(1),
      reset_at: DateTime.add(now, 900, :second),
      source: "local_reconciliation",
      source_precision: "observed",
      quota_scope: "account",
      quota_family: "account",
      freshness_state: "fresh",
      last_sync_at: now,
      observed_at: now,
      metadata: %{}
    }

    with {:ok, journal} <- intent(journal, run_dir, "quota_window", "insert", %{}),
         {:ok, [%AccountQuotaWindow{} = window]} <-
           QuotaWindows.upsert_quota_windows(identity, [attrs],
             delete_missing?: false,
             broadcast?: false
           ),
         {:ok, journal} <- completed(journal, run_dir, "quota_window", window.id, %{}) do
      {:ok, journal, window}
    else
      {:error, reason} -> {:error, "routeable quota provisioning failed: #{safe_reason(reason)}"}
      other -> {:error, "routeable quota provisioning failed: #{safe_reason(other)}"}
    end
  end

  defp provision_catalog(_scope, journal, run_dir, pool) do
    with {:ok, journal} <- intent(journal, run_dir, "catalog", "sync", %{pool_id: pool.id}),
         {:ok, %{sync_run: sync_run, models: _models, partial?: false}} <-
           Journal.accept_catalog_sync_result(
             Catalog.sync_pool_catalog(pool, trigger_kind: "manual")
           ),
         {:ok, journal} <-
           completed(journal, run_dir, "sync_run", sync_run.id, %{pool_id: pool.id}),
         models = Catalog.list_models(pool),
         {:ok, journal} <- record_models(journal, run_dir, pool, models),
         %Model{} = model <- Enum.find(models, &(&1.exposed_model_id == @model_id)),
         false <- Map.get(model.metadata, "use_responses_lite") == true do
      {:ok, journal, model}
    else
      nil -> {:error, "catalog sync did not surface the deterministic Full model"}
      true -> {:error, "catalog model unexpectedly advertises Responses Lite"}
      {:error, reason} -> {:error, "catalog provisioning failed: #{safe_reason(reason)}"}
    end
  end

  defp record_models(journal, run_dir, pool, models) do
    Enum.reduce_while(models, {:ok, journal}, fn model, {:ok, current} ->
      {:ok, next} = completed(current, run_dir, "model", model.id, %{pool_id: pool.id})
      {:cont, {:ok, next}}
    end)
  end

  defp provision_serving_override(scope, journal, run_dir, pool) do
    with {:ok, journal} <-
           intent(journal, run_dir, "serving_override", "create", %{
             pool_id: pool.id,
             model_id: @model_id
           }),
         {:ok, %{revision: revision}} <- Pools.model_serving_modes_snapshot(scope, pool),
         {:ok, %{overrides: overrides}} <-
           Pools.update_model_serving_modes(
             scope,
             pool,
             [%{exposed_model_id: @model_id, mode: "full"}],
             revision
           ),
         %ModelServingOverride{} = override <-
           Enum.find(overrides, &(&1.exposed_model_id == @model_id and &1.mode == "full")),
         {:ok, journal} <-
           completed(journal, run_dir, "serving_override", override.id, %{
             pool_id: pool.id,
             model_id: @model_id
           }) do
      {:ok, journal, override}
    else
      nil -> {:error, "serving override was not written as Full"}
      {:error, reason} -> {:error, "serving override failed: #{safe_reason(reason)}"}
    end
  end

  # The gateway reserves accounting before dispatch. This task-owned, zero-rate
  # snapshot is the smallest local prerequisite that lets the proof reach the
  # real Pooler -> fake-upstream boundary; it is journaled and hard-deleted
  # before the receipt is returned.
  defp provision_pricing_snapshot(journal, run_dir, %Model{} = model) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    attrs = %{
      model_identifier: model.upstream_model_id,
      price_version: "todo9-loopback-" <> journal["run_id"],
      currency_code: "USD",
      billing_unit: "token",
      input_token_micros: Decimal.new(0),
      cached_input_token_micros: Decimal.new(0),
      cache_write_token_micros: Decimal.new(0),
      output_token_micros: Decimal.new(0),
      reasoning_token_micros: Decimal.new(0),
      request_base_micros: Decimal.new(0),
      effective_at: DateTime.add(now, -60, :second),
      captured_at: now,
      source_url: "http://127.0.0.1/loopback-pricing",
      config: %{
        "service_tier" => "standard",
        "price_bucket" => "default",
        "pricing_type" => "per_1m_tokens"
      }
    }

    with {:ok, journal} <- intent(journal, run_dir, "pricing_snapshot", "insert", %{}),
         {:ok, %PricingSnapshot{} = snapshot} <-
           attrs |> PricingSnapshot.insert_changeset() |> Repo.insert(),
         {:ok, journal} <- completed(journal, run_dir, "pricing_snapshot", snapshot.id, %{}) do
      {:ok, journal, snapshot}
    else
      {:error, reason} -> {:error, "pricing snapshot provisioning failed: #{safe_reason(reason)}"}
    end
  end

  defp verify_routeability_preconditions(%Model{} = model, assignment, identity) do
    source_bound? =
      assignment.id in List.wrap(get_in(model.metadata || %{}, ["source_assignment_ids"]))

    quota_state =
      identity
      |> QuotaWindows.routing_quota_eligibility(
        model: model.exposed_model_id,
        requested_model: model.exposed_model_id,
        upstream_model: model.upstream_model_id
      )
      |> Map.get(:routing_state)

    case CandidateEligibility.routable_candidates(model) do
      {:ok, candidates} when source_bound? and quota_state == :precise ->
        if Enum.any?(candidates, fn {candidate, _identity} -> candidate.id == assignment.id end) do
          :ok
        else
          {:error, "routeability preflight candidate binding mismatch"}
        end

      {:ok, candidates} ->
        {:error,
         "routeability preflight failed source_bound=#{source_bound?} quota_precise=#{quota_state == :precise} candidate_count=#{length(candidates)}"}

      {:error, _reason} ->
        {:error,
         "routeability preflight failed source_bound=#{source_bound?} quota_precise=#{quota_state == :precise} candidate_count=0"}
    end
  end

  # ── Bounded routed traffic. ──

  defp routed_http_control(raw_key, correlator) do
    response =
      Req.post!("http://127.0.0.1:#{@pooler_port}#{@responses_endpoint}",
        headers: [
          {"authorization", "Bearer " <> raw_key},
          {"x-request-id", correlator},
          {"accept", "text/event-stream"}
        ],
        json: %{
          "model" => @model_id,
          "instructions" => "You are a bounded loopback control.",
          "input" => [
            %{
              "type" => "message",
              "role" => "user",
              "content" => [%{"type" => "input_text", "text" => "hello"}]
            }
          ],
          "stream" => true
        },
        retry: false,
        decode_body: false,
        receive_timeout: @traffic_deadline_ms
      )

    body = IO.iodata_to_binary(response.body)

    cond do
      response.status != 200 ->
        {:error, http_failure_reason(response.status, body)}

      not String.contains?(body, "response.completed") ->
        {:error, "routed HTTP control did not reach response.completed"}

      true ->
        {:ok, %{"status" => 200, "terminal" => "response.completed"}}
    end
  end

  # A failed control reports only stable error taxonomy fields. The request
  # body itself is deliberately never rendered or retained.
  defp http_failure_reason(status, body) do
    summary =
      with {:ok, %{"error" => error}} when is_map(error) <- Jason.decode(body),
           code when is_binary(code) <- Map.get(error, "code"),
           type when is_binary(type) <- Map.get(error, "type"),
           true <- bounded_error_token?(code),
           true <- bounded_error_token?(type) do
        " error_fingerprint=#{fingerprint({code, type})}"
      else
        _other -> ""
      end

    "routed HTTP control returned status #{status}#{summary}"
  end

  defp bounded_error_token?(value)
       when is_binary(value) and byte_size(value) in 1..80,
       do: String.match?(value, ~r/\A[a-z0-9_.-]+\z/)

  defp bounded_error_token?(_value), do: false

  defp routed_websocket_control(raw_key, correlator) do
    headers = [
      {"authorization", "Bearer " <> raw_key},
      {"x-request-id", correlator}
    ]

    payload =
      Jason.encode!(%{
        "type" => "response.create",
        "model" => @model_id,
        "instructions" => "You are a bounded loopback control.",
        "input" => [
          %{
            "type" => "message",
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => "hello"}]
          }
        ],
        "stream" => true,
        "generate" => true,
        "client_metadata" => %{@websocket_probe_metadata_key => "1"}
      })

    new_websocket = &Mint.WebSocket.new/4

    with {:ok, conn} <- Mint.HTTP.connect(:http, "127.0.0.1", @pooler_port, protocols: [:http1]),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(:ws, conn, @responses_endpoint, headers),
         {:ok, conn, response_headers, rest_entries} <- websocket_await_upgrade(conn, ref),
         {:ok, conn, websocket} <- new_websocket.(conn, ref, 101, response_headers),
         {:ok, websocket, frame_data} <- Mint.WebSocket.encode(websocket, {:text, payload}),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(conn, ref, frame_data),
         {:ok, conn, _websocket, terminal} <-
           websocket_await_terminal(conn, ref, websocket, rest_entries) do
      Mint.HTTP.close(conn)
      {:ok, %{"upgrade_status" => 101, "terminal" => terminal}}
    else
      {:error, reason} -> {:error, "routed websocket control failed: #{safe_reason(reason)}"}
      {:error, _conn, reason} -> {:error, "websocket upgrade failed: #{safe_reason(reason)}"}
    end
  end

  defp websocket_await_upgrade(conn, ref) do
    deadline = System.monotonic_time(:millisecond) + @traffic_deadline_ms
    websocket_await_upgrade(conn, ref, nil, nil, [], deadline)
  end

  defp websocket_await_upgrade(conn, ref, status, headers, rest, deadline) do
    cond do
      status == 101 and is_list(headers) ->
        {:ok, conn, headers, rest}

      is_integer(status) ->
        {:error, "downstream websocket upgrade returned #{status}"}

      System.monotonic_time(:millisecond) > deadline ->
        {:error, "downstream websocket upgrade timed out"}

      true ->
        receive do
          message ->
            case Mint.WebSocket.stream(conn, message) do
              :unknown ->
                websocket_await_upgrade(conn, ref, status, headers, rest, deadline)

              {:ok, conn, entries} ->
                status =
                  status ||
                    Enum.find_value(entries, fn
                      {:status, ^ref, code} -> code
                      _other -> nil
                    end)

                headers =
                  headers ||
                    Enum.find_value(entries, fn
                      {:headers, ^ref, found} -> found
                      _other -> nil
                    end)

                data_entries =
                  Enum.filter(entries, fn
                    {:data, ^ref, _data} -> true
                    _other -> false
                  end)

                websocket_await_upgrade(
                  conn,
                  ref,
                  status,
                  headers,
                  rest ++ data_entries,
                  deadline
                )

              {:error, _conn, reason, _responses} ->
                {:error, "websocket upgrade receive failed: #{safe_reason(reason)}"}
            end
        after
          5_000 ->
            websocket_await_upgrade(conn, ref, status, headers, rest, deadline)
        end
    end
  end

  defp websocket_await_terminal(conn, ref, websocket, initial_entries) do
    deadline = System.monotonic_time(:millisecond) + @traffic_deadline_ms
    websocket_drain_entries(conn, ref, websocket, initial_entries, deadline)
  end

  defp websocket_drain_entries(conn, ref, websocket, entries, deadline) do
    {websocket, terminal} =
      Enum.reduce(entries, {websocket, nil}, fn
        {:data, ^ref, data}, {socket, found} ->
          case Mint.WebSocket.decode(socket, data) do
            {:ok, socket, frames} ->
              {socket, found || websocket_terminal_in(frames)}

            {:error, socket, _reason} ->
              {socket, found}
          end

        _entry, acc ->
          acc
      end)

    cond do
      is_binary(terminal) ->
        {:ok, conn, websocket, terminal}

      System.monotonic_time(:millisecond) > deadline ->
        {:error, "routed websocket control timed out before response.completed"}

      true ->
        receive do
          message ->
            case Mint.WebSocket.stream(conn, message) do
              :unknown ->
                websocket_drain_entries(conn, ref, websocket, [], deadline)

              {:ok, conn, new_entries} ->
                websocket_drain_entries(conn, ref, websocket, new_entries, deadline)

              {:error, _conn, reason, _responses} ->
                {:error, "websocket receive failed: #{safe_reason(reason)}"}
            end
        after
          5_000 ->
            websocket_drain_entries(conn, ref, websocket, [], deadline)
        end
    end
  end

  defp websocket_terminal_in(frames) do
    Enum.find_value(frames, fn
      {:text, text} ->
        case Jason.decode(text) do
          {:ok, %{"type" => "response.completed"}} -> "response.completed"
          _other -> nil
        end

      _frame ->
        nil
    end)
  end

  # ── Durable-row and wire evidence. ──

  defp collect_row_evidence(journal, run_dir, correlator, pool, identity, assignment, model) do
    with {:ok, requests} <- poll_correlated_requests(correlator, pool.id),
         {:ok, journal} <- record_requests(journal, run_dir, pool, requests),
         attempts = correlated_attempts(requests),
         :ok <- validate_rows(requests, attempts, pool, identity, assignment, model) do
      http_request = Enum.find(requests, &(&1.transport == "http_sse"))
      websocket_request = Enum.find(requests, &(&1.transport == "websocket"))

      fingerprint_by_transport =
        Map.new(attempts, fn attempt ->
          upstream_request_id = attempt.response_metadata["upstream_request_id"]
          {attempt.transport, FakeUpstream.upstream_request_id_fingerprint(upstream_request_id)}
        end)

      receipt = %{
        "request_count" => length(requests),
        "attempt_count" => length(attempts),
        "transports" => requests |> Enum.map(& &1.transport) |> Enum.sort(),
        "endpoint" => @responses_endpoint,
        "requested_model" => @model_id,
        "retry_counts" => requests |> Enum.map(& &1.retry_count) |> Enum.uniq(),
        "model_serving_mode_configured" =>
          routing_values(requests, "model_serving_mode_configured"),
        "model_serving_mode" => routing_values(requests, "model_serving_mode"),
        "model_serving_mode_source" => routing_values(requests, "model_serving_mode_source"),
        "attempt_identity_match" =>
          Enum.all?(attempts, &(&1.upstream_identity_id == identity.id)),
        "attempt_assignment_match" =>
          Enum.all?(attempts, &(&1.pool_upstream_assignment_id == assignment.id)),
        "upstream_request_id_fingerprints" => fingerprint_by_transport
      }

      {:ok, journal,
       %{
         receipt: receipt,
         requests: requests,
         http_request: http_request,
         websocket_request: websocket_request,
         fingerprints: fingerprint_by_transport
       }}
    end
  end

  defp poll_correlated_requests(correlator, pool_id) do
    deadline = System.monotonic_time(:millisecond) + @row_poll_timeout_ms
    poll_correlated_requests(correlator, pool_id, deadline)
  end

  defp poll_correlated_requests(correlator, pool_id, deadline) do
    requests =
      Repo.all(
        from request in Request,
          where: request.pool_id == ^pool_id,
          where: fragment("? ->> 'client_request_id' = ?", request.request_metadata, ^correlator),
          order_by: [asc: request.admitted_at]
      )

    complete? =
      length(requests) == 2 and
        Enum.all?(requests, fn request ->
          attempts = correlated_attempts([request])

          length(attempts) == 1 and
            is_binary(hd(attempts).response_metadata["upstream_request_id"])
        end)

    cond do
      complete? ->
        {:ok, requests}

      System.monotonic_time(:millisecond) > deadline ->
        {:error,
         "correlated request rows incomplete: #{length(requests)} rows for the shared correlator"}

      true ->
        Process.sleep(250)
        poll_correlated_requests(correlator, pool_id, deadline)
    end
  end

  defp correlated_attempts(requests) do
    request_ids = Enum.map(requests, & &1.id)

    Repo.all(
      from attempt in Attempt,
        where: attempt.request_id in ^request_ids,
        order_by: [asc: attempt.started_at]
    )
  end

  defp record_requests(journal, run_dir, pool, requests) do
    Enum.reduce_while(requests, {:ok, journal}, fn request, {:ok, current} ->
      {:ok, next} = completed(current, run_dir, "request", request.id, %{pool_id: pool.id})
      {:cont, {:ok, next}}
    end)
  end

  defp validate_rows(requests, attempts, pool, identity, assignment, model) do
    transports = requests |> Enum.map(& &1.transport) |> Enum.sort()

    checks = [
      {length(requests) == 2, "expected exactly two correlated request rows"},
      {transports == ["http_sse", "websocket"], "expected one HTTP SSE and one websocket row"},
      {Enum.all?(requests, &(&1.endpoint == @responses_endpoint)), "unexpected endpoint"},
      {Enum.all?(requests, &(&1.requested_model == @model_id)), "unexpected requested model"},
      {Enum.all?(requests, &(&1.retry_count == 0)), "retry_count was not zero"},
      {Enum.all?(requests, &(&1.model_id == model.id)), "request rows resolved another model"},
      {Enum.all?(requests, &(&1.pool_id == pool.id)), "request rows outside the task pool"},
      {routing_values(requests, "model_serving_mode_configured") == ["full"],
       "configured serving mode was not full"},
      {routing_values(requests, "model_serving_mode") == ["full"],
       "effective serving mode was not full"},
      {routing_values(requests, "model_serving_mode_source") == ["override"],
       "serving mode source was not override"},
      {length(attempts) == 2, "expected exactly one attempt per request"},
      {Enum.all?(attempts, &(&1.attempt_number == 1)), "attempts retried"},
      {Enum.all?(attempts, &(&1.upstream_identity_id == identity.id)),
       "attempt identity was not the task identity"},
      {Enum.all?(attempts, &(&1.pool_upstream_assignment_id == assignment.id)),
       "attempt assignment was not the task assignment"}
    ]

    case Enum.find(checks, fn {ok?, _message} -> not ok? end) do
      nil -> :ok
      {_failed, message} -> {:error, "row evidence failed: #{message}"}
    end
  end

  defp routing_values(requests, key) do
    requests
    |> Enum.map(&get_in(&1.request_metadata, ["routing", key]))
    |> Enum.uniq()
  end

  defp collect_wire_evidence(fake_url, rows) do
    with {:ok, captures} <- read_wire_captures(fake_url) do
      http_fingerprint = rows.fingerprints["http_sse"]
      websocket_fingerprint = rows.fingerprints["websocket"]
      http_entry = captures[http_fingerprint]
      websocket_entry = captures[websocket_fingerprint]

      checks = [
        {is_map(http_entry), "HTTP wire capture entry missing for the attempt fingerprint"},
        {is_map(websocket_entry),
         "websocket wire capture entry missing for the attempt fingerprint"},
        {is_map(http_entry) and http_entry["upstreamRequestIdFingerprint"] == http_fingerprint,
         "HTTP capture fingerprint mismatch"},
        {is_map(websocket_entry) and
           websocket_entry["upstreamRequestIdFingerprint"] == websocket_fingerprint,
         "websocket capture fingerprint mismatch"},
        {is_map(http_entry) and http_entry["httpHeaderNames"] != [],
         "HTTP capture observed no header names"},
        {is_map(http_entry) and @lite_http_header not in List.wrap(http_entry["httpHeaderNames"]),
         "HTTP Lite header reached the fake upstream"},
        {is_map(websocket_entry) and websocket_entry["websocketClientMetadataKeys"] != [],
         "websocket capture observed no client metadata keys"},
        {is_map(websocket_entry) and
           @websocket_probe_metadata_key in List.wrap(
             websocket_entry["websocketClientMetadataKeys"]
           ), "websocket capture did not observe the probe metadata key"},
        {is_map(websocket_entry) and
           @lite_websocket_metadata_key not in List.wrap(
             websocket_entry["websocketClientMetadataKeys"]
           ), "websocket Lite client metadata reached the fake upstream"}
      ]

      case Enum.find(checks, fn {ok?, _message} -> not ok? end) do
        nil ->
          {:ok,
           %{
             "http_header_name_count" => length(http_entry["httpHeaderNames"]),
             "http_lite_header_present" => false,
             "websocket_metadata_key_count" =>
               length(websocket_entry["websocketClientMetadataKeys"]),
             "websocket_lite_metadata_present" => false,
             "fingerprints_matched" => true
           }}

        {_failed, message} ->
          {:error, "wire evidence failed: #{message}"}
      end
    end
  end

  defp read_wire_captures(fake_url) do
    response =
      Req.get!(fake_url <> "/__smoke/wire-capture",
        retry: false,
        receive_timeout: 10_000
      )

    case response do
      %{status: 200, body: body} when is_map(body) -> {:ok, body}
      %{status: status} -> {:error, "wire capture read returned status #{status}"}
    end
  end

  # The observer must discriminate, not merely report absence: a direct request
  # to the fake carrying the Lite header must be detected and rejected by the
  # same classification the routed proof relies on. This request does not touch
  # Pooler and counts against the fixed three-request budget.
  defp lite_negative_control(fake_url) do
    response =
      Req.post!(fake_url <> @responses_endpoint,
        headers: [{@lite_http_header, "true"}],
        json: %{"model" => @model_id},
        retry: false,
        decode_body: false,
        receive_timeout: 10_000
      )

    upstream_request_id =
      response.headers
      |> Map.get("x-request-id", [])
      |> List.first()

    with true <- is_binary(upstream_request_id),
         fingerprint = FakeUpstream.upstream_request_id_fingerprint(upstream_request_id),
         {:ok, captures} <- read_wire_captures(fake_url),
         entry when is_map(entry) <- captures[fingerprint] do
      detected? = @lite_http_header in List.wrap(entry["httpHeaderNames"])

      if detected? do
        {:ok, %{"lite_header_detected" => true, "classified_full" => false}}
      else
        {:error, "Lite negative control was not detected by the wire observer"}
      end
    else
      _other -> {:error, "Lite negative control could not be correlated"}
    end
  end

  # ── Exact cleanup: hard delete journaled rows, then read back zero. ──

  defp execute_cleanup(journal, opts) do
    run_dir = Path.join(@runtime_root, journal["run_id"])
    plan = Journal.exact_cleanup_plan(journal)

    with :ok <- validate_cleanup_ownership_or_absence(plan, journal),
         {:ok, traffic_counts} <- delete_traffic_rows(journal),
         {:ok, pricing_counts} <- delete_pricing_snapshots(journal),
         {:ok, plan_counts} <- delete_plan_rows(plan),
         {:ok, identity_counts} <- delete_identity_rows(journal),
         {:ok, job_counts} <- delete_task_oban_jobs(journal),
         :ok <- require_zero_oban_jobs(journal),
         {:ok, readback} <- readback_zero(journal, plan) do
      journal =
        journal
        |> Journal.append_operation("completed", "cleanup", %{})
        |> Map.put("cleanup_status", "completed")

      :ok = Journal.write_journal!(run_dir, journal)

      removed_run_dir? =
        if Keyword.get(opts, :remove_run_dir?, false) do
          File.rm_rf!(run_dir)
          not File.exists?(run_dir)
        else
          false
        end

      {:ok,
       %{
         "deleted" =>
           traffic_counts
           |> Map.merge(pricing_counts)
           |> Map.merge(plan_counts)
           |> Map.merge(identity_counts)
           |> Map.merge(job_counts),
         "readback_zero" => readback,
         "run_dir_removed" => removed_run_dir?
       }}
    end
  end

  defp delete_traffic_rows(journal) do
    request_ids = journaled_ids(journal, "request")
    pool_ids = journaled_ids(journal, "pool")

    session_ids =
      Repo.all(
        from session in CodexSession,
          where: session.pool_id in ^pool_ids,
          select: session.id
      )

    {audit_count, _} =
      Repo.delete_all(from audit in AuditEvent, where: audit.pool_id in ^pool_ids)

    {idempotency_count, _} =
      Repo.delete_all(
        from key in IdempotencyKey,
          where: key.pool_id in ^pool_ids or key.request_id in ^request_ids
      )

    {turn_count, _} =
      Repo.delete_all(
        from turn in CodexTurn,
          where: turn.request_id in ^request_ids or turn.codex_session_id in ^session_ids
      )

    {ledger_count, _} =
      Repo.delete_all(from entry in LedgerEntry, where: entry.request_id in ^request_ids)

    {fact_count, _} =
      Repo.delete_all(from fact in RequestLogFact, where: fact.request_id in ^request_ids)

    {attempt_count, _} =
      Repo.delete_all(from attempt in Attempt, where: attempt.request_id in ^request_ids)

    {request_count, _} =
      Repo.delete_all(from request in Request, where: request.id in ^request_ids)

    {lease_count, _} =
      Repo.delete_all(from lease in BridgeOwnerLease, where: lease.pool_id in ^pool_ids)

    {alias_count, _} =
      Repo.delete_all(
        from bridge_alias in BridgeSessionAlias, where: bridge_alias.pool_id in ^pool_ids
      )

    {session_count, _} =
      Repo.delete_all(from session in CodexSession, where: session.pool_id in ^pool_ids)

    {affinity_count, _} =
      Repo.delete_all(from affinity in BridgeAffinity, where: affinity.pool_id in ^pool_ids)

    {demotion_count, _} =
      Repo.delete_all(from demotion in BridgeDemotion, where: demotion.pool_id in ^pool_ids)

    {circuit_count, _} =
      Repo.delete_all(from circuit in RoutingCircuitState, where: circuit.pool_id in ^pool_ids)

    {routing_settings_count, _} =
      Repo.delete_all(from settings in RoutingSettings, where: settings.pool_id in ^pool_ids)

    {:ok,
     %{
       "audit_events" => audit_count,
       "idempotency_keys" => idempotency_count,
       "ledger_entries" => ledger_count,
       "request_log_facts" => fact_count,
       "attempts" => attempt_count,
       "requests" => request_count,
       "codex_turns" => turn_count,
       "bridge_owner_leases" => lease_count,
       "bridge_session_aliases" => alias_count,
       "codex_sessions" => session_count,
       "bridge_affinities" => affinity_count,
       "bridge_demotions" => demotion_count,
       "routing_circuit_states" => circuit_count,
       "pool_routing_settings" => routing_settings_count
     }}
  end

  defp delete_plan_rows(plan) do
    schema_by_kind = %{
      "serving_override" => ModelServingOverride,
      "assignment" => PoolUpstreamAssignment,
      "api_key" => APIKey,
      "model" => Model,
      "pool" => Pool
    }

    plan
    |> Enum.reduce_while({:ok, %{}}, fn resource, {:ok, counts} ->
      kind = resource["kind"]
      schema = Map.fetch!(schema_by_kind, kind)

      case Repo.get(schema, resource["id"]) do
        nil ->
          {:cont, {:ok, Map.update(counts, kind, 0, & &1)}}

        row ->
          case delete_plan_row(kind, row) do
            {:ok, _deleted} ->
              {:cont, {:ok, Map.update(counts, kind, 1, &(&1 + 1))}}

            {:error, reason} ->
              {:halt, {:error, "cleanup of #{kind} failed: #{safe_reason(reason)}"}}
          end
      end
    end)
    |> case do
      {:ok, counts} -> {:ok, %{"plan_rows" => counts}}
      error -> error
    end
  end

  # A journal may be replayed after a cleanup attempt has already removed its
  # plan rows but failed on a later prerequisite. Absence of the exact
  # journaled id is safe; a present row must still satisfy the shared ownership
  # validation before any deletion can continue.
  defp validate_cleanup_ownership_or_absence(plan, journal) do
    present_plan =
      Enum.filter(plan, fn resource ->
        Repo.get(plan_schema!(resource["kind"]), resource["id"]) != nil
      end)

    Journal.validate_cleanup_ownership(present_plan, journal)
  end

  defp plan_schema!("serving_override"), do: ModelServingOverride
  defp plan_schema!("assignment"), do: PoolUpstreamAssignment
  defp plan_schema!("api_key"), do: APIKey
  defp plan_schema!("model"), do: Model
  defp plan_schema!("pool"), do: Pool

  defp delete_pricing_snapshots(journal) do
    snapshot_ids = journaled_ids(journal, "pricing_snapshot")

    {count, _} =
      Repo.delete_all(from snapshot in PricingSnapshot, where: snapshot.id in ^snapshot_ids)

    {:ok, %{"pricing_snapshots" => count}}
  end

  defp delete_plan_row("pool", %Pool{} = pool) do
    # Rows created implicitly with the Pool and owned by it through the run.
    Repo.delete_all(from sync_run in SyncRun, where: sync_run.pool_id == ^pool.id)
    Repo.delete(pool)
  end

  defp delete_plan_row(_kind, row), do: Repo.delete(row)

  defp delete_identity_rows(journal) do
    identity_ids = journaled_ids(journal, "identity")
    quota_window_ids = journaled_ids(journal, "quota_window")
    labels = journal["identity_labels"] || []

    identities =
      Repo.all(from identity in UpstreamIdentity, where: identity.id in ^identity_ids)

    if Enum.all?(identities, &(&1.account_label in labels)) do
      {quota_window_count, _} =
        Repo.delete_all(from window in AccountQuotaWindow, where: window.id in ^quota_window_ids)

      {secret_count, _} =
        Repo.delete_all(
          from secret in EncryptedSecret, where: secret.upstream_identity_id in ^identity_ids
        )

      {identity_count, _} =
        Repo.delete_all(from identity in UpstreamIdentity, where: identity.id in ^identity_ids)

      {:ok,
       %{
         "quota_windows" => quota_window_count,
         "encrypted_secrets" => secret_count,
         "upstream_identities" => identity_count
       }}
    else
      {:error, "journaled identity ownership did not match its task label"}
    end
  end

  defp require_zero_oban_jobs(journal) do
    pool_ids = journaled_ids(journal, "pool")
    identity_ids = journaled_ids(journal, "identity")
    references = pool_ids ++ identity_ids

    count =
      Enum.reduce(references, 0, fn id, total ->
        total +
          Repo.one(
            from job in Oban.Job,
              where:
                fragment("?->>'pool_id' = ?", job.args, ^id) or
                  fragment("?->>'upstream_identity_id' = ?", job.args, ^id) or
                  fragment("?->>'identity_id' = ?", job.args, ^id),
              select: count(job.id)
          )
      end)

    if count == 0, do: :ok, else: {:error, "#{count} Oban jobs reference task-owned rows"}
  end

  defp delete_task_oban_jobs(journal) do
    references = journaled_ids(journal, "pool") ++ journaled_ids(journal, "identity")

    job_ids =
      references
      |> Enum.flat_map(fn id ->
        Repo.all(
          from job in Oban.Job,
            where:
              fragment("?->>'pool_id' = ?", job.args, ^id) or
                fragment("?->>'upstream_identity_id' = ?", job.args, ^id) or
                fragment("?->>'identity_id' = ?", job.args, ^id),
            select: job.id
        )
      end)
      |> Enum.uniq()

    {count, _} = Repo.delete_all(from job in Oban.Job, where: job.id in ^job_ids)
    {:ok, %{"oban_jobs" => count}}
  end

  defp readback_zero(journal, plan) do
    request_ids = journaled_ids(journal, "request")
    identity_ids = journaled_ids(journal, "identity")
    pool_ids = journaled_ids(journal, "pool")
    pricing_snapshot_ids = journaled_ids(journal, "pricing_snapshot")
    quota_window_ids = journaled_ids(journal, "quota_window")

    plan_gone? =
      Enum.all?(plan, fn resource ->
        schema =
          Map.fetch!(
            %{
              "serving_override" => ModelServingOverride,
              "assignment" => PoolUpstreamAssignment,
              "api_key" => APIKey,
              "model" => Model,
              "pool" => Pool
            },
            resource["kind"]
          )

        Repo.get(schema, resource["id"]) == nil
      end)

    counts = %{
      "requests" => count_where(Request, :id, request_ids),
      "pricing_snapshots" => count_where(PricingSnapshot, :id, pricing_snapshot_ids),
      "quota_windows" => count_where(AccountQuotaWindow, :id, quota_window_ids),
      "attempts" =>
        Repo.one(
          from attempt in Attempt, where: attempt.request_id in ^request_ids, select: count()
        ),
      "upstream_identities" => count_where(UpstreamIdentity, :id, identity_ids),
      "encrypted_secrets" =>
        Repo.one(
          from secret in EncryptedSecret,
            where: secret.upstream_identity_id in ^identity_ids,
            select: count()
        ),
      "pools" => count_where(Pool, :id, pool_ids),
      "pool_models" =>
        Repo.one(from model in Model, where: model.pool_id in ^pool_ids, select: count()),
      "pool_sync_runs" =>
        Repo.one(from sync_run in SyncRun, where: sync_run.pool_id in ^pool_ids, select: count()),
      "pool_sessions" =>
        Repo.one(
          from session in CodexSession, where: session.pool_id in ^pool_ids, select: count()
        ),
      "codex_turns" =>
        Repo.one(
          from turn in CodexTurn,
            where:
              turn.codex_session_id in subquery(
                from(session in CodexSession,
                  where: session.pool_id in ^pool_ids,
                  select: session.id
                )
              ),
            select: count()
        ),
      "bridge_owner_leases" =>
        Repo.one(
          from lease in BridgeOwnerLease, where: lease.pool_id in ^pool_ids, select: count()
        ),
      "bridge_session_aliases" =>
        Repo.one(
          from alias_record in BridgeSessionAlias,
            where: alias_record.pool_id in ^pool_ids,
            select: count()
        ),
      "bridge_affinities" =>
        Repo.one(
          from affinity in BridgeAffinity, where: affinity.pool_id in ^pool_ids, select: count()
        ),
      "bridge_demotions" =>
        Repo.one(
          from demotion in BridgeDemotion, where: demotion.pool_id in ^pool_ids, select: count()
        ),
      "routing_circuit_states" =>
        Repo.one(
          from circuit in RoutingCircuitState,
            where: circuit.pool_id in ^pool_ids,
            select: count()
        ),
      "idempotency_keys" =>
        Repo.one(from key in IdempotencyKey, where: key.pool_id in ^pool_ids, select: count()),
      "pool_routing_settings" =>
        Repo.one(
          from settings in RoutingSettings, where: settings.pool_id in ^pool_ids, select: count()
        ),
      "audit_events" =>
        Repo.one(from audit in AuditEvent, where: audit.pool_id in ^pool_ids, select: count())
    }

    if plan_gone? and Enum.all?(counts, fn {_key, value} -> value == 0 end) do
      {:ok, Map.put(counts, "plan_rows_gone", true)}
    else
      {:error, "cleanup readback found surviving task-owned rows: #{inspect(counts)}"}
    end
  end

  defp count_where(schema, field, ids) do
    Repo.one(from row in schema, where: field(row, ^field) in ^ids, select: count())
  end

  defp journaled_ids(journal, kind) do
    (journal["resources"] || [])
    |> Enum.filter(&(&1["kind"] == kind and is_binary(&1["id"])))
    |> Enum.map(& &1["id"])
    |> Enum.uniq()
  end

  # ── Journal wrappers over the shared smoke helpers. ──

  defp intent(journal, run_dir, kind, operation, fields) do
    journal =
      Journal.append_operation(journal, "intent", kind, Map.put(fields, :operation, operation))

    :ok = Journal.write_journal!(run_dir, journal)
    {:ok, journal}
  end

  defp completed(journal, run_dir, kind, id, fields) do
    journal =
      journal
      |> Journal.record_resource(kind, id, fields)
      |> Journal.append_operation("completed", kind, %{id: id})

    :ok = Journal.write_journal!(run_dir, journal)
    {:ok, journal}
  end

  # ── Owned application boot: endpoint on loopback, manual Oban, no watchers. ──

  defp start_owned_application do
    endpoint_env = Application.get_env(:codex_pooler, CodexPoolerWeb.Endpoint, [])

    Application.put_env(
      :codex_pooler,
      CodexPoolerWeb.Endpoint,
      endpoint_env
      |> Keyword.put(:server, true)
      |> Keyword.put(:http, ip: {127, 0, 0, 1}, port: @pooler_port)
      |> Keyword.put(:watchers, [])
      |> Keyword.put(:code_reloader, false)
    )

    oban_env = Application.get_env(:codex_pooler, Oban, [])
    Application.put_env(:codex_pooler, Oban, Keyword.put(oban_env, :testing, :manual))

    case Application.ensure_all_started(:codex_pooler) do
      {:ok, apps} -> {:ok, apps}
      {:error, reason} -> {:error, "owned application could not start: #{safe_reason(reason)}"}
    end
  end

  defp stop_owned_application([]), do: :ok
  defp stop_owned_application(_apps), do: Application.stop(:codex_pooler)

  defp start_fake_upstream(run_id) do
    profile = Enum.find(FakeUpstream.profiles(), &(&1["name"] == "opencode-text-ok"))

    FakeUpstream.start_link(
      host: "127.0.0.1",
      port: 0,
      profiles: [profile],
      run_id: run_id
    )
    |> case do
      {:ok, fake} -> {:ok, fake}
      {:error, reason} -> {:error, "fake upstream could not start: #{safe_reason(reason)}"}
    end
  end

  defp require_port_free(port) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 500) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        {:error, "port #{port} is already in use; stop the dev server first (make dev-stop)"}

      {:error, _reason} ->
        :ok
    end
  end

  defp owner_scope(owner_id) do
    resolved_owner_id =
      case owner_id do
        id when is_binary(id) and id != "" ->
          {:ok, id}

        _absent ->
          case sole_instance_owner_ids() do
            [id] -> {:ok, id}
            ids -> {:error, "expected exactly one active instance owner, found #{length(ids)}"}
          end
      end

    with {:ok, id} <- resolved_owner_id,
         %User{status: "active", deleted_at: nil} = user <- Repo.get(User, id),
         %Scope{} = scope <- Scope.for_user(user),
         true <- Pools.owner?(scope) do
      {:ok, scope}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, "owner id does not identify an active instance owner"}
    end
  end

  defp sole_instance_owner_ids do
    %{rows: rows} =
      Repo.query!("""
      SELECT DISTINCT users.id::text
      FROM users
      JOIN memberships ON memberships.user_id = users.id
      WHERE users.status = 'active'
        AND users.deleted_at IS NULL
        AND memberships.role = 'instance_owner'
        AND memberships.status = 'active'
      ORDER BY users.id::text
      """)

    Enum.map(rows, &hd/1)
  end

  defp generate_run_id do
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")
    timestamp <> "-" <> random_suffix()
  end

  defp random_suffix do
    Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
  end

  defp safe_reason(reason), do: "reason_fingerprint:" <> fingerprint(reason)

  defp failure(class, reason), do: class <> ":" <> fingerprint(reason)

  defp fingerprint(reason) do
    reason
    |> inspect(limit: 50, printable_limit: 200)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end
end
