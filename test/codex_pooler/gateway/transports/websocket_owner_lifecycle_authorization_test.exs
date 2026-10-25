defmodule CodexPooler.Gateway.Transports.WebsocketOwnerLifecycleAuthorizationTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.RequestReplayFixtures, only: [replay_fixture: 1]

  alias CodexPooler.Accounting.LedgerEntry
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Repo

  @moduletag capture_log: true
  @lifecycle CodexPooler.JSON.encode!(%{"type" => "response.created", "response" => %{"status" => "in_progress", "output" => []}})

  test "local lifecycle delivery runs once inside its nine SELECT authorization transaction" do
    fixture = replay_fixture(reservation?: true)
    state = owner_state(fixture)

    assert {{:noreply, ^state}, 9} = capture_selects(fn -> deliver(state, @lifecycle) end)
    assert_received {:local_delivery, @lifecycle, true}
    refute_received {:local_delivery, _, _}
    assert Repo.reload!(fixture.turn).first_visible_output_at == nil
    assert Repo.reload!(fixture.request).status == "in_progress"
    assert Repo.all(from e in LedgerEntry, where: e.request_id == ^fixture.request.id, select: e.entry_kind) == ["reservation"]
  end

  test "a missing turn remains a valid six SELECT lifecycle delivery" do
    fixture = replay_fixture(reservation?: true)
    Repo.delete!(fixture.turn)
    state = owner_state(fixture)

    assert {{:noreply, ^state}, 6} = capture_selects(fn -> deliver(state, @lifecycle) end)
    assert_received {:local_delivery, @lifecycle, true}
    refute_received {:local_delivery, _, _}
  end

  for missing <- [:request, :attempt, :reservation] do
    @tag missing: missing
    test("missing #{missing} suppresses local lifecycle delivery", %{missing: missing}, do: assert_missing_row_refused(missing))
  end

  test "a stale generation suppresses local lifecycle delivery" do
    fixture = replay_fixture(reservation?: true)
    Repo.update!(Ecto.Changeset.change(fixture.attempt, replay_generation: 1))
    state = owner_state(fixture)

    assert {:noreply, ^state} = deliver(state, @lifecycle)
    refute_received {:local_delivery, _, _}
  end

  test "a cancelled database read withholds lifecycle data and records visible output unavailable" do
    state = replay_fixture(reservation?: true) |> owner_state()

    with_failed_request_reads("57014", state, fn ->
      assert {:noreply, next} = deliver(state, @lifecycle)
      assert next.active_turn.lifecycle_authorization_result == {:error, :visible_output_unavailable}
      refute_received {:local_delivery, _, _}
    end)
  end

  test "a nontransient database read error is reraised without lifecycle delivery" do
    state = replay_fixture(reservation?: true) |> owner_state()

    with_failed_request_reads("22012", state, fn ->
      error = assert_raise Postgrex.Error, fn -> deliver(state, @lifecycle) end
      assert error.postgres.code == :division_by_zero
      refute_received {:local_delivery, _, _}
    end)
  end

  test "visible output commits visibility and later lifecycle and terminal frames keep their fast path" do
    fixture = replay_fixture(reservation?: true)
    state = owner_state(fixture)
    output = CodexPooler.JSON.encode!(%{"type" => "response.output_text.delta", "delta" => "synthetic"})
    terminal = CodexPooler.JSON.encode!(%{"type" => "response.completed", "response" => %{"status" => "completed"}})

    assert {:noreply, visible} = deliver(state, output)
    assert visible.active_turn.visible_output?
    assert Repo.reload!(fixture.turn).first_visible_output_at
    assert_received {:local_delivery, ^output, false}

    assert {{:noreply, ^visible}, 0} = capture_selects(fn -> deliver(visible, @lifecycle) end)
    assert_received {:local_delivery, @lifecycle, false}
    assert {{:noreply, completed}, 0} = capture_selects(fn -> deliver(visible, terminal) end)
    assert completed.active_turn.terminal_forwarded?
    assert_received {:local_delivery, ^terminal, false}
    refute_received {:local_delivery, _, _}
  end

  defp assert_missing_row_refused(missing) do
    fixture = replay_fixture(reservation?: missing != :reservation)
    state = owner_state(fixture)

    state =
      case missing do
        :request -> put_in(state.active_turn.descriptor.request_id, Ecto.UUID.generate())
        :attempt -> put_in(state.active_turn.descriptor.attempt_id, Ecto.UUID.generate())
        :reservation -> state
      end

    assert {:noreply, ^state} = deliver(state, @lifecycle)
    refute_received {:local_delivery, _, _}
  end

  defp owner_state(fixture) do
    %{
      active_turn: %{
        ref: make_ref(),
        collect?: false,
        terminal_forwarded?: false,
        pending_result: nil,
        visible_output?: false,
        downstream: %{pid: self(), epoch: 1, correlation_id: "local-lifecycle"},
        descriptor: %{
          request_id: fixture.request.id,
          attempt_id: fixture.attempt.id,
          replay_generation: fixture.attempt.replay_generation,
          replay_claim_digest: fixture.replay_claim_digest,
          visible_output?: false
        }
      },
      callbacks: %{
        downstream_sender: fn pid, {:websocket_owner_frame, "local-lifecycle", 1, {:data, payload}} ->
          send(pid, {:local_delivery, payload, Repo.in_transaction?()})
          :ok
        end
      }
    }
  end

  defp deliver(state, payload),
    do: WebsocketOwnerSession.handle_info({:websocket_owner_upstream_frame, state.active_turn.ref, payload}, state)

  defp capture_selects(callback) do
    observer = self()
    handler = {__MODULE__, make_ref()}
    on_exit(fn -> :telemetry.detach(handler) end)

    :ok = :telemetry.attach(handler, [:codex_pooler, :repo, :query], &__MODULE__.observe_select/4, {observer, handler})

    try do
      result = callback.()
      {result, drain_selects(handler, 0)}
    after
      :telemetry.detach(handler)
    end
  end

  @doc false
  def observe_select(_event, _measurements, %{repo: Repo, query: query}, {observer, handler}) do
    if self() == observer and String.starts_with?(String.trim_leading(query), "SELECT"), do: send(observer, {handler, :select})
  end

  defp drain_selects(handler, count) do
    receive do
      {^handler, :select} -> drain_selects(handler, count + 1)
    after
      0 -> count
    end
  end

  # The temporary view shadows only this sandbox connection's request reads.
  # PostgreSQL itself raises the error; sandbox rollback also covers setup failure.
  defp with_failed_request_reads(sqlstate, state, callback) do
    Repo.query!("CREATE FUNCTION pg_temp.fail_local_lifecycle_read() RETURNS boolean LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'synthetic lifecycle read failure' USING ERRCODE = '#{sqlstate}'; END $$")
    # The function initializes pg_temp before the exact request query is warmed,
    # reproducing a connection whose prepared plan still resolves public.requests.
    assert_lifecycle_read(state)

    Repo.query!("CREATE TEMP VIEW requests AS SELECT * FROM public.requests WHERE pg_temp.fail_local_lifecycle_read()")
    # Creating a shadow view does not invalidate a plan bound to public.requests.
    # Replan this connection's statements without dropping Postgrex's prepared names.
    Repo.query!("DISCARD PLANS")

    try do
      callback.()
    after
      Repo.query!("DROP VIEW pg_temp.requests")
      Repo.query!("DROP FUNCTION pg_temp.fail_local_lifecycle_read()")
      assert %{rows: [[nil, nil]]} = Repo.query!("SELECT to_regclass('pg_temp.requests'), to_regprocedure('pg_temp.fail_local_lifecycle_read()')")
    end

    assert_lifecycle_read(state)
  end

  defp assert_lifecycle_read(state) do
    assert {{:noreply, ^state}, 9} = capture_selects(fn -> deliver(state, @lifecycle) end)
    assert_received {:local_delivery, @lifecycle, true}
    refute_received {:local_delivery, _, _}
  end
end
