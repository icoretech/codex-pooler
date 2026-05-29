defmodule CodexPooler.PoolerFixtures do
  @moduledoc """
  Fixtures for pool-oriented gateway and accounting tests.

  These helpers use public contexts where task coverage depends on final behavior.
  """

  alias CodexPooler.Upstreams.Secrets, as: Secrets

  import ExUnit.Assertions
  import Ecto.Query

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Accounting.LedgerEntry
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Accounts.User
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Pools.{Membership, OperatorPoolAssignment, Pool}
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Lifecycle.IdentityLifecycle
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  def pool_fixture(attrs \\ %{}) do
    now = now()
    slug = Map.get(attrs, :slug, "pool-#{unique_suffix()}")

    %Pool{
      slug: slug,
      name: Map.get(attrs, :name, "Pool #{slug}"),
      status: Map.get(attrs, :status, "active"),
      created_by_user_id: Map.get(attrs, :created_by_user_id),
      created_at: now,
      updated_at: now,
      disabled_at: Map.get(attrs, :disabled_at)
    }
    |> Repo.insert!()
  end

  def operator_pool_assignment_fixture(%User{} = user, %Pool{} = pool, attrs \\ %{}) do
    attrs = Map.new(attrs)
    now = now()
    status = Map.get(attrs, :status, "active")

    %OperatorPoolAssignment{}
    |> OperatorPoolAssignment.changeset(%{
      user_id: Map.get(attrs, :user_id, user.id),
      pool_id: Map.get(attrs, :pool_id, pool.id),
      status: status,
      created_by_user_id: Map.get(attrs, :created_by_user_id, user.id),
      created_at: Map.get(attrs, :created_at, now),
      updated_at: Map.get(attrs, :updated_at, now),
      revoked_at: Map.get(attrs, :revoked_at, if(status == "revoked", do: now))
    })
    |> Repo.insert!()
  end

  def api_key_fixture(pool \\ pool_fixture(), attrs \\ %{}) do
    attrs = Map.new(attrs)
    scope = Map.get(attrs, :scope) || fixture_scope(Map.get(attrs, :created_by_user_id))

    {:ok, %{api_key: key, raw_key: raw_key}} =
      Access.create_api_key(scope, pool, %{
        display_name: Map.get(attrs, :display_name, "Gateway test key"),
        expires_at: Map.get(attrs, :expires_at)
      })

    key =
      maybe_force_api_key_status(
        key,
        Map.get(attrs, :status, "active"),
        Map.get(attrs, :revoked_at)
      )

    %{pool: pool, api_key: key, raw_key: raw_key, authorization: "Bearer #{raw_key}"}
  end

  def active_api_key_fixture(pool \\ pool_fixture(), attrs \\ %{}) do
    api_key_fixture(pool, Map.put(attrs, :status, "active"))
  end

  def paused_api_key_fixture(pool \\ pool_fixture(), attrs \\ %{}) do
    api_key_fixture(pool, Map.put(attrs, :status, "paused"))
  end

  def missing_api_key_headers, do: %{}

  def upstream_assignment_fixture(pool \\ pool_fixture(), attrs \\ %{}) do
    now = now()

    identity =
      %UpstreamIdentity{
        chatgpt_account_id: Map.get(attrs, :chatgpt_account_id),
        account_label: Map.get(attrs, :account_label, "Primary upstream"),
        onboarding_method: Map.get(attrs, :onboarding_method, "import"),
        status: Map.get(attrs, :identity_status, "active"),
        plan_family: Map.get(attrs, :plan_family),
        plan_label: Map.get(attrs, :plan_label),
        headers_profile_version: 1,
        created_at: now,
        updated_at: now,
        metadata: Map.get(attrs, :identity_metadata, %{})
      }
      |> Repo.insert!()

    assignment =
      %PoolUpstreamAssignment{
        pool_id: pool.id,
        upstream_identity_id: identity.id,
        assignment_label: Map.get(attrs, :assignment_label, "Primary upstream"),
        status: Map.get(attrs, :assignment_status, "active"),
        health_status: Map.get(attrs, :health_status, "active"),
        eligibility_status: Map.get(attrs, :eligibility_status, "eligible"),
        created_at: now,
        updated_at: now,
        metadata: Map.get(attrs, :assignment_metadata, %{})
      }
      |> Repo.insert!()

    %{identity: identity, assignment: assignment}
  end

  def active_upstream_assignment_fixture(pool \\ pool_fixture(), attrs \\ %{}) do
    attrs = Map.new(attrs)
    unique = System.unique_integer([:positive])
    token = Map.get(attrs, :access_token, "upstream-token-#{unique}")
    metadata = Map.get(attrs, :metadata, %{})

    assert {:ok, identity} =
             IdentityLifecycle.create_upstream_identity(%{
               chatgpt_account_id: Map.get(attrs, :chatgpt_account_id, "acct_#{unique}"),
               account_label: Map.get(attrs, :account_label, "Gateway upstream #{unique}"),
               onboarding_method: Map.get(attrs, :onboarding_method, "import"),
               metadata: metadata
             })

    assert {:ok, identity} =
             IdentityLifecycle.activate_upstream_identity(identity)

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(identity, %{
               secret_kind: Map.get(attrs, :secret_kind, "access_token"),
               plaintext: token
             })

    assert {:ok, assignment} =
             PoolAssignments.create_pool_assignment(pool, identity, %{
               assignment_label:
                 Map.get(attrs, :assignment_label, "Gateway assignment #{unique}"),
               metadata: metadata
             })

    assert {:ok, assignment} =
             PoolAssignments.activate_pool_assignment(assignment)

    assert {:ok, ^token} =
             Secrets.decrypt_active_secret(identity, "access_token")

    %{identity: identity, assignment: assignment, access_token: token}
  end

  def model_fixture(pool \\ pool_fixture(), attrs \\ %{}) do
    now = now()
    exposed_model_id = Map.get(attrs, :exposed_model_id, "gpt-5.4-mini")

    %Model{
      pool_id: pool.id,
      upstream_model_id: Map.get(attrs, :upstream_model_id, "upstream-#{exposed_model_id}"),
      exposed_model_id: exposed_model_id,
      display_name: Map.get(attrs, :display_name, "GPT 5.4 Mini"),
      status: Map.get(attrs, :status, "active"),
      supports_responses: Map.get(attrs, :supports_responses, true),
      supports_streaming: Map.get(attrs, :supports_streaming, true),
      supports_tools: Map.get(attrs, :supports_tools, true),
      supports_reasoning: Map.get(attrs, :supports_reasoning, true),
      source_assignment_count: Map.get(attrs, :source_assignment_count, 1),
      first_seen_at: now,
      last_seen_at: now,
      metadata: Map.get(attrs, :metadata, %{})
    }
    |> Repo.insert!()
  end

  def request_fixture(%{pool: pool, api_key: api_key}, attrs \\ %{}) do
    %Request{
      pool_id: pool.id,
      api_key_id: api_key.id,
      model_id: Map.get(attrs, :model_id),
      requested_model: Map.get(attrs, :requested_model, "gpt-5.4-mini"),
      endpoint: Map.get(attrs, :endpoint, "/backend-api/codex/responses"),
      transport: Map.get(attrs, :transport, "http_json"),
      status: Map.get(attrs, :status, "succeeded"),
      usage_status: Map.get(attrs, :usage_status, "usage_known"),
      correlation_id:
        Map.get(attrs, :correlation_id, "corr-#{System.unique_integer([:positive])}"),
      user_agent: Map.get(attrs, :user_agent),
      request_metadata: Map.get(attrs, :request_metadata, %{}),
      admitted_at: now(),
      completed_at: Map.get(attrs, :completed_at, now()),
      response_status_code: Map.get(attrs, :response_status_code, 200),
      retry_count: Map.get(attrs, :retry_count, 0),
      last_error_code: Map.get(attrs, :last_error_code),
      upstream_account_label: Map.get(attrs, :upstream_account_label),
      upstream_account_email: Map.get(attrs, :upstream_account_email),
      upstream_account_plan_label: Map.get(attrs, :upstream_account_plan_label),
      upstream_account_plan_family: Map.get(attrs, :upstream_account_plan_family),
      reasoning_effort: Map.get(attrs, :reasoning_effort),
      service_tier: Map.get(attrs, :service_tier),
      requested_service_tier: Map.get(attrs, :requested_service_tier),
      actual_service_tier: Map.get(attrs, :actual_service_tier)
    }
    |> Repo.insert!()
  end

  def attempt_fixture(request, assignment, attrs \\ %{}) do
    %Attempt{
      request_id: request.id,
      attempt_number: Map.get(attrs, :attempt_number, 1),
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: assignment.upstream_identity_id,
      upstream_model_id: Map.get(attrs, :upstream_model_id, "upstream-gpt-5.4-mini"),
      transport: Map.get(attrs, :transport, request.transport),
      status: Map.get(attrs, :status, "succeeded"),
      started_at: now(),
      completed_at: Map.get(attrs, :completed_at, now()),
      upstream_status_code: Map.get(attrs, :upstream_status_code, 200),
      retryable: Map.get(attrs, :retryable, false),
      usage_status: Map.get(attrs, :usage_status, "usage_known"),
      response_metadata: Map.get(attrs, :response_metadata, %{})
    }
    |> Repo.insert!()
  end

  def ledger_entry_fixture(request, attrs \\ %{}) do
    %LedgerEntry{
      request_id: request.id,
      attempt_id: Map.get(attrs, :attempt_id),
      pricing_snapshot_id: Map.get(attrs, :pricing_snapshot_id),
      pool_id: request.pool_id,
      api_key_id: request.api_key_id,
      pool_upstream_assignment_id: Map.get(attrs, :pool_upstream_assignment_id),
      upstream_identity_id: Map.get(attrs, :upstream_identity_id),
      entry_kind: Map.get(attrs, :entry_kind, "settlement"),
      amount_status: Map.get(attrs, :amount_status, "recorded"),
      usage_status: Map.get(attrs, :usage_status, "usage_known"),
      transport: Map.get(attrs, :transport, request.transport),
      currency_code: Map.get(attrs, :currency_code, "USD"),
      input_tokens: Map.get(attrs, :input_tokens, 10),
      cached_input_tokens: Map.get(attrs, :cached_input_tokens, 0),
      output_tokens: Map.get(attrs, :output_tokens, 4),
      reasoning_tokens: Map.get(attrs, :reasoning_tokens, 0),
      total_tokens: Map.get(attrs, :total_tokens, 14),
      request_count: Map.get(attrs, :request_count, 1),
      estimated_cost_micros: Decimal.new(Map.get(attrs, :estimated_cost_micros, 0)),
      settled_cost_micros: Decimal.new(Map.get(attrs, :settled_cost_micros, 0)),
      occurred_at: Map.get(attrs, :occurred_at, now()),
      created_at: Map.get(attrs, :created_at, now()),
      details: Map.get(attrs, :details, %{})
    }
    |> Repo.insert!()
  end

  def assert_accounting_for_request(request, attrs \\ %{}) do
    attrs = Map.new(attrs)

    entries = Repo.all(from entry in LedgerEntry, where: entry.request_id == ^request.id)

    expected_count = Map.get(attrs, :entry_count, 1)
    assert length(entries) == expected_count

    if usage_status = Map.get(attrs, :usage_status) do
      assert Enum.all?(entries, &(&1.usage_status == usage_status))
    end

    entries
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp unique_suffix do
    "#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
  end

  defp fixture_scope(user_id) when is_binary(user_id) do
    user_id
    |> ensure_fixture_owner!()
    |> Scope.for_user(["instance_owner"])
  end

  defp fixture_scope(_user_id) do
    case Repo.one(
           from m in Membership,
             join: u in User,
             on: u.id == m.user_id,
             where: m.role == "instance_owner" and m.status == "active",
             limit: 1,
             select: u
         ) do
      %User{} = user ->
        Scope.for_user(user, ["instance_owner"])

      nil ->
        user =
          %User{}
          |> User.bootstrap_changeset(%{
            "email" => "pooler-#{System.unique_integer([:positive])}@example.com",
            "display_name" => "Pooler Fixture Owner",
            "password" => "bootstrap-pass-123"
          })
          |> Repo.insert!()

        ensure_fixture_owner!(user.id)
        Scope.for_user(user, ["instance_owner"])
    end
  end

  defp ensure_fixture_owner!(user_id) do
    user = Repo.get!(User, user_id)

    case Repo.get_by(Membership, user_id: user.id, role: "instance_owner", status: "active") do
      nil ->
        %Membership{}
        |> Membership.changeset(%{
          user_id: user.id,
          role: "instance_owner",
          status: "active",
          created_by_user_id: user.id,
          created_at: now()
        })
        |> Repo.insert!()

      _membership ->
        :ok
    end

    user
  end

  defp maybe_force_api_key_status(key, "active", _revoked_at), do: key

  defp maybe_force_api_key_status(key, status, revoked_at) do
    timestamp = now()

    key
    |> Access.APIKey.changeset(%{
      status: status,
      revoked_at: revoked_at || if(status == "revoked", do: timestamp, else: nil)
    })
    |> Repo.update!()
  end
end
