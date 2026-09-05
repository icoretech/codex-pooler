defmodule CodexPooler.Gateway.Transports.OwnerCleanupPeer do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.Gateway.Persistence.{BridgeOwnerLease, CodexSession, CodexTurn}
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession.Persistence
  alias CodexPooler.Gateway.Transports.WebsocketOwnerNodeHarness
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Repo

  @budget 30_000

  @spec bootstrap(keyword(), keyword()) :: :ok
  def bootstrap(env, repo_config) do
    Enum.each(env, fn {key, value} -> Application.put_env(:codex_pooler, key, value) end)
    {:ok, _} = Application.ensure_all_started(:logger)
    {:ok, _} = Application.ensure_all_started(:crypto)
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)

    {:ok, pubsub} =
      Supervisor.start_link([{Phoenix.PubSub, name: CodexPooler.PubSub}], strategy: :one_for_one)

    Process.unlink(pubsub)

    WebsocketOwnerNodeHarness.start_repo(
      Keyword.put(repo_config, :pool, DBConnection.ConnectionPool)
    )

    {:ok, _} = WebsocketOwnerNodeHarness.start_owner_runtime()
    :ok
  end

  @spec start_request(map(), map(), pid()) :: map()
  def start_request(setup, session, observer) do
    upstream = %{
      start: fn -> Agent.start_link(fn -> :ready end) end,
      send: fn _pid, request, _writer ->
        ref = request.request_id
        send(observer, {:upstream_waiting, ref, self(), node()})

        receive do
          {:finish_upstream, ^ref} -> :ok
        after
          @budget -> raise "owner cleanup upstream barrier timeout"
        end
      end,
      close: fn pid ->
        if Process.alive?(pid), do: Agent.stop(pid)
        :ok
      end
    }

    started =
      WebsocketOwnerSession.start_owner(
        codex_session_id: session.id,
        owner_instance_id: session.owner_instance_id,
        owner_lease_token: session.owner_lease_token,
        owner_renewal_ms: 120_000,
        idle_shutdown_ms: 120_000,
        upstream: upstream
      )

    owner =
      case started do
        {:ok, pid} -> pid
        {:ok, pid, :existing} -> pid
      end

    {:ok, downstream} =
      WebsocketOwnerSession.attach_downstream(owner, %{
        pid: observer,
        correlation_id: Ecto.UUID.generate(),
        epoch: 0
      })

    {:ok, reserved} =
      Accounting.reserve(setup.auth, setup.model, %{"model" => setup.model.exposed_model_id}, %{
        endpoint: "/backend-api/codex/responses",
        transport: "websocket",
        correlation_id: Ecto.UUID.generate(),
        request_metadata: %{
          "codex_session_id" => session.id,
          "websocket_owner_forwarding" => %{
            "owner_instance_id" => session.owner_instance_id,
            "downstream_epoch" => downstream.epoch
          }
        }
      })

    {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)
    {:ok, turn} = Gateway.start_codex_turn(session, reserved.request)

    request = %UpstreamWebsocketSession.Request{
      request_id: reserved.request.id,
      attempt_id: attempt.id,
      url: "http://127.0.0.1/unused",
      payload: "{}",
      headers: [],
      timeouts: %{connect_timeout_ms: 1_000, receive_timeout_ms: @budget}
    }

    ref = reserved.request.id

    submitter =
      spawn(fn ->
        result = WebsocketOwnerSession.submit_request(owner, downstream, request)
        send(observer, {:submission_finished, ref, result})
      end)

    %{
      owner: owner,
      downstream: downstream,
      request: reserved.request,
      attempt: attempt,
      turn: turn,
      ref: ref,
      submitter: submitter
    }
  end

  @spec delay_cleanup(pid(), pid(), atom()) :: pid()
  def delay_cleanup(owner, observer, mode) do
    snapshot = :sys.get_state(owner)

    snapshot =
      if mode == :absent_witness,
        do: put_in(snapshot.active_turn.cleanup_witness, nil),
        else: snapshot

    spawn(fn ->
      send(observer, {:cleanup_waiting, self(), snapshot.active_turn.cleanup_witness, node()})

      receive do
        :release_cleanup ->
          result = Persistence.interrupt_codex_session(snapshot, :owner_drained)
          send(observer, {:cleanup_finished, self(), result})
      after
        @budget -> raise "owner cleanup persistence barrier timeout"
      end
    end)
  end

  @spec takeover(map(), node(), boolean()) :: map()
  def takeover(session, target, reuse_token?) do
    token = if reuse_token?, do: session.owner_lease_token, else: Ecto.UUID.generate()
    expiry = DateTime.add(DateTime.utc_now(), 120, :second)

    Repo.update_all(from(row in BridgeOwnerLease, where: row.codex_session_id == ^session.id),
      set: [owner_instance_id: Atom.to_string(target), lease_token: token, expires_at: expiry]
    )

    session
    |> Ecto.Changeset.change(
      owner_instance_id: Atom.to_string(target),
      owner_lease_token: token,
      owner_lease_expires_at: expiry
    )
    |> Repo.update!()
  end

  @spec facts(map()) :: map()
  def facts(turn) do
    %{
      session: Repo.get!(CodexSession, turn.turn.codex_session_id),
      request: Repo.get!(Request, turn.request.id),
      attempt: Repo.get!(Attempt, turn.attempt.id),
      turn: Repo.get!(CodexTurn, turn.turn.id),
      lease:
        Repo.one!(
          from row in BridgeOwnerLease,
            where: row.codex_session_id == ^turn.turn.codex_session_id
        ),
      active: if(Process.alive?(turn.owner), do: :sys.get_state(turn.owner).active_turn),
      ledger:
        Repo.all(
          from entry in LedgerEntry,
            where: entry.request_id == ^turn.request.id,
            order_by: [asc: entry.id]
        ),
      settlements:
        Repo.aggregate(
          from(entry in LedgerEntry,
            where: entry.request_id == ^turn.request.id and entry.entry_kind == "settlement"
          ),
          :count
        )
    }
  end

  @spec finish(map()) :: :ok
  def finish(turn) do
    state = :sys.get_state(turn.owner)
    send(state.active_turn.task_pid, {:finish_upstream, turn.ref})
    :ok
  end

  @spec invalidate(map(), :expired_lease | :generation_changed) :: :ok
  def invalidate(turn, :expired_lease) do
    session = Repo.get!(CodexSession, turn.turn.codex_session_id)

    session
    |> Ecto.Changeset.change(
      owner_lease_expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
    )
    |> Repo.update!()

    :ok
  end

  def invalidate(turn, :generation_changed) do
    turn.attempt
    |> Ecto.Changeset.change(replay_generation: turn.attempt.replay_generation + 1)
    |> Repo.update!()

    :ok
  end

  @spec correct_usage(map()) :: {:ok, map()} | {:error, term()}
  def correct_usage(turn) do
    Accounting.finalize_success_with_disposition(
      Repo.get!(Request, turn.request.id),
      Repo.get!(Attempt, turn.attempt.id),
      %{
        status: "usage_known",
        source: "late_owner_completion",
        input_tokens: 7,
        output_tokens: 3,
        total_tokens: 10,
        recorded_at: DateTime.utc_now()
      },
      %{response_status_code: 200}
    )
  end

  @spec delay_release(pid(), pid()) :: pid()
  def delay_release(owner, observer) do
    snapshot = :sys.get_state(owner)

    spawn(fn ->
      send(observer, {:release_waiting, self()})

      receive do
        :release_cleanup ->
          result = Persistence.release_owner_lease(snapshot, :owner_drained, :drain_cut)
          send(observer, {:release_finished, self(), result})
      after
        @budget -> raise "owner cleanup lease release barrier timeout"
      end
    end)
  end
end
