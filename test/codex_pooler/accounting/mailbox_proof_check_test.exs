defmodule CodexPooler.Accounting.MailboxProofCheckTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Accounting.{Attempt, ClientRetry, Request}
  alias CodexPooler.Gateway.Payloads.{NativeMailboxContinuation, RequestOptions, WebsocketTurnIdentity}
  alias CodexPooler.Gateway.Persistence.CodexTurn

  @semantic :crypto.hash(:sha256, "synthetic proof turn")
  @now ~U[2026-10-01 00:00:00.000000Z]
  @attempt_id "018f60df-713f-7ca8-b9a0-0d12c508a002"

  setup do
    %{proof: proof("websocket")}
  end

  @tag mailbox_proof_negative: true
  test "no_candidate precedes malformed settlement and authorization", %{proof: proof} do
    for witness <- [nil, %{}, %{proof.witness | mailbox: []}, %{proof.witness | mailbox: nil}, %{proof.witness | mailbox: [nil | :invalid]}] do
      assert ClientRetry.mailbox_check(nil, nil, nil, witness, nil, :rejected) == %{stage: :no_candidate}
      refute ClientRetry.verified_mailbox_continuation?(nil, nil, nil, witness, nil)
    end
  end

  for row <- [:turn, :request, :attempt] do
    @tag mailbox_proof_negative: true
    test "settlement rejects a nonterminal #{row}", %{proof: proof} do
      changed = Map.update!(proof, unquote(row), &%{&1 | completed_at: nil})
      assert_stage(changed, :settlement)
    end
  end

  @tag mailbox_proof_negative: true
  test "settlement binds transport, endpoint, generation zero and final attempt", %{proof: proof} do
    for changed <- [
          %{proof | turn: %{proof.turn | status: "failed"}},
          %{proof | request: %{proof.request | endpoint: "/v1/responses"}},
          %{proof | request: %{proof.request | transport: "http_sse"}},
          %{proof | attempt: %{proof.attempt | replay_generation: 1}},
          %{proof | attempt: %{proof.attempt | id: "other-attempt"}},
          %{proof | turn: nil},
          %{proof | request: %{}},
          %{proof | attempt: nil}
        ] do
      assert_stage(changed, :settlement)
    end
  end

  @tag mailbox_proof_negative: true
  test "authorization precedes session and binds witness version, eligibility and epoch", %{proof: proof} do
    for changed <- [
          %{proof | witness: %{proof.witness | version: 2}},
          %{proof | witness: %{proof.witness | auth_epoch: 2}},
          %{proof | request: %{proof.request | native_client_retry_version: nil}},
          %{proof | request: %{proof.request | native_client_retry_digest: <<1>>}},
          %{proof | request: %{proof.request | native_client_retry_auth_epoch: -1}}
        ] do
      assert_stage(changed, :authorization)
      assert check(changed, :rejected).stage == :authorization
    end
  end

  @tag mailbox_proof_negative: true
  test "session requires an explicitly trusted verdict", %{proof: proof} do
    for verdict <- [:rejected, nil, :unknown, %{}, "same_session"] do
      assert check(proof, verdict) == %{stage: :session}
    end

    for verdict <- [:same_session, :expired_replacement] do
      assert check(proof, verdict) == %{stage: :verified, candidate_index: 1}
    end

    assert ClientRetry.verified_mailbox_continuation?(proof.turn, proof.request, proof.attempt, proof.witness, nil)
  end

  @tag mailbox_proof_negative: true
  test "witness rejects changed prefix and malformed candidates without raising", %{proof: proof} do
    for candidate <- [nil, %{}, %{proof.candidate | prefix: nil}, %{proof.candidate | prefix: %{websocket: nil}}, %{proof.candidate | prefix: %{websocket: [nil | :invalid]}}, %{proof.candidate | prefix: %{websocket: [nil, <<1>>]}}, %{proof.candidate | prefix: %{websocket: [:crypto.hash(:sha256, "changed")]}}] do
      assert_stage(with_candidates(proof, [candidate]), :witness, 1)
    end
  end

  for transport <- ["websocket", "http_sse"] do
    @tag mailbox_proof_negative: true
    test "#{transport} malformed candidate output fails closed" do
      proof = proof(unquote(transport))

      for candidate <- [Map.delete(proof.candidate, :items), %{proof.candidate | items: nil, http_progress: []}, %{proof.candidate | items: ["invalid" | :invalid], http_progress: []}] do
        assert_stage(with_candidates(proof, [candidate]), :output_prefix, 1)
      end
    end
  end

  @tag mailbox_proof_negative: true
  test "ending requires current tail or the actual stored successor witness", %{proof: proof} do
    historical = with_candidates(proof, [%{proof.candidate | current?: false}])
    assert_stage(historical, :ending, 1)
    assert_stage(with_candidates(proof, [Map.delete(proof.candidate, :current?)]), :ending, 1)
    assert_stage(with_candidates(proof, [%{proof.candidate | current?: "true"}]), :ending, 1)

    successor = %{proof.request | native_client_retry_digest: hd(proof.candidate.ending.websocket)}
    assert check(historical, :same_session, successor).stage == :verified
    assert check(historical, :same_session, %{successor | native_client_retry_digest: proof.request.native_client_retry_digest}).stage == :ending
    assert check(historical, :same_session, %{successor | native_client_retry_version: 2}).stage == :ending
    assert check(historical, :same_session, %{}).stage == :ending
  end

  for transport <- ["websocket", "http_sse"] do
    test "#{transport} succeeded and interrupted real-codec proofs retain boolean acceptance" do
      proof = proof(unquote(transport))
      assert_stage(proof, :verified, 1)
      succeeded = %{proof | turn: %{proof.turn | status: "succeeded", error_code: nil}, request: %{proof.request | status: "succeeded", last_error_code: nil}, attempt: %{proof.attempt | status: "succeeded", network_error_code: nil}}
      assert_stage(succeeded, :verified, 1)
      assert Map.keys(check(proof)) |> Enum.sort() == [:candidate_index, :stage]
      refute Map.has_key?(ClientRetry.request_attrs(proof.witness), :mailbox)
    end

    @tag mailbox_proof_negative: true
    test "#{transport} output_prefix rejects changed, split, reordered and extra consumed items" do
      proof = proof(unquote(transport), [reasoning("first"), reasoning("second")])
      [first, second] = proof.candidate.items

      for items <- [[second], [second, first], [first, "changed"], ["changed", second], [], [first, second, "extra"]] do
        candidate = %{proof.candidate | items: items, http_progress: []}
        assert_stage(with_candidates(proof, [candidate]), :output_prefix, 1)
      end

      # A nonempty prefix may be shorter than the complete server-write receipt.
      assert_stage(with_candidates(proof, [%{proof.candidate | items: [first], http_progress: []}]), :verified, 1)
    end

    @tag mailbox_proof_negative: true
    test "#{transport} candidate A witness cannot combine with candidate B output" do
      proof = proof(unquote(transport))
      a = %{proof.candidate | items: ["changed"], http_progress: []}
      b = %{proof.candidate | prefix: %{websocket: [], http: nil}}
      assert_stage(with_candidates(proof, [a, b]), :output_prefix, 1)
      assert_stage(with_candidates(proof, [b, a]), :output_prefix, 2)
      assert_stage(with_candidates(proof, [a, proof.candidate]), :verified, 2)
    end
  end

  @tag mailbox_proof_negative: true
  test "furthest stage and ties identify one candidate without merging", %{proof: proof} do
    witness_failure = %{proof.candidate | prefix: %{websocket: []}}
    ending_failure = %{proof.candidate | current?: false}
    output_failure = %{proof.candidate | items: ["changed"]}
    assert_stage(with_candidates(proof, [witness_failure, ending_failure]), :ending, 2)
    assert_stage(with_candidates(proof, [ending_failure, witness_failure]), :ending, 1)
    assert_stage(with_candidates(proof, [output_failure, ending_failure, output_failure]), :output_prefix, 1)
  end

  for change <- [
        %{"outcome" => "unknown"},
        %{"terminal_class" => "response.failed"},
        %{"highest_frame_class" => "delta"},
        %{"completed_items" => 2},
        %{"completed_item_digests" => []}
      ] do
    @tag mailbox_proof_negative: true
    test "websocket output_prefix retains receipt fence #{inspect(change)}", %{proof: proof} do
      attempt = Map.update!(proof.attempt, :response_metadata, &Map.update!(&1, "downstream_delivery", fn receipt -> Map.merge(receipt, unquote(Macro.escape(change))) end))
      assert_stage(%{proof | attempt: attempt}, :output_prefix, 1)
    end
  end

  for arm <- ["opening", "steered_continuation", "tool_continuation", "post_compaction_resume"] do
    test "HTTP #{arm} uses its original claim-arm witness" do
      proof = proof("http_sse")
      digest = if unquote(arm) == "post_compaction_resume", do: proof.candidate.prefix.http, else: hd(proof.candidate.prefix.websocket)
      request = %{proof.request | native_client_retry_digest: digest, request_metadata: %{"native_http_claim_arm" => unquote(arm)}}
      assert_stage(%{proof | request: request}, :verified, 1)
      wrong = if unquote(arm) == "post_compaction_resume", do: hd(proof.candidate.prefix.websocket), else: proof.candidate.prefix.http
      assert_stage(%{proof | request: %{request | native_client_retry_digest: wrong}}, :witness, 1)
    end
  end

  @tag mailbox_proof_negative: true
  test "HTTP unknown arm and malformed or cross-transport receipts stay fenced" do
    proof = proof("http_sse")
    assert_stage(%{proof | request: %{proof.request | request_metadata: %{"native_http_claim_arm" => "unknown"}}}, :witness, 1)

    for metadata <- [nil, %{}, %{"native_http_resume_progress" => nil}, %{"native_http_resume_progress" => %{"version" => 2, "output_item_done_count" => 1, "digest" => "invalid"}}, %{"downstream_delivery" => proof("websocket").attempt.response_metadata["downstream_delivery"]}, %{"native_http_mailbox_prefix" => %{"version" => 1, "output_item_done_count" => 2, "item_digests" => proof.candidate.items}}] do
      assert_stage(%{proof | attempt: %{proof.attempt | response_metadata: metadata}}, :output_prefix, 1)
    end

    websocket = proof("websocket")
    assert_stage(%{websocket | attempt: %{websocket.attempt | response_metadata: proof.attempt.response_metadata}}, :output_prefix, 1)
  end

  test "producer retains the latest sixteen runs and four completed prefixes per run" do
    runs = Enum.flat_map(1..23, fn run -> Enum.map(1..4, &reasoning("#{run}-#{&1}")) ++ [mailbox()] end)
    witness = witness(append(payload(), runs))
    assert length(witness.mailbox) == 64
    assert Enum.all?(witness.mailbox, &(length(&1.items) in 1..4))
    assert length(witness(append(payload(), runs ++ [reasoning("latest"), mailbox()])).mailbox) == 61

    proof = proof("websocket")
    # The evaluator does not silently discard a producer's later valid proof.
    invalid = %{proof.candidate | prefix: %{websocket: []}}
    assert_stage(with_candidates(proof, List.duplicate(invalid, 63) ++ [proof.candidate]), :verified, 64)
  end

  for {call_type, result_type} <- [{"function_call", "function_call_output"}, {"custom_tool_call", "custom_tool_call_output"}], output_kind <- ["reasoning", "commentary"] do
    @tag mailbox_tool_drain_regression: true
    test "#{call_type}/#{output_kind}: codec-bound completed calls and preemptible output allow their matched native drain before mail" do
      proof = drained_proof(unquote(call_type), unquote(result_type), unquote(output_kind))
      assert ClientRetry.mailbox_check(proof.turn, proof.request, proof.attempt, proof.witness, nil, :same_session).stage == :verified
      assert ClientRetry.verified_mailbox_continuation?(proof.turn, proof.request, proof.attempt, proof.witness, nil)
    end

    @tag mailbox_tool_drain_regression: true
    test "#{call_type}/#{output_kind}: fulfilled-call recovery cannot discard prefix, output, epoch or session proof" do
      proof = drained_proof(unquote(call_type), unquote(result_type), unquote(output_kind))

      for changed <- [
            %{proof | request: %{proof.request | native_client_retry_digest: :crypto.hash(:sha256, "foreign original prefix")}},
            %{proof | witness: %{proof.witness | auth_epoch: 2}},
            %{proof | request: %{proof.request | native_client_retry_auth_epoch: 2}},
            %{proof | attempt: %{proof.attempt | replay_generation: 1}},
            %{proof | attempt: %{proof.attempt | id: "foreign-final-attempt"}},
            %{proof | attempt: %{proof.attempt | response_metadata: %{}}}
          ] do
        refute ClientRetry.verified_mailbox_continuation?(changed.turn, changed.request, changed.attempt, changed.witness, nil)
      end

      assert check(proof, :rejected).stage != :verified

      for field <- ["model", "instructions"] do
        changed = Map.put(proof.continuation, field, "synthetic changed option")
        refute ClientRetry.verified_mailbox_continuation?(proof.turn, proof.request, proof.attempt, witness(changed), nil)
      end

      anchored = Map.put(proof.continuation, "previous_response_id", "resp_synthetic_foreign_socket")
      assert witness(anchored).mailbox == []
    end
  end

  @tag mailbox_tool_drain_regression: true
  test "fulfilled calls retain real downstream proof stages after candidate recognition" do
    proof = drained_proof("function_call", "function_call_output", "reasoning")
    assert check(proof).stage == :verified
    assert [%{items: [_call_digest, _reasoning_digest]}] = proof.witness.mailbox
    assert check(%{proof | request: %{proof.request | native_client_retry_digest: :crypto.hash(:sha256, "foreign prefix")}}).stage == :witness
    assert check(%{proof | witness: %{proof.witness | auth_epoch: 2}}).stage == :authorization
    assert check(%{proof | attempt: %{proof.attempt | replay_generation: 1}}).stage == :settlement
    assert check(proof, :rejected).stage == :session
    receipt = proof.attempt.response_metadata["downstream_delivery"]
    reversed = put_in(proof.attempt.response_metadata["downstream_delivery"]["completed_item_digests"], Enum.reverse(receipt["completed_item_digests"]))
    assert check(reversed).stage == :output_prefix

    for field <- ["arguments", "name", "call_id"] do
      changed = update_in(proof.continuation, ["input"], fn [head, call | tail] -> [head, Map.put(call, field, "synthetic changed") | tail] end)
      stage = if field == "call_id", do: :no_candidate, else: :output_prefix
      assert check(%{proof | witness: witness(changed)}).stage == stage
    end

    for field <- ["model", "instructions"] do
      assert check(%{proof | witness: witness(Map.put(proof.continuation, field, "synthetic changed"))}).stage == :witness
    end

    # A client tool result belongs to the ending witness, not the server receipt.
    historical = witness(append(proof.continuation, [%{"type" => "function_call_output", "call_id" => "sample-later-call", "output" => "synthetic later input"}]))
    historical_proof = %{proof | witness: historical}
    assert check(historical_proof).stage == :ending
    successor = %{proof.request | native_client_retry_digest: hd(hd(proof.witness.mailbox).ending.websocket)}
    assert check(historical_proof, :same_session, successor).stage == :verified
    assert check(historical_proof, :same_session, proof.request).stage == :ending
  end

  defp drained_proof(call_type, result_type, output_kind) do
    original = payload()
    call = if call_type == "function_call", do: %{"type" => call_type, "id" => "fc_sample_inflight", "call_id" => "sample-inflight-call", "name" => "sample_tool", "arguments" => "{}"}, else: %{"type" => call_type, "id" => "ct_sample_inflight", "call_id" => "sample-inflight-call", "name" => "sample_tool", "input" => "synthetic input"}
    output = if output_kind == "reasoning", do: reasoning("preemptible"), else: %{"type" => "message", "id" => "msg_sample_preemptible", "role" => "assistant", "phase" => "commentary", "content" => [%{"type" => "output_text", "text" => "synthetic commentary"}]}
    outputs = [call, output]
    result = %{"type" => result_type, "call_id" => "sample-inflight-call", "output" => "synthetic tool completion"}
    continuation = append(original, outputs ++ [result, mailbox()])
    {:ok, digest} = WebsocketTurnIdentity.replay_claim_digest(@semantic, original)

    written =
      Enum.map(outputs, fn item ->
        {:ok, value} = WebsocketTurnIdentity.completed_item_digest(item)
        value
      end)

    attempt = %Attempt{id: @attempt_id, status: "failed", network_error_code: "client_disconnected", transport: "websocket", replay_generation: 0, completed_at: @now, response_metadata: %{"downstream_delivery" => %{"outcome" => "aborted", "terminal_class" => "none", "highest_frame_class" => "item_done", "completed_items" => 2, "completed_item_digests" => written}}}
    request = %Request{status: "failed", last_error_code: "client_disconnected", endpoint: "/backend-api/codex/responses", transport: "websocket", completed_at: @now, native_client_retry_version: 1, native_client_retry_digest: digest, native_client_retry_auth_epoch: 1}
    turn = %CodexTurn{status: "interrupted", error_code: "client_disconnected", transport_kind: "websocket", final_attempt_id: @attempt_id, completed_at: @now}
    %{turn: turn, request: request, attempt: attempt, witness: witness(continuation), continuation: continuation}
  end

  defp assert_stage(proof, stage, index \\ nil) do
    expected = if index, do: %{stage: stage, candidate_index: index}, else: %{stage: stage}
    assert check(proof) == expected
    assert ClientRetry.verified_mailbox_continuation?(proof.turn, proof.request, proof.attempt, proof.witness, nil) == (stage == :verified)
  end

  defp check(proof, verdict \\ :same_session, successor \\ nil),
    do: ClientRetry.mailbox_check(proof.turn, proof.request, proof.attempt, proof.witness, successor, verdict)

  defp with_candidates(proof, candidates), do: %{proof | witness: %{proof.witness | mailbox: candidates}}

  defp proof(transport, outputs \\ [reasoning("first")]) do
    original = payload()
    witness = witness(append(original, outputs ++ [mailbox()]))
    candidate = Enum.find(witness.mailbox, &(length(&1.items) == length(outputs)))
    witness = %{witness | mailbox: [candidate]}
    digest = if transport == "websocket", do: hd(candidate.prefix.websocket), else: candidate.prefix.http
    progress = Enum.reduce(outputs, ClientRetry.new_native_http_progress(), &ClientRetry.observe_native_http_output_item(&2, &1))
    metadata = %{"native_http_resume_progress" => ClientRetry.native_http_progress_metadata(progress), "native_http_mailbox_prefix" => ClientRetry.native_http_mailbox_prefix_metadata(progress)}
    metadata = if transport == "websocket", do: Map.put(metadata, "downstream_delivery", %{"outcome" => "aborted", "terminal_class" => "none", "highest_frame_class" => "item_done", "completed_items" => length(outputs), "completed_item_digests" => candidate.items}), else: metadata
    request = %Request{status: "failed", last_error_code: "client_disconnected", endpoint: "/backend-api/codex/responses", transport: transport, completed_at: @now, request_metadata: %{"native_http_claim_arm" => "post_compaction_resume"}, native_client_retry_version: 1, native_client_retry_digest: digest, native_client_retry_auth_epoch: 1}
    turn = %CodexTurn{status: "interrupted", error_code: "client_disconnected", transport_kind: transport, final_attempt_id: @attempt_id, completed_at: @now}
    attempt = %Attempt{id: @attempt_id, status: "failed", network_error_code: "client_disconnected", transport: transport, replay_generation: 0, completed_at: @now, response_metadata: metadata}
    %{turn: turn, request: request, attempt: attempt, witness: witness, candidate: candidate}
  end

  defp witness(payload) do
    ClientRetry.original_witness!(:crypto.hash(:sha256, "current proof request"), 1)
    |> NativeMailboxContinuation.attach(@semantic, payload, RequestOptions.build(%{}, "/backend-api/codex/responses", %{}))
  end

  defp payload, do: %{"type" => "response.create", "model" => "synthetic-model", "instructions" => "synthetic instructions", "input" => [%{"type" => "message", "role" => "user", "content" => "synthetic"}], "client_metadata" => %{"x-codex-turn-metadata" => %{"turn_id" => "synthetic-turn", "request_kind" => "turn", "agent_name" => "/root"}}}
  defp append(payload, items), do: Map.update!(payload, "input", &(&1 ++ items))
  defp reasoning(id), do: %{"type" => "reasoning", "id" => "rs_" <> id, "summary" => [], "encrypted_content" => "synthetic-reasoning-" <> id}
  defp mailbox, do: %{"type" => "agent_message", "author" => "/root/worker", "recipient" => "/root", "content" => [%{"type" => "input_text", "text" => "synthetic update"}]}
end
