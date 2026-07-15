defmodule CodexPooler.Jobs.AccountPrimingJobsTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Jobs
  alias CodexPooler.Jobs.{AccountReconciliationWorker, SavedResetRedemptionWorker}
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Lifecycle.IdentityLifecycle
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.Reconciliation.AccountReconciliation
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment

  import CodexPooler.PoolerFixtures

  setup do
    Repo.delete_all(Oban.Job)
    :ok
  end

  describe "account reconciliation priming jobs" do
    test "Jobs assignment activation orchestration enqueues priming immediately" do
      upstream = start_path_upstream(%{"/codex/models" => {200, %{"models" => []}}})

      {pool, assignment, _identity} =
        codex_assignment_fixture(upstream, skip_activation_priming: false)

      assignment = Repo.get!(PoolUpstreamAssignment, assignment.id)
      assert assignment.metadata["quota_priming"]["status"] == "unknown"
      assert assignment.metadata["quota_priming"]["trigger_kind"] == "assignment_activated"

      assert [job] = all_enqueued(worker: AccountReconciliationWorker)
      assert job.args["pool_id"] == pool.id
      assert job.args["pool_upstream_assignment_id"] == assignment.id
      assert job.args["trigger_kind"] == "assignment_activated"
    end

    test "account-link priming records reset-bearing known state" do
      future_reset = DateTime.add(DateTime.utc_now(), 900, :second)

      upstream =
        start_path_upstream(%{
          "/backend-api/wham/usage" =>
            {200,
             %{
               "rate_limit" => %{
                 "primary_window" => %{
                   "used_percent" => 25,
                   "limit_window_seconds" => 18_000,
                   "reset_at" => DateTime.to_iso8601(future_reset)
                 }
               }
             }},
          "/codex/models" => {200, %{"models" => [%{"id" => "gpt-primed"}]}}
        })

      {pool, assignment, identity} = codex_assignment_fixture(upstream)

      assert {:ok, job} =
               Jobs.enqueue_assignment_priming(pool, assignment, trigger_kind: "account_link")

      assignment = Repo.get!(PoolUpstreamAssignment, assignment.id)
      assert assignment.metadata["quota_priming"]["status"] == "unknown"
      assert job.args["trigger_kind"] == "account_link"
      assert [queued] = all_enqueued(worker: AccountReconciliationWorker)
      assert queued.id == job.id

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :jobs)

      assignment = Repo.get!(PoolUpstreamAssignment, assignment.id)
      priming = assignment.metadata["quota_priming"]
      assert priming["status"] == "known"
      assert priming["account_primary_usable_window_count"] == 1
      assert priming["usable_window_count"] == 1
      assert priming["reset_bearing_window_count"] == 1

      assert [window] = QuotaWindows.list_quota_windows(identity)
      assert window.window_kind == "primary"
      assert QuotaWindows.usable_window?(window)
    end

    test "manual quota refresh updates priming state for every assignment of the identity" do
      future_reset = DateTime.add(DateTime.utc_now(), 900, :second)

      upstream =
        start_path_upstream(%{
          "/backend-api/wham/usage" =>
            {200,
             %{
               "rate_limit" => %{
                 "primary_window" => %{
                   "used_percent" => 25,
                   "limit_window_seconds" => 18_000,
                   "reset_at" => DateTime.to_iso8601(future_reset)
                 }
               }
             }}
        })

      {pool, assignment, identity} = codex_assignment_fixture(upstream)
      second_pool = pool_fixture(%{name: "Shared identity quota pool"})

      assert {:ok, sibling_assignment} =
               PoolAssignments.assign_pool_assignment(second_pool, identity)

      assert {:ok, result} =
               AccountReconciliation.run(pool.id, assignment.id, "admin_upstreams_live")

      assert result.catalog.code == "catalog_sync_skipped"

      primary_priming =
        Repo.get!(PoolUpstreamAssignment, assignment.id).metadata["quota_priming"]

      sibling_priming =
        Repo.get!(PoolUpstreamAssignment, sibling_assignment.id).metadata["quota_priming"]

      assert primary_priming["status"] == "known"
      assert sibling_priming == primary_priming

      assert [usage_request] = FakeUpstream.requests(upstream)
      assert usage_request.path == "/backend-api/wham/usage"
    end

    test "account reconciliation refreshes an expired access token before quota priming" do
      future_reset = DateTime.add(DateTime.utc_now(), 900, :second)
      refresh_token = "refresh-token-#{System.unique_integer([:positive])}"
      new_access_token = "new-access-token-#{System.unique_integer([:positive])}"

      usage_payload = %{
        "rate_limit" => %{
          "primary_window" => %{
            "used_percent" => 25,
            "limit_window_seconds" => 18_000,
            "reset_at" => DateTime.to_iso8601(future_reset)
          }
        }
      }

      {:ok, upstream} =
        FakeUpstream.start_link(
          {:sequence,
           [
             {:path_json, %{"/backend-api/wham/usage" => {401, %{"error" => "expired"}}}},
             {:path_json, %{"/oauth/token" => {200, %{"access_token" => new_access_token}}}},
             {:path_json, %{"/backend-api/wham/usage" => {200, usage_payload}}},
             {:path_json,
              %{"/backend-api/codex/models" => {200, %{"models" => [%{"id" => "gpt-refreshed"}]}}}}
           ]}
        )

      on_exit(fn -> FakeUpstream.stop(upstream) end)

      {pool, assignment, identity} = codex_assignment_fixture(upstream)

      assert {:ok, _secret} =
               Upstreams.store_encrypted_secret(identity, %{
                 secret_kind: "refresh_token",
                 plaintext: refresh_token
               })

      assert {:ok, result} = AccountReconciliation.run(pool.id, assignment.id, "account_link")

      assert result.assignment.metadata["quota_priming"]["status"] == "known"
      assert result.identity.id == identity.id
      assert result.quota.status == :succeeded

      persisted = Repo.get!(CodexPooler.Upstreams.Schemas.UpstreamIdentity, identity.id)
      assert persisted.metadata["token_refresh"]["status"] == "succeeded"
      assert persisted.metadata["token_refresh"]["trigger_kind"] == "account_reconciliation"

      assert {:ok, ^new_access_token} =
               Upstreams.Secrets.decrypt_active_secret(identity, "access_token")

      assert [usage_401, token_refresh, usage_retry, catalog] = FakeUpstream.requests(upstream)
      assert usage_401.path == "/backend-api/wham/usage"
      assert token_refresh.path == "/oauth/token"
      assert usage_retry.path == "/backend-api/wham/usage"
      assert catalog.path == "/backend-api/codex/models"
    end

    test "account reconciliation does not report stale existing quota as refreshed after auth failure" do
      expired_reset = DateTime.add(DateTime.utc_now(), -60, :second)

      upstream =
        start_path_upstream(%{
          "/backend-api/wham/usage" => {401, %{"error" => "expired"}}
        })

      {pool, assignment, identity} = codex_assignment_fixture(upstream)

      assert {:ok, [_window]} =
               QuotaWindows.upsert_quota_windows(identity, [
                 %{
                   quota_key: "account",
                   quota_scope: "account",
                   quota_family: "account",
                   window_kind: "primary",
                   window_minutes: 300,
                   used_percent: Decimal.new("47"),
                   reset_at: expired_reset,
                   source: "codex_usage_api",
                   source_precision: "observed",
                   freshness_state: "fresh",
                   observed_at: DateTime.add(DateTime.utc_now(), -3_600, :second)
                 }
               ])

      assert {:ok, result} = AccountReconciliation.run(pool.id, assignment.id, "scheduled")

      assert result.quota.status == :failed
      assert result.quota.code == "quota_refresh_auth_unavailable"
      assert result.assignment.metadata["quota_priming"]["status"] == "failed"

      assert result.assignment.metadata["quota_priming"]["reason"]["code"] ==
               "quota_refresh_auth_unavailable"
    end

    test "weekly-only account-link priming records resetless unprimed state" do
      upstream =
        start_path_upstream(%{
          "/api/codex/usage" => {404, %{"error" => "missing"}},
          "/backend-api/codex/usage" => {404, %{"error" => "missing"}},
          "/wham/usage" => {404, %{"error" => "missing"}},
          "/backend-api/wham/usage" =>
            {200,
             %{
               "rate_limit" => %{
                 "primary_window" => %{
                   "used_percent" => 67,
                   "limit_window_seconds" => 604_800
                 }
               }
             }},
          "/codex/models" => {200, %{"models" => [%{"id" => "gpt-weekly"}]}}
        })

      {pool, assignment, identity} = codex_assignment_fixture(upstream)

      assert {:ok, _job} =
               Jobs.enqueue_assignment_priming(pool, assignment, trigger_kind: "account_link")

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :jobs)

      assignment = Repo.get!(PoolUpstreamAssignment, assignment.id)
      priming = assignment.metadata["quota_priming"]
      assert priming["status"] == "resetless_unprimed"
      assert priming["usable_window_count"] == 0
      assert priming["reset_bearing_window_count"] == 0

      assert [weekly] = QuotaWindows.list_quota_windows(identity)
      assert weekly.window_kind == "secondary"
      assert weekly.reset_at == nil
      refute QuotaWindows.usable_window?(weekly)
    end

    test "weekly reset-bearing priming records probe state without account-primary evidence" do
      future_reset = DateTime.add(DateTime.utc_now(), 300, :second)

      upstream =
        start_path_upstream(%{
          "/api/codex/usage" => {404, %{"error" => "missing"}},
          "/backend-api/codex/usage" => {404, %{"error" => "missing"}},
          "/wham/usage" => {404, %{"error" => "missing"}},
          "/backend-api/wham/usage" =>
            {200,
             %{
               "rate_limit" => %{
                 "primary_window" => %{
                   "used_percent" => 67,
                   "limit_window_seconds" => 604_800,
                   "reset_at" => DateTime.to_iso8601(future_reset)
                 }
               }
             }},
          "/codex/models" => {200, %{"models" => [%{"id" => "gpt-weekly-reset"}]}}
        })

      {pool, assignment, identity} = codex_assignment_fixture(upstream)

      assert {:ok, _job} =
               Jobs.enqueue_assignment_priming(pool, assignment, trigger_kind: "account_link")

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :jobs)

      assignment = Repo.get!(PoolUpstreamAssignment, assignment.id)
      priming = assignment.metadata["quota_priming"]
      assert priming["status"] == "weekly_only_probe"
      assert priming["account_primary_usable_window_count"] == 0
      assert priming["usable_window_count"] == 1
      assert priming["reset_bearing_window_count"] == 1

      assert [weekly] = QuotaWindows.list_quota_windows(identity)
      assert weekly.window_kind == "secondary"
      assert QuotaWindows.usable_window?(weekly)
    end

    test "failed account-link priming records sanitized failure and discards without retry" do
      upstream =
        start_path_upstream(%{
          "/backend-api/wham/usage" =>
            {500, %{"error" => %{"message" => "Bearer secret-token failed"}}},
          "/codex/models" => {200, %{"models" => [%{"id" => "gpt-failure"}]}}
        })

      {pool, assignment, _identity} = codex_assignment_fixture(upstream)

      assert {:ok, job} =
               Jobs.enqueue_assignment_priming(pool, assignment, trigger_kind: "account_link")

      assert %{discard: 1, success: 0} = Oban.drain_queue(queue: :jobs)

      discarded_job = Repo.get!(Oban.Job, job.id)
      assert discarded_job.state == "discarded"
      assert discarded_job.max_attempts == 1

      assignment = Repo.get!(PoolUpstreamAssignment, assignment.id)
      priming = assignment.metadata["quota_priming"]
      assert priming["status"] == "failed"
      assert priming["reason"]["code"] == "quota_refresh_unavailable"
      refute inspect(priming) =~ "secret-token"
      refute inspect(priming) =~ "Bearer"
    end

    test "priming reports expired when resetless rows coexist with expired reset evidence" do
      expired_reset = DateTime.add(DateTime.utc_now(), -60, :second)

      {pool, assignment} =
        active_assignment_fixture(%{
          "quota_windows" => [
            %{
              "window_kind" => "primary",
              "window_minutes" => 300,
              "reset_at" => DateTime.to_iso8601(expired_reset),
              "source" => "local_reconciliation",
              "source_precision" => "observed",
              "freshness_state" => "fresh"
            },
            %{
              "window_kind" => "secondary",
              "window_minutes" => 10_080,
              "used_percent" => 67,
              "source" => "codex_usage_api",
              "source_precision" => "inferred",
              "freshness_state" => "fresh"
            }
          ]
        })

      assert {:ok, result} =
               AccountReconciliation.run(pool.id, assignment.id, "classification_test")

      assert result.assignment.metadata["quota_priming"]["status"] == "expired"
      assert result.assignment.metadata["quota_priming"]["expired_window_count"] == 1
      assert result.assignment.metadata["quota_priming"]["usable_window_count"] == 0
    end

    test "priming reports stale when resetless rows coexist with stale reset evidence" do
      stale_observed_at = DateTime.add(DateTime.utc_now(), -3_600, :second)
      future_reset = DateTime.add(DateTime.utc_now(), 900, :second)

      {pool, assignment} =
        active_assignment_fixture(%{
          "quota_windows" => [
            %{
              "window_kind" => "primary",
              "window_minutes" => 300,
              "reset_at" => DateTime.to_iso8601(future_reset),
              "observed_at" => DateTime.to_iso8601(stale_observed_at),
              "source" => "local_reconciliation",
              "source_precision" => "observed",
              "freshness_state" => "fresh"
            },
            %{
              "window_kind" => "secondary",
              "window_minutes" => 10_080,
              "used_percent" => 67,
              "source" => "codex_usage_api",
              "source_precision" => "inferred",
              "freshness_state" => "fresh"
            }
          ]
        })

      assert {:ok, result} =
               AccountReconciliation.run(pool.id, assignment.id, "classification_test")

      assert result.assignment.metadata["quota_priming"]["status"] == "stale"
      assert result.assignment.metadata["quota_priming"]["stale_window_count"] == 1
      assert result.assignment.metadata["quota_priming"]["usable_window_count"] == 0
    end
  end

  describe "saved reset redemption jobs" do
    test "deduplicates duplicate redemption enqueue for the same upstream assignment" do
      %{assignment: assignment} = upstream_assignment_fixture()

      assert {:ok, first_job} =
               Jobs.enqueue_saved_reset_redemption(assignment, trigger_kind: "admin_manual")

      assert {:ok, duplicate_job} =
               Jobs.enqueue_saved_reset_redemption(assignment.id, trigger_kind: "operator_retry")

      refute first_job.conflict?
      assert duplicate_job.conflict?
      assert duplicate_job.id == first_job.id

      assert [job] = all_enqueued(worker: SavedResetRedemptionWorker)
      assert job.id == first_job.id
      assert job.args["pool_upstream_assignment_id"] == assignment.id
      assert job.args["trigger_kind"] == "admin_manual"
      refute Map.has_key?(job.args, "credit_id")
      refute Map.has_key?(job.args, "redeem_request_id")
    end
  end

  defp active_assignment_fixture(metadata) do
    pool = pool_fixture()

    assert {:ok, identity} =
             IdentityLifecycle.create_upstream_identity(%{
               chatgpt_account_id: "acct_#{System.unique_integer([:positive])}",
               account_label: "Job account",
               onboarding_method: "import",
               metadata: %{}
             })

    assert {:ok, identity} =
             IdentityLifecycle.activate_upstream_identity(identity)

    configure_upstream_secret_key!()

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(identity, %{
               secret_kind: "access_token",
               plaintext: "token"
             })

    assert {:ok, assignment} =
             PoolAssignments.create_pool_assignment(pool, identity, %{
               assignment_label: "Job assignment",
               metadata: metadata
             })

    assert {:ok, assignment} =
             PoolAssignments.activate_pool_assignment(assignment, %{
               skip_quota_priming: true
             })

    {pool, assignment}
  end

  defp codex_assignment_fixture(upstream, opts \\ []) do
    pool = pool_fixture()

    assert {:ok, identity} =
             IdentityLifecycle.create_upstream_identity(%{
               chatgpt_account_id: "acct_#{System.unique_integer([:positive])}",
               account_label: "Codex account",
               onboarding_method: "invite",
               metadata: %{"base_url" => FakeUpstream.url(upstream)}
             })

    assert {:ok, identity} =
             IdentityLifecycle.activate_upstream_identity(identity)

    assert {:ok, assignment} =
             PoolAssignments.create_pool_assignment(pool, identity, %{
               assignment_label: "Codex assignment"
             })

    configure_upstream_secret_key!()

    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(identity, %{
               secret_kind: "access_token",
               plaintext: "token"
             })

    skip_activation_priming = Keyword.get(opts, :skip_activation_priming, true)

    assert {:ok, assignment} =
             PoolAssignments.activate_pool_assignment(assignment, %{
               skip_quota_priming: skip_activation_priming
             })

    unless skip_activation_priming do
      assert {:ok, _job} =
               Jobs.enqueue_assignment_priming(assignment.pool_id, assignment,
                 trigger_kind: "assignment_activated"
               )
    end

    {pool, assignment, identity}
  end

  defp start_path_upstream(routes) do
    {:ok, upstream} = FakeUpstream.start_link({:path_json, routes})
    on_exit(fn -> FakeUpstream.stop(upstream) end)
    upstream
  end

  defp configure_upstream_secret_key! do
    previous = Application.get_env(:codex_pooler, CodexPooler.Upstreams)

    Application.put_env(:codex_pooler, CodexPooler.Upstreams,
      upstream_secret_key: Base.encode64(:crypto.hash(:sha256, "test-upstream-secret-key")),
      upstream_secret_key_version: "test-v1"
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:codex_pooler, CodexPooler.Upstreams, previous)
      else
        Application.delete_env(:codex_pooler, CodexPooler.Upstreams)
      end
    end)
  end
end
