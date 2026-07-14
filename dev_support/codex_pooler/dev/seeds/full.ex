defmodule CodexPooler.Dev.Seeds.Full do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Access.{APIKey, Invite}
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Catalog.Sync.PreservedSources
  alias CodexPooler.Gateway.Persistence.RoutingCircuitState
  alias CodexPooler.Pools.{OperatorPoolAssignment, Pool}
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  @typep quota_window_spec :: %{
           required(:window_kind) => String.t(),
           required(:window_minutes) => pos_integer(),
           required(:quota_key) => String.t(),
           required(:active_limit) => non_neg_integer(),
           required(:credits) => non_neg_integer() | nil,
           required(:used_percent) => String.t() | nil,
           required(:freshness_state) => String.t()
         }

  @seed_key "codex_pooler_dev_seed"

  @spec run(%{
          required(:owner) => User.t(),
          required(:operators) => [User.t()],
          required(:password) => String.t()
        }) :: map()
  def run(%{owner: owner, operators: operators, password: password}) do
    reset_full_fake_data!()

    pool_active = seed_pool!(owner, %{slug: "dev-primary", name: "Dev Primary Pool"})
    pool_secondary = seed_pool!(owner, %{slug: "dev-secondary", name: "Dev Secondary Pool"})

    pool_disabled =
      seed_pool!(owner, %{
        slug: "dev-disabled",
        name: "Dev Disabled Pool",
        status: "disabled",
        disabled_at: minutes_ago(90)
      })

    api_keys = seed_api_keys!(owner, pool_active)
    seed_operator_pool_assignments!(owner, operators, pool_active)
    identities = seed_identities!(owner)
    assignments = seed_assignments!(owner, pool_active, identities)

    [active | _rest] = identities

    secondary_assignment =
      seed_assignment!(
        assignment_attrs(
          owner,
          pool_secondary,
          active,
          "Dev Active Secondary Assignment",
          "active",
          "active",
          "eligible"
        )
      )

    models = seed_models!(pool_active, assignments, secondary_assignment)
    secondary_models = seed_secondary_models!(pool_secondary, secondary_assignment)
    seed_routing_circuit_states!(pool_active, assignments, active)
    quota_windows = seed_quota_windows!(identities)
    request_logs = seed_request_logs!(pool_active, api_keys, assignments, models)
    seed_recent_token_usage!(pool_active, api_keys, assignments, models)
    invites = seed_invites!(owner, pool_active)
    audit_events = seed_audit_events!(owner, pool_active, api_keys)
    jobs = seed_jobs!(pool_active, assignments, identities, api_keys)

    %{
      owner: owner,
      operators: operators,
      password: password,
      pools: [pool_active, pool_secondary, pool_disabled],
      api_keys: api_keys,
      upstream_identities: identities,
      assignments: assignments ++ [secondary_assignment],
      models: models ++ secondary_models,
      quota_windows: quota_windows,
      request_logs: request_logs,
      invites: invites,
      audit_events: audit_events,
      jobs: jobs
    }
  end

  defp reset_full_fake_data! do
    Repo.delete_all(
      from job in Oban.Job, where: fragment("?->>?", job.meta, "dev_seed") == ^@seed_key
    )

    Repo.delete_all(
      from event in AuditEvent, where: fragment("?->>?", event.details, "dev_seed") == ^@seed_key
    )

    Repo.delete_all(
      from invite in Invite, where: like(invite.invited_email, "dev-invite-%@example.com")
    )

    Repo.delete_all(
      from pool in Pool, where: pool.slug in ["dev-primary", "dev-secondary", "dev-disabled"]
    )

    Repo.delete_all(
      from identity in UpstreamIdentity,
        where: fragment("?->>?", identity.metadata, "dev_seed") == ^@seed_key
    )
  end

  defp seed_pool!(owner, attrs) do
    timestamp = now()

    %Pool{}
    |> Pool.changeset(%{
      slug: attrs.slug,
      name: attrs.name,
      status: Map.get(attrs, :status, "active"),
      disabled_at: Map.get(attrs, :disabled_at),
      created_by_user_id: owner.id,
      created_at: timestamp,
      updated_at: timestamp
    })
    |> Repo.insert!()
  end

  defp seed_api_keys!(owner, pool) do
    scope = Scope.for_user(owner, ["instance_owner"])
    active = create_api_key!(scope, pool, "Dev active key", %{labels: ["dev", "active"]})
    limited = create_api_key!(scope, pool, "Dev limited models", %{labels: ["dev", "limited"]})
    paused = create_api_key!(scope, pool, "Dev paused key", %{labels: ["dev", "paused"]})
    revoked = create_api_key!(scope, pool, "Dev revoked key", %{labels: ["dev", "revoked"]})

    update_api_key!(limited, %{
      allowed_model_identifiers: ["gpt-5.4-mini", "gpt-5.4"],
      enforced_reasoning_effort: "medium",
      enforced_service_tier: "priority"
    })

    paused = update_api_key!(paused, %{status: "paused"})
    revoked = update_api_key!(revoked, %{status: "revoked", revoked_at: minutes_ago(20)})

    [active, limited, paused, revoked]
  end

  defp seed_operator_pool_assignments!(owner, operators, pool) do
    operators
    |> Enum.filter(&(&1.status == "active"))
    |> Enum.map(fn operator ->
      timestamp = now()

      %OperatorPoolAssignment{}
      |> OperatorPoolAssignment.changeset(%{
        user_id: operator.id,
        pool_id: pool.id,
        status: "active",
        created_by_user_id: owner.id,
        created_at: timestamp,
        updated_at: timestamp
      })
      |> Repo.insert!()
    end)
  end

  defp create_api_key!(scope, pool, display_name, metadata) do
    %{api_key: api_key} = create_api_key_result!(scope, pool, display_name, metadata)

    api_key
  end

  defp create_api_key_result!(scope, pool, display_name, metadata) do
    {:ok, result} =
      CodexPooler.Access.create_api_key(scope, pool, %{
        display_name: display_name,
        metadata: Map.put(metadata, :operator_notes, "Generated by local dev seeds")
      })

    result
  end

  defp update_api_key!(api_key, attrs) do
    api_key
    |> APIKey.changeset(attrs)
    |> Repo.update!()
  end

  defp seed_identities!(owner) do
    [
      identity_attrs(owner, "dev-acct-active", "Dev Active Pro", "active", "pro", "Pro"),
      identity_attrs(owner, "dev-acct-ready-quota", "Dev Ready Quota", "active", "pro", "Pro"),
      identity_attrs(
        owner,
        "dev-acct-exhausted-quota",
        "Dev Exhausted Quota",
        "active",
        "pro",
        "Pro"
      ),
      identity_attrs(
        owner,
        "dev-acct-plus",
        "Dev Plus Refresh Due",
        "refresh_due",
        "plus",
        "Plus"
      ),
      identity_attrs(
        owner,
        "dev-acct-reauth",
        "Dev Reauth Required",
        "reauth_required",
        "team",
        "Team"
      ),
      identity_attrs(owner, "dev-acct-paused", "Dev Paused Account", "paused", "free", "Free")
    ]
    |> Enum.map(fn attrs ->
      %UpstreamIdentity{} |> UpstreamIdentity.changeset(attrs) |> Repo.insert!()
    end)
  end

  defp seed_assignments!(owner, pool, [active, ready, exhausted, plus, reauth, paused]) do
    [
      assignment_attrs(
        owner,
        pool,
        active,
        "Dev Active Assignment",
        "active",
        "active",
        "eligible"
      ),
      assignment_attrs(
        owner,
        pool,
        ready,
        "Dev Ready Assignment",
        "active",
        "active",
        "eligible"
      ),
      assignment_attrs(
        owner,
        pool,
        exhausted,
        "Dev Exhausted Assignment",
        "active",
        "active",
        "eligible"
      ),
      assignment_attrs(
        owner,
        pool,
        plus,
        "Dev Cooldown Assignment",
        "active",
        "cooldown",
        "ineligible",
        cooldown_until: minutes_from_now(35)
      ),
      assignment_attrs(
        owner,
        pool,
        reauth,
        "Dev Reauth Assignment",
        "reauth_required",
        "errored",
        "ineligible"
      ),
      assignment_attrs(
        owner,
        pool,
        paused,
        "Dev Paused Assignment",
        "paused",
        "disabled",
        "ineligible"
      )
    ]
    |> Enum.map(&seed_assignment!/1)
  end

  defp seed_assignment!(attrs) do
    %PoolUpstreamAssignment{} |> PoolUpstreamAssignment.changeset(attrs) |> Repo.insert!()
  end

  defp seed_models!(pool, [active_assignment, ready_assignment | _rest], _secondary_assignment) do
    active_id = active_assignment.id
    ready_id = ready_assignment.id

    [
      model_attrs(pool, "gpt-5.4-mini", "GPT 5.4 Mini", "active",
        source_assignment_models: %{
          active_id => observed_source_metadata(),
          ready_id => observed_source_metadata()
        }
      ),
      model_attrs(pool, "gpt-5.4", "GPT 5.4", "active",
        source_assignment_models: %{
          active_id => observed_source_metadata(),
          ready_id => observed_source_metadata()
        },
        missing_sync_assignment_ids: [active_id]
      ),
      model_attrs(pool, "gpt-5.5", "GPT 5.5", "active",
        source_assignment_models: %{active_id => observed_source_metadata()}
      ),
      model_attrs(pool, "gpt-5.5-pro", "GPT 5.5 Pro", "stale", stale_at: minutes_ago(45)),
      model_attrs(pool, "codex-image", "Codex Image", "suppressed",
        suppressed_at: minutes_ago(15)
      )
    ]
    |> Enum.map(fn attrs -> %Model{} |> Model.changeset(attrs) |> Repo.insert!() end)
  end

  defp seed_secondary_models!(pool, secondary_assignment) do
    [
      model_attrs(pool, "gpt-5.4-mini", "GPT 5.4 Mini", "active",
        source_assignment_models: %{secondary_assignment.id => observed_source_metadata()}
      )
    ]
    |> Enum.map(fn attrs -> %Model{} |> Model.changeset(attrs) |> Repo.insert!() end)
  end

  defp observed_source_metadata do
    %{
      "supports_responses" => true,
      "supports_streaming" => true,
      "supports_tools" => true,
      "supports_reasoning" => true
    }
  end

  # Circuit rows chosen so the routing panel shows one model per serving
  # signal: a serving rejection, a cooling-off route with a probe in flight,
  # and a nominal observed route that must render without badges.
  defp seed_routing_circuit_states!(pool, [active_assignment | _rest], active_identity) do
    [
      circuit_attrs(pool, active_assignment, active_identity, "gpt-5.4-mini", "proxy_stream",
        status: "closed",
        reason_code: "upstream_model_unavailable",
        failure_count: 4,
        last_failure_at: minutes_ago(6),
        closed_at: minutes_ago(6)
      ),
      circuit_attrs(pool, active_assignment, active_identity, "gpt-5.5", "proxy_http",
        status: "open",
        reason_code: "upstream_model_unavailable",
        failure_count: 3,
        last_failure_at: minutes_ago(4),
        opened_at: minutes_ago(4),
        next_probe_at: minutes_from_now(12)
      ),
      circuit_attrs(pool, active_assignment, active_identity, "gpt-5.5", "proxy_websocket",
        status: "half_open",
        reason_code: "upstream_model_unavailable",
        failure_count: 2,
        last_failure_at: minutes_ago(9),
        half_opened_at: minutes_ago(1)
      ),
      circuit_attrs(pool, active_assignment, active_identity, "gpt-5.4", "proxy_http",
        status: "closed",
        failure_count: 0,
        success_count: 12,
        last_success_at: minutes_ago(2),
        closed_at: minutes_ago(120)
      )
    ]
    |> Enum.each(fn attrs ->
      %RoutingCircuitState{} |> RoutingCircuitState.changeset(attrs) |> Repo.insert!()
    end)
  end

  defp circuit_attrs(pool, assignment, identity, model_identifier, route_class, extras) do
    timestamp = now()

    %{
      pool_id: pool.id,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: identity.id,
      model_identifier: model_identifier,
      route_class: route_class,
      status: Keyword.fetch!(extras, :status),
      reason_code: Keyword.get(extras, :reason_code),
      failure_count: Keyword.get(extras, :failure_count, 0),
      success_count: Keyword.get(extras, :success_count, 0),
      opened_at: Keyword.get(extras, :opened_at),
      half_opened_at: Keyword.get(extras, :half_opened_at),
      closed_at: Keyword.get(extras, :closed_at),
      next_probe_at: Keyword.get(extras, :next_probe_at),
      last_failure_at: Keyword.get(extras, :last_failure_at),
      last_success_at: Keyword.get(extras, :last_success_at),
      metadata: %{"dev_seed" => @seed_key},
      created_at: timestamp,
      updated_at: timestamp
    }
  end

  defp seed_quota_windows!([active, ready, exhausted, plus, reauth, paused]) do
    windows = [
      quota_attrs(active, quota_window_spec("primary", 300, "account", 1000, 640, "36", "fresh")),
      quota_attrs(
        active,
        quota_window_spec("secondary", 10_080, "account", 500, 95, "81", "fresh")
      ),
      quota_attrs(
        active,
        quota_window_spec("secondary", 10_080, "gpt-5.4", 500, 95, "81", "fresh"),
        display_label: "GPT 5.4",
        model: "gpt-5.4"
      ),
      quota_attrs(ready, quota_window_spec("primary", 300, "account", 1000, 720, "28", "fresh")),
      quota_attrs(
        ready,
        quota_window_spec("secondary", 10_080, "account", 1000, 460, "54", "fresh")
      ),
      quota_attrs(
        exhausted,
        quota_window_spec("primary", 300, "account", 1000, 820, "18", "fresh")
      ),
      quota_attrs(
        exhausted,
        quota_window_spec("secondary", 10_080, "account", 1000, 0, "100", "fresh")
      ),
      quota_attrs(plus, quota_window_spec("primary", 300, "account", 1000, 40, "96", "fresh")),
      quota_attrs(
        reauth,
        quota_window_spec("primary", 300, "account", 1000, nil, nil, "unknown")
      ),
      quota_attrs(paused, quota_window_spec("primary", 300, "account", 1000, 0, "100", "stale"))
    ]

    Enum.map(windows, fn attrs ->
      %AccountQuotaWindow{} |> AccountQuotaWindow.changeset(attrs) |> Repo.insert!()
    end)
  end

  defp seed_request_logs!(
         pool,
         [active_key, limited_key, paused_key, _revoked_key],
         assignments,
         models
       ) do
    [active_assignment, cooldown_assignment, reauth_assignment | _] = assignments
    [mini_model, full_model | _] = models

    [
      request_spec(
        active_key,
        active_assignment,
        mini_model,
        "succeeded",
        "usage_known",
        200,
        "http_json"
      ),
      request_spec(
        limited_key,
        active_assignment,
        full_model,
        "succeeded",
        "usage_known",
        200,
        "http_sse",
        retry_count: 1,
        request_metadata: %{"codex_mode" => "fast"}
      ),
      request_spec(
        active_key,
        cooldown_assignment,
        mini_model,
        "failed",
        "usage_unknown",
        429,
        "http_json",
        last_error_code: "quota_exhausted"
      ),
      request_spec(
        paused_key,
        reauth_assignment,
        mini_model,
        "rejected",
        "not_applicable",
        403,
        "http_json",
        last_error_code: "api_key_disabled"
      ),
      request_spec(
        active_key,
        active_assignment,
        mini_model,
        "in_progress",
        "usage_pending",
        nil,
        "websocket",
        completed_at: nil
      )
    ]
    |> Enum.with_index(1)
    |> Enum.map(fn {spec, index} -> seed_request!(pool, spec, index) end)
  end

  # Settled usage inside the token-burn windows: requests in the last five
  # minutes feed the 5M TOKENS footer block, the older ones give the burn
  # multiplier a previous-hour baseline to compare against.
  defp seed_recent_token_usage!(pool, [active_key, limited_key | _rest], assignments, models) do
    [active_assignment | _rest_assignments] = assignments
    [mini_model, full_model, fresh_model | _rest_models] = models

    [
      {active_key, full_model, 1, 46_400},
      {active_key, mini_model, 3, 11_600},
      {limited_key, fresh_model, 4, 3_200},
      {active_key, full_model, 20, 58_000},
      {active_key, mini_model, 35, 49_000},
      {limited_key, full_model, 50, 41_000}
    ]
    |> Enum.with_index(1)
    |> Enum.each(fn {{api_key, model, minutes, total_tokens}, index} ->
      spec =
        request_spec(
          api_key,
          active_assignment,
          model,
          "succeeded",
          "usage_known",
          200,
          "http_sse",
          occurred_at: minutes_ago(minutes),
          total_tokens: total_tokens,
          correlation_prefix: "dev-seed-burn"
        )

      seed_request!(pool, spec, index)
    end)
  end

  defp seed_request!(pool, spec, index) do
    timestamp = Map.get(spec, :occurred_at) || minutes_ago(index * 7)

    request =
      %Request{
        pool_id: pool.id,
        api_key_id: spec.api_key.id,
        model_id: spec.model.id,
        requested_model: spec.model.exposed_model_id,
        endpoint: endpoint_for_transport(spec.transport),
        transport: spec.transport,
        status: spec.status,
        usage_status: spec.usage_status,
        correlation_id: "#{Map.get(spec, :correlation_prefix, "dev-seed-request")}-#{index}",
        user_agent: "codex-pooler-dev-seed/1.0",
        request_metadata:
          Map.merge(%{"dev_seed" => @seed_key}, Map.get(spec, :request_metadata, %{})),
        admitted_at: timestamp,
        completed_at: Map.get(spec, :completed_at, timestamp),
        response_status_code: spec.response_status_code,
        retry_count: Map.get(spec, :retry_count, 0),
        last_error_code: Map.get(spec, :last_error_code),
        upstream_account_label: spec.assignment_label,
        upstream_account_plan_family: spec.plan_family,
        upstream_account_plan_label: spec.plan_label,
        reasoning_effort: "medium",
        requested_service_tier: "auto",
        actual_service_tier: "default"
      }
      |> Repo.insert!()

    attempt =
      %Attempt{
        request_id: request.id,
        attempt_number: 1,
        pool_upstream_assignment_id: spec.assignment.id,
        upstream_identity_id: spec.identity.id,
        model_id: spec.model.id,
        upstream_model_id: "upstream-#{spec.model.exposed_model_id}",
        transport: spec.transport,
        status: attempt_status(spec.status),
        started_at: timestamp,
        completed_at: Map.get(spec, :completed_at, timestamp),
        upstream_status_code: spec.response_status_code,
        retryable: spec.status == "failed",
        network_error_code: if(spec.status == "failed", do: "quota_limit"),
        latency_ms: if(spec.status == "in_progress", do: nil, else: 180 + index * 70),
        usage_status: spec.usage_status,
        response_metadata: %{"dev_seed" => @seed_key}
      }
      |> Repo.insert!()

    tokens = ledger_tokens(spec, index)

    if spec.usage_status == "usage_known" do
      %LedgerEntry{
        request_id: request.id,
        attempt_id: attempt.id,
        pool_id: pool.id,
        api_key_id: spec.api_key.id,
        pool_upstream_assignment_id: spec.assignment.id,
        upstream_identity_id: spec.identity.id,
        model_id: spec.model.id,
        entry_kind: "settlement",
        amount_status: "recorded",
        usage_status: "usage_known",
        transport: spec.transport,
        currency_code: "USD",
        input_tokens: tokens.input,
        cached_input_tokens: tokens.cached,
        output_tokens: tokens.output,
        reasoning_tokens: tokens.reasoning,
        total_tokens: tokens.total,
        request_count: 1,
        estimated_cost_micros: Decimal.new(index * 1000),
        settled_cost_micros: Decimal.new(index * 1000),
        occurred_at: timestamp,
        created_at: timestamp,
        details: %{"dev_seed" => @seed_key, "pricing_status" => "priced"}
      }
      |> Repo.insert!()
    end

    request
  end

  defp seed_invites!(owner, pool) do
    timestamp = now()

    [
      invite_attrs(
        owner,
        pool,
        "dev-invite-active@example.com",
        "active",
        minutes_from_now(1_440)
      ),
      invite_attrs(
        owner,
        pool,
        "dev-invite-accepted@example.com",
        "accepted",
        minutes_from_now(1_440),
        accepted_at: minutes_ago(30),
        email_sent_at: minutes_ago(60)
      ),
      invite_attrs(
        owner,
        pool,
        "dev-invite-revoked@example.com",
        "revoked",
        minutes_from_now(1_440),
        revoked_at: minutes_ago(20)
      ),
      invite_attrs(owner, pool, "dev-invite-expired@example.com", "expired", minutes_ago(15))
    ]
    |> Enum.with_index(1)
    |> Enum.map(fn {attrs, index} ->
      attrs = Map.put(attrs, :token_hash, :crypto.hash(:sha256, "dev-seed-invite-#{index}"))
      %Invite{} |> Invite.changeset(Map.put_new(attrs, :created_at, timestamp)) |> Repo.insert!()
    end)
  end

  defp seed_audit_events!(owner, pool, [api_key | _]) do
    [
      audit_attrs(owner, pool, "pool.create", "pool", pool.id, "success", %{
        "pool_slug" => pool.slug
      }),
      audit_attrs(owner, pool, "api_key.create", "api_key", api_key.id, "success", %{
        "key_prefix" => api_key.key_prefix
      }),
      audit_attrs(owner, pool, "operator.update", "user", owner.id, "failure", %{
        "reason" => "dev validation failure"
      })
    ]
    |> Enum.map(&Repo.insert!(struct(AuditEvent, &1)))
  end

  defp seed_jobs!(pool, assignments, identities, [api_key | _]) do
    [primary_assignment, ready_assignment, exhausted_assignment, cooldown_assignment | _] =
      assignments

    [primary_identity, ready_identity, exhausted_identity, plus_identity | _] = identities
    rollup_date = Date.utc_today() |> Date.add(-1) |> Date.to_iso8601()

    [
      seed_job!(
        CodexPooler.Jobs.AccountReconciliationWorker,
        %{"pool_id" => pool.id, "pool_upstream_assignment_id" => primary_assignment.id},
        state: "discarded",
        attempt: 3,
        max_attempts: 3,
        inserted_at: minutes_ago(120),
        attempted_at: minutes_ago(118),
        discarded_at: minutes_ago(116),
        errors: [job_error(3, "RuntimeError", "account reconciliation quota probe unavailable")]
      ),
      seed_job!(
        CodexPooler.Jobs.AccountReconciliationWorker,
        %{"pool_id" => pool.id, "pool_upstream_assignment_id" => primary_assignment.id},
        state: "discarded",
        attempt: 2,
        max_attempts: 3,
        inserted_at: minutes_ago(110),
        attempted_at: minutes_ago(108),
        discarded_at: minutes_ago(106),
        errors: [job_error(2, "RuntimeError", "account reconciliation usage refresh unavailable")]
      ),
      seed_job!(
        CodexPooler.Jobs.DailyRollupRebuildWorker,
        %{"api_key_id" => api_key.id, "rollup_date" => rollup_date},
        state: "discarded",
        attempt: 1,
        max_attempts: 1,
        inserted_at: minutes_ago(95),
        attempted_at: minutes_ago(94),
        discarded_at: minutes_ago(93),
        errors: [job_error(1, "RuntimeError", "daily rollup source window missing")]
      ),
      seed_job!(
        CodexPooler.Jobs.TokenRefreshWorker,
        %{"upstream_identity_id" => primary_identity.id},
        state: "retryable",
        attempt: 4,
        max_attempts: 8,
        inserted_at: minutes_ago(80),
        attempted_at: minutes_ago(78),
        scheduled_at: minutes_from_now(15),
        errors: [
          job_error(4, "RuntimeError", "token refresh provider returned temporary failure")
        ]
      ),
      seed_job!(
        CodexPooler.Jobs.TokenRefreshWorker,
        %{"upstream_identity_id" => ready_identity.id},
        state: "retryable",
        attempt: 2,
        max_attempts: 8,
        inserted_at: minutes_ago(76),
        attempted_at: minutes_ago(75),
        scheduled_at: minutes_from_now(25),
        errors: [job_error(2, "RuntimeError", "token refresh provider rate limited")]
      ),
      seed_job!(
        CodexPooler.Jobs.TokenRefreshWorker,
        %{"upstream_identity_id" => exhausted_identity.id},
        state: "retryable",
        attempt: 1,
        max_attempts: 8,
        inserted_at: minutes_ago(70),
        attempted_at: minutes_ago(69),
        scheduled_at: minutes_from_now(35),
        errors: [job_error(1, "RuntimeError", "token refresh waiting for provider recovery")]
      ),
      seed_job!(
        CodexPooler.Jobs.RuntimeStateCleanupWorker,
        %{},
        state: "executing",
        attempt: 1,
        max_attempts: 3,
        inserted_at: minutes_ago(65),
        attempted_at: minutes_ago(45)
      ),
      seed_job!(
        CodexPooler.Jobs.DailyRollupRebuildWorker,
        %{
          "api_key_id" => api_key.id,
          "rollup_date" => Date.utc_today() |> Date.add(-2) |> Date.to_iso8601()
        },
        state: "executing",
        attempt: 1,
        max_attempts: 3,
        inserted_at: minutes_ago(70),
        attempted_at: minutes_ago(40)
      ),
      seed_job!(
        CodexPooler.Jobs.CatalogSyncWorker,
        %{"pool_id" => pool.id},
        state: "available",
        inserted_at: minutes_ago(50),
        scheduled_at: minutes_ago(25)
      ),
      seed_job!(
        CodexPooler.Jobs.AccountReconciliationWorker,
        %{"pool_id" => pool.id, "pool_upstream_assignment_id" => ready_assignment.id},
        state: "available",
        inserted_at: minutes_ago(48),
        scheduled_at: minutes_ago(18)
      ),
      seed_job!(
        CodexPooler.Jobs.AccountReconciliationWorker,
        %{"pool_id" => pool.id, "pool_upstream_assignment_id" => exhausted_assignment.id},
        state: "available",
        inserted_at: minutes_ago(44),
        scheduled_at: minutes_ago(12)
      ),
      seed_job!(
        CodexPooler.Jobs.TokenRefreshWorker,
        %{"upstream_identity_id" => plus_identity.id},
        state: "scheduled",
        inserted_at: minutes_ago(5),
        scheduled_at: minutes_from_now(60)
      ),
      seed_job!(
        CodexPooler.Jobs.AccountReconciliationWorker,
        %{"pool_id" => pool.id, "pool_upstream_assignment_id" => cooldown_assignment.id},
        state: "completed",
        attempt: 1,
        max_attempts: 3,
        inserted_at: minutes_ago(35),
        attempted_at: minutes_ago(34),
        completed_at: minutes_ago(33)
      ),
      seed_job!(
        CodexPooler.Jobs.RuntimeStateCleanupWorker,
        %{},
        state: "completed",
        inserted_at: minutes_ago(30),
        attempted_at: minutes_ago(29),
        completed_at: minutes_ago(28)
      ),
      seed_job!(
        CodexPooler.Jobs.AccountReconciliationWorker,
        %{"pool_id" => pool.id, "pool_upstream_assignment_id" => primary_assignment.id},
        state: "cancelled",
        inserted_at: minutes_ago(25),
        cancelled_at: minutes_ago(24)
      )
    ]
  end

  defp seed_job!(worker, args, attrs) do
    base_job =
      args
      |> worker.new(job_options(attrs))
      |> Ecto.Changeset.apply_changes()

    base_job
    |> Map.merge(job_attrs(attrs))
    |> Map.put(:queue, "dev_seed_jobs")
    |> Repo.insert!()
  end

  defp job_options(_attrs) do
    [meta: %{"dev_seed" => @seed_key}, scheduled_at: minutes_from_now(1_440)]
  end

  defp identity_attrs(owner, account_id, label, status, plan_family, plan_label) do
    timestamp = now()

    %{
      chatgpt_account_id: account_id,
      account_label: label,
      onboarding_method: "import",
      status: status,
      plan_family: plan_family,
      plan_label: plan_label,
      auth_fresh_at: minutes_ago(10),
      auth_verified_at: minutes_ago(10),
      headers_profile_version: 1,
      last_successful_sync_at: if(status in ["active", "paused"], do: minutes_ago(5)),
      created_by_user_id: owner.id,
      created_at: timestamp,
      updated_at: timestamp,
      metadata: %{"dev_seed" => @seed_key, "state" => status}
    }
  end

  defp assignment_attrs(owner, pool, identity, label, status, health, eligibility, extras \\ []) do
    timestamp = now()

    %{
      pool_id: pool.id,
      upstream_identity_id: identity.id,
      assignment_label: label,
      status: status,
      health_status: health,
      eligibility_status: eligibility,
      cooldown_until: Keyword.get(extras, :cooldown_until),
      last_healthcheck_at: minutes_ago(8),
      last_successful_sync_at: if(health == "active", do: minutes_ago(5)),
      created_by_user_id: owner.id,
      created_at: timestamp,
      updated_at: timestamp,
      metadata: %{"dev_seed" => @seed_key, "state" => health}
    }
  end

  defp model_attrs(pool, exposed_model_id, display_name, status, extras) do
    source_models = Keyword.get(extras, :source_assignment_models, %{})
    missing_sync_ids = Keyword.get(extras, :missing_sync_assignment_ids, [])

    %{
      pool_id: pool.id,
      upstream_model_id: "upstream-#{exposed_model_id}",
      exposed_model_id: exposed_model_id,
      display_name: display_name,
      status: status,
      supports_responses: true,
      supports_streaming: status != "suppressed",
      supports_tools: status in ["active", "stale"],
      supports_reasoning: status in ["active", "stale"],
      source_assignment_count: max(map_size(source_models), 1),
      first_seen_at: minutes_ago(180),
      last_seen_at: minutes_ago(5),
      stale_at: Keyword.get(extras, :stale_at),
      suppressed_at: Keyword.get(extras, :suppressed_at),
      metadata: model_metadata(source_models, missing_sync_ids)
    }
  end

  defp model_metadata(source_models, missing_sync_ids) do
    %{"dev_seed" => @seed_key}
    |> put_present_metadata("source_assignment_models", source_models)
    |> put_present_metadata(
      "source_assignment_ids",
      source_models |> Map.keys() |> Enum.sort()
    )
    |> put_present_metadata(
      PreservedSources.missing_sync_metadata_key(),
      Map.new(missing_sync_ids, &{&1, Ecto.UUID.generate()})
    )
  end

  defp put_present_metadata(metadata, _key, value) when value == %{} or value == [],
    do: metadata

  defp put_present_metadata(metadata, key, value), do: Map.put(metadata, key, value)

  @spec quota_window_spec(
          String.t(),
          pos_integer(),
          String.t(),
          non_neg_integer(),
          non_neg_integer() | nil,
          String.t() | nil,
          String.t()
        ) :: quota_window_spec()
  defp quota_window_spec(
         window_kind,
         window_minutes,
         quota_key,
         active_limit,
         credits,
         used_percent,
         freshness_state
       ) do
    %{
      window_kind: window_kind,
      window_minutes: window_minutes,
      quota_key: quota_key,
      active_limit: active_limit,
      credits: credits,
      used_percent: used_percent,
      freshness_state: freshness_state
    }
  end

  @spec quota_attrs(UpstreamIdentity.t(), quota_window_spec(), keyword()) :: map()
  defp quota_attrs(identity, spec, extras \\ []) do
    timestamp = now()

    %{
      upstream_identity_id: identity.id,
      quota_key: spec.quota_key,
      window_kind: spec.window_kind,
      window_minutes: spec.window_minutes,
      active_limit: spec.active_limit,
      credits: spec.credits,
      reset_at: minutes_from_now(spec.window_minutes),
      used_percent: if(spec.used_percent, do: Decimal.new(spec.used_percent)),
      display_label: quota_display_label(spec.quota_key, extras),
      limit_name: quota_limit_name(spec.quota_key, extras),
      source: "dev_seed",
      source_precision: "observed",
      quota_scope: if(Keyword.get(extras, :model), do: "model", else: "account"),
      quota_family: spec.quota_key,
      model: Keyword.get(extras, :model),
      freshness_state: spec.freshness_state,
      last_sync_at: timestamp,
      observed_at: timestamp,
      merge_precedence: 50,
      metadata: %{"dev_seed" => @seed_key},
      created_at: timestamp,
      updated_at: timestamp
    }
  end

  defp quota_display_label("account", _extras), do: nil
  defp quota_display_label(_quota_key, extras), do: Keyword.get(extras, :display_label)

  defp quota_limit_name("account", _extras), do: nil
  defp quota_limit_name(quota_key, _extras), do: quota_key

  defp request_spec(
         api_key,
         assignment,
         model,
         status,
         usage_status,
         response_status_code,
         transport,
         extras \\ []
       ) do
    identity = Repo.get!(UpstreamIdentity, assignment.upstream_identity_id)

    %{
      api_key: api_key,
      assignment: assignment,
      identity: identity,
      assignment_label: identity.account_label,
      plan_family: identity.plan_family,
      plan_label: identity.plan_label,
      model: model,
      status: status,
      usage_status: usage_status,
      response_status_code: response_status_code,
      transport: transport
    }
    |> Map.merge(Map.new(extras))
  end

  defp invite_attrs(owner, pool, email, status, expires_at, extras \\ []) do
    timestamp = now()

    %{
      pool_id: pool.id,
      invited_email: email,
      status: status,
      expires_at: expires_at,
      created_by_user_id: owner.id,
      created_at: timestamp,
      updated_at: timestamp,
      accepted_at: Keyword.get(extras, :accepted_at),
      email_sent_at: Keyword.get(extras, :email_sent_at),
      revoked_at: Keyword.get(extras, :revoked_at)
    }
  end

  defp audit_attrs(owner, pool, action, target_type, target_id, outcome, details) do
    %{
      occurred_at: minutes_ago(12),
      actor_type: "user",
      actor_user_id: owner.id,
      pool_id: pool.id,
      action: action,
      target_type: target_type,
      target_id: target_id,
      outcome: outcome,
      correlation_id: "dev-seed-audit-#{action}",
      details: Map.put(details, "dev_seed", @seed_key)
    }
  end

  defp job_attrs(attrs) do
    attrs
    |> Keyword.take([
      :state,
      :attempt,
      :max_attempts,
      :inserted_at,
      :scheduled_at,
      :attempted_at,
      :completed_at,
      :discarded_at,
      :cancelled_at,
      :errors
    ])
    |> Map.new()
  end

  defp job_error(attempt, kind, message) do
    %{
      "attempt" => attempt,
      "kind" => kind,
      "error" => message,
      "at" => DateTime.to_iso8601(now())
    }
  end

  defp ledger_tokens(%{total_tokens: total}, _index) when is_integer(total) do
    input = div(total * 3, 4)
    reasoning = div(total, 20)

    %{
      input: input,
      cached: div(input, 5),
      output: total - input - reasoning,
      reasoning: reasoning,
      total: total
    }
  end

  defp ledger_tokens(_spec, index) do
    %{
      input: 1200 * index,
      cached: 100 * index,
      output: 240 * index,
      reasoning: 80 * index,
      total: 1520 * index
    }
  end

  defp attempt_status("succeeded"), do: "succeeded"
  defp attempt_status("failed"), do: "failed"
  defp attempt_status("rejected"), do: "failed"
  defp attempt_status("cancelled"), do: "cancelled"
  defp attempt_status(_status), do: "in_progress"

  defp endpoint_for_transport("websocket"), do: "/backend-api/codex/responses"
  defp endpoint_for_transport("http_sse"), do: "/backend-api/codex/responses"
  defp endpoint_for_transport(_transport), do: "/backend-api/codex/responses"

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp minutes_ago(minutes), do: DateTime.add(now(), -minutes, :minute)
  defp minutes_from_now(minutes), do: DateTime.add(now(), minutes, :minute)
end
