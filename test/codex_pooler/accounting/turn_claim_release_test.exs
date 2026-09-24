defmodule CodexPooler.Accounting.TurnClaimReleaseTest do
  # A websocket request claim closed before anything reached the provider gives
  # its claim up and keeps its row as history (findings#206 rows 206-419,
  # 206-420, 206-421): a refusal at the reservation, the client's disconnect
  # before the reservation, and the six-hour stale-claim recovery. A row that
  # holds more than its claim, a row another request chained onto, and the
  # owner's pre-attempt drain row keep it.
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountingTestSupport

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{ClientRetry, Request, RequestClientRetryLink}
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Runtime.Finalization.Interruption
  alias CodexPooler.Repo

  @endpoint "/backend-api/codex/responses"

  describe "a refusal at the reservation (206-420)" do
    test "records the refusal on the claimed row and gives the claim up" do
      setup = accounting_setup()
      opts = claim_opts(setup)
      assert {:ok, %{request: claimed}} = Accounting.claim_websocket_turn(setup.auth, setup.model, opts)

      refused = refuse!(setup, claimed)

      assert %Request{id: id, status: "rejected", last_error_code: "api_key_concurrency_limit_exceeded", response_status_code: 429} = refused
      assert id == claimed.id
      assert {:ok, _uuid} = Ecto.UUID.cast(refused.correlation_id)
      assert refused.request_metadata["released_turn_claim"] == opts.correlation_id

      assert {:ok, %{request: again}} = Accounting.claim_websocket_turn(setup.auth, setup.model, opts)
      assert again.correlation_id == opts.correlation_id
      refute again.id == claimed.id
    end

    test "a chained resend gives up its own claim and link, and the next resend chains to the predecessor again" do
      setup = accounting_setup()
      opts = setup |> claim_opts() |> Map.put(:codex_session, insert_session!(setup))

      assert {:ok, %{request: predecessor}} = Accounting.claim_websocket_turn(setup.auth, setup.model, opts)
      predecessor = fail!(predecessor)

      assert {:ok, %{request: successor, client_resend: %{predecessor_request_id: predecessor_id}}} =
               Accounting.claim_websocket_turn(setup.auth, setup.model, opts)

      assert predecessor_id == predecessor.id
      _link = ClientRetry.insert_link!(predecessor, successor, DateTime.utc_now())

      refused = refuse!(setup, successor)
      assert {:ok, _uuid} = Ecto.UUID.cast(refused.correlation_id)
      assert refused.request_metadata["client_resend"]["predecessor_request_id"] == predecessor.id
      refute Repo.exists?(from(link in RequestClientRetryLink, where: link.successor_request_id == ^successor.id))
      assert Repo.get!(Request, predecessor.id) == predecessor

      assert {:ok, %{request: again, client_resend: %{predecessor_request_id: ^predecessor_id}}} =
               Accounting.claim_websocket_turn(setup.auth, setup.model, opts)

      assert again.correlation_id == successor.correlation_id
    end

    test "a row another request chained onto keeps its claim" do
      setup = accounting_setup()
      opts = claim_opts(setup)
      assert {:ok, %{request: predecessor}} = Accounting.claim_websocket_turn(setup.auth, setup.model, opts)
      assert {:ok, %{request: successor}} = Accounting.claim_websocket_turn(setup.auth, setup.model, claim_opts(setup))
      _link = ClientRetry.insert_link!(predecessor, successor, DateTime.utc_now())

      refused = refuse!(setup, predecessor)
      assert %Request{status: "rejected"} = refused
      assert refused.correlation_id == opts.correlation_id
      refute Map.has_key?(refused.request_metadata, "released_turn_claim")
    end

    test "a claim whose reservation committed is not refused and keeps its claim" do
      setup = accounting_setup()
      opts = claim_opts(setup)
      assert {:ok, %{request: claimed}} = Accounting.claim_websocket_turn(setup.auth, setup.model, opts)

      assert {:ok, %{request: %Request{status: "in_progress"}}} =
               Accounting.reserve(setup.auth, setup.model, %{"model" => setup.model.exposed_model_id, "input" => []}, %{
                 endpoint: @endpoint,
                 transport: "websocket",
                 correlation_id: opts.correlation_id,
                 turn_claim: claimed
               })

      assert {:error, %{code: :request_already_finalized}} = Accounting.record_denied_request(setup.auth, setup.model, refusal_opts(claimed))
      assert %Request{status: "in_progress", correlation_id: claim} = Repo.get!(Request, claimed.id)
      assert claim == opts.correlation_id
    end
  end

  describe "the client leaving before the reservation (206-419)" do
    for reason <- ["client_disconnected", "owner_drained"] do
      test "a claim-only row closed #{reason} by the direct interrupt gives the claim up" do
        setup = accounting_setup()
        session = insert_session!(setup)
        opts = setup |> claim_opts() |> Map.put(:codex_session, session)
        assert {:ok, %{request: claimed}} = Accounting.claim_websocket_turn(setup.auth, setup.model, opts)

        assert :ok = interrupt!(session, claimed, unquote(reason))

        closed = Repo.get!(Request, claimed.id)
        assert %Request{status: "failed", response_status_code: 499, usage_status: "usage_unknown"} = closed
        assert closed.last_error_code == unquote(reason)
        assert {:ok, _uuid} = Ecto.UUID.cast(closed.correlation_id)
        assert closed.request_metadata["released_turn_claim"] == opts.correlation_id
        refute Map.has_key?(closed.request_metadata, "websocket_pre_attempt_drain")

        assert {:ok, %{request: again} = claimed_again} = Accounting.claim_websocket_turn(setup.auth, setup.model, opts)
        assert again.correlation_id == opts.correlation_id
        refute Map.has_key?(claimed_again, :client_resend)
      end
    end
  end

  describe "the stale-claim recovery (206-421)" do
    test "a recovered claim-only row gives the claim up" do
      setup = accounting_setup()
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      opts = setup |> claim_opts() |> Map.put(:now, DateTime.add(now, -7, :hour))
      assert {:ok, %{request: claimed}} = Accounting.claim_websocket_turn(setup.auth, setup.model, opts)

      assert {:ok, %{stale_turn_claims_recovered: 1}} = Accounting.recover_stale_reservations(now)

      recovered = Repo.get!(Request, claimed.id)
      assert %Request{status: "failed", last_error_code: "stale_websocket_turn_claim_recovered"} = recovered
      assert {:ok, _uuid} = Ecto.UUID.cast(recovered.correlation_id)
      assert recovered.request_metadata["released_turn_claim"] == opts.correlation_id

      assert {:ok, %{request: again}} = Accounting.claim_websocket_turn(setup.auth, setup.model, Map.delete(opts, :now))
      assert again.correlation_id == opts.correlation_id
      assert {:ok, %{stale_turn_claims_recovered: 0}} = Accounting.recover_stale_reservations(now)
    end

    test "a recovered row another request chained onto keeps its claim" do
      setup = accounting_setup()
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      opts = setup |> claim_opts() |> Map.put(:now, DateTime.add(now, -7, :hour))
      assert {:ok, %{request: predecessor}} = Accounting.claim_websocket_turn(setup.auth, setup.model, opts)
      assert {:ok, %{request: successor}} = Accounting.claim_websocket_turn(setup.auth, setup.model, claim_opts(setup))
      _link = ClientRetry.insert_link!(predecessor, successor, DateTime.utc_now())

      assert {:ok, %{stale_turn_claims_recovered: 1}} = Accounting.recover_stale_reservations(now)
      assert %Request{status: "failed", correlation_id: claim} = Repo.get!(Request, predecessor.id)
      assert claim == opts.correlation_id
    end
  end

  defp refuse!(setup, %Request{} = claimed) do
    assert {:ok, %{request: refused}} = Accounting.record_denied_request(setup.auth, setup.model, refusal_opts(claimed))
    refused
  end

  # What `Denials.log_gateway/2` records for the key's active-request cap.
  defp refusal_opts(%Request{} = claimed) do
    %{
      endpoint: @endpoint,
      transport: "websocket",
      correlation_id: claimed.correlation_id,
      response_status_code: 429,
      last_error_code: "api_key_concurrency_limit_exceeded",
      request_metadata: %{"gateway_denial" => %{"code" => "api_key_concurrency_limit_exceeded"}},
      turn_claim: claimed
    }
  end

  defp interrupt!(%CodexSession{} = session, %Request{} = claimed, reason) do
    receipt = %{session_id: session.id, request_id: claimed.id, correlation_id: claimed.correlation_id, api_key_id: claimed.api_key_id, owner_binding: nil}

    case Interruption.interrupt_direct_request(receipt, reason) do
      :ok -> :ok
      {:ok, _markers} -> :ok
      other -> other
    end
  end

  defp claim_opts(setup) do
    %{
      endpoint: @endpoint,
      correlation_id: "codex-request:" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
      requested_model: setup.model.exposed_model_id
    }
  end

  # The terminal shape the resend policy chains: the response task failed
  # before anything was dispatched.
  defp fail!(%Request{} = request) do
    request
    |> Ecto.Changeset.change(status: "failed", usage_status: "not_applicable", last_error_code: "owner_task_exception", response_status_code: 500, completed_at: db_now())
    |> Repo.update!()
  end

  defp insert_session!(setup) do
    now = db_now()

    Repo.insert!(%CodexSession{
      pool_id: setup.pool.id,
      api_key_id: setup.api_key.id,
      session_key: "claim-fence-#{System.unique_integer([:positive, :monotonic])}",
      pool_upstream_assignment_id: setup.assignment.id,
      status: "active",
      created_at: now,
      updated_at: now
    })
  end

  defp db_now do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()", [])
    DateTime.truncate(now, :microsecond)
  end
end
