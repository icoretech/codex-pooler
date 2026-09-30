defmodule CodexPooler.Gateway.Payloads.NativeTurnContinuationTest do
  # The duplicate-turn fence's premise is that both transports ask the same
  # questions of a native Codex request (findings#212, rows 212-49/212-51/212-53).
  # These are those questions, pinned directly against the shared module so a
  # change to any of them is visible whichever transport motivated it. The
  # end-to-end consequences live in
  # `test/codex_pooler_web/controllers/runtime/backend_codex_http_duplicate_turn_test.exs`.
  use ExUnit.Case, async: true

  alias CodexPooler.Accounting.NativeTurnProgress
  alias CodexPooler.Gateway.Payloads.NativeCodexTurnMetadata
  alias CodexPooler.Gateway.Payloads.NativeTurnContinuation
  alias CodexPooler.Gateway.Payloads.RequestOptions

  @metadata_key "x-codex-turn-metadata"
  @responses "/backend-api/codex/responses"
  @compact "/backend-api/codex/responses/compact"
  @turn_key :crypto.hash(:sha256, "p88-steered-turn")
  @other_turn_key :crypto.hash(:sha256, "p88-other-turn")
  # provenance: codex-rs/prompts/templates/compact/summary_prefix.md at rust-v0.158.0-alpha.2, plus the joining newline.
  @inline_summary_prefix "Another language model started to solve this problem and produced a summary of its thinking process. You also have access to the state of the tools that were used by that language model. Use this to build on the work that has already been done and avoid duplicating work. Here is the summary produced by the other language model, use the information in this summary to assist with your own analysis:\n"

  describe "canonical_document/2" do
    test "reads the body document, the header copy, and prefers the body" do
      body = document(%{"request_kind" => "turn", "turn_id" => "t-body"})
      header = document(%{"request_kind" => "turn", "turn_id" => "t-header"})

      assert NativeTurnContinuation.canonical_document(
               %{"client_metadata" => %{@metadata_key => body}},
               options()
             ) == body

      assert NativeTurnContinuation.canonical_document(
               %{},
               options(headers: [{@metadata_key, header}])
             ) ==
               header

      assert NativeTurnContinuation.canonical_document(
               %{"client_metadata" => %{@metadata_key => body}},
               options(headers: [{@metadata_key, header}])
             ) == body
    end

    # A native Codex client sends the header once. Two different values mean an
    # intermediary put them there and nothing says which turn is meant, so the
    # document is absent rather than "whichever arrived first" (212-34).
    test "a repeated header is used only when every copy agrees" do
      one = document(%{"request_kind" => "turn", "turn_id" => "t-one"})
      two = document(%{"request_kind" => "turn", "turn_id" => "t-two"})

      assert NativeTurnContinuation.canonical_document(
               %{},
               options(headers: [{@metadata_key, one}, {@metadata_key, one}])
             ) == one

      assert NativeTurnContinuation.canonical_document(
               %{},
               options(headers: [{@metadata_key, one}, {@metadata_key, two}])
             ) == nil
    end

    test "is absent for a payload and options that carry neither" do
      assert NativeTurnContinuation.canonical_document(%{"input" => []}, options()) == nil
      assert NativeTurnContinuation.canonical_document(%{}, options(headers: [])) == nil
      assert NativeTurnContinuation.canonical_document(%{}, options(headers: :none)) == nil
    end
  end

  describe "thread_identity/2" do
    # The thread is what a remote compaction leaves alone while the window
    # rotates, so it is what the turn claim is scoped by
    # (icoretech/codex-pooler-findings#250). A value that does not meet the
    # bound is reported ABSENT, never replaced: the caller then keeps the
    # session scope instead of merging unrelated threads under one stand-in.
    test "reads the thread from either carrier and trims it" do
      body = document(%{"request_kind" => "turn", "turn_id" => "t-1", "thread_id" => " thread-a "})
      header = document(%{"request_kind" => "turn", "turn_id" => "t-1", "thread_id" => "thread-b"})

      assert NativeTurnContinuation.thread_identity(
               %{"client_metadata" => %{@metadata_key => body}},
               options()
             ) == "thread-a"

      assert NativeTurnContinuation.thread_identity(
               %{},
               options(headers: [{@metadata_key, header}])
             ) == "thread-b"
    end

    test "an absent, oversized or malformed thread is absent rather than derived" do
      for absent <- [nil, "", "   ", 42, %{"id" => "thread"}, String.duplicate("z", 257), "thread a", "threadid"] do
        document = document(%{"request_kind" => "turn", "turn_id" => "t-1", "thread_id" => absent})

        assert NativeTurnContinuation.thread_identity(
                 %{"client_metadata" => %{@metadata_key => document}},
                 options()
               ) == nil
      end

      assert NativeTurnContinuation.thread_identity(%{}, options()) == nil
    end
  end

  describe "request_kind/2" do
    # A client that sends only the bounded header copy must resolve its kind
    # exactly as one that sends the body document, or it is classified
    # differently from itself on a second request (212-49).
    test "resolves identically from either carrier" do
      for carrier <- [:body, :header] do
        assert NativeTurnContinuation.request_kind(
                 payload_for(carrier, %{"request_kind" => "turn"}),
                 options_for(carrier, %{"request_kind" => "turn"})
               ) == "turn"
      end
    end

    # The whole fence has to survive an intermediary that normalises the
    # document; an exact byte comparison was a one-string off switch (212-53).
    test "is trimmed and case folded, and blank or oversized values are absent" do
      for raw <- ["turn", "TURN", "Turn", " turn ", "\tturn\n"] do
        assert NativeTurnContinuation.request_kind(
                 payload_for(:body, %{"request_kind" => raw}),
                 options()
               ) == "turn"
      end

      for raw <- ["", "   ", String.duplicate("t", 129)] do
        assert NativeTurnContinuation.request_kind(
                 payload_for(:body, %{"request_kind" => raw}),
                 options()
               ) == nil
      end
    end

    test "a malformed document, a non-string kind and an absent field are all absent" do
      assert NativeTurnContinuation.request_kind(
               %{"client_metadata" => %{@metadata_key => "not-json"}},
               options()
             ) == nil

      assert NativeTurnContinuation.request_kind(
               payload_for(:body, %{"request_kind" => 7}),
               options()
             ) == nil

      assert NativeTurnContinuation.request_kind(
               payload_for(:body, %{"turn_id" => "t"}),
               options()
             ) ==
               nil
    end
  end

  describe "compaction_request?/2" do
    # The released client has no /compact URL: remote compaction V2 declares the
    # kind on the ordinary Responses route. The endpoint covers the Pooler's own
    # bridge-rewritten upstream endpoint. Either signal is enough.
    test "either the declared kind or the compact endpoint is enough" do
      assert NativeTurnContinuation.compaction_request?(
               payload_for(:body, %{"request_kind" => "compaction"}),
               options()
             )

      assert NativeTurnContinuation.compaction_request?(
               payload_for(:body, %{"request_kind" => "turn"}),
               options(endpoint: @compact)
             )

      assert NativeTurnContinuation.compaction_request?(
               %{"input" => []},
               options(endpoint: @compact)
             )
    end

    test "an ordinary turn on the ordinary route is not a compaction" do
      refute NativeTurnContinuation.compaction_request?(
               payload_for(:body, %{"request_kind" => "turn"}),
               options()
             )

      refute NativeTurnContinuation.compaction_request?(%{"input" => []}, options())
    end

    # Everything unexpected must fail open rather than raise: this predicate is
    # reached before the caller can know the shape is well formed (212-53).
    test "a non-map payload and a non-options term fail open rather than raising" do
      refute NativeTurnContinuation.compaction_request?("not a payload", options())
      refute NativeTurnContinuation.compaction_request?(%{}, :not_request_options)
    end
  end

  describe "turn_role/1" do
    test "plain input with neither a tool result nor a compaction item opens a turn" do
      assert NativeTurnContinuation.turn_role(%{"input" => [user_message("hello")]}) == :opening
    end

    test "a tool result means a previous request of this turn produced the call" do
      assert NativeTurnContinuation.turn_role(%{
               "input" => [
                 %{"type" => "function_call_output", "call_id" => "c1", "output" => "done"}
               ]
             }) == :tool_continuation
    end

    # The compaction output item is the pivot, and what follows it decides.
    for item_type <- ["compaction", "compaction_summary", "context_compaction"] do
      test "a #{item_type} with nothing after it is a resume" do
        assert {:post_compaction_resume, anchor} =
                 NativeTurnContinuation.turn_role(%{
                   "input" => [user_message("before"), %{"type" => unquote(item_type)}]
                 })

        assert byte_size(anchor) == 32
      end

      test "a #{item_type} followed by a user message opens a turn" do
        assert NativeTurnContinuation.turn_role(%{
                 "input" => [
                   user_message("retained"),
                   %{"type" => unquote(item_type)},
                   user_message("the next thing")
                 ]
               }) == :opening
      end
    end

    # A retry of a resume appends what it already delivered; none of that is a
    # user message, so the role and the anchor both hold (findings#212, 212-48).
    test "a resume keeps one anchor across everything a retry can append" do
      base = [user_message("retained"), %{"type" => "compaction"}]

      assert {:post_compaction_resume, anchor} =
               NativeTurnContinuation.turn_role(%{"input" => base})

      for appended <- [
            [assistant_message("delivered")],
            [assistant_message("one"), assistant_message("two")],
            [%{"type" => "reasoning", "summary" => []}]
          ] do
        assert {:post_compaction_resume, ^anchor} =
                 NativeTurnContinuation.turn_role(%{"input" => base ++ appended})
      end
    end

    # And the anchor ignores everything else in the input, which is what makes
    # the resume claim payload-independent rather than prefix-independent.
    test "the anchor ignores every item that is not a compaction output" do
      assert {:post_compaction_resume, anchor} =
               NativeTurnContinuation.turn_role(%{
                 "input" => [user_message("a"), user_message("b"), %{"type" => "compaction"}]
               })

      assert {:post_compaction_resume, ^anchor} =
               NativeTurnContinuation.turn_role(%{
                 "input" => [user_message("b"), %{"type" => "compaction"}]
               })

      assert {:post_compaction_resume, ^anchor} =
               NativeTurnContinuation.turn_role(%{"input" => [%{"type" => "compaction"}]})
    end

    test "a different compaction is a different anchor" do
      assert {:post_compaction_resume, one} =
               NativeTurnContinuation.turn_role(%{
                 "input" => [%{"type" => "compaction", "encrypted_content" => "first"}]
               })

      assert {:post_compaction_resume, two} =
               NativeTurnContinuation.turn_role(%{
                 "input" => [%{"type" => "compaction", "encrypted_content" => "second"}]
               })

      refute one == two
    end

    test "only the last compaction pivot anchors a resume" do
      latest = %{"type" => "compaction", "encrypted_content" => "latest"}

      assert {:post_compaction_resume, anchor} =
               NativeTurnContinuation.turn_role(%{
                 "input" => [
                   %{"type" => "compaction", "encrypted_content" => "old"},
                   latest
                 ]
               })

      assert {:post_compaction_resume, ^anchor} =
               NativeTurnContinuation.turn_role(%{"input" => [latest]})

      assert {:post_compaction_resume, ^anchor} =
               NativeTurnContinuation.turn_role(%{
                 "input" => [
                   %{"type" => "compaction_summary", "encrypted_content" => "old"},
                   latest
                 ]
               })
    end

    test "the latest compaction content remains part of the resume anchor" do
      assert {:post_compaction_resume, first} =
               NativeTurnContinuation.turn_role(%{
                 "input" => [
                   %{"type" => "compaction", "encrypted_content" => "old"},
                   %{"type" => "compaction", "encrypted_content" => "latest-one"}
                 ]
               })

      assert {:post_compaction_resume, second} =
               NativeTurnContinuation.turn_role(%{
                 "input" => [
                   %{"type" => "compaction", "encrypted_content" => "old"},
                   %{"type" => "compaction", "encrypted_content" => "latest-two"}
                 ]
               })

      refute first == second
    end

    test "unknown and malformed tail items do not move the latest-pivot anchor" do
      pivot = %{"type" => "compaction", "encrypted_content" => "latest"}

      assert {:post_compaction_resume, anchor} =
               NativeTurnContinuation.turn_role(%{"input" => [pivot]})

      assert {:post_compaction_resume, ^anchor} =
               NativeTurnContinuation.turn_role(%{
                 "input" => [pivot, %{"type" => "future_output"}, "malformed"]
               })
    end

    # Asked of the segment after the last compaction item, so a tool result that
    # is part of the compacted history does not move the role.
    test "a tool result is judged after the last compaction item, not before it" do
      assert {:post_compaction_resume, _anchor} =
               NativeTurnContinuation.turn_role(%{
                 "input" => [
                   %{"type" => "function_call_output", "call_id" => "c1", "output" => "done"},
                   %{"type" => "compaction"}
                 ]
               })

      assert NativeTurnContinuation.turn_role(%{
               "input" => [
                 %{"type" => "compaction"},
                 %{"type" => "function_call_output", "call_id" => "c1", "output" => "done"}
               ]
             }) == :tool_continuation
    end

    # The compaction TRIGGER is a request control, not a compaction output.
    test "a compaction_trigger item does not make a request a later one" do
      assert NativeTurnContinuation.turn_role(%{
               "input" => [user_message("history"), %{"type" => "compaction_trigger"}]
             }) == :opening
    end

    # A local inline compaction (Codex 0.158 `compact.rs`) leaves no compaction
    # item: the replacement history is the earlier user messages then the
    # summary as a user message starting with `SUMMARY_PREFIX` and a newline.
    test "a local inline compaction's summary message is the pivot a compaction item is" do
      summary = inline_summary("the worker was asked to finish")
      mailbox = %{"type" => "agent_message", "author" => "/root/worker", "recipient" => "/root", "content" => [%{"type" => "input_text", "text" => "done"}]}

      assert {:post_compaction_resume, anchor} = NativeTurnContinuation.turn_role(%{"input" => [user_message("task"), summary]})

      # Mailbox input and delivered output after the summary keep the resume
      # and its anchor; the retained user messages before it do not matter.
      assert {:post_compaction_resume, ^anchor} =
               NativeTurnContinuation.turn_role(%{"input" => [user_message("older"), user_message("task"), summary, mailbox, assistant_message("partial")]})

      assert {:post_compaction_resume, other} = NativeTurnContinuation.turn_role(%{"input" => [user_message("task"), inline_summary("another summary")]})
      refute other == anchor

      # A new user message after it opens a turn, a tool result continues one.
      assert NativeTurnContinuation.turn_role(%{"input" => [summary, user_message("next")]}) == :opening

      assert NativeTurnContinuation.turn_role(%{"input" => [summary, %{"type" => "function_call_output", "call_id" => "c1", "output" => "ok"}]}) ==
               :tool_continuation
    end

    test "the summarisation request itself and look-alike messages are not inline compaction pivots" do
      prompt = user_message("You are performing a CONTEXT CHECKPOINT COMPACTION. Create a handoff summary.")
      output = %{"type" => "function_call_output", "call_id" => "c1", "output" => "ok"}

      assert NativeTurnContinuation.turn_role(%{"input" => [user_message("task"), output, prompt]}) == :tool_continuation
      assert NativeTurnContinuation.turn_role(%{"input" => [user_message("task"), prompt]}) == :opening

      # Without its newline, quoted mid-text, or from the assistant, the prefix is not the summary.
      assert NativeTurnContinuation.turn_role(%{"input" => [user_message(String.trim_trailing(@inline_summary_prefix))]}) == :opening
      assert NativeTurnContinuation.turn_role(%{"input" => [user_message("quote: " <> @inline_summary_prefix <> "x")]}) == :opening
      assert NativeTurnContinuation.turn_role(%{"input" => [assistant_message(@inline_summary_prefix <> "x")]}) == :opening
    end

    test "the inline summary is the progress pivot too" do
      summary = inline_summary("s")

      assert NativeTurnContinuation.turn_position(%{"input" => [user_message("a"), summary]}) ==
               NativeTurnContinuation.turn_position(%{"input" => [summary]})

      assert {<<_::256>>, 1} = NativeTurnContinuation.turn_position(%{"input" => [user_message("a"), summary, user_message("b")]})
    end

    test "a payload with no list input fails CLOSED, to the turn's own claim" do
      assert NativeTurnContinuation.turn_role(%{}) == :opening
      assert NativeTurnContinuation.turn_role(%{"input" => "text"}) == :opening
      assert NativeTurnContinuation.turn_role("not a payload") == :opening
    end
  end

  describe "endpoints" do
    test "the compact route is one of the native routes, from one definition" do
      assert NativeTurnContinuation.compact_endpoint() == @compact

      assert NativeTurnContinuation.compact_endpoint() in NativeTurnContinuation.native_endpoints()

      assert @responses in NativeTurnContinuation.native_endpoints()
    end
  end

  # The websocket steer (findings#206 row 206-409): a frame anchored on the
  # response its own turn just completed on this socket is a later request of
  # that turn. Only that exact pairing counts.
  describe "steered_continuation?/3" do
    test "an anchored turn frame on the last response its own turn completed here is steered" do
      assert NativeTurnContinuation.steered_continuation?(steer_payload("resp_own"), websocket_options(@turn_key, "resp_own"), @turn_key)
    end

    test "another turn's response, another anchor, no record or no anchor are not steered" do
      refute NativeTurnContinuation.steered_continuation?(steer_payload("resp_own"), websocket_options(@other_turn_key, "resp_own"), @turn_key)
      refute NativeTurnContinuation.steered_continuation?(steer_payload("resp_other"), websocket_options(@turn_key, "resp_own"), @turn_key)
      refute NativeTurnContinuation.steered_continuation?(steer_payload("resp_own"), websocket_transport(options()), @turn_key)
      refute NativeTurnContinuation.steered_continuation?(Map.delete(steer_payload("resp_own"), "previous_response_id"), websocket_options(@turn_key, "resp_own"), @turn_key)
    end

    test "a compaction, a non-websocket transport and the compact route are not steered" do
      compaction = put_in(steer_payload("resp_own"), ["client_metadata", @metadata_key], document(%{"request_kind" => "compaction", "turn_id" => "t-steer"}))
      refute NativeTurnContinuation.steered_continuation?(compaction, websocket_options(@turn_key, "resp_own"), @turn_key)

      http = put_in(websocket_options(@turn_key, "resp_own").transport.transport, "http_sse")
      refute NativeTurnContinuation.steered_continuation?(steer_payload("resp_own"), http, @turn_key)

      compact_route = put_in(websocket_options(@turn_key, "resp_own").transport.upstream_endpoint, @compact)
      refute NativeTurnContinuation.steered_continuation?(steer_payload("resp_own"), compact_route, @turn_key)
    end
  end

  # findings#206 row 206-412: the socket reads an anchored frame in
  # full-history terms from the progress of the request whose response it
  # names, so the digest must equal `turn_progress/1` of the full history the
  # client would resend (`client.rs` `get_incremental_items`: previous input,
  # that response's output items, then the increment).
  describe "websocket_frame_progress/2" do
    test "an unanchored frame's progress digests to turn_progress/1 of the same payload" do
      payload = %{"input" => [user_message("one"), assistant_message("a"), user_message("two")]}

      assert {:ok, progress} = NativeTurnContinuation.websocket_frame_progress(payload, nil)
      assert NativeTurnContinuation.progress_digest(progress) == NativeTurnContinuation.turn_progress(payload)
    end

    test "an anchored increment on the recorded response extends that request's progress to the full-history digest" do
      opener = %{"input" => [user_message("one")]}
      {:ok, opener_progress} = NativeTurnContinuation.websocket_frame_progress(opener, nil)
      base = %{semantic_turn_key: @turn_key, response_digest: NativeCodexTurnMetadata.response_id_digest("resp_one"), progress: opener_progress}

      increment = %{"previous_response_id" => "resp_one", "input" => [user_message("two")]}
      full_history = %{"input" => [user_message("one"), assistant_message("a"), user_message("two")]}

      assert {:ok, progress} = NativeTurnContinuation.websocket_frame_progress(increment, base)
      assert NativeTurnContinuation.progress_digest(progress) == NativeTurnContinuation.turn_progress(full_history)
      refute NativeTurnContinuation.progress_digest(progress) == NativeTurnContinuation.turn_progress(opener)
    end

    test "an increment carrying a compaction item restarts from that pivot" do
      pivot = %{"type" => "compaction", "encrypted_content" => "synthetic-pivot"}
      base = %{semantic_turn_key: @turn_key, response_digest: NativeCodexTurnMetadata.response_id_digest("resp_one"), progress: {nil, 4}}
      increment = %{"previous_response_id" => "resp_one", "input" => [pivot, user_message("after")]}

      assert {:ok, progress} = NativeTurnContinuation.websocket_frame_progress(increment, base)
      assert NativeTurnContinuation.progress_digest(progress) == NativeTurnContinuation.turn_progress(%{"input" => [user_message("x"), pivot, user_message("after")]})
    end

    test "an anchor the socket has no progress for is unknown" do
      base = %{semantic_turn_key: @turn_key, response_digest: NativeCodexTurnMetadata.response_id_digest("resp_one"), progress: {nil, 1}}
      increment = %{"previous_response_id" => "resp_other", "input" => [user_message("two")]}

      assert NativeTurnContinuation.websocket_frame_progress(increment, base) == :unknown
      assert NativeTurnContinuation.websocket_frame_progress(increment, Map.delete(base, :progress)) == :unknown
      assert NativeTurnContinuation.websocket_frame_progress(%{increment | "previous_response_id" => "resp_one"}, nil) == :unknown
      assert NativeTurnContinuation.websocket_frame_progress(%{"input" => "not a list"}, nil) == :unknown
    end
  end

  # findings#206 row 206-423: the position orders a request against the turn's
  # opener, and an anchored frame's position is the one its full history has.
  describe "progress positions" do
    test "an anchored increment stands where its full history stands" do
      pivot = %{"type" => "compaction", "encrypted_content" => "synthetic-pivot"}
      opener = %{"input" => [user_message("x"), pivot, user_message("one")]}
      {:ok, opener_progress} = NativeTurnContinuation.websocket_frame_progress(opener, nil)
      base = %{semantic_turn_key: @turn_key, response_digest: NativeCodexTurnMetadata.response_id_digest("resp_one"), progress: opener_progress}

      increment = %{"previous_response_id" => "resp_one", "input" => [user_message("two")]}
      full_history = %{"input" => [user_message("x"), pivot, user_message("one"), assistant_message("a"), user_message("two")]}

      assert {:ok, progress} = NativeTurnContinuation.websocket_frame_progress(increment, base)
      assert NativeTurnContinuation.progress_position(progress) == NativeTurnContinuation.turn_position(full_history)
      assert {<<_::256>>, 2} = NativeTurnContinuation.turn_position(full_history)
    end

    test "the pivot is a digest of the latest compaction item alone, and absent without one" do
      pivot = %{"type" => "compaction", "encrypted_content" => "synthetic-pivot"}
      {pivot_digest, 1} = NativeTurnContinuation.turn_position(%{"input" => [user_message("x"), pivot, user_message("one")]})

      # Pruning history before the pivot keeps the position.
      assert NativeTurnContinuation.turn_position(%{"input" => [pivot, user_message("one")]}) == {pivot_digest, 1}
      refute NativeTurnContinuation.turn_position(%{"input" => [%{pivot | "encrypted_content" => "synthetic-other"}, user_message("one")]}) == {pivot_digest, 1}
      assert NativeTurnContinuation.turn_position(%{"input" => [user_message("x"), user_message("one")]}) == {nil, 2}
      assert NativeTurnContinuation.turn_position(%{"input" => "not a list"}) == {nil, 0}
    end
  end

  # findings#282, findings#270 row 270-286: a local compaction (`compact.rs`)
  # leaves no pivot item. It rebuilds the history from the thread's initial
  # context, its most recent user messages (as many as fit the compaction's
  # budget) and the summary as one more user message, and the client moves to
  # its next context window, which every later request names in its turn
  # metadata (`window_number`). The window stands in for the missing pivot.
  describe "the context window after a local compaction" do
    test "the window is read from the body document or the header copy, and a malformed one is none" do
      for source <- [:body, :header] do
        metadata = %{"request_kind" => "turn", "window_number" => 3}
        assert NativeTurnContinuation.window_number(payload_for(source, metadata), options_for(source, metadata)) == 3
      end

      for value <- [-1, 1.5, "1", 4_294_967_296, nil] do
        assert NativeTurnContinuation.window_number(document(%{"request_kind" => "turn", "window_number" => value})) == nil
      end

      assert NativeTurnContinuation.window_number(%{"window_number" => 0}) == 0
      assert NativeTurnContinuation.window_number(document(%{"request_kind" => "turn"})) == nil
      assert NativeTurnContinuation.window_number("not a document") == nil
      assert NativeTurnContinuation.window_number(nil) == nil
    end

    test "window 0, or none, leaves every progress as it was" do
      payload = %{"input" => [user_message("one"), assistant_message("a"), user_message("two")]}

      for window <- [nil, 0] do
        assert NativeTurnContinuation.turn_progress(payload, window) == NativeTurnContinuation.turn_progress(payload)
        assert NativeTurnContinuation.turn_position(payload, window) == {nil, 2}
      end
    end

    test "each later window is a compaction point of its own, which a compaction item still overrides" do
      payload = %{"input" => [user_message("task"), user_message("summary")]}
      assert {<<_::256>> = window_one, 2} = NativeTurnContinuation.turn_position(payload, 1)
      assert {<<_::256>> = window_two, 2} = NativeTurnContinuation.turn_position(payload, 2)
      refute window_one == window_two

      progress = Enum.map([nil, 1, 2], &NativeTurnContinuation.turn_progress(payload, &1))
      assert progress == Enum.uniq(progress)

      pivot = %{"type" => "compaction", "encrypted_content" => "synthetic-pivot"}
      remote = %{"input" => [user_message("x"), pivot, user_message("after")]}

      for window <- [0, 1, 7] do
        assert NativeTurnContinuation.turn_progress(remote, window) == NativeTurnContinuation.turn_progress(remote)
        assert NativeTurnContinuation.turn_position(remote, window) == NativeTurnContinuation.turn_position(remote)
      end
    end

    # The requests of a thread that compacts locally, in the released client's
    # shape (initial context, retained user messages, the summary), against
    # the request whose claim each one meets.
    test "every resume after a local compaction is further along than the request whose claim it meets, and a resend is not" do
      context = [developer_message("instructions"), user_message("environment")]
      opener = NativeTurnContinuation.turn_position(%{"input" => context ++ [user_message("task")]}, 0)
      first_resume = %{"input" => context ++ [user_message("task"), user_message("summary one")]}
      second_resume = %{"input" => context ++ [user_message("task"), user_message("summary two")]}

      # The second compaction of one turn: the resume stands where the first
      # did in user messages, on the next window, under a claim of its own.
      assert NativeTurnProgress.advances?(opener, NativeTurnContinuation.turn_position(first_resume, 1))
      assert NativeTurnProgress.advances?(opener, NativeTurnContinuation.turn_position(second_resume, 2))
      refute NativeTurnContinuation.turn_progress(second_resume, 2) == NativeTurnContinuation.turn_progress(first_resume, 1)

      # A compaction in the thread's next turn: that turn's opener already
      # carries the previous summary, as many user messages as its resume.
      next_opener = NativeTurnContinuation.turn_position(%{"input" => context ++ [user_message("task"), user_message("summary one"), assistant_message("done"), user_message("next task")]}, 1)
      next_resume = NativeTurnContinuation.turn_position(%{"input" => context ++ [user_message("task"), user_message("next task"), user_message("summary two")]}, 2)
      assert elem(next_opener, 1) == elem(next_resume, 1)
      assert NativeTurnProgress.advances?(next_opener, next_resume)

      # A compaction that dropped older user messages to fit its budget.
      long_opener = NativeTurnContinuation.turn_position(%{"input" => context ++ Enum.map(1..5, &user_message("message #{&1}"))}, 0)
      trimmed_resume = NativeTurnContinuation.turn_position(%{"input" => context ++ [user_message("message 5"), user_message("summary one")]}, 1)
      assert NativeTurnProgress.advances?(long_opener, trimmed_resume)

      # A true resend, or a rebuilt retry, stands where its holder stood.
      retried = %{"input" => first_resume["input"] ++ [assistant_message("partial")]}
      assert NativeTurnContinuation.turn_progress(retried, 1) == NativeTurnContinuation.turn_progress(first_resume, 1)
      refute NativeTurnProgress.advances?(NativeTurnContinuation.turn_position(first_resume, 1), NativeTurnContinuation.turn_position(retried, 1))
      refute NativeTurnProgress.advances?(next_opener, next_opener)
    end

    test "an anchored increment stands on the window its full history names" do
      window_one = %{"input" => [user_message("task"), user_message("summary one")]}
      {:ok, base_progress} = NativeTurnContinuation.websocket_frame_progress(window_one, nil, 1)
      base = %{semantic_turn_key: @turn_key, response_digest: NativeCodexTurnMetadata.response_id_digest("resp_window_one"), progress: base_progress}
      increment = %{"previous_response_id" => "resp_window_one", "input" => [user_message("steered")]}
      full_history = %{"input" => [user_message("task"), user_message("summary one"), assistant_message("a"), user_message("steered")]}

      for window <- [1, 2, nil] do
        assert {:ok, progress} = NativeTurnContinuation.websocket_frame_progress(increment, base, window)
        assert NativeTurnContinuation.progress_digest(progress) == NativeTurnContinuation.turn_progress(full_history, window)
        assert NativeTurnContinuation.progress_position(progress) == NativeTurnContinuation.turn_position(full_history, window)
      end
    end
  end

  defp steer_payload(anchor),
    do: %{
      "previous_response_id" => anchor,
      "input" => [user_message("steered")],
      "client_metadata" => %{@metadata_key => document(%{"request_kind" => "turn", "turn_id" => "t-steer"})}
    }

  defp websocket_options(turn_key, response_id) do
    options = websocket_transport(options())
    record = %{semantic_turn_key: turn_key, response_digest: NativeCodexTurnMetadata.response_id_digest(response_id)}
    %{options | extra: Map.put(options.extra, :socket_last_completed_native_response, record)}
  end

  defp websocket_transport(options) do
    options
    |> put_in([Access.key!(:transport), Access.key!(:transport)], "websocket")
    |> put_in([Access.key!(:payload_context), Access.key!(:compaction_trigger_bridge?)], false)
    |> put_in([Access.key!(:openai_compatibility), Access.key!(:public_openai_responses_stream)], false)
  end

  defp document(map), do: CodexPooler.JSON.encode!(map)

  defp payload_for(:body, metadata),
    do: %{"input" => [], "client_metadata" => %{@metadata_key => document(metadata)}}

  defp payload_for(:header, _metadata), do: %{"input" => []}

  defp options_for(:body, _metadata), do: options()
  defp options_for(:header, metadata), do: options(headers: [{@metadata_key, document(metadata)}])

  defp options(opts \\ []) do
    endpoint = Keyword.get(opts, :endpoint, @responses)

    options = RequestOptions.build(%{}, endpoint, %{})

    case Keyword.get(opts, :headers, :absent) do
      :absent ->
        options

      :none ->
        put_in(options.transport.forwarded_metadata_headers, nil)

      headers ->
        put_in(options.transport.forwarded_metadata_headers, headers)
    end
  end

  defp inline_summary(text), do: user_message(@inline_summary_prefix <> text)

  defp user_message(text),
    do: %{
      "type" => "message",
      "role" => "user",
      "content" => [%{"type" => "input_text", "text" => text}]
    }

  defp developer_message(text),
    do: %{
      "type" => "message",
      "role" => "developer",
      "content" => [%{"type" => "input_text", "text" => text}]
    }

  defp assistant_message(text),
    do: %{
      "type" => "message",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => text}]
    }
end
