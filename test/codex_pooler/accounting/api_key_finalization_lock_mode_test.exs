defmodule CodexPooler.Accounting.APIKeyFinalizationLockModeTest do
  @moduledoc """
  Query-capture contract for the `api_keys` lock mode on finalization reached
  from reader transactions. Interruption and request replay take the `api_keys`
  reader lock (`FOR SHARE`) and then finalize through
  `finalize_request_with_disposition/3`, whose replay prefix locks the same row
  again. Each captured call below is exactly one top-level transaction, so an
  `api_keys ... FOR UPDATE` after an `api_keys ... FOR SHARE` inside it would be
  an in-transaction lock upgrade, which deadlocks between two such transactions
  on one key.
  """

  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountingTestSupport, only: [accounting_setup: 0]

  import CodexPooler.RequestReplayFixtures,
    only: [replay_fixture: 1, arm_input: 1, consume_input: 3, stop_replay_owner: 1]

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{ClientRetry, Request, RequestReplay}
  alias CodexPooler.Gateway.Payloads.{RequestOptions, WebsocketTurnIdentity}
  alias CodexPooler.Gateway.Persistence.SessionContinuity
  alias CodexPooler.Gateway.Runtime.Finalization.Interruption
  alias CodexPooler.Gateway.Websocket, as: Gateway

  # The site lock of interruption and replay transactions and the finalization
  # replay prefix both take this sequence; only its `api_keys` mode is under test.
  @reader_prefix [{"codex_sessions", :update}, {"api_keys", :share}, {"codex_turns", :update}]

  test "interruption task-exception finalization keeps the api_keys reader lock through the replay prefix" do
    fixture = interruption_fixture()

    {result, events} =
      capture_lock_events(fn ->
        Interruption.finalize_task_exception_request(fixture.receipt, "owner_task_exception")
      end)

    assert :ok = result
    assert %Request{status: "failed"} = Repo.get!(Request, fixture.request.id)
    assert_reader_lock_contract!(events)
  end

  test "owner-shutdown close of an armed replay finalizes under reader locks only" do
    fixture = replay_fixture(reservation?: true)
    assert {:ok, _armed} = RequestReplay.arm(arm_input(fixture))

    {result, events} =
      capture_lock_events(fn -> RequestReplay.close(fixture.request.id, :owner_shutdown) end)

    assert {:ok, :closed} = result
    assert Repo.reload!(fixture.request).last_error_code == "websocket_replay_revoked"
    assert_reader_lock_contract!(events)
  end

  test "no-send compensation of a consumed replay finalizes under reader locks only" do
    fixture = replay_fixture(reservation?: true)

    try do
      assert {:ok, armed} = RequestReplay.arm(arm_input(fixture))

      assert {:ok, consumed} =
               RequestReplay.consume(consume_input(fixture, armed, :crypto.strong_rand_bytes(32)))

      {result, events} =
        capture_lock_events(fn -> RequestReplay.compensate_no_send(consumed.consume_binding) end)

      assert {:ok, _finalized} = result
      assert Repo.reload!(fixture.request).last_error_code == "websocket_replay_abandoned"
      assert_reader_lock_contract!(events)
    after
      stop_replay_owner(fixture.session.id)
    end
  end

  defp assert_reader_lock_contract!(events) do
    api_key_modes = for {"api_keys", mode} <- events, do: mode

    case Enum.split_while(api_key_modes, &(&1 != :share)) do
      {_before_reader, [:share | after_reader]} ->
        refute :update in after_reader,
               "an api_keys FOR UPDATE followed an api_keys FOR SHARE in one transaction: " <>
                 inspect(events)

      {_modes, []} ->
        flunk("the transaction took no api_keys FOR SHARE lock: #{inspect(events)}")
    end

    prefix_starts = prefix_starts(events)

    assert length(prefix_starts) >= 2,
           "expected the site lock and the finalization prefix to take api_keys FOR SHARE: " <>
             inspect(events)

    # The last reader sequence belongs to the finalization prefix: finalization
    # locks the request's ledger rows after it.
    after_prefix = Enum.drop(events, List.last(prefix_starts) + length(@reader_prefix))
    assert {"ledger_entries", :update} in after_prefix
  end

  defp prefix_starts(events) do
    events
    |> Enum.with_index()
    |> Enum.filter(fn {_event, index} ->
      Enum.slice(events, index, length(@reader_prefix)) == @reader_prefix
    end)
    |> Enum.map(fn {_event, index} -> index end)
  end

  defp capture_lock_events(fun) when is_function(fun, 0) do
    parent = self()
    handler_id = {__MODULE__, System.unique_integer([:positive, :monotonic])}

    # Also on_exit: a linked crash or the ExUnit timeout kills the test before `after` runs.
    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata[:repo] == Repo and self() == parent do
            forward_lock_event(parent, handler_id, metadata)
          end
        end,
        nil
      )

    try do
      result = fun.()
      {result, drain_lock_events(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp forward_lock_event(parent, handler_id, metadata) do
    case lock_mode(Map.get(metadata, :query, "")) do
      nil -> :ok
      mode -> send(parent, {handler_id, {metadata[:source], mode}})
    end
  end

  defp drain_lock_events(handler_id, events) do
    receive do
      {^handler_id, event} -> drain_lock_events(handler_id, [event | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp lock_mode(query) do
    query = String.upcase(query)

    cond do
      String.contains?(query, "FOR UPDATE") -> :update
      String.contains?(query, "FOR SHARE") -> :share
      true -> nil
    end
  end

  defp interruption_fixture do
    setup = accounting_setup()

    {:ok, session} =
      Gateway.start_codex_session(setup.auth, %{
        accepted_turn_state: "lock-mode-#{System.unique_integer([:positive])}"
      })

    payload = %{
      "model" => setup.model.exposed_model_id,
      "input" => [],
      "client_metadata" => %{"turn_id" => "lock-mode-turn"}
    }

    {:ok, identity} = WebsocketTurnIdentity.resolve(payload, session.id)
    claim = identity.turn_claim_key

    witness =
      ClientRetry.original_witness!(
        :crypto.strong_rand_bytes(32),
        setup.api_key.runtime_revocation_epoch
      )

    {:ok, %{request: claimed}} =
      Accounting.claim_websocket_turn(setup.auth, setup.model, %{
        endpoint: "/backend-api/codex/responses",
        correlation_id: claim,
        native_client_retry_witness: witness
      })

    {:ok, reserved} =
      Accounting.reserve(setup.auth, setup.model, payload, %{
        endpoint: "/backend-api/codex/responses",
        transport: "websocket",
        correlation_id: claim,
        turn_claim: claimed
      })

    {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

    options =
      RequestOptions.for_websocket(%{request_id: claim})
      |> RequestOptions.put_continuity(semantic_turn_key: identity.semantic_turn_key)

    {:ok, _turn} = SessionContinuity.start_codex_turn(session, reserved.request, options)
    :ok = SessionContinuity.mark_codex_turn_visible(reserved.request)

    %{
      request: reserved.request,
      receipt: %{
        session_id: session.id,
        request_id: reserved.request.id,
        correlation_id: claim,
        api_key_id: setup.api_key.id,
        owner_binding: nil,
        attempt_id: attempt.id,
        replay_generation: attempt.replay_generation
      }
    }
  end
end
