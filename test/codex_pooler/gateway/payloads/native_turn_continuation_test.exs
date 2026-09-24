defmodule CodexPooler.Gateway.Payloads.NativeTurnContinuationTest do
  # The duplicate-turn fence's premise is that both transports ask the same
  # questions of a native Codex request (findings#212, rows 212-49/212-51/212-53).
  # These are those questions, pinned directly against the shared module so a
  # change to any of them is visible whichever transport motivated it. The
  # end-to-end consequences live in
  # `test/codex_pooler_web/controllers/runtime/backend_codex_http_duplicate_turn_test.exs`.
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Payloads.NativeCodexTurnMetadata
  alias CodexPooler.Gateway.Payloads.NativeTurnContinuation
  alias CodexPooler.Gateway.Payloads.RequestOptions

  @metadata_key "x-codex-turn-metadata"
  @responses "/backend-api/codex/responses"
  @compact "/backend-api/codex/responses/compact"
  @turn_key :crypto.hash(:sha256, "p88-steered-turn")
  @other_turn_key :crypto.hash(:sha256, "p88-other-turn")

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

  defp user_message(text),
    do: %{
      "type" => "message",
      "role" => "user",
      "content" => [%{"type" => "input_text", "text" => text}]
    }

  defp assistant_message(text),
    do: %{
      "type" => "message",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => text}]
    }
end
