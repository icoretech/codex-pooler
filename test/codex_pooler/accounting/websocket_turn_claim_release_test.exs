defmodule CodexPooler.Accounting.WebsocketTurnClaimReleaseTest do
  # A websocket turn claim commits before its reservation; when the reservation
  # rolls back the claim is released (findings#206 row 206-331). Only a row that
  # is still nothing but that claim goes: a reserved or terminal row, a row
  # another request chained onto, and the predecessor a chained claim names are
  # kept.
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountingTestSupport

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{ClientRetry, Request, RequestClientRetryLink, RequestLogFact}
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Repo

  @endpoint "/backend-api/codex/responses"

  test "a row holding nothing but its claim is released, with its log fact, and the claim can be taken again" do
    setup = accounting_setup()
    opts = claim_opts(setup)

    assert {:ok, %{request: claimed}} = Accounting.claim_websocket_turn(setup.auth, setup.model, opts)
    assert Repo.exists?(from(fact in RequestLogFact, where: fact.request_id == ^claimed.id))

    assert {:ok, :released} = Accounting.release_websocket_turn_claim(claimed)
    refute Repo.get(Request, claimed.id)
    refute Repo.exists?(from(fact in RequestLogFact, where: fact.request_id == ^claimed.id))

    assert {:ok, %{request: again}} = Accounting.claim_websocket_turn(setup.auth, setup.model, opts)
    assert again.correlation_id == claimed.correlation_id
  end

  test "a claim whose reservation committed is kept" do
    setup = accounting_setup()
    opts = claim_opts(setup)
    assert {:ok, %{request: claimed}} = Accounting.claim_websocket_turn(setup.auth, setup.model, opts)

    assert {:ok, %{request: reserved}} =
             Accounting.reserve(setup.auth, setup.model, %{"model" => setup.model.exposed_model_id, "input" => []}, %{
               endpoint: @endpoint,
               transport: "websocket",
               correlation_id: opts.correlation_id,
               turn_claim: claimed
             })

    assert reserved.id == claimed.id
    assert {:ok, :kept} = Accounting.release_websocket_turn_claim(claimed)
    assert %Request{status: "in_progress"} = Repo.get!(Request, claimed.id)
  end

  test "a terminal claim row is kept" do
    setup = accounting_setup()
    assert {:ok, %{request: claimed}} = Accounting.claim_websocket_turn(setup.auth, setup.model, claim_opts(setup))
    fail!(claimed)

    assert {:ok, :kept} = Accounting.release_websocket_turn_claim(claimed)
    assert %Request{status: "failed"} = Repo.get!(Request, claimed.id)
  end

  test "a claim row another request chained onto is kept" do
    setup = accounting_setup()
    assert {:ok, %{request: predecessor}} = Accounting.claim_websocket_turn(setup.auth, setup.model, claim_opts(setup))
    assert {:ok, %{request: successor}} = Accounting.claim_websocket_turn(setup.auth, setup.model, claim_opts(setup))
    _link = ClientRetry.insert_link!(predecessor, successor, DateTime.utc_now())

    assert {:ok, :kept} = Accounting.release_websocket_turn_claim(predecessor)
    assert %Request{status: "accepted"} = Repo.get!(Request, predecessor.id)
  end

  test "a chained claim is released alone: its predecessor keeps its claim and the resend chains to it again" do
    setup = accounting_setup()
    session = insert_session!(setup)
    opts = setup |> claim_opts() |> Map.put(:codex_session, session)

    assert {:ok, %{request: predecessor}} = Accounting.claim_websocket_turn(setup.auth, setup.model, opts)
    predecessor = fail!(predecessor)

    assert {:ok, %{request: successor, client_resend: %{predecessor_request_id: predecessor_id}}} =
             Accounting.claim_websocket_turn(setup.auth, setup.model, opts)

    assert predecessor_id == predecessor.id
    assert String.starts_with?(successor.correlation_id, "codex-request-retry:")

    assert {:ok, :released} = Accounting.release_websocket_turn_claim(successor)
    refute Repo.get(Request, successor.id)
    assert Repo.get!(Request, predecessor.id) == predecessor

    assert {:ok, %{request: again, client_resend: %{predecessor_request_id: ^predecessor_id}}} =
             Accounting.claim_websocket_turn(setup.auth, setup.model, opts)

    assert again.correlation_id == successor.correlation_id
    refute Repo.exists?(from(link in RequestClientRetryLink, where: link.predecessor_request_id == ^predecessor.id))
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
      session_key: "claim-release-#{System.unique_integer([:positive, :monotonic])}",
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
