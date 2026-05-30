defmodule CodexPooler.Dev.Seeds do
  @moduledoc """
  Idempotent local development seed data.

  The compact seed is safe for `mix ecto.setup`: it keeps the operator list small
  while making the app immediately sign-in capable on an empty database.

  The full seed is a richer, deterministic UI exercise dataset. It deletes only
  rows carrying this module's `dev_seed` marker or deterministic `dev-*` labels,
  then recreates them so reruns converge instead of accumulating duplicates.
  """

  import Ecto.Query

  alias CodexPooler.Access.{APIKey, Invite}
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.Accounts.{PlatformBootstrapState, Scope, User}
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Pools.{Membership, OperatorPoolAssignment, Pool}
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

  @password "dev-password-123"
  @seed_key "codex_pooler_dev_seed"
  @owner_email "dev-owner@example.com"
  @operator_specs [
    %{email: "dev-admin@example.com", display_name: "Dev Admin", status: "active"},
    %{
      email: "dev-password-reset@example.com",
      display_name: "Dev Password Reset",
      status: "active",
      password_change_required: true
    },
    %{email: "dev-disabled@example.com", display_name: "Dev Disabled", status: "disabled"},
    %{email: "dev-operator@example.com", display_name: "Dev Operator", status: "active"}
  ]

  @doc "Seeds the compact default development operator set."
  @spec compact() :: %{owner: User.t(), operators: [User.t()], password: String.t()}
  def compact do
    require_dev_seeds_enabled!()

    owner = ensure_owner!()

    operators =
      Enum.map(@operator_specs, fn spec ->
        spec
        |> ensure_operator_user!()
        |> ensure_membership!("instance_admin", owner.id)
      end)

    %{owner: owner, operators: operators, password: @password}
  end

  @doc "Seeds a rich local fake dataset for exercising admin UI states."
  @spec full() :: map()
  def full do
    require_dev_seeds_enabled!()

    %{owner: owner, operators: operators, password: password} = compact()

    reset_full_fake_data!()

    pool_active = seed_pool!(owner, %{slug: "dev-primary", name: "Dev Primary Pool"})

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
    models = seed_models!(pool_active)
    quota_windows = seed_quota_windows!(identities)
    request_logs = seed_request_logs!(pool_active, api_keys, assignments, models)
    invites = seed_invites!(owner, pool_active)
    audit_events = seed_audit_events!(owner, pool_active, api_keys)
    jobs = seed_jobs!(pool_active, assignments, identities, api_keys)

    %{
      owner: owner,
      operators: operators,
      password: password,
      pools: [pool_active, pool_disabled],
      api_keys: api_keys,
      upstream_identities: identities,
      assignments: assignments,
      models: models,
      quota_windows: quota_windows,
      request_logs: request_logs,
      invites: invites,
      audit_events: audit_events,
      jobs: jobs
    }
  end

  defp ensure_owner! do
    case active_owner() do
      %User{email: @owner_email} = owner ->
        reset_owner_password!(owner)

      %User{} = owner ->
        owner

      nil ->
        owner = reset_owner_password!(ensure_user!(owner_spec()))
        ensure_membership!(owner, "instance_owner", owner.id)
        complete_bootstrap!(owner)
        owner
    end
  end

  defp require_dev_seeds_enabled! do
    unless Application.get_env(:codex_pooler, :dev_seeds_enabled, false) do
      raise "development seeds are disabled for this environment"
    end
  end

  defp owner_spec, do: %{email: @owner_email, display_name: "Dev Owner", status: "active"}

  defp reset_owner_password!(%User{} = owner) do
    owner
    |> User.operator_temporary_password_changeset(%{
      password: @password,
      password_change_required: false
    })
    |> Ecto.Changeset.cast(owner_spec(), [:email, :display_name])
    |> Ecto.Changeset.put_change(:status, "active")
    |> Ecto.Changeset.put_change(:updated_at, now())
    |> Repo.update!()
  end

  defp ensure_operator_user!(spec) do
    spec
    |> Map.put_new(:password_change_required, false)
    |> ensure_user!()
  end

  defp ensure_user!(spec) do
    now = now()
    attrs = user_attrs(spec, now)

    case Repo.get_by(User, email: spec.email) do
      %User{} = user ->
        user
        |> User.operator_temporary_password_changeset(attrs)
        |> Ecto.Changeset.cast(attrs, [:email, :display_name])
        |> Ecto.Changeset.put_change(:status, spec.status)
        |> Ecto.Changeset.put_change(:updated_at, now)
        |> Repo.update!()

      nil ->
        %User{}
        |> User.operator_create_changeset(attrs)
        |> Ecto.Changeset.put_change(:status, spec.status)
        |> Ecto.Changeset.put_change(:created_at, now)
        |> Ecto.Changeset.put_change(:updated_at, now)
        |> Repo.insert!()
    end
  end

  defp ensure_membership!(%User{} = user, role, created_by_user_id) do
    membership = Repo.get_by(Membership, user_id: user.id, role: role, status: "active")

    if is_nil(membership) do
      %Membership{}
      |> Membership.changeset(%{
        user_id: user.id,
        role: role,
        status: "active",
        created_by_user_id: created_by_user_id,
        created_at: now()
      })
      |> Repo.insert!()
    end

    user
  end

  defp complete_bootstrap!(%User{} = owner) do
    state = Repo.get!(PlatformBootstrapState, true)
    timestamp = now()

    state
    |> Ecto.Changeset.change(%{
      status: "completed",
      owner_user_id: owner.id,
      completed_at: timestamp,
      updated_at: timestamp
    })
    |> Repo.update!()
  end

  defp active_owner do
    Repo.one(
      from user in User,
        join: membership in Membership,
        on: membership.user_id == user.id,
        where:
          membership.role == "instance_owner" and membership.status == "active" and
            is_nil(user.deleted_at),
        order_by: [asc: user.created_at, asc: user.id],
        limit: 1
    )
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

    Repo.delete_all(from pool in Pool, where: pool.slug in ["dev-primary", "dev-disabled"])

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
    {:ok, %{api_key: api_key}} =
      CodexPooler.Access.create_api_key(scope, pool, %{
        display_name: display_name,
        metadata: Map.put(metadata, :operator_notes, "Generated by local dev seeds")
      })

    api_key
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
    |> Enum.map(fn attrs ->
      %PoolUpstreamAssignment{} |> PoolUpstreamAssignment.changeset(attrs) |> Repo.insert!()
    end)
  end

  defp seed_models!(pool) do
    [
      model_attrs(pool, "gpt-5.4-mini", "GPT 5.4 Mini", "active"),
      model_attrs(pool, "gpt-5.4", "GPT 5.4", "active"),
      model_attrs(pool, "gpt-5.5-pro", "GPT 5.5 Pro", "stale", stale_at: minutes_ago(45)),
      model_attrs(pool, "codex-image", "Codex Image", "suppressed",
        suppressed_at: minutes_ago(15)
      )
    ]
    |> Enum.map(fn attrs -> %Model{} |> Model.changeset(attrs) |> Repo.insert!() end)
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

  defp seed_request!(pool, spec, index) do
    timestamp = minutes_ago(index * 7)

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
        correlation_id: "dev-seed-request-#{index}",
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
        input_tokens: 1200 * index,
        cached_input_tokens: 100 * index,
        output_tokens: 240 * index,
        reasoning_tokens: 80 * index,
        total_tokens: 1520 * index,
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

  defp seed_jobs!(pool, [assignment | _], [identity | _], [api_key | _]) do
    jobs = [
      {CodexPooler.Jobs.AccountReconciliationWorker, "completed",
       %{"pool_id" => pool.id, "pool_upstream_assignment_id" => assignment.id}},
      {CodexPooler.Jobs.AccountReconciliationWorker, "cancelled",
       %{"pool_id" => pool.id, "pool_upstream_assignment_id" => assignment.id}},
      {CodexPooler.Jobs.TokenRefreshWorker, "scheduled",
       %{"upstream_identity_id" => identity.id}},
      {CodexPooler.Jobs.DailyRollupRebuildWorker, "discarded",
       %{"api_key_id" => api_key.id, "rollup_date" => Date.to_iso8601(Date.utc_today())}}
    ]

    Enum.map(jobs, fn {worker, state, args} ->
      args
      |> worker.new(meta: %{"dev_seed" => @seed_key}, scheduled_at: minutes_from_now(1_440))
      |> Oban.insert!()
      |> Ecto.Changeset.change(job_state_attrs(state))
      |> Repo.update!()
    end)
  end

  defp user_attrs(spec, timestamp) do
    %{
      email: spec.email,
      display_name: spec.display_name,
      password: @password,
      password_change_required: Map.get(spec, :password_change_required, false),
      status: spec.status,
      created_at: timestamp,
      updated_at: timestamp
    }
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

  defp model_attrs(pool, exposed_model_id, display_name, status, extras \\ []) do
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
      source_assignment_count: 1,
      first_seen_at: minutes_ago(180),
      last_seen_at: minutes_ago(5),
      stale_at: Keyword.get(extras, :stale_at),
      suppressed_at: Keyword.get(extras, :suppressed_at),
      metadata: %{"dev_seed" => @seed_key}
    }
  end

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

  defp job_state_attrs("completed"), do: %{state: "completed", completed_at: minutes_ago(5)}
  defp job_state_attrs("cancelled"), do: %{state: "cancelled", cancelled_at: minutes_ago(3)}
  defp job_state_attrs("discarded"), do: %{state: "discarded", discarded_at: minutes_ago(4)}

  defp job_state_attrs("scheduled"),
    do: %{state: "scheduled", scheduled_at: minutes_from_now(1_440)}

  defp job_state_attrs(state), do: %{state: state}

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
