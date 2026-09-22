defmodule CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSessionThreadScopeTest do
  # A native turn the owner accepts without a preceding preflight (the socket's
  # dequeue path: a frame queued behind a running task is submitted straight to
  # the owner) gets its descriptor from the upstream payload. The socket derives
  # the frame's semantic turn key under the claim scope of the client's thread
  # when the turn metadata names one (`WebsocketCodec.native_turn_claim_scope/2`),
  # so the owner has to derive it under the same scope, or a same-turn resend of
  # a thread-naming client never matches the turn the owner is running
  # (findings#225, row 225-91).
  use CodexPooler.DataCase, async: false

  @moduletag capture_log: true

  alias CodexPooler.Gateway.Payloads.WebsocketTurnIdentity
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Websocket.RemoteReconnectControlV2
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession

  @owner_shutdown_timeout_ms 15_000

  setup do
    session = %{
      id: Ecto.UUID.generate(),
      pool_id: Ecto.UUID.generate(),
      api_key_id: Ecto.UUID.generate()
    }

    # Tests stop their owner inside the capture window; this is the backstop
    # for a test that failed before it got there.
    on_exit(fn -> stop_owner(session.id) end)

    {:ok, session: session, owner_lease_token: Ecto.UUID.generate()}
  end

  test "a same-turn resend of a thread-naming client matches the turn the owner accepted without a preflight", context do
    {owner, downstream} = start_running_owner(context, "thread-scope-turn", "thread-scope-thread")

    thread_key = codex_key(context.session, "thread-scope-turn", "thread-scope-thread")
    session_key = codex_key(context.session, "thread-scope-turn", nil)
    refute thread_key == session_key

    assert WebsocketOwnerSession.preflight_reconnect(owner, downstream, thread_key, make_ref()) ==
             {:ok, :same_turn_replay}

    # The session-scoped key is not this frame's key any more.
    assert WebsocketOwnerSession.preflight_reconnect(owner, downstream, session_key, make_ref()) ==
             {:error, :owner_busy}

    stop_owner(context.session.id)
  end

  test "a client that names no thread keeps the session-scoped key", context do
    {owner, downstream} = start_running_owner(context, "session-scope-turn", nil)

    session_key = codex_key(context.session, "session-scope-turn", nil)

    assert WebsocketOwnerSession.preflight_reconnect(owner, downstream, session_key, make_ref()) ==
             {:ok, :same_turn_replay}

    stop_owner(context.session.id)
  end

  test "an owner started without the session's Pool and key falls back to the session scope", context do
    {owner, downstream} = start_running_owner(context, "legacy-start-turn", "legacy-start-thread", scope_opts: false)

    assert WebsocketOwnerSession.preflight_reconnect(
             owner,
             downstream,
             codex_key(context.session, "legacy-start-turn", nil),
             make_ref()
           ) == {:ok, :same_turn_replay}

    stop_owner(context.session.id)
  end

  test "an active reattach control against a turn accepted without a preflight is refused, not a crash", context do
    {owner, downstream} = start_running_owner(context, "reattach-turn", "reattach-thread")
    owner_ref = Process.monitor(owner)
    %{downstream_epoch: epoch} = :sys.get_state(owner)

    {:ok, control} =
      RemoteReconnectControlV2.new(%{
        version: 2,
        action: :preflight,
        intent: :active_reattach,
        codex_session_id: context.session.id,
        downstream: %{Map.take(downstream, [:pid, :correlation_id]) | correlation_id: "reattach-successor"} |> Map.put(:epoch, epoch + 1),
        semantic_turn_digest: codex_key(context.session, "reattach-turn", "reattach-thread"),
        replay_claim_digest: <<7::256>>,
        provisional_token: nil,
        replay_generation: nil,
        owner_lease_token: context.owner_lease_token,
        control_ref: make_ref(),
        authorization_binding: %{
          api_key_id: context.session.api_key_id,
          api_key_runtime_epoch: 0,
          pool_id: context.session.pool_id,
          codex_session_id: context.session.id,
          model_identifier: "gpt-test"
        },
        consume_binding: %{
          request_id: Ecto.UUID.generate(),
          codex_turn_id: Ecto.UUID.generate(),
          eligible_attempt_id: Ecto.UUID.generate(),
          replay_attempt_id: nil,
          replay_generation: 0,
          provisional_binding_digest: nil,
          owner_lease_digest: <<1::256>>
        }
      })

    assert WebsocketOwnerSession.reconnect_control_v2(owner, control) == {:error, :owner_busy}
    refute_received {:DOWN, ^owner_ref, :process, ^owner, _reason}
    assert Process.alive?(owner)
    Process.demonitor(owner_ref, [:flush])
    stop_owner(context.session.id)
  end

  defp start_running_owner(context, turn_id, thread_id, opts \\ []) do
    parent = self()

    scope_opts =
      if Keyword.get(opts, :scope_opts, true),
        do: [pool_id: context.session.pool_id, api_key_id: context.session.api_key_id],
        else: []

    {:ok, owner} =
      WebsocketOwnerSession.start_owner(
        [
          codex_session_id: context.session.id,
          owner_lease_token: context.owner_lease_token,
          owner_instance_id: Atom.to_string(node()),
          upstream: blocking_upstream(parent)
        ] ++ scope_opts
      )

    assert_receive {:thread_scope_upstream_started, _upstream_pid}

    {:ok, downstream} =
      WebsocketOwnerSession.attach_downstream(owner, %{pid: self(), correlation_id: "thread-scope-first"})

    # The dequeue path: no preflight, the owner derives the descriptor itself.
    _submitter =
      spawn(fn ->
        _result = WebsocketOwnerSession.submit_request(owner, downstream, native_request(turn_id, thread_id))
      end)

    assert_receive {:thread_scope_upstream_send, _task_pid}
    {owner, downstream}
  end

  # The frame's key as the socket derives it: `WebsocketCodec` resolves the
  # turn id under `WebsocketTurnIdentity.claim_scope/2` of the frame's session
  # and thread.
  defp codex_key(session, turn_id, thread_id) do
    scope = WebsocketTurnIdentity.claim_scope(session, thread_id)
    {:ok, %{semantic_turn_key: key}} = WebsocketTurnIdentity.resolve(payload(turn_id, thread_id), scope)
    key
  end

  defp native_request(turn_id, thread_id) do
    %UpstreamWebsocketSession.Request{
      url: "https://example.com/backend-api/codex/responses",
      headers: [],
      payload: CodexPooler.JSON.encode!(payload(turn_id, thread_id)),
      timeouts: %{},
      writer: fn _frame -> :ok end,
      message_mapper: &StreamProtocol.canonicalize_native_codex_responses_json_message/1
    }
  end

  defp payload(turn_id, thread_id) do
    metadata =
      %{"turn_id" => turn_id, "request_kind" => "turn"}
      |> then(&if(thread_id, do: Map.put(&1, "thread_id", thread_id), else: &1))

    %{
      "type" => "response.create",
      "client_metadata" => %{
        "turn_id" => turn_id,
        "x-codex-turn-metadata" => CodexPooler.JSON.encode!(metadata)
      }
    }
  end

  defp blocking_upstream(parent) do
    %{
      start: fn ->
        pid =
          spawn(fn ->
            receive do
              :stop -> :ok
            end
          end)

        send(parent, {:thread_scope_upstream_started, pid})
        {:ok, pid}
      end,
      send: fn _upstream_pid, _request, _writer ->
        send(parent, {:thread_scope_upstream_send, self()})

        receive do
          :never -> :ok
        end
      end,
      invalidate: fn _upstream_pid -> :ok end,
      close: fn pid ->
        send(pid, :stop)
        :ok
      end
    }
  end

  defp stop_owner(codex_session_id) do
    case WebsocketOwnerSession.lookup(codex_session_id) do
      {:ok, owner} ->
        owner_ref = Process.monitor(owner)
        _result = GenServer.stop(owner, :normal, @owner_shutdown_timeout_ms)

        receive do
          {:DOWN, ^owner_ref, :process, ^owner, _reason} -> :ok
        after
          @owner_shutdown_timeout_ms -> flunk("websocket owner did not terminate during test cleanup")
        end

      {:error, :owner_unavailable} ->
        :ok
    end
  catch
    :exit, _reason -> :ok
  end
end
