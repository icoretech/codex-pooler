defmodule CodexPooler.Pools.ModelServingModesTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Events
  alias CodexPooler.Pools
  alias CodexPooler.Pools.{ModelServingModes, ModelServingOverride, Pool}
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  describe "snapshots and updates" do
    setup context do
      if context[:unboxed] do
        %{}
      else
        create_boxed_model_serving_fixture()
      end
    end

    @tag :unboxed
    test "writes one safe audit and one post-commit pool event for real transitions" do
      %{owner: owner, scope: scope, pool: pool, revision: revision} =
        create_unboxed_model_serving_fixture("gpt-event")

      on_exit(&reset_unboxed_fixture!/0)
      assert :ok = Events.subscribe_all_pools()

      assert {:ok, %{changed?: true}} =
               Sandbox.unboxed_run(Repo, fn ->
                 Pools.update_model_serving_modes(
                   scope,
                   pool,
                   [%{exposed_model_id: "gpt-event", mode: "lite"}],
                   revision
                 )
               end)

      audit_event =
        Sandbox.unboxed_run(Repo, fn -> Repo.one!(model_serving_audits_query()) end)

      assert %AuditEvent{
               actor_user_id: actor_user_id,
               pool_id: pool_id,
               action: "pool.model_serving_modes_update",
               details: %{
                 "changed_count" => 1,
                 "transitions" => [
                   %{
                     "exposed_model_id" => "gpt-event",
                     "from_mode" => "auto",
                     "to_mode" => "lite"
                   }
                 ]
               }
             } = audit_event

      assert actor_user_id == owner.id
      assert pool_id == pool.id

      assert_receive {Events,
                      %{
                        pool_id: event_pool_id,
                        reason: "pool_updated",
                        payload: %{
                          "changed" => ["model_serving_modes"],
                          "changed_count" => 1
                        }
                      }},
                     1_000

      assert event_pool_id == pool.id
      refute_receive {Events, _event}
    end

    defp create_boxed_model_serving_fixture do
      %{user: owner} = bootstrap_owner_fixture()
      scope = Scope.for_user(owner, ["instance_owner"])
      pool = pool_fixture(%{created_by_user_id: owner.id})
      %{assignment: assignment, identity: identity} = upstream_assignment_fixture(pool)
      visible_model_fixture(pool, assignment, %{exposed_model_id: "gpt-example-active"})

      %{owner: owner, scope: scope, pool: pool, assignment: assignment, identity: identity}
    end

    test "canonicalizes explicit overrides, computes stable revisions, and batch reads once", %{
      scope: scope,
      pool: pool
    } do
      assert {:ok, initial} = Pools.model_serving_modes_snapshot(scope, pool)
      assert initial.overrides == []

      assert {:ok, updated} =
               Pools.update_model_serving_modes(
                 scope,
                 pool,
                 [%{"exposed_model_id" => "  GPT-EXAMPLE-ACTIVE  ", "mode" => "lite"}],
                 initial.revision
               )

      assert updated.changed?
      assert [%{exposed_model_id: "gpt-example-active", mode: "lite"}] = updated.overrides
      refute updated.revision == initial.revision

      assert {:ok, unchanged} =
               Pools.update_model_serving_modes(
                 scope,
                 pool,
                 [%{exposed_model_id: "gpt-example-active", mode: "lite"}],
                 updated.revision
               )

      refute unchanged.changed?
      assert unchanged.revision == updated.revision

      second_pool = pool_fixture(%{created_by_user_id: scope.user.id})
      %{assignment: second_assignment} = upstream_assignment_fixture(second_pool)

      visible_model_fixture(second_pool, second_assignment, %{
        exposed_model_id: "gpt-example-second"
      })

      assert {:ok, second_snapshot} = Pools.model_serving_modes_snapshot(scope, second_pool)

      assert {:ok, _result} =
               Pools.update_model_serving_modes(
                 scope,
                 second_pool,
                 [%{exposed_model_id: "gpt-example-second", mode: "full"}],
                 second_snapshot.revision
               )

      {overrides_by_pool, queries} =
        count_repo_sources(fn ->
          Pools.model_serving_modes_by_pool_ids([pool.id, second_pool.id, pool.id, nil])
        end)

      assert overrides_by_pool[pool.id]["gpt-example-active"].mode == "lite"
      assert overrides_by_pool[second_pool.id]["gpt-example-second"].mode == "full"
      assert Map.get(queries, "pool_model_serving_overrides", 0) == 1
      assert Enum.sum(Map.values(queries)) == 1
    end

    test "commits an internal-space model override and its audit atomically", %{
      scope: scope,
      pool: pool,
      assignment: assignment
    } do
      # Given
      visible_model_fixture(pool, assignment, %{exposed_model_id: "gpt alpha"})
      assert {:ok, initial} = Pools.model_serving_modes_snapshot(scope, pool)

      # When
      assert {:ok, %{changed?: true}} =
               Pools.update_model_serving_modes(
                 scope,
                 pool,
                 [%{exposed_model_id: "gpt alpha", mode: "lite"}],
                 initial.revision
               )

      # Then
      assert %ModelServingOverride{mode: "lite"} =
               Repo.get_by!(ModelServingOverride,
                 pool_id: pool.id,
                 exposed_model_id: "gpt alpha"
               )

      assert %AuditEvent{
               details: %{
                 "changed_count" => 1,
                 "transitions" => [
                   %{
                     "exposed_model_id" => "gpt alpha",
                     "from_mode" => "auto",
                     "to_mode" => "lite"
                   }
                 ]
               }
             } = Repo.one!(model_serving_audits_query())
    end

    test "audits every transition in a mixed canonical identifier update", %{
      scope: scope,
      pool: pool,
      assignment: assignment
    } do
      # Given
      visible_model_fixture(pool, assignment, %{exposed_model_id: "gpt alpha"})
      visible_model_fixture(pool, assignment, %{exposed_model_id: "gpt β"})
      visible_model_fixture(pool, assignment, %{exposed_model_id: "provider@example.com"})
      assert {:ok, initial} = Pools.model_serving_modes_snapshot(scope, pool)

      # When
      assert {:ok, %{changed?: true}} =
               Pools.update_model_serving_modes(
                 scope,
                 pool,
                 [
                   %{exposed_model_id: "gpt-example-active", mode: "full"},
                   %{exposed_model_id: "gpt alpha", mode: "lite"},
                   %{exposed_model_id: "gpt β", mode: "full"},
                   %{exposed_model_id: "provider@example.com", mode: "lite"}
                 ],
                 initial.revision
               )

      # Then
      assert Repo.aggregate(ModelServingOverride, :count) == 4

      assert %AuditEvent{
               details: %{
                 "changed_count" => 4,
                 "transitions" => transitions
               }
             } = Repo.one!(model_serving_audits_query())

      assert Enum.map(transitions, & &1["exposed_model_id"]) == [
               "gpt alpha",
               "gpt β",
               "gpt-example-active",
               "provider@example.com"
             ]
    end

    test "Auto deletes only the submitted known override and omitted rows are unchanged", %{
      scope: scope,
      pool: pool,
      assignment: assignment
    } do
      visible_model_fixture(pool, assignment, %{exposed_model_id: "gpt-example-other"})
      assert {:ok, initial} = Pools.model_serving_modes_snapshot(scope, pool)

      assert {:ok, configured} =
               Pools.update_model_serving_modes(
                 scope,
                 pool,
                 [
                   %{exposed_model_id: "gpt-example-active", mode: "lite"},
                   %{exposed_model_id: "gpt-example-other", mode: "full"}
                 ],
                 initial.revision
               )

      assert {:ok, omitted} =
               Pools.update_model_serving_modes(scope, pool, [], configured.revision)

      refute omitted.changed?
      assert omitted.revision == configured.revision

      assert {:ok, updated} =
               Pools.update_model_serving_modes(
                 scope,
                 pool,
                 [%{exposed_model_id: "gpt-example-active", mode: "auto"}],
                 omitted.revision
               )

      assert Enum.map(updated.overrides, &{&1.exposed_model_id, &1.mode}) == [
               {"gpt-example-other", "full"}
             ]
    end

    test "omitted no-op creates neither audit nor event", %{scope: scope, pool: pool} do
      assert :ok = Events.subscribe_all_pools()
      assert {:ok, initial} = Pools.model_serving_modes_snapshot(scope, pool)

      assert {:ok, %{changed?: false}} =
               Pools.update_model_serving_modes(scope, pool, [], initial.revision)

      assert Repo.aggregate(model_serving_audits_query(), :count) == 0
      refute_received {Events, _event}
    end

    test "rolls back mode writes and the deferred event when the audit insert fails", %{
      scope: scope,
      pool: pool
    } do
      assert :ok = Events.subscribe_all_pools()
      install_audit_failure_trigger!()
      assert {:ok, initial} = Pools.model_serving_modes_snapshot(scope, pool)

      assert_raise Postgrex.Error, fn ->
        Pools.update_model_serving_modes(
          scope,
          pool,
          [%{exposed_model_id: "gpt-example-active", mode: "lite"}],
          initial.revision
        )
      end

      assert Repo.aggregate(ModelServingOverride, :count) == 0
      assert Repo.aggregate(model_serving_audits_query(), :count) == 0
      refute_received {Events, _event}
    end

    test "revision is independent of explicit row ordering" do
      rows = [
        %ModelServingOverride{exposed_model_id: "model-b", mode: "full"},
        %ModelServingOverride{exposed_model_id: "model-a", mode: "lite"}
      ]

      expected_revision =
        "model-a\0lite\nmodel-b\0full"
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      assert ModelServingModes.revision(rows) == expected_revision
      assert ModelServingModes.revision(Enum.reverse(rows)) == expected_revision
    end

    test "rejects identifiers exceeding the PostgreSQL codepoint limit before writes", %{
      scope: scope,
      pool: pool
    } do
      combining_identifier = "e" <> String.duplicate("\u0301", 255)
      assert String.length(combining_identifier) == 1
      assert length(String.codepoints(combining_identifier)) == 256

      model_fixture(pool, %{exposed_model_id: combining_identifier})
      assert {:ok, initial} = Pools.model_serving_modes_snapshot(scope, pool)

      assert {:ok, configured} =
               Pools.update_model_serving_modes(
                 scope,
                 pool,
                 [%{exposed_model_id: "gpt-example-active", mode: "lite"}],
                 initial.revision
               )

      assert {:error, %{code: :invalid_model}} =
               Pools.update_model_serving_modes(
                 scope,
                 pool,
                 [%{exposed_model_id: combining_identifier, mode: "full"}],
                 configured.revision
               )

      assert [%{exposed_model_id: "gpt-example-active", mode: "lite"}] =
               Repo.all(ModelServingOverride)
    end

    test "rejects unauthorized, unknown, duplicate, invalid, and stale submissions atomically", %{
      owner: owner,
      scope: scope,
      pool: pool
    } do
      %{user: unassigned_admin} = operator_fixture(owner)
      admin_scope = Scope.for_user(unassigned_admin, [])

      assert {:error, %{code: :capability_denied}} =
               Pools.model_serving_modes_snapshot(admin_scope, pool)

      assert {:ok, initial} = Pools.model_serving_modes_snapshot(scope, pool)

      invalid_submissions = [
        [%{exposed_model_id: "gpt-arbitrary", mode: "lite"}],
        [
          %{exposed_model_id: "gpt-example-active", mode: "lite"},
          %{exposed_model_id: " GPT-EXAMPLE-ACTIVE ", mode: "full"}
        ],
        [%{exposed_model_id: "gpt-example-active", mode: "turbo"}],
        [%{exposed_model_id: "", mode: "lite"}]
      ]

      for submission <- invalid_submissions do
        assert {:error, %{code: code}} =
                 Pools.update_model_serving_modes(scope, pool, submission, initial.revision)

        assert code in [:unknown_model, :duplicate_model, :invalid_mode, :invalid_model]
        assert Repo.aggregate(ModelServingOverride, :count) == 0
      end

      assert {:ok, configured} =
               Pools.update_model_serving_modes(
                 scope,
                 pool,
                 [%{exposed_model_id: "gpt-example-active", mode: "lite"}],
                 initial.revision
               )

      assert {:error, %{code: :stale_revision}} =
               Pools.update_model_serving_modes(
                 scope,
                 pool,
                 [%{exposed_model_id: "gpt-example-active", mode: "full"}],
                 initial.revision
               )

      assert [%{mode: "lite"}] = configured.overrides
      assert Repo.one!(ModelServingOverride).mode == "lite"
      assert owner.id == scope.user.id
    end

    test "rejects a model that becomes invisible after the form revision was loaded", %{
      scope: scope,
      pool: pool,
      assignment: assignment
    } do
      assert {:ok, initial} = Pools.model_serving_modes_snapshot(scope, pool)

      assignment
      |> Ecto.Changeset.change(status: "paused", updated_at: now())
      |> Repo.update!()

      assert {:error, %{code: :unknown_model}} =
               Pools.update_model_serving_modes(
                 scope,
                 pool,
                 [%{exposed_model_id: "gpt-example-active", mode: "lite"}],
                 initial.revision
               )

      assert Repo.aggregate(ModelServingOverride, :count) == 0
      assert Repo.aggregate(model_serving_audits_query(), :count) == 0
    end

    test "accepts models routed through a refreshing identity", %{
      scope: scope,
      pool: pool,
      identity: identity
    } do
      assert {:ok, initial} = Pools.model_serving_modes_snapshot(scope, pool)

      identity
      |> Ecto.Changeset.change(status: "refreshing", updated_at: now())
      |> Repo.update!()

      assert {:ok, %{changed?: true}} =
               Pools.update_model_serving_modes(
                 scope,
                 pool,
                 [%{exposed_model_id: "gpt-example-active", mode: "lite"}],
                 initial.revision
               )
    end

    test "rejects malformed Pool references before authorization or queries", %{scope: scope} do
      for malformed_ref <- [nil, "not-a-pool-id", %{}] do
        assert {:error, %{code: :pool_not_found}} =
                 Pools.model_serving_modes_snapshot(scope, malformed_ref)

        assert {:error, %{code: :pool_not_found}} =
                 Pools.update_model_serving_modes(scope, malformed_ref, [], "revision")
      end
    end

    test "allows already-saved unavailable rows and preserves them through catalog lifecycle churn",
         %{
           scope: scope,
           pool: pool
         } do
      assert {:ok, initial} = Pools.model_serving_modes_snapshot(scope, pool)

      assert {:ok, configured} =
               Pools.update_model_serving_modes(
                 scope,
                 pool,
                 [%{exposed_model_id: "gpt-example-active", mode: "lite"}],
                 initial.revision
               )

      final_snapshot =
        Enum.reduce(~w(stale retired suppressed), configured, fn status, snapshot ->
          {1, _rows} =
            Repo.update_all(
              from(model in Model,
                where:
                  model.pool_id == ^pool.id and
                    model.exposed_model_id == "gpt-example-active"
              ),
              set: [status: status]
            )

          assert {:ok, unavailable} = Pools.model_serving_modes_snapshot(scope, pool)
          assert [%{exposed_model_id: "gpt-example-active"}] = unavailable.overrides

          next_mode = if hd(snapshot.overrides).mode == "lite", do: "full", else: "lite"

          assert {:ok, changed} =
                   Pools.update_model_serving_modes(
                     scope,
                     pool,
                     [%{exposed_model_id: "gpt-example-active", mode: next_mode}],
                     unavailable.revision
                   )

          assert [%{mode: ^next_mode}] = changed.overrides
          changed
        end)

      Repo.delete_all(
        from model in Model,
          where: model.pool_id == ^pool.id and model.exposed_model_id == "gpt-example-active"
      )

      assert {:ok, missing} = Pools.model_serving_modes_snapshot(scope, pool)
      assert [%{exposed_model_id: "gpt-example-active"}] = missing.overrides

      next_mode = if hd(final_snapshot.overrides).mode == "lite", do: "full", else: "lite"

      assert {:ok, changed_while_missing} =
               Pools.update_model_serving_modes(
                 scope,
                 pool,
                 [%{exposed_model_id: "gpt-example-active", mode: next_mode}],
                 missing.revision
               )

      assert [%{mode: ^next_mode}] = changed_while_missing.overrides
      refute final_snapshot.revision == changed_while_missing.revision
    end

    test "Pool deletion cascades explicit overrides", %{scope: scope, pool: pool} do
      assert {:ok, initial} = Pools.model_serving_modes_snapshot(scope, pool)

      assert {:ok, _configured} =
               Pools.update_model_serving_modes(
                 scope,
                 pool,
                 [%{exposed_model_id: "gpt-example-active", mode: "lite"}],
                 initial.revision
               )

      Repo.delete!(pool)
      assert Repo.aggregate(ModelServingOverride, :count) == 0
    end
  end

  describe "database invariants" do
    test "PostgreSQL rejects blank, oversized, noncanonical, duplicate, and invalid modes" do
      pool = pool_fixture()

      for {field, value, constraint} <- [
            {:exposed_model_id, "", :pool_model_serving_overrides_exposed_model_id_check},
            {:exposed_model_id, String.duplicate("a", 256),
             :pool_model_serving_overrides_exposed_model_id_check},
            {:exposed_model_id, " Model-A ",
             :pool_model_serving_overrides_exposed_model_id_check},
            {:exposed_model_id, "Model-A", :pool_model_serving_overrides_exposed_model_id_check},
            {:exposed_model_id, "\tmodel-a",
             :pool_model_serving_overrides_exposed_model_id_check},
            {:mode, "auto", :pool_model_serving_overrides_mode_check}
          ] do
        attrs = %{
          pool_id: pool.id,
          exposed_model_id: "model-a",
          mode: "lite",
          created_at: now(),
          updated_at: now()
        }

        changeset =
          %ModelServingOverride{}
          |> Ecto.Changeset.change(Map.put(attrs, field, value))
          |> Ecto.Changeset.check_constraint(field, name: constraint)

        assert {:error, changeset} = Repo.insert(changeset, mode: :savepoint)
        assert Keyword.has_key?(changeset.errors, field)
      end

      Repo.insert!(%ModelServingOverride{
        pool_id: pool.id,
        exposed_model_id: "model-a",
        mode: "lite",
        created_at: now(),
        updated_at: now()
      })

      duplicate =
        %ModelServingOverride{}
        |> Ecto.Changeset.change(%{
          pool_id: pool.id,
          exposed_model_id: "model-a",
          mode: "full",
          created_at: now(),
          updated_at: now()
        })
        |> Ecto.Changeset.unique_constraint(:exposed_model_id,
          name: :pool_model_serving_overrides_pool_model_uq
        )

      assert {:error, changeset} = Repo.insert(duplicate, mode: :savepoint)
      assert Keyword.has_key?(changeset.errors, :exposed_model_id)
    end
  end

  describe "concurrency" do
    @tag :unboxed
    test "a concurrent update waits on the Pool row and then rejects the stale revision" do
      %{scope: scope, pool: pool, revision: revision} =
        create_unboxed_model_serving_fixture("gpt-concurrent")

      on_exit(&reset_unboxed_fixture!/0)

      parent = self()

      first =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              first_backend_pid = backend_pid()

              Repo.one!(
                from persisted_pool in Pool,
                  where: persisted_pool.id == ^pool.id,
                  lock: "FOR UPDATE"
              )

              send(parent, {:model_serving_pool_locked, first_backend_pid})

              receive do
                :persist_first_update ->
                  Pools.update_model_serving_modes(
                    scope,
                    pool,
                    [%{exposed_model_id: "gpt-concurrent", mode: "lite"}],
                    revision
                  )
              after
                5_000 -> raise "timed out waiting to persist the first model serving update"
              end
            end)
          end)
        end)

      assert_receive {:model_serving_pool_locked, first_backend_pid}, 5_000

      second =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            second_backend_pid = backend_pid()
            send(parent, {:model_serving_second_ready, second_backend_pid})

            Pools.update_model_serving_modes(
              scope,
              pool,
              [%{exposed_model_id: "gpt-concurrent", mode: "full"}],
              revision
            )
          end)
        end)

      assert_receive {:model_serving_second_ready, second_backend_pid}, 5_000
      refute second_backend_pid == first_backend_pid
      assert_backend_blocked_by!(second_backend_pid, first_backend_pid)
      send(first.pid, :persist_first_update)

      assert {:ok, {:ok, %{changed?: true}}} = Task.await(first, 10_000)
      assert {:error, %{code: :stale_revision}} = Task.await(second, 10_000)

      Sandbox.unboxed_run(Repo, fn ->
        rows =
          Repo.all(
            from override in ModelServingOverride,
              where: override.pool_id == ^pool.id
          )

        assert [%{mode: mode}] = rows
        assert mode in ["lite", "full"]
      end)
    end
  end

  defp create_unboxed_model_serving_fixture(exposed_model_id) do
    Sandbox.unboxed_run(Repo, fn ->
      reset_bootstrap_state_fixture!()
      %{user: owner} = bootstrap_owner_fixture()
      scope = Scope.for_user(owner, ["instance_owner"])
      pool = pool_fixture(%{created_by_user_id: owner.id})
      %{assignment: assignment} = upstream_assignment_fixture(pool)
      visible_model_fixture(pool, assignment, %{exposed_model_id: exposed_model_id})
      assert {:ok, snapshot} = Pools.model_serving_modes_snapshot(scope, pool)
      %{owner: owner, scope: scope, pool: pool, revision: snapshot.revision}
    end)
  end

  defp reset_unboxed_fixture! do
    Sandbox.unboxed_run(Repo, fn -> reset_bootstrap_state_fixture!() end)
  end

  defp visible_model_fixture(pool, assignment, attrs) do
    metadata =
      attrs
      |> Map.get(:metadata, %{})
      |> Map.put("source_assignment_ids", [assignment.id])

    model_fixture(pool, Map.put(attrs, :metadata, metadata))
  end

  defp install_audit_failure_trigger! do
    Repo.query!("""
    CREATE FUNCTION pg_temp.reject_model_serving_audit() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.action = 'pool.model_serving_modes_update' THEN
        RAISE EXCEPTION 'forced model serving audit failure' USING ERRCODE = '23514';
      END IF;

      RETURN NEW;
    END
    $$
    """)

    Repo.query!("""
    CREATE TRIGGER reject_model_serving_audit
    BEFORE INSERT ON audit_events
    FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_model_serving_audit()
    """)

    :ok
  end

  defp model_serving_audits_query do
    from event in AuditEvent,
      where: event.action == "pool.model_serving_modes_update"
  end

  defp assert_backend_blocked_by!(backend_pid, blocker_pid) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    assert_backend_blocked_by!(backend_pid, blocker_pid, deadline)
  end

  defp assert_backend_blocked_by!(backend_pid, blocker_pid, deadline) do
    blocked? =
      Repo.query!(
        """
        SELECT wait_event_type = 'Lock' AND $2 = ANY(pg_blocking_pids($1))
        FROM pg_stat_activity
        WHERE pid = $1
        """,
        [backend_pid, blocker_pid]
      ).rows == [[true]]

    cond do
      blocked? ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        receive do
        after
          0 -> assert_backend_blocked_by!(backend_pid, blocker_pid, deadline)
        end

      true ->
        flunk("second backend did not wait on the first backend's Pool row lock")
    end
  end

  defp backend_pid, do: Repo.query!("SELECT pg_backend_pid()").rows |> hd() |> hd()

  defp count_repo_sources(fun) do
    parent = self()
    handler_id = "model-serving-query-count-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata[:repo] == Repo and is_binary(metadata[:source]) do
            send(parent, {handler_id, metadata.source})
          end
        end,
        nil
      )

    try do
      result = fun.()
      {result, drain_repo_sources(handler_id, %{})}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_repo_sources(handler_id, counts) do
    receive do
      {^handler_id, source} ->
        drain_repo_sources(handler_id, Map.update(counts, source, 1, &(&1 + 1)))
    after
      0 -> counts
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
