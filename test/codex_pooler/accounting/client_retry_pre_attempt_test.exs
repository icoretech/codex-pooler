defmodule CodexPooler.Accounting.ClientRetryPreAttemptTest do
  # PREDICATE tests, not drain tests. `predecessor_fixture/1` below stamps
  # `websocket_pre_attempt_drain` onto the request itself and then asserts that
  # `ClientRetry` admits or refuses the resend. That is deliberate and correct
  # input for a predicate -- the predicate's job is to decide, not to produce --
  # and the `mutate/2` cases depend on being able to vary it freely.
  #
  # What it cannot do is notice that nothing *writes* the marker, which is
  # exactly what happened: the key had never been set once in ~1,000,000
  # production requests while this file was green
  # (icoretech/codex-pooler-findings#160, #170).
  #
  # The PRODUCER -- a real drain writing the marker and the release, with the
  # real predicate reading them back and admitting the resend -- is covered in
  # `test/codex_pooler_web/controllers/runtime/backend_codex_pre_attempt_drain_resend_test.exs`.
  # If this file is green and that one is not, the capability does not exist.
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountingTestSupport

  alias CodexPooler.Accounting

  alias CodexPooler.Accounting.{
    Attempt,
    ClientRetry,
    LedgerEntry,
    Request,
    RequestClientRetryLink
  }

  alias CodexPooler.Gateway.Persistence.{BridgeOwnerLease, CodexSession, CodexTurn}
  alias CodexPooler.Repo

  test "native retry completion uses database time despite a future application clock" do
    before = database_now()
    fixture = predecessor_fixture(%{now: DateTime.add(before, 60, :second)})
    assert DateTime.compare(fixture.request.completed_at, before) in [:eq, :gt]
    assert DateTime.compare(fixture.request.completed_at, database_now()) in [:eq, :lt]
    assert {:ok, %ClientRetry.SuccessorClaim{}} = claim(fixture)
  end

  test "attempt finalization uses database time only for native retry witnesses" do
    for native? <- [true, false], attempted? <- [true, false] do
      setup = accounting_setup(%{price_version: "clock-#{System.unique_integer([:positive])}"})
      before = database_now()
      future = DateTime.add(before, 60, :second)

      witness =
        if native?,
          do:
            ClientRetry.original_witness!(
              :crypto.strong_rand_bytes(32),
              setup.api_key.runtime_revocation_epoch
            )

      {:ok, %{request: claimed}} =
        Accounting.claim_websocket_turn(setup.auth, setup.model, %{
          endpoint: "/backend-api/codex/responses",
          correlation_id: Ecto.UUID.generate(),
          native_client_retry_witness: witness
        })

      {:ok, %{request: reserved}} =
        Accounting.reserve(setup.auth, setup.model, %{"model" => setup.model.exposed_model_id}, %{
          transport: "websocket",
          endpoint: claimed.endpoint,
          correlation_id: claimed.correlation_id,
          turn_claim: claimed
        })

      {:ok, result} =
        if attempted? do
          {:ok, attempt} = Accounting.create_attempt(reserved, setup.assignment)
          Accounting.finalize_failure(reserved, attempt, %{now: future})
        else
          Accounting.finalize_reservation_failure(reserved, %{now: future})
        end

      if attempted?, do: assert(result.attempt.completed_at == result.request.completed_at)

      if native? do
        assert DateTime.compare(result.request.completed_at, before) in [:eq, :gt]
        assert DateTime.compare(result.request.completed_at, database_now()) in [:eq, :lt]
      else
        assert result.request.completed_at == future
      end
    end
  end

  test "a drained accepted claim with no turn or ledger receives one fresh successor" do
    fixture = claimed_predecessor_fixture()
    assert {:ok, %ClientRetry.SuccessorClaim{} = successor} = claim(fixture)
    assert successor.predecessor_request_id == fixture.request.id
    assert {:error, :successor_claimed} = claim(fixture)
    assert Repo.get!(Request, fixture.request.id) == fixture.request
    refute Repo.get_by(CodexTurn, request_id: fixture.request.id)
    refute Repo.exists?(from entry in LedgerEntry, where: entry.request_id == ^fixture.request.id)
    refute Repo.exists?(from attempt in Attempt, where: attempt.request_id == ^fixture.request.id)
  end

  test "claimed-only retry rejects changed scope and incomplete cancellation evidence" do
    for mutation <- [
          :marker,
          :active,
          :attempt,
          :expired,
          :future,
          :witness,
          :payload,
          :epoch,
          :anchor,
          :model,
          :endpoint,
          :claim
        ] do
      fixture = claimed_predecessor_fixture() |> mutate(mutation)
      assert {:error, _} = claim(fixture), "accepted #{mutation}"

      refute Repo.exists?(
               from link in RequestClientRetryLink,
                 where: link.predecessor_request_id == ^fixture.request.id
             )
    end
  end

  test "a verified pre-attempt drain permits one successor without changing closed accounting" do
    fixture = predecessor_fixture()
    before = Repo.all(from entry in LedgerEntry, where: entry.request_id == ^fixture.request.id)

    assert {:ok, %ClientRetry.SuccessorClaim{} = successor} = claim(fixture)
    assert successor.predecessor_request_id == fixture.request.id
    refute ClientRetry.original_witness_eligible?(successor.request)
    assert Repo.get!(Request, fixture.request.id) == fixture.request

    assert Repo.all(from entry in LedgerEntry, where: entry.request_id == ^fixture.request.id) ==
             before

    refute Repo.exists?(from attempt in Attempt, where: attempt.request_id == ^fixture.request.id)
    assert {:error, :successor_claimed} = claim(fixture)

    assert {:ok, %Attempt{attempt_number: 1, replay_generation: 0}} =
             Accounting.create_client_retry_dispatch_attempt(
               successor.request,
               fixture.setup.assignment,
               successor.dispatch_authority
             )

    assert {:error, %{code: :client_retry_dispatch_claimed}} =
             Accounting.create_client_retry_dispatch_attempt(
               successor.request,
               fixture.setup.assignment,
               successor.dispatch_authority
             )

    refute Repo.exists?(from attempt in Attempt, where: attempt.request_id == ^fixture.request.id)
  end

  test "a replacement owner needs its exact current idle capability" do
    fixture = predecessor_fixture()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    token = Ecto.UUID.generate()

    session =
      Repo.update!(
        Ecto.Changeset.change(fixture.opts.codex_session,
          owner_instance_id: "replacement-owner",
          owner_lease_token: token,
          owner_lease_expires_at: DateTime.add(now, 60),
          last_heartbeat_at: now
        )
      )

    Repo.insert!(%BridgeOwnerLease{
      codex_session_id: session.id,
      pool_id: fixture.setup.pool.id,
      api_key_id: fixture.setup.api_key.id,
      pool_upstream_assignment_id: fixture.setup.assignment.id,
      owner_instance_id: "replacement-owner",
      lease_token: token,
      status: "active",
      acquired_at: now,
      renewed_at: now,
      expires_at: DateTime.add(now, 60),
      metadata: %{},
      created_at: now,
      updated_at: now
    })

    fixture = put_in(fixture.opts.codex_session, session)
    assert {:error, :active_predecessor} = claim(fixture)

    wrong =
      Map.merge(fixture.opts, %{
        owner_idle_validated?: true,
        owner_instance_id: "replacement-owner",
        owner_lease_token: Ecto.UUID.generate()
      })

    assert {:error, :active_predecessor} = claim(%{fixture | opts: wrong})

    assert {:ok, %ClientRetry.SuccessorClaim{}} =
             claim(%{fixture | opts: Map.put(wrong, :owner_lease_token, token)})
  end

  test "incomplete or unsafe zero-attempt drain evidence never creates a successor" do
    for mutation <- [
          :marker,
          :ordinary_failure,
          :active,
          :visible,
          :attempt,
          :release,
          :settlement,
          :expired,
          :future,
          :witness,
          :payload,
          :epoch,
          :anchor,
          :model,
          :endpoint
        ] do
      fixture = predecessor_fixture()
      fixture = mutate(fixture, mutation)
      count = Repo.aggregate(Request, :count)
      assert {:error, _reason} = claim(fixture), "accepted #{mutation}"
      assert Repo.aggregate(Request, :count) == count

      refute Repo.exists?(
               from link in RequestClientRetryLink,
                 where: link.predecessor_request_id == ^fixture.request.id
             )
    end
  end

  defp claim(fixture) do
    Accounting.claim_client_retry_successor(
      fixture.setup.auth,
      fixture.setup.model,
      fixture.payload,
      fixture.opts
    )
  end

  defp claimed_predecessor_fixture do
    fixture = predecessor_fixture()
    Repo.delete!(fixture.turn)
    Repo.delete_all(from entry in LedgerEntry, where: entry.request_id == ^fixture.request.id)
    claim = "codex-turn:" <> Base.url_encode64(fixture.opts.semantic_turn_digest, padding: false)

    request =
      Repo.update!(
        Ecto.Changeset.change(fixture.request,
          correlation_id: claim,
          usage_status: "usage_unknown"
        )
      )

    %{
      fixture
      | request: request,
        turn: nil,
        opts: Map.put(fixture.opts, :original_request_claim, claim)
    }
  end

  defp predecessor_fixture(completion_attrs \\ %{}) do
    setup =
      accounting_setup(%{price_version: "pre-attempt-#{System.unique_integer([:positive])}"})

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    digest = :crypto.strong_rand_bytes(32)
    semantic_digest = :crypto.strong_rand_bytes(32)
    payload = %{"model" => setup.model.exposed_model_id, "input" => []}
    witness = ClientRetry.original_witness!(digest, setup.api_key.runtime_revocation_epoch)

    {:ok, %{request: claimed}} =
      Accounting.claim_websocket_turn(setup.auth, setup.model, %{
        endpoint: "/backend-api/codex/responses",
        correlation_id: Ecto.UUID.generate(),
        native_client_retry_witness: witness
      })

    {:ok, %{request: reserved}} =
      Accounting.reserve(setup.auth, setup.model, payload, %{
        transport: "websocket",
        endpoint: claimed.endpoint,
        correlation_id: claimed.correlation_id,
        turn_claim: claimed
      })

    {:ok, %{request: request}} =
      Accounting.finalize_reservation_failure(
        reserved,
        Map.merge(
          %{
            last_error_code: "owner_drained",
            usage_status: "usage_unknown",
            response_status_code: 499
          },
          completion_attrs
        )
      )

    # Stamped input: production writes this marker from
    # `Interruption.interrupt_direct_request/2` on a `%DirectCleanup{}` receipt,
    # which needs a live socket and owner and so cannot run here. See the module
    # comment for where the producer is covered.
    request =
      Repo.update!(
        Ecto.Changeset.change(request,
          request_metadata:
            Map.put(request.request_metadata || %{}, "websocket_pre_attempt_drain", true)
        )
      )

    session =
      Repo.insert!(%CodexSession{
        pool_id: setup.pool.id,
        api_key_id: setup.api_key.id,
        session_key: "pre-attempt-#{System.unique_integer([:positive])}",
        pool_upstream_assignment_id: setup.assignment.id,
        status: "active",
        created_at: now,
        updated_at: now
      })

    turn =
      Repo.insert!(%CodexTurn{
        codex_session_id: session.id,
        request_id: request.id,
        turn_sequence: 1,
        transport_kind: "websocket",
        semantic_turn_digest: semantic_digest,
        status: "interrupted",
        error_code: "owner_drained",
        completed_at: request.completed_at,
        started_at: now,
        created_at: now,
        updated_at: now
      })

    %{
      setup: setup,
      request: request,
      turn: turn,
      payload: payload,
      opts: %{
        endpoint: request.endpoint,
        requested_model: setup.model.exposed_model_id,
        runtime_revocation_epoch: setup.api_key.runtime_revocation_epoch,
        codex_session: session,
        semantic_turn_digest: semantic_digest,
        replay_claim_digest: digest
      }
    }
  end

  defp mutate(fixture, :marker), do: update_request(fixture, request_metadata: %{})

  defp mutate(fixture, :ordinary_failure),
    do: update_request(fixture, last_error_code: "client_disconnected")

  defp mutate(fixture, :active),
    do: update_request(fixture, status: "in_progress", completed_at: nil)

  defp mutate(fixture, :witness),
    do:
      update_request(fixture,
        native_client_retry_digest: nil,
        native_client_retry_version: nil,
        native_client_retry_auth_epoch: nil
      )

  defp mutate(fixture, :expired),
    do: update_request(fixture, completed_at: DateTime.add(DateTime.utc_now(), -31))

  defp mutate(fixture, :future),
    do: update_request(fixture, completed_at: DateTime.add(DateTime.utc_now(), 31))

  defp mutate(fixture, :payload),
    do: put_in(fixture.opts.replay_claim_digest, :crypto.strong_rand_bytes(32))

  defp mutate(fixture, :anchor),
    do: %{fixture | opts: Map.put(fixture.opts, :anchor_present?, true)}

  defp mutate(fixture, :model),
    do: put_in(fixture.opts.requested_model, "changed-model")

  defp mutate(fixture, :endpoint),
    do: put_in(fixture.opts.endpoint, "/v1/responses")

  defp mutate(fixture, :claim),
    do: %{fixture | opts: Map.put(fixture.opts, :original_request_claim, Ecto.UUID.generate())}

  defp mutate(fixture, :epoch) do
    Repo.update!(
      Ecto.Changeset.change(fixture.setup.api_key,
        runtime_revocation_epoch: fixture.setup.api_key.runtime_revocation_epoch + 1
      )
    )

    fixture
  end

  defp mutate(fixture, :visible) do
    Repo.update!(Ecto.Changeset.change(fixture.turn, first_visible_output_at: DateTime.utc_now()))
    fixture
  end

  defp mutate(fixture, :attempt) do
    CodexPooler.PoolerFixtures.attempt_fixture(fixture.request, fixture.setup.assignment)
    fixture
  end

  defp mutate(fixture, :release) do
    Repo.delete_all(
      from entry in LedgerEntry,
        where: entry.request_id == ^fixture.request.id and entry.entry_kind == "release"
    )

    fixture
  end

  defp mutate(fixture, :settlement) do
    release = Repo.get_by!(LedgerEntry, request_id: fixture.request.id, entry_kind: "release")
    Repo.update!(Ecto.Changeset.change(release, entry_kind: "settlement"))
    fixture
  end

  defp update_request(fixture, attrs) do
    %{fixture | request: Repo.update!(Ecto.Changeset.change(fixture.request, attrs))}
  end

  defp database_now do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()", [])
    now
  end
end
