defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocket.PostvisibleCompletedItemResendTest do
  # A native websocket turn cut after its socket pushed the client a completed
  # item (`response.output_item.done`) and no terminal. The released Codex
  # client records that item in its history and resends the turn under the same
  # turn id as the original request with the item appended (measured with Codex
  # 0.156.1 through a recording proxy: the resend is the original's items plus
  # the completed item, re-serialized without its `status` and its content
  # parts' `annotations` and `logprobs`). A direct provider serves it; the
  # Pooler's `codex-turn:` fence refused it `409 duplicate_turn` on every
  # websocket retry and over HTTPS, and the turn failed (findings#232 row
  # 232-232). The grown resend is now admitted as one linked successor when it
  # is exactly the predecessor plus the completed items its delivery receipt
  # names; an appended item that is not one of them, or an extra item, keeps
  # the fence.
  #
  # Everything runs through the real listener and the real owner (forwarding
  # on) or direct task (forwarding off); the fake provider holds its stream at a
  # frame barrier right after the completed item, so what the socket pushed is
  # exactly the cut shape. Only the resend timing is simplified: it is sent once
  # the original settled and its receipt was recorded (the released client's
  # own retries are the real-client lanes' job).
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 1, public_websocket_connect!: 3, public_websocket_receive_text!: 3, public_websocket_send_text!: 4, start_public_endpoint!: 0, start_upstream: 1]

  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3]
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketOwnerForwardingSupport, only: [enter_peer_owner_topology!: 0, start_peer_session_owner!: 2]

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request, RequestClientRetryLink}
  alias CodexPooler.CompatibilityMatrix
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.CodexTurn
  alias CodexPooler.Platform.ExecutionTerminalProofs
  alias CodexPooler.Repo
  alias CodexPoolerWeb.CodexResponsesSocket
  alias CodexPoolerWeb.Runtime.CleanupProofRace

  @timeout_ms 15_000
  @poll_ms 100
  # provenance: observed findings#232 row 232-231 (the released client's Lite websocket frame carries the marker in client_metadata, its HTTPS fallback a header)
  @websocket_lite_marker "ws_request_header_x_openai_internal_codex_responses_lite"
  # With owner forwarding off the closing socket used to leave a direct task
  # that had pushed a completed item running for its whole 5 s post-cleanup
  # grace after the 250 ms drain, so with the provider held its receipt could
  # not exist before about 5.25 s, and the original generation ran beside the
  # served successor (findings#232 row 232-257); such a task is now stopped at
  # the cleanup, like the owner cancels its active turn at the detach. The
  # budget sits below that floor and far above the stop's own cost.
  @stopped_receipt_budget_ms 4_000
  # The frames up to and including the completed item, as the released client
  # received them before the cut (findings#232 row 232-232).
  @item_text "completed answer"

  for forwarding <- [true, false, :peer] do
    for transport <- [:websocket, :https] do
      @tag forwarding: forwarding, transport: transport, post_compaction_mailbox: true
      @tag slow: "a Full post-compaction reasoning cut, mailbox continuation and duplicate control through the real socket"
      test "owner forwarding #{forwarding}: a post-compaction mailbox continuation is served once over #{transport}", %{forwarding: forwarding, transport: transport} do
        contract = CompatibilityMatrix.by_slug!(:duplicate_turn_fence).duplicate_turn.mailbox_resume
        %{setup: setup, upstream: upstream, request_id: request_id, resend: resend, receipt: receipt, port: port, turn_state: turn_state, resend_payload: payload} = scenario!(forwarding, :held, :mailbox, transport)

        case transport do
          :websocket -> assert resend["type"] == "response.completed"
          :https -> assert {200, _body} = resend
        end

        assert %{"completed_items" => 1, "highest_frame_class" => "item_done", "terminal_class" => "none"} = receipt
        assert [%Request{id: ^request_id, status: "failed", last_error_code: "client_disconnected", correlation_id: original_claim}, %Request{status: "succeeded", correlation_id: continuation_claim}] = pool_requests(setup.pool.id)
        assert String.starts_with?(original_claim, contract.original_prefix)
        assert String.starts_with?(continuation_claim, contract.successor_prefix)
        assert original_claim != continuation_claim
        assert FakeUpstream.count(upstream) == 2

        changed = update_in(payload["input"], fn input -> input ++ [%{"type" => "message", "role" => "assistant", "content" => "changed history"}] end)

        case resend!(transport, port, setup, turn_state, changed) do
          %{"type" => "error", "error" => %{"code" => "duplicate_turn"}} -> :ok
          {409, body} -> assert %{"error" => %{"code" => "duplicate_turn"}} = CodexPooler.JSON.decode!(body)
          _unexpected -> flunk("the changed mailbox continuation was not fenced")
        end

        assert length(pool_requests(setup.pool.id)) == 2
        assert FakeUpstream.count(upstream) == 2
      end
    end
  end

  for forwarding <- [true, false], transport <- [:websocket, :https] do
    @tag forwarding: forwarding, transport: transport
    @tag slow: "real item-done cut followed by a second socket or HTTPS resend"
    test "an identical resend after an unread completed item is chained (#{forwarding}, #{transport})", %{forwarding: forwarding, transport: transport} do
      %{setup: setup, upstream: upstream, request_id: request_id, resend: resend} = scenario!(forwarding, :held, :identical, transport)

      case transport do
        :websocket -> assert resend["type"] == "response.completed"
        :https -> assert {200, _body} = resend
      end

      assert [%Request{id: ^request_id}, %Request{id: successor_id, status: "succeeded"}] = pool_requests(setup.pool.id)
      assert [%RequestClientRetryLink{predecessor_request_id: ^request_id, successor_request_id: ^successor_id}] = Repo.all(RequestClientRetryLink)
      assert_one_settlement_each!([request_id, successor_id])
      assert FakeUpstream.count(upstream) == 2
    end
  end

  for forwarding <- [true, false], code <- ["owner_drained", "dead_execution_recovered"] do
    @tag forwarding: forwarding, code: code
    @tag slow: "real item-done socket cut with a metadata-only terminal settlement variant and grown resend"
    test "a grown resend keeps retained items after #{code} (#{forwarding})", %{forwarding: forwarding, code: code} do
      %{setup: setup, upstream: upstream, request_id: request_id, resend: resend} = scenario!(forwarding, :held, :grown, :websocket, settlement_variant: code)
      assert resend["type"] == "response.completed"
      assert [%Request{id: ^request_id, last_error_code: ^code}, %Request{id: successor_id, status: "succeeded"}] = pool_requests(setup.pool.id)
      assert [%RequestClientRetryLink{predecessor_request_id: ^request_id, successor_request_id: ^successor_id}] = Repo.all(RequestClientRetryLink)
      assert FakeUpstream.count(upstream) == 2
    end
  end

  # The same cut inside an ordinary turn: the opener pushed a commentary
  # message, mail addressed to the agent arrived, and the client resends the
  # turn under its bare `codex-turn:` claim with the message (re-serialized
  # without `status` and `annotations`) and the mail appended.
  for forwarding <- [true, false] do
    for transport <- [:websocket, :https] do
      @tag forwarding: forwarding, transport: transport, ordinary_turn_mailbox: true
      @tag slow: "an ordinary turn's commentary cut, mailbox continuation and duplicate control through the real socket"
      test "owner forwarding #{forwarding}: an ordinary turn's mailbox continuation is served once over #{transport}", %{forwarding: forwarding, transport: transport} do
        %{setup: setup, upstream: upstream, request_id: request_id, resend: resend, receipt: receipt, port: port, turn_state: turn_state, resend_payload: payload} = scenario!(forwarding, :held, :ordinary_mailbox, transport)

        case transport do
          :websocket -> assert resend["type"] == "response.completed"
          :https -> assert {200, _body} = resend
        end

        assert %{"completed_items" => 1, "highest_frame_class" => "item_done", "terminal_class" => "none"} = receipt
        assert [%Request{id: ^request_id, status: "failed", last_error_code: "client_disconnected", correlation_id: "codex-turn:" <> _turn}, %Request{id: successor_id, status: "succeeded", correlation_id: successor_claim}] = pool_requests(setup.pool.id)
        # With owner forwarding on, the owner's preflight chains a websocket resend under its own successor claim.
        assert String.starts_with?(successor_claim, if(forwarding and transport == :websocket, do: "client-retry-v1:", else: "codex-request-retry:"))
        assert [%RequestClientRetryLink{predecessor_request_id: ^request_id, successor_request_id: ^successor_id}] = Repo.all(RequestClientRetryLink)
        assert_one_settlement_each!([request_id, successor_id])
        assert FakeUpstream.count(upstream) == 2

        changed = update_in(payload["input"], fn input -> input ++ [%{"type" => "message", "role" => "assistant", "content" => "changed history"}] end)

        case resend!(transport, port, setup, turn_state, changed) do
          %{"type" => "error", "error" => %{"code" => "duplicate_turn"}} -> :ok
          {409, body} -> assert %{"error" => %{"code" => "duplicate_turn"}} = CodexPooler.JSON.decode!(body)
          _unexpected -> flunk("the changed mailbox continuation was not fenced")
        end

        assert length(pool_requests(setup.pool.id)) == 2
        assert FakeUpstream.count(upstream) == 2
      end
    end

    @tag forwarding: forwarding
    @tag slow: "an ordinary turn's commentary cut and a mailbox resend whose delivered message differs"
    test "owner forwarding #{forwarding}: an ordinary turn's mailbox resend with a changed message stays a duplicate", %{forwarding: forwarding} do
      %{setup: setup, upstream: upstream, request_id: request_id, resend: resend} = scenario!(forwarding, :held, :ordinary_mailbox_changed)

      assert %{"type" => "error", "error" => %{"code" => "duplicate_turn"}} = resend
      assert [%Request{id: ^request_id}] = pool_requests(setup.pool.id)
      assert Repo.all(RequestClientRetryLink) == []
      assert FakeUpstream.count(upstream) == 1
    end
  end

  for forwarding <- [true, false] do
    @tag forwarding: forwarding
    @tag slow: "a real socket cut after a completed item, its owner or direct cleanup, the recorded receipt and a second socket's resend"
    test "owner forwarding #{forwarding}: the grown resend after a completed item whose provider was still generating is served as one successor", %{forwarding: forwarding} do
      %{setup: setup, upstream: upstream, request_id: request_id, resend: resend, receipt: receipt} = scenario!(forwarding, :held, :grown)

      assert resend["type"] == "response.completed"
      assert [%Request{id: ^request_id, status: "failed", last_error_code: "client_disconnected"}, %Request{id: successor_id, status: "succeeded"}] = pool_requests(setup.pool.id)
      assert %CodexTurn{status: "interrupted", first_visible_output_at: %DateTime{}} = Repo.get_by!(CodexTurn, request_id: request_id)
      assert [%RequestClientRetryLink{predecessor_request_id: ^request_id, successor_request_id: ^successor_id}] = Repo.all(RequestClientRetryLink)
      assert_one_settlement_each!([request_id, successor_id])
      # The cut generation was stopped (the owner's detach, or with forwarding off
      # the closing socket's cleanup), so the provider released afterwards never
      # completed it beside the served successor: no late answer corrected the
      # original's settlement (findings#232 row 232-257).
      assert Repo.all(from(l in LedgerEntry, where: l.request_id == ^request_id and l.amount_status == "voided")) == []
      assert %Request{usage_status: "usage_unknown"} = Repo.get!(Request, request_id)
      # Lite rewrites what reaches the provider; the successor carries the original's items plus the completed item.
      assert [%{json: %{"input" => original_input}}, %{json: %{"input" => successor_input}}] = FakeUpstream.requests(upstream)
      assert successor_input == original_input ++ [client_recorded_item(@item_text)]
      assert %{"outcome" => "aborted", "terminal_class" => "none", "highest_frame_class" => "item_done", "completed_items" => 1, "completed_item_digests" => [digest]} = receipt
      assert digest =~ ~r/\A[0-9a-f]{12}\z/
    end

    @tag forwarding: forwarding
    @tag slow: "a real socket cut after a completed item, the provider completing after it, the recorded receipt and a second socket's resend"
    test "owner forwarding #{forwarding}: the grown resend after a completed item the provider completed afterwards is served as one successor", %{forwarding: forwarding} do
      %{setup: setup, upstream: upstream, request_id: request_id, resend: resend} = scenario!(forwarding, :completes, :grown)

      assert resend["type"] == "response.completed"
      assert [%Request{id: ^request_id, status: "succeeded"}, %Request{id: successor_id, status: "succeeded"}] = pool_requests(setup.pool.id)
      assert [%RequestClientRetryLink{predecessor_request_id: ^request_id, successor_request_id: ^successor_id}] = Repo.all(RequestClientRetryLink)
      assert_one_settlement_each!([request_id, successor_id])
      assert FakeUpstream.count(upstream) == 2
    end

    @tag forwarding: forwarding
    @tag slow: "a real socket cut after a completed item, its cleanup, the recorded receipt and the HTTPS fallback resend"
    test "owner forwarding #{forwarding}: the HTTPS fallback of the grown resend is served as one successor", %{forwarding: forwarding} do
      %{setup: setup, upstream: upstream, request_id: request_id, resend: resend} = scenario!(forwarding, :held, :grown, :https)

      assert {200, body} = resend
      assert body =~ "response.completed"
      assert [%Request{id: ^request_id, status: "failed"}, %Request{id: successor_id, status: "succeeded", transport: "http_sse"}] = pool_requests(setup.pool.id)
      assert [%RequestClientRetryLink{predecessor_request_id: ^request_id, successor_request_id: ^successor_id}] = Repo.all(RequestClientRetryLink)
      assert_one_settlement_each!([request_id, successor_id])
      assert FakeUpstream.count(upstream) == 2
    end

    # The appended item is not the one the socket pushed (its text differs), so
    # the resend is not the grown resend of this turn.
    @tag forwarding: forwarding
    @tag slow: "a real socket cut after a completed item, its cleanup, the recorded receipt and a second socket's resend"
    test "owner forwarding #{forwarding}: a resend whose appended item is not the pushed completed item stays a duplicate", %{forwarding: forwarding} do
      %{setup: setup, upstream: upstream, request_id: request_id, resend: resend} = scenario!(forwarding, :held, :mismatched)

      assert %{"type" => "error", "error" => %{"code" => "duplicate_turn"}} = resend
      assert [%Request{id: ^request_id}] = pool_requests(setup.pool.id)
      assert Repo.all(RequestClientRetryLink) == []
      assert FakeUpstream.count(upstream) == 1
    end

    @tag forwarding: forwarding
    @tag slow: "a real socket cut after a completed item, its cleanup, the recorded receipt and a second socket's resend"
    test "owner forwarding #{forwarding}: a resend that appends more than the pushed completed items stays a duplicate", %{forwarding: forwarding} do
      %{setup: setup, upstream: upstream, request_id: request_id, resend: resend} = scenario!(forwarding, :held, :extra)

      assert %{"type" => "error", "error" => %{"code" => "duplicate_turn"}} = resend
      assert [%Request{id: ^request_id}] = pool_requests(setup.pool.id)
      assert Repo.all(RequestClientRetryLink) == []
      assert FakeUpstream.count(upstream) == 1
    end

    @tag forwarding: forwarding
    @tag slow: "a real socket cut after a completed item, its cleanup, the recorded receipt and the HTTPS fallback resend"
    test "owner forwarding #{forwarding}: the HTTPS fallback whose appended item is not the pushed completed item stays a duplicate", %{forwarding: forwarding} do
      %{setup: setup, upstream: upstream, request_id: request_id, resend: resend} = scenario!(forwarding, :held, :mismatched, :https)

      assert {409, body} = resend
      assert %{"error" => %{"code" => "duplicate_turn"}} = CodexPooler.JSON.decode!(body)
      assert [%Request{id: ^request_id}] = pool_requests(setup.pool.id)
      assert FakeUpstream.count(upstream) == 1
    end
  end

  # The closing socket stops the direct task that pushed the completed item,
  # then interrupts its request `client_disconnected`. When the stopped task's
  # terminal proof lands between the two (the production publisher, a few
  # milliseconds, `CleanupProofRace`), the interrupt used to take the stop for
  # a lost executor and settle `dead_execution_recovered`. The continuation
  # and the grown resend are admitted against the disconnect and its receipt,
  # so they were refused `duplicate_turn` and the turn was lost (findings#270
  # row 270-353). The socket knows why the task ended, so the request keeps
  # its reason and the resend is served.
  for shape <- [:mailbox, :grown], transport <- [:websocket, :https] do
    @tag shape: shape, transport: transport
    @tag slow: "a real socket cut after a completed item, the stopped task's proof published before the cleanup interrupts, and the resend"
    test "owner forwarding false: the #{shape} #{transport} resend is served once when the stopped task's end is proven before the cleanup interrupts it", %{shape: shape, transport: transport} do
      %{setup: setup, upstream: upstream, request_id: request_id, resend: resend, proven_attempt_id: attempt_id} =
        scenario!(false, :held, shape, transport, proof_before_cleanup: true)

      assert ExecutionTerminalProofs.terminal?(Repo.get!(Attempt, attempt_id))

      case transport do
        :websocket -> assert resend["type"] == "response.completed"
        :https -> assert {200, _body} = resend
      end

      assert [%Request{id: ^request_id, status: "failed", response_status_code: 499, last_error_code: "client_disconnected"}, %Request{id: successor_id, status: "succeeded"}] = pool_requests(setup.pool.id)
      assert %CodexTurn{status: "interrupted", error_code: "client_disconnected"} = Repo.get_by!(CodexTurn, request_id: request_id)
      if shape == :grown, do: assert([%RequestClientRetryLink{predecessor_request_id: ^request_id, successor_request_id: ^successor_id}] = Repo.all(RequestClientRetryLink))
      assert FakeUpstream.count(upstream) == 2
    end
  end

  defp scenario!(forwarding, provider, resend_shape, resend_transport \\ :websocket, opts \\ []) do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, false)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, forwarding != false)
    release_ref = make_ref()
    served? = resend_shape in [:identical, :grown, :mailbox, :ordinary_mailbox]
    ordinary? = resend_shape in [:ordinary_mailbox, :ordinary_mailbox_changed]
    mailbox? = resend_shape == :mailbox or ordinary?

    frames = scenario_frames(ordinary?, mailbox?)
    hold_at = length(frames) - 1

    upstream =
      start_upstream(
        FakeUpstream.strict_sequence(
          [native_request(FakeUpstream.barrier_websocket_frames(frames, notify: self(), release_ref: release_ref))] ++
            if(served?, do: [successor_request(resend_transport)], else: [])
        )
      )

    setup = topology_setup(upstream, forwarding)
    if not mailbox?, do: set_model_serving_mode!(model_serving_scope(), setup, "lite")
    turn_state = Ecto.UUID.generate()
    peer = if forwarding == :peer, do: start_peer_session_owner!(setup, %{accepted_turn_state: turn_state})
    payload = scenario_payload(native_turn_payload(Ecto.UUID.generate(), setup.model.exposed_model_id), ordinary?, mailbox?)
    port = start_public_endpoint!()

    {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state)
    {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, CodexPooler.JSON.encode!(payload))

    for ordinal <- 0..(hold_at - 1) do
      assert_receive {:fake_upstream_frame_barrier, ^ordinal, _handler, ^release_ref}, @timeout_ms
      :ok = FakeUpstream.release_frame(upstream, release_ref)
    end

    # The barrier notification is read before any socket frame: the socket
    # helpers consume every message they do not recognise.
    assert_receive {:fake_upstream_frame_barrier, ^hold_at, _handler, ^release_ref}, @timeout_ms
    conn = receive_until!(conn, websocket, ref, "response.output_item.done")
    assert [%Request{id: request_id} = original] = pool_requests(setup.pool.id)
    if mailbox?, do: assert(original.request_metadata["routing"]["model_serving_mode"] == "full")

    assert_peer_forwarding(original, peer)

    {receipt, proven_attempt_id} = CleanupProofRace.around_cut(opts, request_id, fn -> close_and_await_receipt!(conn, request_id, provider, upstream, release_ref) end)
    _settled = await_settled!(request_id, System.monotonic_time(:millisecond) + @timeout_ms)

    if code = Keyword.get(opts, :settlement_variant) do
      {1, _} = Repo.update_all(from(r in Request, where: r.id == ^request_id), set: [last_error_code: code])
      {1, _} = Repo.update_all(from(t in CodexTurn, where: t.request_id == ^request_id), set: [error_code: code])
      {1, _} = Repo.update_all(from(a in Attempt, where: a.request_id == ^request_id), set: [network_error_code: code])
    end

    resend_payload = resend_payload(payload, resend_shape)
    resend = resend!(resend_transport, port, setup, turn_state, resend_payload)

    await_all_settled!(setup.pool.id, System.monotonic_time(:millisecond) + @timeout_ms)
    %{setup: setup, upstream: upstream, request_id: request_id, resend: resend, receipt: receipt, port: port, turn_state: turn_state, resend_payload: resend_payload, proven_attempt_id: proven_attempt_id}
  end

  defp scenario_frames(true = _ordinary?, _mailbox?), do: commentary_stream_frames()
  defp scenario_frames(false, true = _mailbox?), do: reasoning_stream_frames()
  defp scenario_frames(false, false), do: stream_frames("resp_completed_item_original")

  defp scenario_payload(payload, true = _ordinary?, _mailbox?), do: mailbox_agent_payload(payload)
  defp scenario_payload(payload, false, true = _mailbox?), do: mailbox_resume_payload(payload)
  defp scenario_payload(payload, false, false), do: payload

  defp topology_setup(upstream, :peer) do
    enter_peer_owner_topology!()
    gateway_setup(upstream)
  end

  defp topology_setup(upstream, _forwarding), do: gateway_setup(upstream)

  defp assert_peer_forwarding(_original, nil), do: :ok

  defp assert_peer_forwarding(original, peer) do
    forwarding = original.request_metadata["websocket_owner_forwarding"]
    assert forwarding["owner_instance_id"] == Atom.to_string(peer.node)
    assert forwarding["owner_instance_id"] != forwarding["proxy_instance_id"]
  end

  # provenance: observed findings#232 row 232-232 (Codex 0.156.1 through a recording proxy: the resend appends the completed item as its own model re-serializes it, without `status` and the parts' `annotations` and `logprobs`, keeping the id; every other field unchanged except the restamped request-start metadata)
  defp resend_payload(payload, shape) do
    payload
    |> Map.update!("input", &(&1 ++ appended_items(shape)))
    |> put_in(["client_metadata", "x-codex-ws-stream-request-start-ms"], 2_000)
  end

  defp appended_items(:identical), do: []
  defp appended_items(:grown), do: [client_recorded_item(@item_text)]
  defp appended_items(:mismatched), do: [client_recorded_item(@item_text <> " altered")]
  defp appended_items(:extra), do: [client_recorded_item(@item_text), client_recorded_item(@item_text)]
  defp appended_items(:mailbox), do: [reasoning_item() | Enum.map(1..5, fn n -> %{"type" => "agent_message", "author" => "/root/worker", "recipient" => "/root", "content" => [%{"type" => "input_text", "text" => "synthetic task update #{n}"}]} end)]

  defp appended_items(:ordinary_mailbox), do: [commentary_item(), mailbox_item(1), mailbox_item(2)]
  defp appended_items(:ordinary_mailbox_changed), do: [put_in(commentary_item(), ["content", Access.at(0), "text"], "changed"), mailbox_item(1)]

  defp mailbox_resume_payload(payload) do
    payload
    |> mailbox_agent_payload()
    |> Map.update!("input", &(&1 ++ [%{"type" => "compaction", "encrypted_content" => "synthetic-compaction"}]))
  end

  defp mailbox_agent_payload(payload) do
    payload
    |> Map.update!("client_metadata", &Map.delete(&1, @websocket_lite_marker))
    |> update_in(["client_metadata", "x-codex-turn-metadata"], fn metadata -> metadata |> CodexPooler.JSON.decode!() |> Map.put("agent_name", "/root") |> CodexPooler.JSON.encode!() end)
  end

  defp mailbox_item(n), do: %{"type" => "agent_message", "author" => "/root/worker", "recipient" => "/root", "content" => [%{"type" => "input_text", "text" => "synthetic task update #{n}"}]}

  # As the client resends it: without the pushed item's `status` and the part's
  # `annotations` and `logprobs`.
  defp commentary_item, do: %{"id" => "msg_mailbox_commentary", "type" => "message", "role" => "assistant", "phase" => "commentary", "content" => [%{"type" => "output_text", "text" => "checking the workers"}]}

  defp commentary_stream_frames do
    item = commentary_item() |> Map.put("status", "completed") |> put_in(["content", Access.at(0)], %{"type" => "output_text", "text" => "checking the workers", "annotations" => [], "logprobs" => []})

    Enum.map(
      [
        %{"type" => "response.created", "response" => %{"id" => "resp_mailbox_commentary", "status" => "in_progress", "output" => []}},
        %{"type" => "response.output_item.added", "output_index" => 0, "item" => Map.merge(item, %{"status" => "in_progress", "content" => []})},
        %{"type" => "response.output_item.done", "output_index" => 0, "item" => item},
        %{"type" => "response.completed", "response" => %{"id" => "resp_mailbox_commentary", "status" => "completed", "output" => [item], "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}}}
      ],
      &CodexPooler.JSON.encode!/1
    )
  end

  defp reasoning_item, do: %{"type" => "reasoning", "id" => "rs_mailbox_original", "summary" => [%{"type" => "summary_text", "text" => "synthetic reasoning"}], "encrypted_content" => "synthetic-reasoning"}

  defp reasoning_stream_frames do
    item = reasoning_item()

    Enum.map(
      [
        %{"type" => "response.created", "response" => %{"id" => "resp_mailbox_original", "status" => "in_progress", "output" => []}},
        %{"type" => "response.output_item.added", "output_index" => 0, "item" => Map.put(item, "summary", [])},
        %{"type" => "response.output_item.done", "output_index" => 0, "item" => item},
        %{"type" => "response.completed", "response" => %{"id" => "resp_mailbox_original", "status" => "completed", "output" => [item], "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}}}
      ],
      &CodexPooler.JSON.encode!/1
    )
  end

  defp client_recorded_item(text),
    do: %{"id" => "msg_resp_completed_item_original", "type" => "message", "role" => "assistant", "content" => [%{"type" => "output_text", "text" => text}]}

  # The provider completes only once the closing socket entered `terminate`
  # and pushes nothing more; released earlier, the socket could still write the
  # terminal into the closed connection, which is a turn the client was pushed
  # a terminal of (the fence stays).
  defp close_and_await_receipt!(conn, request_id, :completes, upstream, release_ref) do
    trace_socket_terminate!()
    _closed = Mint.HTTP.close(conn)
    assert_receive {:trace, _socket, :call, {CodexResponsesSocket, :terminate, [_reason, _state]}}, @timeout_ms
    stop_socket_terminate_trace()
    :ok = FakeUpstream.release_remaining_frames(upstream, release_ref)
    _settled = await_settled!(request_id, System.monotonic_time(:millisecond) + @timeout_ms)
    await_receipt!(request_id, System.monotonic_time(:millisecond) + @timeout_ms)
  end

  # Nothing releases the provider until the original's generation was stopped
  # (the owner's detach, or the closing socket's cleanup with forwarding off)
  # and the original settled. The receipt alone is not that signal: with
  # forwarding on the socket records it before its session cleanup detaches
  # from the owner, so when that cleanup outlasted the socket's 100 ms yield
  # the provider was released into a turn nothing had stopped yet, and the
  # original completed `succeeded` (findings#206 row 206-425).
  defp close_and_await_receipt!(conn, request_id, :held, upstream, release_ref) do
    _closed = Mint.HTTP.close(conn)
    receipt = await_receipt!(request_id, System.monotonic_time(:millisecond) + @stopped_receipt_budget_ms)
    _settled = await_settled!(request_id, System.monotonic_time(:millisecond) + @timeout_ms)
    :ok = FakeUpstream.release_remaining_frames(upstream, release_ref)
    receipt
  end

  defp resend!(:websocket, port, setup, turn_state, payload), do: send_and_receive_terminal!(port, setup, turn_state, CodexPooler.JSON.encode!(payload))
  defp resend!(:https, _port, setup, turn_state, payload), do: post_https_fallback!(setup, turn_state, payload)

  defp trace_socket_terminate! do
    on_exit(&stop_socket_terminate_trace/0)
    _matched = :erlang.trace_pattern({CodexResponsesSocket, :terminate, 2}, true, [:local])
    _traced = :erlang.trace(:all, true, [:call, {:tracer, self()}])
    :ok
  end

  defp stop_socket_terminate_trace do
    _traced = :erlang.trace(:all, false, [:call])
    _matched = :erlang.trace_pattern({CodexResponsesSocket, :terminate, 2}, false, [:local])
    :ok
  end

  defp assert_one_settlement_each!(request_ids) do
    for id <- request_ids do
      assert Repo.all(from(l in LedgerEntry, where: l.request_id == ^id and l.amount_status == "recorded", select: l.entry_kind)) |> Enum.frequencies() ==
               %{"reservation" => 1, "settlement" => 1, "release" => 1}
    end
  end

  defp successor_request(:websocket), do: native_request(FakeUpstream.websocket_text_frames(stream_frames("resp_completed_item_successor")))

  defp successor_request(:https) do
    FakeUpstream.expect_request(
      method: "POST",
      path: "/backend-api/codex/responses",
      respond: FakeUpstream.sse_stream(Enum.map(stream_frames("resp_completed_item_successor"), &CodexPooler.JSON.decode!/1))
    )
  end

  # The released client's HTTPS fallback of the websocket request: the same body
  # without the frame's `type` and without the websocket-only client metadata,
  # the Lite marker sent as a header (findings#232 row 232-231).
  defp post_https_fallback!(setup, turn_state, payload) do
    body =
      payload
      |> Map.delete("type")
      |> Map.update!("client_metadata", &Map.drop(&1, ["x-codex-ws-stream-request-start-ms", @websocket_lite_marker]))

    conn =
      build_conn()
      |> put_req_header("authorization", setup.authorization)
      |> put_req_header("x-codex-turn-state", turn_state)
      |> maybe_lite_header(payload)
      |> put_req_header("content-type", "application/json")
      |> post("/backend-api/codex/responses", CodexPooler.JSON.encode!(body))

    {conn.status, conn.resp_body}
  end

  defp maybe_lite_header(conn, %{"client_metadata" => %{@websocket_lite_marker => "true"}}), do: put_req_header(conn, "x-openai-internal-codex-responses-lite", "true")
  defp maybe_lite_header(conn, _payload), do: conn

  defp native_request(respond) do
    FakeUpstream.expect_request(method: "WEBSOCKET", path: "/backend-api/codex/responses", json: [valid: true, equals: %{"type" => "response.create"}], respond: respond)
  end

  defp stream_frames(response_id) do
    item_id = "msg_" <> response_id
    item = %{"id" => item_id, "type" => "message", "role" => "assistant", "status" => "completed", "content" => [%{"type" => "output_text", "text" => @item_text, "annotations" => [], "logprobs" => []}]}

    Enum.map(
      [
        %{"type" => "response.created", "response" => %{"id" => response_id, "status" => "in_progress", "output" => []}},
        %{"type" => "response.in_progress", "response" => %{"id" => response_id, "status" => "in_progress", "output" => []}},
        %{"type" => "response.output_item.added", "output_index" => 0, "item" => %{"id" => item_id, "type" => "message", "role" => "assistant", "status" => "in_progress", "content" => []}},
        %{"type" => "response.content_part.added", "item_id" => item_id, "output_index" => 0, "content_index" => 0, "part" => %{"type" => "output_text", "text" => "", "annotations" => []}},
        %{"type" => "response.output_text.delta", "item_id" => item_id, "output_index" => 0, "content_index" => 0, "delta" => "completed "},
        %{"type" => "response.output_text.delta", "item_id" => item_id, "output_index" => 0, "content_index" => 0, "delta" => "answer"},
        %{"type" => "response.output_text.done", "item_id" => item_id, "output_index" => 0, "content_index" => 0, "text" => @item_text},
        %{"type" => "response.content_part.done", "item_id" => item_id, "output_index" => 0, "content_index" => 0, "part" => %{"type" => "output_text", "text" => @item_text, "annotations" => []}},
        %{"type" => "response.output_item.done", "output_index" => 0, "item" => item},
        %{"type" => "response.completed", "response" => %{"id" => response_id, "status" => "completed", "output" => [item], "usage" => %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}}}
      ],
      &CodexPooler.JSON.encode!/1
    )
  end

  defp native_turn_payload(thread_id, model) do
    %{
      "type" => "response.create",
      "model" => model,
      "instructions" => "synthetic base instructions",
      "stream" => true,
      "store" => false,
      "client_metadata" => %{
        "session_id" => thread_id,
        "thread_id" => thread_id,
        "turn_id" => "completed-item-turn",
        "x-codex-window-id" => thread_id <> ":0",
        "x-codex-turn-metadata" => CodexPooler.JSON.encode!(%{"session_id" => thread_id, "thread_id" => thread_id, "turn_id" => "completed-item-turn", "request_kind" => "turn"}),
        "x-codex-ws-stream-request-start-ms" => 100,
        @websocket_lite_marker => "true"
      },
      "input" => [%{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic completed item turn"}]}]
    }
  end

  defp send_and_receive_terminal!(port, setup, turn_state, raw_payload) do
    {conn, websocket, ref} = public_websocket_connect!(port, setup, turn_state)
    {conn, websocket} = public_websocket_send_text!(conn, websocket, ref, raw_payload)
    {conn, frame} = receive_terminal!(conn, websocket, ref)
    _closed = Mint.HTTP.close(conn)
    frame
  end

  defp receive_until!(conn, websocket, ref, type) do
    {conn, websocket, text} = public_websocket_receive_text!(conn, websocket, ref)
    if CodexPooler.JSON.decode!(text)["type"] == type, do: conn, else: receive_until!(conn, websocket, ref, type)
  end

  defp receive_terminal!(conn, websocket, ref) do
    {conn, websocket, text} = public_websocket_receive_text!(conn, websocket, ref)
    frame = CodexPooler.JSON.decode!(text)

    if frame["type"] in ["response.completed", "response.failed", "response.incomplete", "error"],
      do: {conn, frame},
      else: receive_terminal!(conn, websocket, ref)
  end

  defp pool_requests(pool_id), do: Repo.all(from(r in Request, where: r.pool_id == ^pool_id, order_by: [asc: r.admitted_at]))

  # The closing socket's own cleanup can hold the shared sandbox connection
  # longer than a checkout waits under load; a dropped checkout is retried, and
  # the polls are spaced so the test's own reads do not crowd the queue the
  # socket, its task and the owner settle through.
  defp await_receipt!(request_id, deadline_ms) do
    case Repo.all(from(a in Attempt, where: a.request_id == ^request_id)) do
      [%Attempt{response_metadata: %{"downstream_delivery" => %{} = receipt}}] ->
        receipt

      _pending ->
        if System.monotonic_time(:millisecond) >= deadline_ms,
          do: flunk("no delivery receipt for #{request_id} within the budget"),
          else: Process.sleep(@poll_ms) && await_receipt!(request_id, deadline_ms)
    end
  end

  defp await_settled!(request_id, deadline_ms) do
    case Repo.all(from(r in Request, where: r.id == ^request_id and r.status != "in_progress")) do
      [%Request{} = request] ->
        request

      _pending ->
        if System.monotonic_time(:millisecond) >= deadline_ms,
          do: flunk("request never settled"),
          else: Process.sleep(@poll_ms) && await_settled!(request_id, deadline_ms)
    end
  end

  defp await_all_settled!(pool_id, deadline_ms) do
    requests = Repo.all(from(r in Request, where: r.pool_id == ^pool_id))

    cond do
      requests != [] and Enum.all?(requests, &(&1.status != "in_progress")) -> :ok
      System.monotonic_time(:millisecond) >= deadline_ms -> flunk("requests never settled")
      true -> Process.sleep(@poll_ms) && await_all_settled!(pool_id, deadline_ms)
    end
  end
end
