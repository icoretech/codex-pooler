defmodule CodexPooler.Upstreams.PreparedImportPersistenceTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures

  alias CodexPooler.Accounting.{Attempt, Request, RequestLogFact}
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Events
  alias CodexPooler.Pools
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Lifecycle.{CredentialFencing, IdentityLifecycle, IdentitySlotLock}
  alias CodexPooler.Upstreams.PreparedAccount

  alias CodexPooler.Upstreams.Schemas.{
    EncryptedSecret,
    PoolUpstreamAssignment,
    UpstreamIdentity
  }

  alias CodexPooler.Upstreams.Secrets
  alias CodexPooler.Upstreams.TokenLinking
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  @detection_timeout_ms 15_000

  for {label, boundary} <- [
        {"auto-publishing prepared link", :link_prepared},
        {"public prepared persistence with internal slot locking", :persist_prepared},
        {"public prepared persistence with caller-owned slot locks", :persist_prepared_locked},
        {"transaction-only prepared link with caller-owned slot locks", :link_prepared_locked}
      ] do
    test "#{label} rejects a well-formed stale import without rotating credentials" do
      fixture = committed_fixture!()

      try do
        assert {:ok, %{identity: identity}} =
                 unboxed(fn ->
                   Upstreams.import_trusted_account(
                     fixture.scope,
                     fixture.pool,
                     fixture.initial_attrs
                   )
                 end)

        stale_prepared =
          unboxed(fn ->
            {:ok, prepared} =
              Upstreams.prepare_trusted_account(
                fixture.scope,
                fixture.pool,
                fixture.stale_attrs
              )

            prepared
          end)

        assert {:ok, %{identity: newer_identity}} =
                 unboxed(fn ->
                   Upstreams.import_trusted_account(
                     fixture.scope,
                     fixture.pool,
                     fixture.newer_attrs
                   )
                 end)

        before = credential_snapshot(identity.id)

        assert {:error,
                %{
                  code: :stale_import,
                  message:
                    "credentials changed after import preparation; submit the current auth data again"
                }} = invoke_boundary(unquote(boundary), fixture, stale_prepared)

        assert credential_snapshot(identity.id) == before
        assert before.credential_epoch == newer_identity.metadata["credential_epoch"]
      after
        cleanup_fixture!(fixture)
      end
    end
  end

  @tag :manual_public_stale_race
  test "an older prepared import waiting on the canonical lock rejects after a newer writer commits" do
    fixture = committed_fixture!()

    try do
      assert {:ok, %{identity: identity}} =
               unboxed(fn ->
                 Upstreams.import_trusted_account(
                   fixture.scope,
                   fixture.pool,
                   fixture.initial_attrs
                 )
               end)

      stale_prepared =
        unboxed(fn ->
          {:ok, prepared} =
            Upstreams.prepare_trusted_account(fixture.scope, fixture.pool, fixture.stale_attrs)

          prepared
        end)

      newer_prepared =
        unboxed(fn ->
          {:ok, prepared} =
            Upstreams.prepare_trusted_account(fixture.scope, fixture.pool, fixture.newer_attrs)

          prepared
        end)

      parent = self()
      barrier = make_ref()
      assert :ok = Events.subscribe_pool(fixture.pool.id, "upstreams")
      side_effects_before = side_effect_snapshot()

      newer_writer =
        Task.async(fn ->
          unboxed(fn ->
            Repo.transaction(fn ->
              IdentitySlotLock.lock_slots!([newer_prepared.attrs])
              {:ok, selected} = IdentityLifecycle.select_upsert_identity(newer_prepared.attrs)
              locked = CredentialFencing.lock_credential_replacement(selected)
              backend_pid = backend_pid!()
              send(parent, {barrier, :newer_locked, backend_pid})
              await_message!({barrier, :commit_newer})

              assert {:ok, result} =
                       TokenLinking.persist_prepared(
                         fixture.scope,
                         fixture.pool,
                         newer_prepared,
                         true
                       )

              assert result.identity.id == locked.id
              b_snapshot = persistence_snapshot_in_transaction(result.identity.id)
              send(parent, {barrier, :newer_persisted, b_snapshot})
              {backend_pid, result}
            end)
          end)
        end)

      assert_receive {^barrier, :newer_locked, newer_backend_pid}, @detection_timeout_ms

      stale_writer =
        Task.async(fn ->
          unboxed(fn ->
            backend_pid = backend_pid!()
            send(parent, {barrier, :stale_started, backend_pid})

            result =
              TokenLinking.link_prepared(fixture.scope, fixture.pool, stale_prepared, [])

            {backend_pid, result}
          end)
        end)

      assert_receive {^barrier, :stale_started, stale_backend_pid}, @detection_timeout_ms
      blocking_pids = assert_waiting_on!(stale_backend_pid, newer_backend_pid)

      evidence("lock_wait", %{
        holder_backend_pid: newer_backend_pid,
        waiter_backend_pid: stale_backend_pid,
        pg_blocking_pids: blocking_pids
      })

      send(newer_writer.pid, {barrier, :commit_newer})

      assert {:ok, {^newer_backend_pid, %{identity: newer_identity}}} =
               Task.await(newer_writer, @detection_timeout_ms)

      assert_receive {^barrier, :newer_persisted, b_snapshot}, @detection_timeout_ms

      stale_task_result = Task.await(stale_writer, @detection_timeout_ms)

      evidence("stale_result", %{
        result: sanitized_result(stale_task_result),
        b_authoritative: b_snapshot
      })

      assert %{
               backend_pid: ^stale_backend_pid,
               result: %{
                 outcome: "error",
                 code: :stale_import,
                 message:
                   "credentials changed after import preparation; submit the current auth data again"
               }
             } = sanitized_result(stale_task_result)

      assert side_effect_snapshot() == side_effects_before
      event_count = drain_event_count(0)
      assert event_count == 0

      final_b_snapshot = persistence_snapshot(identity.id)
      assert final_b_snapshot == b_snapshot

      evidence("stale_zero_effects", %{
        b_snapshot_matches_after_a: final_b_snapshot == b_snapshot,
        durable_delta_after_a: snapshot_delta(b_snapshot, final_b_snapshot),
        side_effect_delta_after_a: snapshot_delta(side_effects_before, side_effect_snapshot()),
        pubsub_event_count_after_a: event_count
      })

      persisted = unboxed(fn -> Repo.get!(UpstreamIdentity, identity.id) end)
      assert persisted.metadata["credential_epoch"] == newer_identity.metadata["credential_epoch"]
      newer_token = fixture.newer_attrs.token

      assert {:ok, ^newer_token} =
               unboxed(fn -> Secrets.decrypt_active_secret(persisted, "access_token") end)

      fresh_prepared =
        unboxed(fn ->
          {:ok, prepared} =
            Upstreams.prepare_trusted_account(fixture.scope, fixture.pool, fixture.stale_attrs)

          prepared
        end)

      assert {:ok, %{identity: fresh_identity}} =
               unboxed(fn ->
                 TokenLinking.link_prepared(fixture.scope, fixture.pool, fresh_prepared, [])
               end)

      assert fresh_identity.id == identity.id
      stale_token = fixture.stale_attrs.token

      assert {:ok, ^stale_token} =
               unboxed(fn -> Secrets.decrypt_active_secret(identity, "access_token") end)

      fresh_snapshot = persistence_snapshot(identity.id)

      evidence("fresh_resubmit", %{
        identity_continuity:
          fresh_snapshot.identity_id_fingerprint == b_snapshot.identity_id_fingerprint,
        before_epoch: b_snapshot.credential_epoch,
        after_epoch: fresh_snapshot.credential_epoch,
        before_generation: b_snapshot.token_refresh_generation,
        after_generation: fresh_snapshot.token_refresh_generation,
        active_secret_count: fresh_snapshot.active_secret_count,
        status: fresh_snapshot.status
      })
    after
      cleanup_fixture!(fixture)
    end
  end

  @tag :manual_public_stale_race
  test "public prepared persistence requires a transaction even for unchecked generic carriers" do
    fixture = committed_fixture!()

    try do
      prepared =
        unboxed(fn ->
          {:ok, prepared} =
            PreparedAccount.prepare(
              fixture.scope,
              fixture.pool,
              fixture.initial_attrs,
              []
            )

          prepared
        end)

      outside_result =
        unboxed(fn ->
          TokenLinking.persist_prepared(fixture.scope, fixture.pool, prepared, true)
        end)

      assert {:error,
              %{
                code: :transaction_required,
                message: "token linking requires a caller-owned transaction"
              }} = outside_result

      assert unboxed(fn -> Repo.aggregate(UpstreamIdentity, :count) end) == 0

      inside_result =
        unboxed(fn ->
          Repo.transaction(fn ->
            assert {:ok, %{status: :created}} =
                     result =
                     TokenLinking.persist_prepared(fixture.scope, fixture.pool, prepared, false)

            Repo.rollback({:characterized, elem(result, 1).status})
          end)
        end)

      assert {:error, {:characterized, :created}} = inside_result
      assert unboxed(fn -> Repo.aggregate(UpstreamIdentity, :count) end) == 0

      evidence("generic_transaction_contract", %{
        outside_result: sanitized_result(outside_result),
        outside_write_count: 0,
        inside_transaction_result: "created_then_rolled_back",
        after_rollback_write_count: 0
      })
    after
      cleanup_fixture!(fixture)
    end
  end

  test "a malformed import carrier is rejected before persistence" do
    fixture = committed_fixture!()

    try do
      prepared =
        unboxed(fn ->
          {:ok, prepared} =
            Upstreams.prepare_trusted_account(fixture.scope, fixture.pool, fixture.initial_attrs)

          prepared
        end)

      malformed = %{prepared | import_binding: <<0::256>>}

      assert {:error, %{code: :invalid_request}} =
               unboxed(fn ->
                 Repo.transaction(fn ->
                   case TokenLinking.persist_prepared(
                          fixture.scope,
                          fixture.pool,
                          malformed,
                          false
                        ) do
                     {:ok, result} -> result
                     {:error, reason} -> Repo.rollback(reason)
                   end
                 end)
               end)

      assert unboxed(fn -> Repo.aggregate(UpstreamIdentity, :count) end) == 0
    after
      cleanup_fixture!(fixture)
    end
  end

  @tag :manual_public_stale_race
  test "a malformed current credential epoch keeps the invalid credential epoch error" do
    fixture = committed_fixture!()

    try do
      assert {:ok, %{identity: identity}} =
               unboxed(fn ->
                 Upstreams.import_trusted_account(
                   fixture.scope,
                   fixture.pool,
                   fixture.initial_attrs
                 )
               end)

      prepared =
        unboxed(fn ->
          {:ok, prepared} =
            Upstreams.prepare_trusted_account(fixture.scope, fixture.pool, fixture.stale_attrs)

          prepared
        end)

      unboxed(fn ->
        identity
        |> Repo.reload!()
        |> Ecto.Changeset.change(metadata: %{"credential_epoch" => "malformed"})
        |> Repo.update!()
      end)

      before = credential_snapshot(identity.id)

      result =
        unboxed(fn ->
          TokenLinking.link_prepared(fixture.scope, fixture.pool, prepared, [])
        end)

      assert {:error, %{code: :invalid_credential_epoch, message: "credential epoch is invalid"}} =
               result

      assert credential_snapshot(identity.id) == before

      evidence("malformed_current_epoch", %{
        result: sanitized_result(result),
        snapshot_unchanged: credential_snapshot(identity.id) == before
      })
    after
      cleanup_fixture!(fixture)
    end
  end

  test "absent-to-present state and newly appearing selection conflicts are stale imports" do
    fixture = committed_fixture!()

    try do
      absent_prepared =
        unboxed(fn ->
          {:ok, prepared} =
            Upstreams.prepare_trusted_account(fixture.scope, fixture.pool, fixture.stale_attrs)

          prepared
        end)

      assert {:ok, %{identity: present_identity}} =
               unboxed(fn ->
                 Upstreams.import_trusted_account(
                   fixture.scope,
                   fixture.pool,
                   fixture.newer_attrs
                 )
               end)

      before = credential_snapshot(present_identity.id)

      assert {:error, %{code: :stale_import}} =
               unboxed(fn ->
                 TokenLinking.link_prepared(
                   fixture.scope,
                   fixture.pool,
                   absent_prepared,
                   []
                 )
               end)

      assert credential_snapshot(present_identity.id) == before

      conflict_fixture = committed_fixture!()

      try do
        conflict_prepared =
          unboxed(fn ->
            {:ok, prepared} =
              Upstreams.prepare_trusted_account(
                conflict_fixture.scope,
                conflict_fixture.pool,
                %{conflict_fixture.stale_attrs | chatgpt_user_id: nil}
              )

            prepared
          end)

        assert {:ok, %UpstreamIdentity{}} =
                 unboxed(fn ->
                   IdentityLifecycle.create_upstream_identity(%{
                     chatgpt_account_id: conflict_fixture.initial_attrs.chatgpt_account_id,
                     chatgpt_user_id: conflict_fixture.initial_attrs.chatgpt_user_id,
                     account_email: conflict_fixture.initial_attrs.account_email,
                     account_label: conflict_fixture.initial_attrs.account_label,
                     workspace_id: conflict_fixture.initial_attrs.workspace_id,
                     workspace_label: conflict_fixture.initial_attrs.workspace_label,
                     seat_type: conflict_fixture.initial_attrs.seat_type,
                     onboarding_method: "import",
                     credential_provenance: "codex_chatgpt_oauth",
                     created_by_user_id: conflict_fixture.scope.user.id
                   })
                 end)

        assert {:error, %{code: :stale_import}} =
                 unboxed(fn ->
                   TokenLinking.link_prepared(
                     conflict_fixture.scope,
                     conflict_fixture.pool,
                     conflict_prepared,
                     []
                   )
                 end)
      after
        cleanup_fixture!(conflict_fixture)
      end
    after
      cleanup_fixture!(fixture)
    end
  end

  test "changed canonical evidence and status reject before mutation" do
    for change <- [:canonical_evidence, :status] do
      fixture = committed_fixture!()

      try do
        assert {:ok, %{identity: identity}} =
                 unboxed(fn ->
                   Upstreams.import_trusted_account(
                     fixture.scope,
                     fixture.pool,
                     fixture.initial_attrs
                   )
                 end)

        prepared =
          unboxed(fn ->
            {:ok, prepared} =
              Upstreams.prepare_trusted_account(
                fixture.scope,
                fixture.pool,
                fixture.stale_attrs
              )

            prepared
          end)

        unboxed(fn ->
          identity = Repo.reload!(identity)

          attrs =
            case change do
              :canonical_evidence -> %{account_email: "changed-#{identity.id}@example.com"}
              :status -> %{status: "disabled"}
            end

          identity
          |> Ecto.Changeset.change(attrs)
          |> Repo.update!()
        end)

        before = credential_snapshot(identity.id)

        assert {:error, %{code: :stale_import}} =
                 unboxed(fn ->
                   TokenLinking.link_prepared(fixture.scope, fixture.pool, prepared, [])
                 end)

        assert credential_snapshot(identity.id) == before
      after
        cleanup_fixture!(fixture)
      end
    end
  end

  test "delete-and-replace state rejects the prepared command for the deleted identity" do
    fixture = committed_fixture!()

    try do
      assert {:ok, %{identity: old_identity}} =
               unboxed(fn ->
                 Upstreams.import_trusted_account(
                   fixture.scope,
                   fixture.pool,
                   fixture.initial_attrs
                 )
               end)

      prepared =
        unboxed(fn ->
          {:ok, prepared} =
            Upstreams.prepare_trusted_account(fixture.scope, fixture.pool, fixture.stale_attrs)

          prepared
        end)

      unboxed(fn -> Repo.delete!(Repo.get!(UpstreamIdentity, old_identity.id)) end)

      assert {:ok, %{identity: replacement}} =
               unboxed(fn ->
                 Upstreams.import_trusted_account(
                   fixture.scope,
                   fixture.pool,
                   fixture.newer_attrs
                 )
               end)

      refute replacement.id == old_identity.id
      before = credential_snapshot(replacement.id)

      assert {:error, %{code: :stale_import}} =
               unboxed(fn ->
                 TokenLinking.link_prepared(fixture.scope, fixture.pool, prepared, [])
               end)

      assert credential_snapshot(replacement.id) == before
    after
      cleanup_fixture!(fixture)
    end
  end

  test "caller-owned transaction rollback removes a fresh prepared import" do
    fixture = committed_fixture!()

    try do
      prepared =
        unboxed(fn ->
          {:ok, prepared} =
            Upstreams.prepare_trusted_account(fixture.scope, fixture.pool, fixture.initial_attrs)

          prepared
        end)

      assert {:error, :intentional_rollback} =
               unboxed(fn ->
                 Repo.transaction(fn ->
                   assert {:ok, %{identity: %UpstreamIdentity{}}} =
                            TokenLinking.link_prepared_in_transaction(
                              fixture.scope,
                              fixture.pool,
                              prepared,
                              []
                            )

                   Repo.rollback(:intentional_rollback)
                 end)
               end)

      assert unboxed(fn -> Repo.aggregate(UpstreamIdentity, :count) end) == 0
    after
      cleanup_fixture!(fixture)
    end
  end

  defp committed_fixture! do
    suffix = System.unique_integer([:positive, :monotonic])

    unboxed(fn ->
      %{user: user} =
        bootstrap_owner_fixture(%{"email" => "prepared-persistence-#{suffix}@example.com"})

      scope = Scope.for_user(user)

      {:ok, pool} =
        Pools.create_pool(scope, %{
          slug: "prepared-persistence-#{suffix}",
          name: "Prepared persistence #{suffix}"
        })

      base = %{
        chatgpt_account_id: "acct_prepared_persistence_#{suffix}",
        chatgpt_user_id: "user_prepared_persistence_#{suffix}",
        account_email: "account-#{suffix}@example.com",
        account_label: "Prepared persistence #{suffix}",
        workspace_id: "workspace_prepared_persistence_#{suffix}",
        workspace_label: "Workspace #{suffix}",
        seat_type: "team",
        credential_provenance: "codex_chatgpt_oauth"
      }

      %{
        scope: scope,
        pool: pool,
        initial_attrs: credential_attrs(base, "initial", suffix),
        stale_attrs: credential_attrs(base, "stale", suffix),
        newer_attrs: credential_attrs(base, "newer", suffix)
      }
    end)
  end

  defp credential_attrs(base, version, suffix) do
    Map.merge(base, %{
      token: "access-#{version}-#{suffix}",
      refresh_token: "refresh-#{version}-#{suffix}"
    })
  end

  defp cleanup_fixture!(fixture) do
    unboxed(fn ->
      Repo.delete_all(
        from identity in UpstreamIdentity,
          where: identity.chatgpt_account_id == ^fixture.initial_attrs.chatgpt_account_id
      )

      Repo.delete_all(from pool in Pool, where: pool.id == ^fixture.pool.id)
    end)
  end

  defp invoke_boundary(:link_prepared, fixture, prepared) do
    unboxed(fn -> TokenLinking.link_prepared(fixture.scope, fixture.pool, prepared, []) end)
  end

  defp invoke_boundary(boundary, fixture, prepared)
       when boundary in [:persist_prepared, :persist_prepared_locked, :link_prepared_locked] do
    unboxed(fn -> invoke_boundary_in_transaction(boundary, fixture, prepared) end)
  end

  defp invoke_boundary_in_transaction(boundary, fixture, prepared) do
    Repo.transaction(fn -> persist_boundary!(boundary, fixture, prepared) end)
  end

  defp persist_boundary!(boundary, fixture, prepared) do
    slots_locked? = boundary != :persist_prepared

    if slots_locked?, do: IdentitySlotLock.lock_slots!([prepared.attrs])

    result =
      case boundary do
        :link_prepared_locked ->
          TokenLinking.link_prepared_in_transaction(
            fixture.scope,
            fixture.pool,
            prepared,
            slots_locked?: true
          )

        _persist ->
          TokenLinking.persist_prepared(
            fixture.scope,
            fixture.pool,
            prepared,
            slots_locked?
          )
      end

    case result do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp credential_snapshot(identity_id) do
    unboxed(fn ->
      identity = Repo.get!(UpstreamIdentity, identity_id)

      %{
        identity_id: identity.id,
        status: identity.status,
        credential_epoch: identity.metadata["credential_epoch"],
        access_token: Secrets.decrypt_active_secret(identity, "access_token"),
        refresh_token: Secrets.decrypt_active_secret(identity, "refresh_token")
      }
    end)
  end

  defp side_effect_snapshot do
    unboxed(fn ->
      %{
        audits: Repo.aggregate(AuditEvent, :count),
        jobs: Repo.aggregate(Oban.Job, :count),
        requests: Repo.aggregate(Request, :count),
        attempts: Repo.aggregate(Attempt, :count),
        request_log_facts: Repo.aggregate(RequestLogFact, :count)
      }
    end)
  end

  defp persistence_snapshot(identity_id) do
    unboxed(fn -> persistence_snapshot_in_transaction(identity_id) end)
  end

  defp persistence_snapshot_in_transaction(identity_id) do
    identity = Repo.get!(UpstreamIdentity, identity_id)

    assignments =
      Repo.all(
        from assignment in PoolUpstreamAssignment,
          where: assignment.upstream_identity_id == ^identity_id,
          order_by: [asc: assignment.id]
      )

    secrets =
      Repo.all(
        from secret in EncryptedSecret,
          where: secret.upstream_identity_id == ^identity_id,
          order_by: [asc: secret.secret_kind, asc: secret.id]
      )

    active_secrets = Enum.filter(secrets, &(&1.status == "active"))
    superseded_secrets = Enum.filter(secrets, &(&1.status == "superseded"))
    token_refresh = identity.metadata["token_refresh"] || %{}

    %{
      identity_count: 1,
      identity_id_fingerprint: fingerprint(identity.id),
      status: identity.status,
      remediation: Map.get(identity.metadata, "provider_auth_recovery"),
      credential_epoch: identity.metadata["credential_epoch"],
      token_refresh_generation: token_refresh["generation"],
      token_refresh_status: token_refresh["status"],
      assignment_count: length(assignments),
      assignment_id_fingerprints: Enum.map(assignments, &fingerprint(&1.id)),
      assignment_statuses: Enum.map(assignments, & &1.status),
      assignment_eligibility: Enum.map(assignments, & &1.eligibility_status),
      active_secret_count: length(active_secrets),
      active_secret_fingerprints:
        Enum.map(
          active_secrets,
          &%{kind: &1.secret_kind, fingerprint: fingerprint(&1.ciphertext)}
        ),
      superseded_secret_count: length(superseded_secrets),
      total_secret_count: length(secrets)
    }
  end

  defp backend_pid! do
    %{rows: [[backend_pid]]} = SQL.query!(Repo, "SELECT pg_backend_pid()", [])
    backend_pid
  end

  defp assert_waiting_on!(waiter_pid, blocker_pid) do
    deadline = System.monotonic_time(:millisecond) + @detection_timeout_ms
    do_assert_waiting_on!(waiter_pid, blocker_pid, deadline)
  end

  defp do_assert_waiting_on!(waiter_pid, blocker_pid, deadline) do
    blocking_pids =
      unboxed(fn ->
        %{rows: [[blocking_pids]]} = SQL.query!(Repo, "SELECT pg_blocking_pids($1)", [waiter_pid])
        blocking_pids
      end)

    cond do
      blocker_pid in blocking_pids ->
        blocking_pids

      System.monotonic_time(:millisecond) < deadline ->
        do_assert_waiting_on!(waiter_pid, blocker_pid, deadline)

      true ->
        flunk("backend #{waiter_pid} never waited on backend #{blocker_pid}")
    end
  end

  defp await_message!(message) do
    receive do
      ^message -> :ok
    after
      @detection_timeout_ms -> raise "timed out waiting for concurrency barrier"
    end
  end

  defp sanitized_result({backend_pid, result}) when is_integer(backend_pid) do
    %{backend_pid: backend_pid, result: sanitized_result(result)}
  end

  defp sanitized_result({:error, %{code: code, message: message}}),
    do: %{outcome: "error", code: code, message: message}

  defp sanitized_result({:ok, %{status: status, identity: identity}}),
    do: %{
      outcome: "ok",
      status: status,
      identity_id_fingerprint: fingerprint(identity.id),
      credential_epoch: identity.metadata["credential_epoch"]
    }

  defp sanitized_result(other), do: %{outcome: "other", shape: inspect(other, limit: 3)}

  defp snapshot_delta(before, current) do
    Map.new(before, fn {key, value} ->
      current_value = Map.fetch!(current, key)

      delta =
        if is_integer(value) and is_integer(current_value),
          do: current_value - value,
          else: current_value == value

      {key, delta}
    end)
  end

  defp drain_event_count(count) do
    receive do
      {Events, _event} -> drain_event_count(count + 1)
    after
      0 -> count
    end
  end

  defp evidence(label, data) do
    if System.get_env("PR366_T3_EVIDENCE_MODE") in ["RED", "GREEN"] do
      IO.puts("PR366_T3_EVIDENCE " <> Jason.encode!(%{label: label, data: data}))
    end
  end

  defp fingerprint(value) when is_binary(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
