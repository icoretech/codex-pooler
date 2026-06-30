defmodule CodexPooler.Upstreams.SavedResetRedemptionEnqueueTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Jobs.SavedResetRedemptionWorker
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias CodexPooler.Upstreams.Secrets

  describe "enqueue_for_scope/4" do
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

    test "rejects fresh in-progress redemption and creates no Oban job" do
      scope = owner_scope()
      pool = pool_fixture()

      %{identity: identity} =
        assignment_with_saved_resets(pool, 1, %{},
          redemption: redemption_metadata(DateTime.utc_now())
        )

      assert {:error, %{code: :saved_reset_redemption_in_progress}} =
               Upstreams.enqueue_saved_reset_redemption_for_scope(scope, identity, pool.id)

      assert saved_reset_job_count() == 0
    end

    test "allows stale manual in-progress recovery when saved reset count is usable" do
      scope = owner_scope()
      pool = pool_fixture()

      stale_started_at =
        DateTime.utc_now()
        |> DateTime.add(-5, :minute)
        |> DateTime.truncate(:microsecond)

      %{identity: identity, assignment: assignment} =
        assignment_with_saved_resets(pool, 1, %{},
          redemption: redemption_metadata(stale_started_at)
        )

      assert {:ok, %{status: :queued, job: job}} =
               Upstreams.enqueue_saved_reset_redemption_for_scope(scope, identity, pool.id)

      assert job.args == %{
               "pool_upstream_assignment_id" => assignment.id,
               "trigger_kind" => "admin_manual"
             }
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
               "trigger_kind" => "admin_manual"
             }

      refute Map.has_key?(first_job.args, "credit_id")
      refute Map.has_key?(first_job.args, "redeem_request_id")
    end
  end

  defp owner_scope do
    %{user: user} = bootstrap_owner_fixture(%{"email" => unique_user_email()})
    Scope.for_user(user, ["instance_owner"])
  end

  defp assignment_with_saved_resets(pool, available_count, attrs \\ %{}, opts \\ []) do
    saved_resets =
      %{
        "status" => "reported",
        "available_count" => available_count,
        "source" => "codex_usage_api",
        "path_style" => "codex_api",
        "observed_at" =>
          DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601(),
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

    active_upstream_assignment_fixture(pool, %{metadata: metadata})
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

  defp saved_reset_job_count do
    worker = worker_name(SavedResetRedemptionWorker)

    Repo.aggregate(
      from(job in Oban.Job, where: job.worker == ^worker),
      :count
    )
  end

  defp worker_name(worker), do: worker |> Atom.to_string() |> String.replace_prefix("Elixir.", "")
end
