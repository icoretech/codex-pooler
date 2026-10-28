defmodule CodexPooler.Gateway.Payloads.NativeMailboxContinuationTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Accounting.{Attempt, ClientRetry, Request}
  alias CodexPooler.Gateway.Payloads.{NativeMailboxContinuation, RequestOptions, WebsocketTurnIdentity}
  alias CodexPooler.Gateway.Persistence.CodexTurn

  @semantic :crypto.hash(:sha256, "synthetic mailbox turn")
  @now ~U[2026-09-27 00:00:00.000000Z]
  @attempt_id "018f60df-713f-7ca8-b9a0-0d12c508a002"

  for transport <- ["websocket", "http_sse"] do
    test "#{transport}: exact output followed by five incoming messages qualifies without persisting the candidates" do
      original = payload()
      output = reasoning("first")
      candidate = append(original, [output | Enum.map(1..5, &mailbox(Integer.to_string(&1)))])
      witness = witness(candidate)
      {turn, request, attempt} = predecessor(original, output, unquote(transport))

      assert length(witness.mailbox) == 1
      assert ClientRetry.verified_mailbox_continuation?(turn, request, attempt, witness, nil)
      assert Map.keys(ClientRetry.request_attrs(witness)) |> Enum.sort() == [:native_client_retry_auth_epoch, :native_client_retry_digest, :native_client_retry_version]
    end
  end

  test "altered prefix, output, epoch and completion evidence stay fenced" do
    original = payload()
    output = reasoning("first")
    candidate = append(original, [output, mailbox("first")])
    {turn, request, attempt} = predecessor(original, output, "websocket")

    for changed <- [Map.put(candidate, "instructions", "changed"), put_in(candidate, ["input", Access.at(1), "encrypted_content"], "changed"), put_in(candidate, ["input", Access.at(2), "encrypted_content"], "changed")] do
      refute ClientRetry.verified_mailbox_continuation?(turn, request, attempt, witness(changed), nil)
    end

    witness = witness(candidate)
    refute ClientRetry.verified_mailbox_continuation?(turn, request, attempt, %{witness | auth_epoch: 2}, nil)
    refute ClientRetry.verified_mailbox_continuation?(turn, %{request | status: "succeeded", last_error_code: nil}, attempt, witness, nil)
    refute ClientRetry.verified_mailbox_continuation?(turn, request, %{attempt | replay_generation: 1}, witness, nil)

    [recorded_digest] = attempt.response_metadata["downstream_delivery"]["completed_item_digests"]

    for change <- [%{"completed_items" => 2}, %{"terminal_class" => "response.failed"}, %{"outcome" => "unknown"}, %{"completed_item_digests" => []}, %{"completed_items" => 2, "completed_item_digests" => ["abcdef123456", recorded_digest]}] do
      changed = update_in(attempt.response_metadata["downstream_delivery"], &Map.merge(&1, change))
      refute ClientRetry.verified_mailbox_continuation?(turn, request, changed, witness, nil)
    end
  end

  test "self-authored output, other recipients, malformed mail, old mail and non-turn requests do not qualify" do
    original = payload()
    output = reasoning("first")
    mail = mailbox("first")

    for invalid <- [Map.put(mail, "author", "/root"), Map.put(mail, "recipient", "/root/other"), Map.put(mail, "author", ""), Map.put(mail, "content", []), Map.put(mail, "content", [%{"type" => "output_text", "text" => "synthetic"}])] do
      assert witness(append(original, [output, invalid])).mailbox == []
    end

    assert witness(Map.update!(original, "input", &[output, mail | &1])).mailbox == []
    assert witness(append(original, [output, mail]) |> Map.put("previous_response_id", "resp_synthetic_anchor")).mailbox == []
    assert witness(append(original, [output, mail]) |> Map.put("client_metadata", %{})).mailbox == []
    assert witness(append(original, [output, mail]) |> put_in(["client_metadata", "x-codex-turn-metadata", "request_kind"], "compaction")).mailbox == []
    followed_by_tool = witness(append(original, [output, mail, %{"type" => "function_call_output", "call_id" => "synthetic-call", "output" => "synthetic"}]))
    assert [historical] = followed_by_tool.mailbox
    refute historical.current?
    {turn, request, attempt} = predecessor(original, output, "websocket")
    refute ClientRetry.verified_mailbox_continuation?(turn, request, attempt, followed_by_tool, nil)
  end

  test "a historical edge must end at its actual successor, including a websocket to HTTP chain" do
    original = payload()
    first_output = reasoning("first")
    successor_payload = append(original, [first_output, mailbox("first")])
    next_output = reasoning("second")
    current = append(successor_payload, [next_output, mailbox("second")])
    witness = witness(current)
    {turn, request, attempt} = predecessor(original, first_output, "websocket")
    {next_turn, successor, next_attempt} = predecessor(successor_payload, next_output, "http_sse")

    refute ClientRetry.verified_mailbox_continuation?(turn, request, attempt, witness, nil)
    assert ClientRetry.verified_mailbox_continuation?(turn, request, attempt, witness, successor)
    assert ClientRetry.verified_mailbox_continuation?(next_turn, successor, next_attempt, witness, nil)
    refute ClientRetry.verified_mailbox_continuation?(turn, request, attempt, witness, %{successor | native_client_retry_digest: :crypto.hash(:sha256, "other")})
    refute ClientRetry.verified_mailbox_continuation?(next_turn, successor, next_attempt, witness(append(current, [reasoning("unrequested")])), nil)
  end

  test "an anchored opening is recognized by its request tail before the completed output and mailbox" do
    original = payload()
    tail = %{"type" => "message", "role" => "user", "content" => "synthetic new turn"}
    original = append(original, [tail])
    anchored = original |> Map.put("previous_response_id", "resp_synthetic_prior") |> Map.put("input", [tail])
    {:ok, anchored_digest} = WebsocketTurnIdentity.replay_tail_digest(@semantic, anchored)
    output = reasoning("anchored")
    continuation = append(original, [output, mailbox("anchored")])
    {turn, request, attempt} = predecessor(original, output, "websocket")
    request = %{request | native_client_retry_digest: anchored_digest}
    assert ClientRetry.verified_mailbox_continuation?(turn, request, attempt, witness(continuation), nil)

    for changed <- [put_in(continuation, ["input", Access.at(-3), "content"], "synthetic different turn"), Map.put(continuation, "instructions", "synthetic different instructions"), put_in(continuation, ["input", Access.at(-2), "encrypted_content"], "synthetic changed output")] do
      refute ClientRetry.verified_mailbox_continuation?(turn, request, attempt, witness(changed), nil)
    end
  end

  test "header-only HTTP metadata preserves the input witness and missing agent identity stays fenced" do
    original = payload()
    output = reasoning("first")
    candidate = append(original, [output, mailbox("first")])
    metadata = candidate["client_metadata"]["x-codex-turn-metadata"]
    options = options(forwarded_headers: [{"x-codex-turn-metadata", CodexPooler.JSON.encode!(metadata)}])
    header_candidate = Map.delete(candidate, "client_metadata")
    {turn, request, attempt} = predecessor(original, output, "http_sse")

    assert ClientRetry.verified_mailbox_continuation?(turn, request, attempt, witness(header_candidate, options), nil)
    assert witness(update_in(candidate, ["client_metadata", "x-codex-turn-metadata"], &Map.delete(&1, "agent_name"))).mailbox == []
  end

  test "header metadata with non-object client metadata fails closed without raising" do
    original = payload()
    output = reasoning("first")
    candidate = append(original, [output, mailbox("first")])
    metadata = candidate["client_metadata"]["x-codex-turn-metadata"]
    options = options(forwarded_headers: [{"x-codex-turn-metadata", CodexPooler.JSON.encode!(metadata)}])
    {turn, request, attempt} = predecessor(original, output, "http_sse")

    for invalid <- ["not-a-map", 42, [], true] do
      assert witness(Map.put(candidate, "client_metadata", invalid), options).mailbox == []
    end

    assert ClientRetry.verified_mailbox_continuation?(turn, request, attempt, witness(Map.put(candidate, "client_metadata", nil), options), nil)
  end

  test "candidate work is bounded by mailbox runs independently of mailbox batch size" do
    many_mail = Enum.map(1..20, &mailbox(Integer.to_string(&1)))
    assert length(witness(append(payload(), [reasoning("first") | many_mail])).mailbox) == 1
    historical_runs = Enum.flat_map(1..23, fn n -> [reasoning(Integer.to_string(n)), mailbox(Integer.to_string(n))] end)
    recent = witness(append(payload(), historical_runs)).mailbox
    assert length(recent) == 16
    assert Enum.count(recent, & &1.current?) == 1
  end

  for transport <- ["websocket", "http_sse"] do
    test "#{transport}: old mailbox runs do not disable the newest proof or weaken the complete prefix" do
      history = Enum.flat_map(1..22, fn n -> [reasoning(Integer.to_string(n)), mailbox(Integer.to_string(n))] end)
      original = append(payload(), history)
      output = reasoning("current")
      continuation = append(original, [output, mailbox("current")])
      current = witness(continuation)
      {turn, request, attempt} = predecessor(original, output, unquote(transport))

      assert length(current.mailbox) == 16
      assert ClientRetry.verified_mailbox_continuation?(turn, request, attempt, current, nil)

      altered_old_prefix = put_in(continuation, ["input", Access.at(2), "encrypted_content"], "synthetic altered old output")
      refute ClientRetry.verified_mailbox_continuation?(turn, request, attempt, witness(altered_old_prefix), nil)

      previous = append(payload(), Enum.take(history, 42))
      {previous_turn, previous_request, previous_attempt} = predecessor(previous, reasoning("22"), unquote(transport))
      assert ClientRetry.verified_mailbox_continuation?(previous_turn, previous_request, previous_attempt, current, request)
      refute ClientRetry.verified_mailbox_continuation?(previous_turn, previous_request, previous_attempt, current, nil)

      {old_turn, old_request, old_attempt} = predecessor(payload(), reasoning("1"), unquote(transport))
      {_, old_successor, _} = predecessor(append(payload(), Enum.take(history, 2)), reasoning("2"), unquote(transport))
      refute ClientRetry.verified_mailbox_continuation?(old_turn, old_request, old_attempt, current, old_successor)
    end
  end

  test "mailbox intent is transient and does not change the sealed request or acceptance" do
    ordinary = witness(payload())
    refute ordinary.mailbox_intent?
    marked = %{ordinary | mailbox_intent?: true}
    assert ClientRetry.request_attrs(marked) == ClientRetry.request_attrs(ordinary)
    assert marked.digest == ordinary.digest
    assert marked.mailbox == ordinary.mailbox

    hostile = witness(append(payload(), [reasoning("first"), Map.put(mailbox("first"), "recipient", "/root/other")]))
    assert hostile.mailbox_intent?
    assert hostile.mailbox == []
    refute Map.has_key?(ClientRetry.request_attrs(hostile), :mailbox_intent?)

    for input <- [nil, "invalid", %{}, []] do
      refute witness(Map.put(payload(), "input", input)).mailbox_intent?
    end
  end

  test "mail before a later user message cannot be an edge of that request" do
    original = payload()
    old_mail = append(original, [reasoning("old"), mailbox("old"), %{"type" => "message", "role" => "user", "content" => "synthetic later input"}])
    assert witness(old_mail).mailbox == []
    assert length(witness(append(old_mail, [reasoning("new"), mailbox("new")])).mailbox) == 1
  end

  test "ordinary opening and local-summary windows produce the same bounded mailbox proof" do
    ordinary = Map.update!(payload(), "input", &Enum.take(&1, 1))
    local_summary = ordinary |> append([%{"type" => "message", "role" => "user", "content" => "synthetic summary"}]) |> put_in(["client_metadata", "x-codex-turn-metadata", "window_number"], 2)

    for original <- [ordinary, local_summary] do
      output = reasoning("completed")
      candidate = append(original, [output, mailbox("incoming")])
      assert [proof] = witness(candidate).mailbox
      assert proof.current?
      assert {:ok, digest} = WebsocketTurnIdentity.replay_claim_digest(@semantic, original)
      assert digest in proof.prefix.websocket
      assert {:ok, item_digest} = WebsocketTurnIdentity.completed_item_digest(output)
      assert proof.items == [item_digest]
      assert {:ok, end_digest} = WebsocketTurnIdentity.replay_claim_digest(@semantic, candidate)
      assert end_digest in proof.ending.websocket
    end
  end

  test "only contiguous completed reasoning or commentary can precede incoming mail" do
    ordinary = Map.update!(payload(), "input", &Enum.take(&1, 1))
    commentary = %{"type" => "message", "role" => "assistant", "phase" => "commentary", "content" => [%{"type" => "output_text", "text" => "synthetic commentary"}]}
    assert length(witness(append(ordinary, [reasoning("first"), commentary, mailbox("incoming")])).mailbox) == 2

    for gap <- [%{"type" => "message", "role" => "user", "content" => "synthetic"}, %{"type" => "function_call", "call_id" => "synthetic-call", "name" => "synthetic_tool", "arguments" => "{}"}, %{"type" => "function_call_output", "call_id" => "synthetic-call", "output" => "synthetic"}, Map.put(commentary, "phase", "final_answer")] do
      assert witness(append(ordinary, [reasoning("first"), gap, mailbox("incoming")])).mailbox == []
    end

    assert length(witness(append(ordinary, Enum.map(1..5, &reasoning(Integer.to_string(&1))) ++ [mailbox("incoming")])).mailbox) == 4
  end

  # Codex 989c01a41 / 822e58cc3: a `partial_answer` message is nonterminal like commentary, so mailbox mail can
  # preempt it; only `final_answer` (and an unphased message) is a terminal answer (findings#307).
  test "a completed partial answer can precede incoming mail like commentary, a final answer cannot" do
    ordinary = Map.update!(payload(), "input", &Enum.take(&1, 1))
    commentary = %{"type" => "message", "id" => "msg_commentary", "role" => "assistant", "phase" => "commentary", "content" => [%{"type" => "output_text", "text" => "synthetic commentary"}]}
    partial = %{"type" => "message", "id" => "msg_partial", "role" => "assistant", "phase" => "partial_answer", "content" => [%{"type" => "output_text", "text" => "synthetic partial answer"}]}
    {:ok, partial_digest} = WebsocketTurnIdentity.completed_item_digest(partial)

    assert [candidate] = witness(append(ordinary, [partial, mailbox("incoming")])).mailbox
    assert candidate.current?
    assert candidate.items == [partial_digest]

    assert length(witness(append(ordinary, [reasoning("first"), commentary, partial, mailbox("incoming")])).mailbox) == 3
    assert length(witness(append(ordinary, [partial, commentary, mailbox("incoming")])).mailbox) == 2

    for terminal <- [Map.put(partial, "phase", "final_answer"), Map.delete(partial, "phase")] do
      assert witness(append(ordinary, [terminal, mailbox("incoming")])).mailbox == []
      assert witness(append(ordinary, [partial, terminal, mailbox("incoming")])).mailbox == []
      assert witness(append(ordinary, [reasoning("first"), partial, terminal, mailbox("incoming")])).mailbox == []
    end

    for gap <- [%{"type" => "message", "role" => "user", "content" => "synthetic"}, %{"type" => "function_call_output", "call_id" => "synthetic-call", "output" => "synthetic"}] do
      assert witness(append(ordinary, [partial, gap, mailbox("incoming")])).mailbox == []
    end
  end

  for {call_type, result_type} <- [{"function_call", "function_call_output"}, {"custom_tool_call", "custom_tool_call_output"}], output_kind <- ["reasoning", "commentary", "partial_answer"] do
    @tag mailbox_tool_drain_regression: true
    test "#{call_type}/#{output_kind}: a fulfilled native in-flight call before incoming mail retains its ordered server output proof" do
      original = payload()
      call = drained_call(unquote(call_type))
      output = drained_output(unquote(output_kind))
      result = drained_result(unquote(result_type))
      continuation = append(original, [call, output, result, mailbox("after-drain")])
      sealed = witness(continuation)
      {:ok, prefix} = WebsocketTurnIdentity.replay_claim_digest(@semantic, original)
      {:ok, ending} = WebsocketTurnIdentity.replay_claim_digest(@semantic, continuation)

      written =
        Enum.map([call, output], fn item ->
          {:ok, digest} = WebsocketTurnIdentity.completed_item_digest(item)
          digest
        end)

      assert sealed.mailbox_intent?
      assert Enum.any?(sealed.mailbox, fn candidate -> prefix in candidate.prefix.websocket and ending in candidate.ending.websocket and candidate.current? and candidate.items == written end)
    end

    @tag mailbox_tool_drain_regression: true
    test "#{call_type}/#{output_kind}: unmatched client bookkeeping and wrong-address mail remain ineligible" do
      call = drained_call(unquote(call_type))
      result = drained_result(unquote(result_type))
      output = drained_output(unquote(output_kind))

      for changed <- [Map.delete(result, "call_id"), Map.put(result, "call_id", "sample-foreign-call"), Map.put(result, "type", "output_text")] do
        assert witness(append(payload(), [call, output, changed, mailbox("after-drain")])).mailbox == []
      end

      assert witness(append(payload(), [output, result, mailbox("orphan-result")])).mailbox == []
      assert witness(append(payload(), [call, output, result, Map.put(mailbox("foreign"), "recipient", "/root/other")])).mailbox == []
      assert witness(append(payload(), [call, output, result, mailbox("anchored")]) |> Map.put("previous_response_id", "resp_synthetic_anchor")).mailbox == []
    end
  end

  @tag mailbox_tool_drain_regression: true
  test "fulfilled call bookkeeping remains unique, ordered, typed and bounded by four provider items" do
    first = drained_call("function_call")
    second = drained_call("custom_tool_call") |> Map.put("call_id", "sample-second-call")
    first_result = drained_result("function_call_output")
    second_result = drained_result("custom_tool_call_output") |> Map.put("call_id", "sample-second-call")
    output = reasoning("preemptible")
    valid = append(payload(), [first, second, output, first_result, second_result, mailbox("ordered")])
    assert [_candidate] = witness(valid).mailbox

    for invalid <- [
          [first, second, output, second_result, first_result, mailbox("reordered")],
          [first, output, first_result, first_result, mailbox("duplicate-result")],
          [first, first, output, first_result, first_result, mailbox("duplicate-call")],
          [first, output, first_result, second_result, mailbox("extra-result")],
          [first, output, Map.put(first_result, "type", "custom_tool_call_output"), mailbox("wrong-type")],
          [first, output, Map.put(first_result, "name", "foreign_tool"), mailbox("wrong-name")],
          [first, output, Map.put(first_result, "namespace", "foreign"), mailbox("wrong-namespace")],
          [first, output, Map.delete(first_result, "output"), mailbox("missing-result")],
          [first, output, Map.put(first_result, "output", %{}), mailbox("malformed-result")],
          [first, output, %{"type" => "message", "role" => "assistant", "phase" => "final_answer"}, first_result, mailbox("arbitrary-gap")],
          [first, output, first_result, %{"type" => "message", "role" => "user", "content" => "synthetic new boundary"}, mailbox("new-user")],
          [first, output, first_result, %{"type" => "compaction", "encrypted_content" => "synthetic boundary"}, mailbox("compacted")],
          [first | Enum.map(1..4, &reasoning(Integer.to_string(&1)))] ++ [first_result, mailbox("five-provider-items")]
        ] do
      assert witness(append(payload(), invalid)).mailbox == []
    end

    four = append(payload(), [first | Enum.map(1..3, &reasoning(Integer.to_string(&1)))] ++ [first_result, mailbox("four-provider-items")])
    assert [candidate] = witness(four).mailbox
    assert length(candidate.items) == 4

    runs =
      Enum.flat_map(1..16, fn n ->
        call = Map.put(first, "call_id", "sample-call-#{n}")
        result = Map.put(first_result, "call_id", "sample-call-#{n}")
        [call, output, result, mailbox("run-#{n}")]
      end)

    assert length(witness(append(payload(), runs)).mailbox) == 16
    assert length(witness(append(payload(), runs ++ [first, output, first_result, mailbox("run-17")])).mailbox) == 16
  end

  defp drained_output("reasoning"), do: reasoning("preemptible")
  defp drained_output("commentary"), do: %{"type" => "message", "id" => "msg_sample_preemptible", "role" => "assistant", "phase" => "commentary", "content" => [%{"type" => "output_text", "text" => "synthetic commentary"}]}
  defp drained_output("partial_answer"), do: %{"type" => "message", "id" => "msg_sample_preemptible", "role" => "assistant", "phase" => "partial_answer", "content" => [%{"type" => "output_text", "text" => "synthetic partial answer"}]}
  defp drained_call("function_call"), do: %{"type" => "function_call", "id" => "fc_sample_inflight", "call_id" => "sample-inflight-call", "name" => "sample_tool", "arguments" => "{}"}
  defp drained_call("custom_tool_call"), do: %{"type" => "custom_tool_call", "id" => "ct_sample_inflight", "call_id" => "sample-inflight-call", "name" => "sample_tool", "input" => "synthetic input"}
  defp drained_result(type), do: %{"type" => type, "call_id" => "sample-inflight-call", "output" => "synthetic tool completion"}

  defp witness(payload, options \\ options()) do
    ClientRetry.original_witness!(:crypto.hash(:sha256, "current request"), 1)
    |> NativeMailboxContinuation.attach(@semantic, payload, options)
  end

  defp predecessor(payload, output, transport) do
    {:ok, digest} =
      case transport do
        "websocket" -> WebsocketTurnIdentity.replay_claim_digest(@semantic, payload)
        "http_sse" -> WebsocketTurnIdentity.http_resume_input_digest(@semantic, payload["input"])
      end

    {:ok, item_digest} = WebsocketTurnIdentity.completed_item_digest(output)
    progress = ClientRetry.new_native_http_progress() |> ClientRetry.observe_native_http_output_item(output) |> ClientRetry.native_http_progress_metadata()
    metadata = if transport == "http_sse", do: %{"native_http_claim_arm" => "post_compaction_resume"}, else: %{}
    request = %Request{status: "failed", last_error_code: "client_disconnected", endpoint: "/backend-api/codex/responses", transport: transport, completed_at: @now, request_metadata: metadata, native_client_retry_version: 1, native_client_retry_digest: digest, native_client_retry_auth_epoch: 1}
    turn = %CodexTurn{status: "interrupted", error_code: "client_disconnected", transport_kind: transport, final_attempt_id: @attempt_id, completed_at: @now}
    attempt = %Attempt{id: @attempt_id, status: "failed", network_error_code: "client_disconnected", transport: transport, replay_generation: 0, completed_at: @now, response_metadata: %{"downstream_delivery" => %{"outcome" => "aborted", "terminal_class" => "none", "highest_frame_class" => "item_done", "completed_items" => 1, "completed_item_digests" => [item_digest]}, "native_http_resume_progress" => progress}}
    {turn, request, attempt}
  end

  defp payload do
    %{"type" => "response.create", "model" => "synthetic-model", "instructions" => "synthetic instructions", "input" => [%{"type" => "message", "role" => "user", "content" => "synthetic"}, %{"type" => "compaction", "encrypted_content" => "synthetic-pivot"}], "client_metadata" => %{"x-codex-turn-metadata" => %{"turn_id" => "synthetic-turn", "request_kind" => "turn", "agent_name" => "/root"}}}
  end

  defp append(payload, items), do: Map.update!(payload, "input", &(&1 ++ items))
  defp options(opts \\ []), do: RequestOptions.build(Map.new(opts), "/backend-api/codex/responses", %{})
  defp reasoning(id), do: %{"type" => "reasoning", "id" => "rs_" <> id, "summary" => [], "encrypted_content" => "synthetic-reasoning-" <> id}
  defp mailbox(id), do: %{"type" => "agent_message", "author" => "/root/worker", "recipient" => "/root", "content" => [%{"type" => "input_text", "text" => "synthetic update " <> id}, %{"type" => "encrypted_content", "encrypted_content" => "synthetic-ciphertext"}]}
end
