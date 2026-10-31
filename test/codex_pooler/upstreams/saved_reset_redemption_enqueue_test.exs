defmodule CodexPooler.Upstreams.SavedResetRedemptionEnqueueTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Events
  alias CodexPooler.Jobs
  alias CodexPooler.Jobs.SavedResetRedemptionWorker
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}
  alias CodexPooler.Upstreams.Secrets

  setup do
    Repo.delete_all(Oban.Job)
    :ok
  end

  describe "enqueue_for_scope/4" do
    test "rejects missing confirmation window and creates no Oban job" do
      scope = owner_scope()
      pool = pool_fixture()
      %{identity: identity} = assignment_with_saved_resets(pool, 1, %{}, confirmation_window?: false)

      assert {:error, %{code: :saved_reset_confirmation_unavailable}} =
               Upstreams.enqueue_saved_reset_redemption_for_scope(scope, identity, pool.id)

      assert saved_reset_job_count() == 0
    end

    test "rejects persisted available_count zero and creates no Oban job" do
      scope = owner_scope()
      pool = pool_fixture()
      %{identity: identity} = assignment_with_saved_resets(pool, 0)

      assert {:error, %{code: :saved_reset_unavailable}} =
               Upstreams.enqueue_saved_reset_redemption_for_scope(scope, identity, pool.id)

      assert saved_reset_job_count() == 0
    end

    test "rejects unreported saved reset count and creates no Oban job" do
      scope = owner_scope()
      pool = pool_fixture()

      %{identity: identity} =
        assignment_with_saved_resets(pool, nil, %{
          "status" => "unreported",
          "available_count" => nil,
          "reason" => %{"code" => "saved_resets_unreported"}
        })

      assert {:error, %{code: :saved_reset_unavailable}} =
               Upstreams.enqueue_saved_reset_redemption_for_scope(scope, identity, pool.id)

      assert saved_reset_job_count() == 0
    end

    test "rejects missing assignment and creates no Oban job" do
      scope = owner_scope()
      authorized_pool = pool_fixture()
      requested_pool = pool_fixture()
      %{identity: identity} = assignment_with_saved_resets(authorized_pool, 1)

      assert {:error, %{code: :pool_assignment_not_found}} =
               Upstreams.enqueue_saved_reset_redemption_for_scope(
                 scope,
                 identity,
                 requested_pool.id
               )

      assert saved_reset_job_count() == 0
    end

    test "rejects deleted persisted identity and creates no Oban job" do
      scope = owner_scope()
      pool = pool_fixture()
      %{identity: identity} = assignment_with_saved_resets(pool, 1)
      update_identity_status!(identity, UpstreamIdentity.deleted_status())

      assert {:error, %{code: :upstream_identity_not_found}} =
               Upstreams.enqueue_saved_reset_redemption_for_scope(scope, identity, pool.id)

      assert saved_reset_job_count() == 0
    end

    test "rejects disabled persisted identity and creates no Oban job" do
      scope = owner_scope()
      pool = pool_fixture()
      %{identity: identity} = assignment_with_saved_resets(pool, 1)
      update_identity_status!(identity, UpstreamIdentity.disabled_status())

      assert {:error, %{code: :upstream_identity_unavailable}} =
               Upstreams.enqueue_saved_reset_redemption_for_scope(scope, identity, pool.id)

      assert saved_reset_job_count() == 0
    end

    test "rejects missing usable credentials and creates no Oban job" do
      scope = owner_scope()
      pool = pool_fixture()
      %{identity: identity} = assignment_with_saved_resets(pool, 1)

      {1, _} =
        Secrets.revoke_active_secrets(
          identity.id,
          DateTime.utc_now() |> DateTime.truncate(:microsecond)
        )

      assert {:error, %{code: :upstream_secret_not_routable}} =
               Upstreams.enqueue_saved_reset_redemption_for_scope(scope, identity, pool.id)

      assert saved_reset_job_count() == 0
    end

    test "rejects a canonically expired active secret and creates no Oban job" do
      scope = owner_scope()
      pool = pool_fixture()
      %{identity: identity} = assignment_with_saved_resets(pool, 1)

      identity =
        update_identity_metadata!(
          identity,
          canonical_expiry_metadata(DateTime.add(DateTime.utc_now(), -60, :second))
        )

      assert {:error, %{code: :upstream_secret_not_routable}} =
               Upstreams.enqueue_saved_reset_redemption_for_scope(scope, identity, pool.id)

      assert saved_reset_job_count() == 0
    end

    test "treats untrusted raw past expiry as unknown and keeps the active-secret gate" do
      scope = owner_scope()
      pool = pool_fixture()
      %{identity: identity, assignment: assignment} = assignment_with_saved_resets(pool, 1)

      identity =
        update_identity_metadata!(identity, %{
          "credential_epoch" => 2,
          "access_token_expires_at" => DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601(),
          "token_refresh" => nil
        })

      assert {:ok, %{status: :queued, job: job, secret_status: :present}} =
               Upstreams.enqueue_saved_reset_redemption_for_scope(scope, identity, pool.id)

      assert job.args["pool_upstream_assignment_id"] == assignment.id
    end

    test "rejects fresh in-progress redemption and creates no Oban job" do
      scope = owner_scope()
      pool = pool_fixture()

      %{identity: identity} =
        assignment_with_saved_resets(pool, 1, %{}, redemption: redemption_metadata(DateTime.utc_now()))

      assert {:error, %{code: :saved_reset_redemption_in_progress}} =
               Upstreams.enqueue_saved_reset_redemption_for_scope(scope, identity, pool.id)

      assert saved_reset_job_count() == 0
    end

    @tag :scheduled_expiry_stale_claim_residual
    test "rejects stale phase-bearing consuming redemption and creates no Oban job" do
      scope = owner_scope()
      pool = pool_fixture()
      started_at = DateTime.utc_now() |> DateTime.add(-5, :minute)

      redemption =
        started_at
        |> redemption_metadata()
        |> Map.put("phase", "consuming")

      %{identity: identity} =
        assignment_with_saved_resets(pool, 1, %{}, redemption: redemption)

      assert {:error, %{code: :saved_reset_redemption_in_progress}} =
               Upstreams.enqueue_saved_reset_redemption_for_scope(scope, identity, pool.id)

      assert saved_reset_job_count() == 0
      assert Repo.reload!(identity).metadata["saved_reset_redemption"] == redemption
    end

    test "allows stale manual in-progress recovery when saved reset count is usable" do
      scope = owner_scope()
      pool = pool_fixture()

      stale_started_at =
        DateTime.utc_now()
        |> DateTime.add(-5, :minute)
        |> DateTime.truncate(:microsecond)

      %{identity: identity, assignment: assignment} =
        assignment_with_saved_resets(pool, 1, %{}, redemption: redemption_metadata(stale_started_at))

      assert {:ok, %{status: :queued, job: job}} =
               Upstreams.enqueue_saved_reset_redemption_for_scope(scope, identity, pool.id)

      assert job.args == %{
               "pool_upstream_assignment_id" => assignment.id,
               "trigger_kind" => "admin_manual",
               "manual_request_target" => %{
                 "pool_id" => assignment.pool_id,
                 "upstream_identity_id" => assignment.upstream_identity_id
               }
             }
    end

    # The Pool id comes from the page. An assignment of the same account that appears in a Pool the operator
    # cannot operate, right after the enqueue read the account's assignments, must not become the target.
    test "a forged Pool id cannot reach an assignment created after the authorization read" do
      owner = owner_scope()
      visible = pool_fixture()
      hidden = pool_fixture()
      %{user: operator} = operator_fixture(owner)
      operator_pool_assignment_fixture(operator, visible)
      scope = Scope.for_user(operator)
      %{identity: identity} = assignment_with_saved_resets(visible, 1)

      late = fn ->
        now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
        Repo.insert!(%PoolUpstreamAssignment{pool_id: hidden.id, upstream_identity_id: identity.id, assignment_label: "Late assignment", status: "active", health_status: "active", eligibility_status: "eligible", created_at: now, updated_at: now, metadata: %{}})
      end

      {result, late_assignment} = after_first_assignment_read(late, fn -> Upstreams.enqueue_saved_reset_redemption_for_scope(scope, identity.id, hidden.id) end)

      assert late_assignment.pool_id == hidden.id
      assert {:error, %{code: :pool_assignment_not_found}} = result
      assert saved_reset_job_count() == 0

      # Control: with the assignment already there when the read happens, the operator may not operate its Pool.
      assert {:error, %{code: :capability_denied}} = Upstreams.enqueue_saved_reset_redemption_for_scope(scope, identity.id, hidden.id)
      assert saved_reset_job_count() == 0
    end

    test "duplicate enqueue keeps job args account-assignment scoped only" do
      scope = owner_scope()
      pool = pool_fixture()
      %{identity: identity, assignment: assignment} = assignment_with_saved_resets(pool, 1)

      assert {:ok, %{job: first_job}} =
               Upstreams.enqueue_saved_reset_redemption_for_scope(scope, identity, pool.id)

      assert {:ok, %{status: :already_queued, job: second_job}} =
               Upstreams.enqueue_saved_reset_redemption_for_scope(scope, identity, pool.id)

      assert first_job.args == second_job.args

      assert first_job.args == %{
               "pool_upstream_assignment_id" => assignment.id,
               "trigger_kind" => "admin_manual",
               "manual_request_target" => %{
                 "pool_id" => assignment.pool_id,
                 "upstream_identity_id" => assignment.upstream_identity_id
               }
             }

      refute Map.has_key?(first_job.args, "credit_id")
      refute Map.has_key?(first_job.args, "redeem_request_id")
    end
  end

  describe "scheduled expiry enqueue" do
    @tag :scheduled_expiry_enqueue
    test "requires a canonical assignment struct and inserts no job for invalid references" do
      assert {:error, :pool_upstream_assignment_id_required} =
               Jobs.enqueue_scheduled_saved_reset_redemption(nil)

      assert {:error, :pool_upstream_assignment_id_required} =
               Jobs.enqueue_scheduled_saved_reset_redemption(Ecto.UUID.generate())

      assert saved_reset_job_count() == 0
    end

    @tag :scheduled_expiry_enqueue
    test "persists exactly four safe scheduled args without changing the manual contract" do
      pool = pool_fixture()

      %{identity: identity, assignment: assignment} =
        assignment_with_saved_resets(pool, 1)

      parent = self()

      subscriber =
        Task.async(fn ->
          :ok = Events.subscribe_pool(pool.id)
          send(parent, :saved_reset_subscribed)

          for _index <- 1..2 do
            receive do
              event -> event
            end
          end
        end)

      assert_receive :saved_reset_subscribed
      assert {:ok, manual_job} = Jobs.enqueue_saved_reset_redemption(assignment)

      assert manual_job.args == %{
               "pool_upstream_assignment_id" => assignment.id,
               "trigger_kind" => "admin_manual",
               "manual_request_target" => %{
                 "pool_id" => assignment.pool_id,
                 "upstream_identity_id" => assignment.upstream_identity_id
               }
             }

      assert {:ok, scheduled_job} =
               Jobs.enqueue_scheduled_saved_reset_redemption(assignment)

      assert scheduled_job.args == %{
               "pool_upstream_assignment_id" => assignment.id,
               "upstream_identity_id" => identity.id,
               "target_kind" => "upstream_identity",
               "trigger_kind" => "scheduled_expiry_rescue"
             }

      assert scheduled_job.meta == %{}

      [manual_event, scheduled_event] = Task.await(subscriber)
      manual_job_id = Integer.to_string(manual_job.id)
      scheduled_job_id = Integer.to_string(scheduled_job.id)

      assert {Events,
              %{
                reason: "saved_reset_redemption",
                payload: %{
                  "id" => ^manual_job_id,
                  "pool_upstream_assignment_id" => assignment_id,
                  "status" => "scheduled",
                  "worker" => "saved_reset_redemption"
                }
              }} = manual_event

      assert assignment_id == assignment.id

      assert {Events,
              %{
                reason: "saved_reset_redemption",
                payload: %{
                  "id" => ^scheduled_job_id,
                  "pool_upstream_assignment_id" => assignment_id,
                  "status" => "scheduled",
                  "worker" => "saved_reset_redemption"
                }
              }} = scheduled_event

      assert assignment_id == assignment.id
    end
  end

  # Runs `fun` and calls `late` once, right after the first assignment read that `fun` makes in this process.
  # Ecto reports a query after the connection is checked back in, so `late` runs between that read and the next.
  defp after_first_assignment_read(late, fun) do
    test_pid = self()
    handler_id = {__MODULE__, :late_assignment, System.unique_integer([:positive])}
    fired = :atomics.new(1, [])
    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if self() == test_pid and metadata[:source] == "pool_upstream_assignments" and is_binary(metadata[:query]) and
               String.starts_with?(metadata.query, "SELECT") and :atomics.compare_exchange(fired, 1, 0, 1) == :ok do
            send(test_pid, {handler_id, late.()})
          end
        end,
        nil
      )

    try do
      result = fun.()
      assert_received {^handler_id, late_row}
      {result, late_row}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp owner_scope do
    %{user: user} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    Scope.for_user(user, ["instance_owner"])
  end

  defp assignment_with_saved_resets(pool, available_count, attrs \\ %{}, opts \\ []) do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    saved_resets =
      %{
        "status" => "reported",
        "available_count" => available_count,
        "source" => "codex_usage_api",
        "path_style" => "codex_api",
        "observed_at" => DateTime.to_iso8601(observed_at),
        "usage_path" => "/api/codex/usage",
        "reason" => nil
      }
      |> Map.merge(attrs)

    metadata = %{"saved_resets" => saved_resets}

    metadata =
      case Keyword.get(opts, :redemption) do
        nil -> metadata
        redemption -> Map.put(metadata, "saved_reset_redemption", redemption)
      end

    %{identity: identity} = fixture = active_upstream_assignment_fixture(pool, %{metadata: metadata})

    if Keyword.get(opts, :confirmation_window?, true) do
      assert {:ok, _window} =
               QuotaWindows.record_evidence(
                 identity,
                 %{
                   quota_key: "account",
                   quota_scope: "account",
                   quota_family: "account",
                   window_kind: "secondary",
                   window_minutes: 10_080,
                   used_percent: Decimal.new("25"),
                   reset_at: DateTime.add(observed_at, 2, :hour),
                   observed_at: observed_at,
                   last_sync_at: observed_at,
                   source: "codex_usage_api",
                   source_precision: "observed",
                   freshness_state: "fresh"
                 },
                 observed_at
               )
    end

    fixture
  end

  defp redemption_metadata(started_at) do
    %{
      "status" => "redeeming",
      "attempt_id" => Ecto.UUID.generate(),
      "generation" => 1,
      "trigger_kind" => "admin_manual",
      "started_at" => started_at |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601(),
      "finished_at" => nil,
      "result" => nil
    }
  end

  defp update_identity_status!(identity, status) do
    identity
    |> UpstreamIdentity.changeset(%{
      status: status,
      updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })
    |> Repo.update!()
  end

  defp update_identity_metadata!(identity, expiry_metadata) do
    metadata = Map.merge(identity.metadata || %{}, expiry_metadata)

    identity
    |> UpstreamIdentity.changeset(%{
      metadata: metadata,
      updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })
    |> Repo.update!()
  end

  defp canonical_expiry_metadata(deadline) do
    %{
      "credential_epoch" => 1,
      "access_token_expires_at" => DateTime.to_iso8601(deadline),
      "token_refresh" => %{
        "access_token_expiry" => %{
          "version" => 1,
          "credential_epoch" => 1,
          "state" => "known",
          "source" => "explicit"
        }
      }
    }
  end

  defp saved_reset_job_count do
    worker = worker_name(SavedResetRedemptionWorker)

    Repo.aggregate(
      from(job in Oban.Job, where: job.worker == ^worker),
      :count
    )
  end

  defp worker_name(worker), do: worker |> Atom.to_string() |> String.replace_prefix("Elixir.", "")
end
