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

    for change <- [%{"completed_items" => 2}, %{"terminal_class" => "response.completed"}, %{"outcome" => "delivered"}, %{"completed_item_digests" => []}, %{"completed_items" => 2, "completed_item_digests" => [recorded_digest, "abcdef123456"]}] do
      changed = update_in(attempt.response_metadata["downstream_delivery"], &Map.merge(&1, change))
      refute ClientRetry.verified_mailbox_continuation?(turn, request, changed, witness, nil)
    end
  end

  test "self-authored output, other recipients, malformed mail, old mail and non-resume requests do not qualify" do
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
    assert witness(append(original, [output, mail, %{"type" => "function_call_output", "call_id" => "synthetic-call", "output" => "synthetic"}])).mailbox == []
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
    too_many_runs = Enum.flat_map(1..17, fn n -> [reasoning(Integer.to_string(n)), mailbox(Integer.to_string(n))] end)
    assert witness(append(payload(), too_many_runs)).mailbox == []
  end

  describe "ordinary turn opener" do
    test "a cut opener qualifies on either transport, including re-serialized HTTP items" do
      original = opener()
      output = commentary("first")
      candidate = append(original, [output, mailbox("first")])
      witness = witness(candidate)

      assert length(witness.mailbox) == 1

      for transport <- ["websocket", "http_sse"] do
        {turn, request, attempt} = opener_predecessor(original, output, output, transport)
        assert ClientRetry.verified_mailbox_continuation?(turn, request, attempt, witness, nil)
      end

      delivered = Map.merge(output, %{"status" => "completed", "content" => [%{"type" => "output_text", "text" => "synthetic commentary first", "annotations" => [], "logprobs" => []}]})
      {turn, request, attempt} = opener_predecessor(original, delivered, delivered, "http_sse")
      assert ClientRetry.verified_mailbox_continuation?(turn, request, attempt, witness, nil)

      without_items = update_in(attempt.response_metadata["native_http_resume_progress"], &Map.delete(&1, "item_digests"))
      refute ClientRetry.verified_mailbox_continuation?(turn, request, without_items, witness, nil)
    end

    test "final answers, extra delivered items and tool continuations stay fenced" do
      original = opener()
      output = commentary("first")
      candidate = append(original, [output, mailbox("first")])
      {turn, request, extra} = opener_predecessor(original, output, reasoning("extra"), "http_sse")
      refute ClientRetry.verified_mailbox_continuation?(turn, request, extra, witness(candidate), nil)

      assert witness(append(original, [Map.put(output, "phase", "final_answer"), mailbox("first")])).mailbox == []

      call = [%{"type" => "function_call", "call_id" => "call_1", "name" => "shell", "arguments" => "{}"}, %{"type" => "function_call_output", "call_id" => "call_1", "output" => "ok"}]
      assert witness(append(original, call ++ [output, mailbox("first")])).mailbox == []
    end

    test "mail addressed before the latest user message is never a boundary" do
      earlier = append(opener(), [reasoning("old"), mailbox("old"), %{"type" => "message", "role" => "user", "content" => "next turn"}])
      assert witness(earlier).mailbox == []
      assert length(witness(append(earlier, [commentary("first"), mailbox("first")])).mailbox) == 1
    end
  end

  # `delivered` is what the stream pushed; `more` is delivered after it, so
  # `output == more` records exactly one item.
  defp opener_predecessor(payload, delivered, more, transport) do
    {turn, request, attempt} = predecessor(payload, delivered, transport)
    {:ok, digest} = WebsocketTurnIdentity.replay_claim_digest(@semantic, payload)
    items = if more == delivered, do: [delivered], else: [delivered, more]
    digests = Enum.map(items, fn item -> item |> WebsocketTurnIdentity.completed_item_digest() |> elem(1) end)
    progress = items |> Enum.reduce(ClientRetry.new_native_http_progress(), &ClientRetry.observe_native_http_output_item(&2, &1)) |> ClientRetry.native_http_progress_metadata()
    metadata = if transport == "http_sse", do: %{"native_http_claim_arm" => "opening"}, else: %{}
    attempt = put_in(attempt.response_metadata["native_http_resume_progress"], Map.put(progress, "item_digests", digests))
    {turn, %{request | native_client_retry_digest: digest, request_metadata: metadata}, attempt}
  end

  defp opener, do: Map.update!(payload(), "input", &Enum.take(&1, 1))
  defp commentary(id), do: %{"type" => "message", "id" => "msg_" <> id, "role" => "assistant", "phase" => "commentary", "content" => [%{"type" => "output_text", "text" => "synthetic commentary " <> id}]}

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
