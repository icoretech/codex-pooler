defmodule CodexPooler.Dev.RoutingStrategyFixture.Provisioner do
  @moduledoc false

  alias CodexPooler.{Access, Accounts, Pools, Repo, Upstreams}
  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounting.{Attempt, Request, RequestLogFacts}
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Dev.RoutingStrategyFixture.Names
  alias CodexPooler.Pools.{Pool, RoutingSettings}
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Lifecycle.IdentityLifecycle
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  # Ring size stays at the product default while the fixture provisions four or
  # more assignments: truncation is the only situation where the strategies
  # differ in the selected assignment rather than only in the ordered tail.
  @bridge_ring_size 3
  @exposed_model_id "gpt-5.5-routing"
  @upstream_model_id "provider-gpt-5.5-routing"

  # Differentiation keys. The quota ladder ascends with the assignment index
  # while the success ladder ages with it, so `quota_first` ranks 1..N and
  # `least_recent_success` ranks N..1 — the exact reverse. Neither can collapse
  # into the other, and neither can collapse into the rendezvous-only default.
  @used_percent_step 10
  @success_age_step_seconds 3_600

  @type request :: %{
          required(:upstream_base_url) => String.t(),
          required(:routing_strategy) => String.t(),
          required(:assignments) => pos_integer()
        }

  @type result :: %{
          required(:api_key) => String.t(),
          required(:pool_id) => Ecto.UUID.t(),
          required(:pool_slug) => String.t(),
          required(:model) => String.t(),
          required(:bridge_ring_size) => pos_integer(),
          required(:created) => map()
        }

  @spec provision!(request()) :: result()
  def provision!(%{} = request) do
    scope = operator_scope!()
    {pool, pool_created?} = ensure_pool!(scope)
    ensure_active_pool!(pool)
    {settings_created?, _settings} = ensure_routing_settings!(pool, request.routing_strategy)

    provisioned_assignments =
      Enum.map(1..request.assignments, fn index ->
        provision_assignment!(pool, index, request.upstream_base_url)
      end)

    assignments = Enum.map(provisioned_assignments, & &1.assignment)
    {model, model_created?} = ensure_model!(pool, assignments)
    {raw_key, api_key_id} = create_api_key!(scope, pool)

    differentiation =
      differentiate!(pool, model, provisioned_assignments)

    %{
      api_key: raw_key,
      pool_id: pool.id,
      pool_slug: pool.slug,
      model: model.exposed_model_id,
      bridge_ring_size: @bridge_ring_size,
      created: %{
        pool_id: if(pool_created?, do: pool.id),
        routing_settings_pool_id: if(settings_created?, do: pool.id),
        identity_ids:
          provisioned_assignments
          |> Enum.filter(& &1.identity_created?)
          |> Enum.map(& &1.identity.id),
        assignment_ids:
          provisioned_assignments
          |> Enum.filter(& &1.assignment_created?)
          |> Enum.map(& &1.assignment.id),
        model_ids: if(model_created?, do: [model.id], else: []),
        api_key_ids: [api_key_id],
        request_ids: differentiation.request_ids
      }
    }
  end

  defp operator_scope! do
    Accounts.list_operators()
    |> Enum.find_value(fn user ->
      scope = Scope.for_user(user, Accounts.roles_for_user(user))
      if Pools.can_manage_pools?(scope), do: scope
    end)
    |> Kernel.||(
      raise "routing strategy fixture requires a bootstrapped local operator with pool access"
    )
  end

  defp ensure_pool!(scope) do
    case Repo.get_by(Pool, slug: Names.pool_slug()) do
      %Pool{} = pool ->
        {pool, false}

      nil ->
        case Pools.create_pool(scope, %{
               "slug" => Names.pool_slug(),
               "name" => "Routing Strategy Smoke",
               "status" => "active"
             }) do
          {:ok, pool} -> {pool, true}
          {:error, %Ecto.Changeset{}} -> find_existing_pool!()
          {:error, _reason} -> raise "failed to create routing strategy fixture pool"
        end
    end
  end

  defp find_existing_pool! do
    case Repo.get_by(Pool, slug: Names.pool_slug()) do
      %Pool{} = pool -> {pool, false}
      nil -> raise "failed to create routing strategy fixture pool"
    end
  end

  defp ensure_active_pool!(pool) do
    pool |> Pool.changeset(%{status: "active", disabled_at: nil}) |> Repo.update!()
  end

  defp ensure_routing_settings!(pool, routing_strategy) do
    existing = Pools.get_routing_settings(pool)
    settings = existing || Pools.ensure_routing_settings(pool)

    settings =
      settings
      |> RoutingSettings.changeset(%{
        routing_strategy: routing_strategy,
        bridge_ring_size: @bridge_ring_size,
        # Stickiness and locality are deliberate: sticky HTTP sessions would
        # reorder every plan before the strategy could be observed, and the
        # prompt-cache toggle has to stay on so the lane can prove the inert
        # case as well as the differentiated one.
        sticky_websocket_sessions: true,
        sticky_http_sessions: false,
        prompt_cache_affinity_enabled: true,
        v1_compatibility_enabled: true,
        request_compression_enabled: settings.request_compression_enabled,
        allow_image_generation: true,
        metadata: settings.metadata || %{},
        created_at: settings.created_at,
        updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      })
      |> Repo.update!()

    {is_nil(existing), settings}
  end

  defp provision_assignment!(pool, index, upstream_base_url) do
    {identity, identity_created?} = ensure_identity!(index, upstream_base_url)
    {assignment, assignment_created?} = ensure_assignment!(pool, identity, index)
    ensure_active_assignment!(assignment)

    %{
      index: index,
      identity: identity,
      identity_created?: identity_created?,
      assignment: Repo.get!(PoolUpstreamAssignment, assignment.id),
      assignment_created?: assignment_created?
    }
  end

  defp ensure_identity!(index, upstream_base_url) do
    account_id = Names.account_id(index)

    attributes = %{
      chatgpt_account_id: account_id,
      account_label: "Routing Strategy Smoke #{index}",
      onboarding_method: "import",
      metadata: %{"base_url" => upstream_base_url}
    }

    {identity, created?} = find_or_create_identity!(attributes, account_id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    identity =
      identity
      |> UpstreamIdentity.changeset(%{
        status: "active",
        auth_verified_at: now,
        auth_fresh_at: now,
        disabled_at: nil,
        metadata: attributes.metadata
      })
      |> Repo.update!()

    unless active_access_token?(identity) do
      {:ok, _secret} =
        Upstreams.store_encrypted_secret(identity, %{
          secret_kind: "access_token",
          plaintext: "routing-strategy-smoke-upstream-token-#{index}"
        })
    end

    {identity, created?}
  end

  defp find_or_create_identity!(attributes, account_id) do
    case IdentityLifecycle.create_upstream_identity(attributes) do
      {:ok, identity} ->
        {identity, true}

      {:error, %Ecto.Changeset{errors: errors}} ->
        if Keyword.has_key?(errors, :chatgpt_account_id) do
          case Repo.get_by(UpstreamIdentity, chatgpt_account_id: account_id) do
            %UpstreamIdentity{} = identity -> {identity, false}
            nil -> raise "routing strategy fixture identity was not persisted"
          end
        else
          raise "failed to create routing strategy fixture identity"
        end

      {:error, _reason} ->
        raise "failed to create routing strategy fixture identity"
    end
  end

  defp ensure_assignment!(pool, identity, index) do
    case Repo.get_by(PoolUpstreamAssignment,
           pool_id: pool.id,
           upstream_identity_id: identity.id
         ) do
      %PoolUpstreamAssignment{} = assignment ->
        {assignment, false}

      nil ->
        case PoolAssignments.create_pool_assignment(pool, identity, %{
               assignment_label: "Routing Strategy Smoke #{index}",
               metadata: %{}
             }) do
          {:ok, assignment} -> {assignment, true}
          {:error, %Ecto.Changeset{}} -> find_existing_assignment!(pool, identity)
          {:error, _reason} -> raise "failed to create routing strategy fixture assignment"
        end
    end
  end

  defp find_existing_assignment!(pool, identity) do
    case Repo.get_by(PoolUpstreamAssignment,
           pool_id: pool.id,
           upstream_identity_id: identity.id
         ) do
      %PoolUpstreamAssignment{} = assignment -> {assignment, false}
      nil -> raise "failed to create routing strategy fixture assignment"
    end
  end

  defp ensure_active_assignment!(assignment) do
    assignment
    |> PoolUpstreamAssignment.changeset(%{
      status: "active",
      health_status: "active",
      eligibility_status: "eligible",
      disabled_at: nil
    })
    |> Repo.update!()
  end

  defp ensure_model!(pool, assignments) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    assignment_ids = Enum.map(assignments, & &1.id)

    source_metadata = %{
      "slug" => @exposed_model_id,
      "visibility" => "list",
      "priority" => 20,
      "input_modalities" => ["text", "image"],
      "supports_tools" => true,
      "context_window" => 272_000,
      "effective_context_window_percent" => 95,
      "capabilities" => %{"reasoning" => true},
      "supported_reasoning_levels" => ["none"],
      "default_reasoning_level" => "none"
    }

    changes = %{
      pool_id: pool.id,
      upstream_model_id: @upstream_model_id,
      exposed_model_id: @exposed_model_id,
      display_name: "GPT 5.5 Routing",
      status: "active",
      supports_responses: true,
      supports_streaming: true,
      supports_tools: true,
      supports_reasoning: true,
      source_assignment_count: length(assignment_ids),
      first_seen_at: now,
      last_seen_at: now,
      metadata:
        Map.merge(source_metadata, %{
          "manual_smoke_provisioned" => true,
          "upstream_model" => source_metadata,
          "source_assignment_ids" => assignment_ids,
          "source_assignment_models" =>
            Map.new(assignment_ids, fn assignment_id -> {assignment_id, source_metadata} end),
          "input_modalities" => ["text", "image"]
        })
    }

    case Repo.get_by(Model, pool_id: pool.id, exposed_model_id: @exposed_model_id) do
      %Model{} = model ->
        model =
          model
          |> Model.changeset(Map.put(changes, :first_seen_at, model.first_seen_at || now))
          |> Repo.update!()

        {model, false}

      nil ->
        {%Model{} |> Model.changeset(changes) |> Repo.insert!(), true}
    end
  end

  defp create_api_key!(scope, pool) do
    {:ok, %{api_key: %APIKey{id: id}, raw_key: raw_key}} =
      Access.create_api_key(scope, pool, %{
        display_name: "Routing Strategy Smoke #{System.system_time(:second)}"
      })

    {raw_key, id}
  end

  # The whole point of the fixture: without these two ladders, both
  # `least_recent_success` and `quota_first` score every assignment 0 and
  # degenerate into the default strategy's rendezvous tie-break.
  defp differentiate!(pool, model, provisioned_assignments) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    quota_now = DateTime.truncate(now, :second)

    Enum.each(provisioned_assignments, fn provisioned ->
      prime_quota_windows!(provisioned, model, quota_now)
    end)

    request_ids =
      Enum.map(provisioned_assignments, fn provisioned ->
        record_succeeded_attempt!(pool, model, provisioned, now)
      end)

    %{request_ids: request_ids}
  end

  defp prime_quota_windows!(%{index: index, identity: identity}, model, now) do
    used_percent = Decimal.new(index * @used_percent_step)

    windows = [
      quota_window(used_percent, now, %{
        quota_key: "account",
        quota_scope: "account",
        quota_family: "account"
      }),
      quota_window(used_percent, now, %{
        quota_key: "codex_model",
        quota_scope: "model",
        quota_family: "codex_model",
        model: model.exposed_model_id,
        upstream_model: model.upstream_model_id
      })
    ]

    {:ok, _windows} = Windows.upsert_quota_windows(identity, windows)
    :ok
  end

  defp quota_window(used_percent, now, attributes) do
    Map.merge(attributes, %{
      window_kind: "primary",
      window_minutes: 300,
      active_limit: 120,
      credits: 108,
      used_percent: used_percent,
      reset_at: DateTime.add(now, 900, :second),
      source: "codex_response_headers",
      source_precision: "observed",
      freshness_state: "fresh",
      last_sync_at: now,
      observed_at: now,
      merge_precedence: 70,
      metadata: %{}
    })
  end

  defp record_succeeded_attempt!(pool, model, provisioned, now) do
    %{index: index, assignment: assignment, identity: identity} = provisioned

    completed_at = DateTime.add(now, -index * @success_age_step_seconds, :second)

    request =
      %Request{
        pool_id: pool.id,
        api_key_id: nil,
        model_id: model.id,
        requested_model: model.exposed_model_id,
        endpoint: "/backend-api/codex/responses",
        transport: "http_json",
        status: "succeeded",
        usage_status: "usage_known",
        correlation_id: Names.correlation_id(index),
        request_metadata: %{"fixture" => Names.pool_slug()},
        admitted_at: completed_at,
        completed_at: completed_at,
        response_status_code: 200,
        retry_count: 0
      }
      |> Repo.insert!()

    RequestLogFacts.record_request_created!(request)

    attempt =
      %Attempt{
        request_id: request.id,
        attempt_number: 1,
        pool_upstream_assignment_id: assignment.id,
        upstream_identity_id: identity.id,
        upstream_model_id: model.upstream_model_id,
        transport: "http_json",
        status: "succeeded",
        started_at: completed_at,
        completed_at: completed_at,
        upstream_status_code: 200,
        retryable: false,
        usage_status: "usage_known",
        response_metadata: %{}
      }
      |> Repo.insert!()

    RequestLogFacts.record_attempt_written!(attempt)

    request.id
  end

  defp active_access_token?(identity) do
    match?({:ok, _token}, Upstreams.Secrets.decrypt_active_secret(identity, "access_token"))
  end
end
