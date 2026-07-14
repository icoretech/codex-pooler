defmodule CodexPooler.Jobs.TokenRefreshRecoveryTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Jobs
  alias CodexPooler.Jobs.TokenRefreshWorker
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}

  import CodexPooler.PoolerFixtures

  @now ~U[2026-06-11 12:00:00Z]
  @worker_name TokenRefreshWorker |> Atom.to_string() |> String.replace_prefix("Elixir.", "")
  @incomplete_job_states ~w(available scheduled executing retryable)

  setup do
    Repo.delete_all(Oban.Job)
    :ok
  end

  describe "scheduled token refresh recovery enqueue" do
    test "enqueues refresh_due identities with active assignments immediately" do
      identity = recovery_identity_fixture("refresh_due")

      assert {:ok, %{inserted: [job], conflicts: [], errors: []}} =
               Jobs.enqueue_scheduled_token_refreshes(now: @now)

      assert job.worker == @worker_name

      assert job.args == %{
               "upstream_identity_id" => identity.id,
               "trigger_kind" => "scheduled"
             }

      refute inspect(job.args) =~ "token"
      refute inspect(job.args) =~ "auth"
    end

    test "returns a successful empty batch when there are no candidates" do
      assert {:ok, %{inserted: [], conflicts: [], errors: []}} =
               Jobs.enqueue_scheduled_token_refreshes(now: @now)

      assert [] = all_enqueued(worker: TokenRefreshWorker)
    end

    test "only recoverable lifecycle states are scheduled candidates" do
      due = recovery_identity_fixture("refresh_due", updated_at: DateTime.add(@now, -15, :minute))

      failed =
        recovery_identity_fixture("refresh_failed",
          updated_at: DateTime.add(@now, -8, :hour),
          metadata: failed_metadata(DateTime.add(@now, -7, :hour))
        )

      recent_failed =
        recovery_identity_fixture("refresh_failed",
          updated_at: DateTime.add(@now, -8, :hour),
          metadata: failed_metadata(DateTime.add(@now, -1, :hour))
        )

      for status <- [
            "active",
            "reauth_required",
            "paused",
            "deleted",
            "disabled",
            "errored",
            "pending"
          ] do
        recovery_identity_fixture(status,
          updated_at: DateTime.add(@now, -8, :hour),
          metadata: failed_metadata(DateTime.add(@now, -7, :hour))
        )
      end

      assert {:ok, %{inserted: jobs, conflicts: [], errors: []}} =
               Jobs.enqueue_scheduled_token_refreshes(now: @now)

      assert jobs |> Enum.map(& &1.args["upstream_identity_id"]) |> Enum.sort() ==
               Enum.sort([due.id, failed.id])

      refute Enum.any?(jobs, &(&1.args["upstream_identity_id"] == recent_failed.id))
    end

    test "excludes identities without an active assignment in an active pool" do
      recovery_identity_fixture("refresh_due", assignment?: false)
      recovery_identity_fixture("refresh_due", assignment_status: "disabled")
      recovery_identity_fixture("refresh_due", pool_status: "disabled")
      included = recovery_identity_fixture("refresh_due")

      assert {:ok, %{inserted: [job], conflicts: [], errors: []}} =
               Jobs.enqueue_scheduled_token_refreshes(now: @now)

      assert job.args["upstream_identity_id"] == included.id
    end

    test "refresh_failed identities become eligible only after an active assignment is added" do
      pool = pool_fixture(%{status: "active"})
      unique = System.unique_integer([:positive])

      identity =
        upstream_identity_fixture(%{
          account_label: "Refresh failed transition #{unique}",
          chatgpt_account_id: "acct_refresh_failed_transition_#{unique}",
          metadata: failed_metadata(DateTime.add(@now, -7, :hour))
        })
        |> update_identity!(%{
          status: "refresh_failed",
          updated_at: DateTime.add(@now, -8, :hour),
          metadata: failed_metadata(DateTime.add(@now, -7, :hour))
        })

      assert {:ok, %{inserted: [], conflicts: [], errors: []}} =
               Jobs.enqueue_scheduled_token_refreshes(now: @now)

      assert {:ok, assignment} =
               PoolAssignments.create_pool_assignment(pool, identity, %{
                 assignment_label: "Refresh failed transition assignment #{unique}",
                 metadata: %{}
               })

      put_assignment_status!(assignment, "active")

      assert {:ok, %{inserted: [job], conflicts: [], errors: []}} =
               Jobs.enqueue_scheduled_token_refreshes(now: @now)

      assert job.args["upstream_identity_id"] == identity.id
      assert job.args["trigger_kind"] == "scheduled"
    end

    test "does not insert duplicate scheduled jobs when an incomplete token refresh job exists" do
      identity = recovery_identity_fixture("refresh_due")

      assert {:ok, blocker} = Jobs.enqueue_token_refresh(identity, trigger_kind: "manual")
      refute blocker.conflict?

      assert {:ok, %{inserted: [], conflicts: [], errors: []}} =
               Jobs.enqueue_scheduled_token_refreshes(now: @now)

      assert [job] = all_enqueued(worker: TokenRefreshWorker)
      assert job.id == blocker.id
      assert job.args["trigger_kind"] == "manual"

      assert [persisted_job] = incomplete_token_refresh_jobs_for_identity(identity)
      assert persisted_job.id == blocker.id
    end

    test "fresh in-progress token refresh metadata blocks recovery, but stale or malformed metadata does not" do
      recovery_identity_fixture("refreshing",
        metadata: refreshing_metadata(DateTime.add(@now, -10, :second), 60_000)
      )

      stale =
        recovery_identity_fixture("refreshing",
          metadata: refreshing_metadata(DateTime.add(@now, -2, :minute), 60_000)
        )

      malformed =
        recovery_identity_fixture("refreshing",
          metadata: %{
            "token_refresh" => %{
              "status" => "refreshing",
              "attempt_id" => Ecto.UUID.generate(),
              "generation" => 1,
              "started_at" => "not-a-timestamp",
              "stale_after_ms" => 60_000
            }
          }
        )

      assert {:ok, %{inserted: jobs, conflicts: [], errors: []}} =
               Jobs.enqueue_scheduled_token_refreshes(now: @now)

      assert jobs |> Enum.map(& &1.args["upstream_identity_id"]) |> Enum.sort() ==
               Enum.sort([stale.id, malformed.id])
    end

    test "keeps ordinary refresh_failed identities on a 6 hour cooldown" do
      recent_finished =
        recovery_identity_fixture("refresh_failed",
          updated_at: DateTime.add(@now, -8, :hour),
          metadata: failed_metadata(DateTime.add(@now, -1, :hour))
        )

      future =
        recovery_identity_fixture("refresh_failed",
          updated_at: DateTime.add(@now, -8, :hour),
          metadata: failed_metadata(DateTime.add(@now, 1, :hour))
        )

      old_finished =
        recovery_identity_fixture("refresh_failed",
          updated_at: DateTime.add(@now, -30, :minute),
          metadata: failed_metadata(DateTime.add(@now, -7, :hour))
        )

      missing_finished =
        recovery_identity_fixture("refresh_failed",
          updated_at: DateTime.add(@now, -7, :hour),
          metadata: %{"token_refresh" => %{"status" => "failed"}}
        )

      malformed_finished =
        recovery_identity_fixture("refresh_failed",
          updated_at: DateTime.add(@now, -7, :hour),
          metadata: %{"token_refresh" => %{"status" => "failed", "finished_at" => "later"}}
        )

      assert {:ok, %{inserted: jobs, conflicts: [], errors: []}} =
               Jobs.enqueue_scheduled_token_refreshes(now: @now)

      assert jobs |> Enum.map(& &1.args["upstream_identity_id"]) |> Enum.sort() ==
               Enum.sort([old_finished.id, missing_finished.id, malformed_finished.id])

      refute Enum.any?(jobs, &(&1.args["upstream_identity_id"] == recent_finished.id))
      refute Enum.any?(jobs, &(&1.args["upstream_identity_id"] == future.id))
    end

    test "orders by eligibility timestamp then identity id and applies the requested limit" do
      newest =
        recovery_identity_fixture("refresh_due", updated_at: DateTime.add(@now, -10, :minute))

      oldest =
        recovery_identity_fixture("refresh_due", updated_at: DateTime.add(@now, -30, :minute))

      middle =
        recovery_identity_fixture("refresh_due", updated_at: DateTime.add(@now, -20, :minute))

      assert {:ok, %{inserted: jobs, conflicts: [], errors: []}} =
               Jobs.enqueue_scheduled_token_refreshes(now: @now, limit: 2)

      assert Enum.map(jobs, & &1.args["upstream_identity_id"]) == [oldest.id, middle.id]
      refute Enum.any?(jobs, &(&1.args["upstream_identity_id"] == newest.id))
    end

    test "defaults scheduled recovery to at most 100 identities per pass" do
      identities =
        for index <- 1..101 do
          recovery_identity_fixture("refresh_due",
            updated_at: DateTime.add(@now, -index, :minute)
          )
        end

      assert {:ok, %{inserted: jobs, conflicts: [], errors: []}} =
               Jobs.enqueue_scheduled_token_refreshes(now: @now)

      assert length(jobs) == 100
      refute Enum.any?(jobs, &(&1.args["upstream_identity_id"] == List.first(identities).id))
    end
  end

  defp recovery_identity_fixture(status, opts \\ []) do
    pool = pool_fixture(%{status: Keyword.get(opts, :pool_status, "active")})
    metadata = Keyword.get(opts, :metadata, %{})
    updated_at = Keyword.get(opts, :updated_at, DateTime.add(@now, -1, :hour))
    unique = System.unique_integer([:positive])

    identity =
      upstream_identity_fixture(%{
        account_label: "Refresh recovery #{unique}",
        chatgpt_account_id: "acct_refresh_recovery_#{unique}",
        metadata: metadata
      })
      |> update_identity!(%{status: status, metadata: metadata, updated_at: updated_at})

    if Keyword.get(opts, :assignment?, true) do
      assignment_status = Keyword.get(opts, :assignment_status, "active")

      assert {:ok, assignment} =
               PoolAssignments.create_pool_assignment(pool, identity, %{
                 assignment_label: "Refresh recovery assignment #{unique}",
                 metadata: %{}
               })

      put_assignment_status!(assignment, assignment_status)
    end

    identity
  end

  defp update_identity!(%UpstreamIdentity{} = identity, attrs) do
    identity
    |> UpstreamIdentity.changeset(attrs)
    |> Repo.update!()
  end

  defp put_assignment_status!(%PoolUpstreamAssignment{} = assignment, "active") do
    assert {:ok, assignment} =
             PoolAssignments.activate_pool_assignment(assignment, %{skip_quota_priming: true})

    assignment
  end

  defp put_assignment_status!(%PoolUpstreamAssignment{} = assignment, status) do
    assignment
    |> PoolUpstreamAssignment.changeset(%{
      status: status,
      health_status: "disabled",
      eligibility_status: "ineligible",
      updated_at: @now
    })
    |> Repo.update!()
  end

  defp failed_metadata(%DateTime{} = finished_at) do
    %{
      "token_refresh" => %{
        "status" => "failed",
        "finished_at" => DateTime.to_iso8601(finished_at),
        "reason" => %{"code" => "codex_auth_transient", "message" => "token refresh failed"}
      }
    }
  end

  defp refreshing_metadata(%DateTime{} = started_at, stale_after_ms) do
    %{
      "token_refresh" => %{
        "status" => "refreshing",
        "attempt_id" => Ecto.UUID.generate(),
        "generation" => 1,
        "started_at" => DateTime.to_iso8601(started_at),
        "trigger_kind" => "test",
        "receive_timeout_ms" => 30_000,
        "stale_after_ms" => stale_after_ms
      }
    }
  end

  defp incomplete_token_refresh_jobs_for_identity(%UpstreamIdentity{id: identity_id}) do
    Repo.all(
      from oban_job in Oban.Job,
        where:
          oban_job.worker == ^@worker_name and
            oban_job.state in ^@incomplete_job_states and
            fragment("?->>? = ?::text", oban_job.args, "upstream_identity_id", ^identity_id)
    )
  end
end
