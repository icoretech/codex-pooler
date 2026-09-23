defmodule CodexPooler.Gateway.Payloads.WebsocketTurnIdentityTest do
  use ExUnit.Case, async: false

  alias CodexPooler.Gateway.Payloads.WebsocketTurnIdentity

  @session_id "018f60df-713f-7ca8-b9a0-0d12c508a123"

  test "compaction claims are stable and distinct from ordinary claims for the same payload" do
    payload = %{"input" => [%{"type" => "message", "role" => "user", "content" => "synthetic"}]}
    semantic = :crypto.hash(:sha256, "synthetic-turn")
    compact = WebsocketTurnIdentity.compaction_claim_key(semantic, payload)
    ordinary = WebsocketTurnIdentity.request_claim_key(semantic, payload)

    assert WebsocketTurnIdentity.request_claim?(compact)
    refute compact == ordinary
    assert compact == WebsocketTurnIdentity.compaction_claim_key(semantic, payload)

    refute compact ==
             WebsocketTurnIdentity.compaction_claim_key(
               semantic,
               Map.put(payload, "model", "other")
             )
  end

  describe "claim_scope/2" do
    # The scope has to be the one thing a remote compaction does not move. The
    # client rotates `x-codex-window-id` after compacting
    # (`compact_remote_v2.rs:323`) and the Pooler session follows the window, so
    # a claim named after the session stopped meeting its own predecessor
    # (icoretech/codex-pooler-findings#250).
    setup do
      session = %{
        id: @session_id,
        pool_id: "018f60df-713f-7ca8-b9a0-0d12c508a456",
        api_key_id: "018f60df-713f-7ca8-b9a0-0d12c508a789"
      }

      %{session: session}
    end

    test "a thread names one scope for every window of that thread", %{session: session} do
      window_one = WebsocketTurnIdentity.claim_scope(session, "thread-a")

      window_two =
        WebsocketTurnIdentity.claim_scope(%{session | id: "018f60df-713f-7ca8-b9a0-0d12c508aaaa"}, "thread-a")

      assert window_one == window_two
      refute window_one == session.id
      refute window_one == WebsocketTurnIdentity.claim_scope(session, "thread-b")
    end

    test "the scope separates tenants, because the claim index is global", %{session: session} do
      scope = WebsocketTurnIdentity.claim_scope(session, "thread-a")

      refute scope ==
               WebsocketTurnIdentity.claim_scope(%{session | pool_id: "018f60df-713f-7ca8-b9a0-0d12c508abcd"}, "thread-a")

      refute scope ==
               WebsocketTurnIdentity.claim_scope(%{session | api_key_id: "018f60df-713f-7ca8-b9a0-0d12c508abcd"}, "thread-a")
    end

    test "a request with no thread keeps the session scope it had", %{session: session} do
      assert WebsocketTurnIdentity.claim_scope(session, nil) == session.id
      assert WebsocketTurnIdentity.claim_scope(session, "") == session.id
      assert WebsocketTurnIdentity.claim_scope(%{id: @session_id}, "thread-a") == @session_id
      assert WebsocketTurnIdentity.claim_scope(nil, "thread-a") == nil
    end
  end

  describe "resolve/2" do
    test "pins canonical turn id acceptance and rejection for metadata consumers" do
      for accepted <- ["a", "turn_1", "turn.1", "turn:1", String.duplicate("z", 256)] do
        assert {:ok, %{semantic_turn_key: key}} =
                 WebsocketTurnIdentity.resolve(
                   %{
                     "client_metadata" => %{
                       "x-codex-turn-metadata" => %{"turn_id" => accepted}
                     }
                   },
                   @session_id
                 )

        assert byte_size(key) == 32
      end

      for rejected <- ["", "turn/1", "turn 1", String.duplicate("z", 257), nil, 1] do
        assert_invalid(
          %{
            "client_metadata" => %{
              "x-codex-turn-metadata" => %{"turn_id" => rejected}
            }
          },
          "client_metadata.x-codex-turn-metadata.turn_id"
        )
      end
    end

    test "uses the strict identity source precedence" do
      assert_identity(
        %{
          "client_metadata" => %{
            "turn_id" => "client-direct",
            "x-codex-turn-metadata" => %{"turn_id" => "client-canonical"}
          },
          "turn_id" => "legacy-turn",
          "request_id" => "legacy-request"
        },
        "client-direct"
      )

      assert_identity(
        %{
          "client_metadata" => %{
            "x-codex-turn-metadata" => CodexPooler.JSON.encode!(%{"turn_id" => "canonical-json"})
          },
          "turn_id" => "legacy-turn",
          "request_id" => "legacy-request"
        },
        "canonical-json"
      )

      assert_identity(
        %{
          "client_metadata" => %{
            "x-codex-turn-metadata" => %{"turn_id" => "canonical-object"}
          },
          "turn_id" => "legacy-turn",
          "request_id" => "legacy-request"
        },
        "canonical-object"
      )

      assert_identity(
        %{"turn_id" => "legacy-turn", "request_id" => "legacy-request"},
        "legacy-turn"
      )

      assert_identity(%{"request_id" => "legacy-request"}, "legacy-request")
    end

    test "rejects a present invalid client metadata turn id without fallback" do
      for invalid <- [nil, "", "has spaces", String.duplicate("a", 257), 42] do
        payload = %{
          "client_metadata" => %{
            "turn_id" => invalid,
            "x-codex-turn-metadata" => %{"turn_id" => "canonical-fallback"}
          },
          "turn_id" => "legacy-fallback",
          "request_id" => "request-fallback"
        }

        assert_invalid(payload, "client_metadata.turn_id")
      end
    end

    test "rejects malformed canonical metadata without fallback" do
      for invalid <- ["not-json", CodexPooler.JSON.encode!([]), [], 42] do
        payload = %{
          "client_metadata" => %{"x-codex-turn-metadata" => invalid},
          "turn_id" => "legacy-fallback",
          "request_id" => "request-fallback"
        }

        assert_invalid(payload, "client_metadata.x-codex-turn-metadata")
      end
    end

    test "treats a missing canonical metadata turn id as absent but rejects an invalid one" do
      assert_identity(
        %{
          "client_metadata" => %{"x-codex-turn-metadata" => %{}},
          "turn_id" => "legacy-fallback"
        },
        "legacy-fallback"
      )

      for metadata <- [%{"turn_id" => nil}, %{"turn_id" => "bad/value"}] do
        payload = %{
          "client_metadata" => %{"x-codex-turn-metadata" => metadata},
          "turn_id" => "legacy-fallback",
          "request_id" => "request-fallback"
        }

        assert_invalid(payload, "client_metadata.x-codex-turn-metadata.turn_id")
      end
    end

    test "rejects present invalid legacy sources without fallback" do
      assert_invalid(%{"turn_id" => "bad/value", "request_id" => "request-fallback"}, "turn_id")
      assert_invalid(%{"request_id" => "bad/value"}, "request_id")
    end

    test "returns missing when no identity source is present" do
      assert WebsocketTurnIdentity.resolve(%{"client_metadata" => %{}}, @session_id) == :missing
      assert WebsocketTurnIdentity.resolve(%{}, @session_id) == :missing
    end

    test "ignores non-map metadata that cannot carry a native turn identity" do
      assert WebsocketTurnIdentity.resolve(%{"client_metadata" => []}, @session_id) == :missing

      assert_identity(
        %{"client_metadata" => ["ignored"], "request_id" => "legacy-request"},
        "legacy-request"
      )
    end

    test "scopes deterministic keys by session and raw identity" do
      same_a = resolve!(%{"turn_id" => "auto-compact-0"}, @session_id)
      same_b = resolve!(%{"turn_id" => "auto-compact-0"}, @session_id)
      different_id = resolve!(%{"turn_id" => "auto-compact-1"}, @session_id)

      different_session =
        resolve!(
          %{"turn_id" => "auto-compact-0"},
          "018f60df-713f-7ca8-b9a0-0d12c508a456"
        )

      assert same_a == same_b
      refute same_a.semantic_turn_key == different_id.semantic_turn_key
      refute same_a.semantic_turn_key == different_session.semantic_turn_key
      refute same_a.turn_claim_key == different_id.turn_claim_key
      refute same_a.turn_claim_key == different_session.turn_claim_key
    end

    test "returns only the full binary semantic key and opaque durable claim key" do
      identity = resolve!(%{"turn_id" => "auto-compact-0"}, @session_id)
      expected_digest = :crypto.hash(:sha256, @session_id <> <<0>> <> "auto-compact-0")

      assert identity == %{
               semantic_turn_key: expected_digest,
               turn_claim_key: "codex-turn:" <> Base.url_encode64(expected_digest, padding: false)
             }

      assert byte_size(identity.semantic_turn_key) == 32
      assert identity.turn_claim_key =~ ~r/\Acodex-turn:[A-Za-z0-9_-]{43}\z/
      refute inspect(identity) =~ "auto-compact-0"
    end
  end

  describe "request_claim_key/2" do
    test "pins the deterministic native response claim vector" do
      semantic_turn_key = :crypto.hash(:sha256, "semantic-turn-vector")

      payload = %{
        "type" => "response.create",
        "model" => "gpt-example",
        "previous_response_id" => "resp_vector_0001",
        "input" => [
          %{
            "type" => "function_call_output",
            "call_id" => "call_vector_0001",
            "output" => %{"count" => 2, "status" => "ok"}
          }
        ],
        "client_metadata" => %{"meaningful" => "kept"}
      }

      assert WebsocketTurnIdentity.request_claim_key(semantic_turn_key, payload) ==
               "codex-request:kuxYokaG14TbR87mK2-_QJTJWkNUQm-l_4_Du-AKlG8"
    end

    test "is stable across map order and excluded metadata but diverges on request semantics" do
      semantic_turn_key = :crypto.hash(:sha256, "semantic-turn-stability")
      base = request_claim_payload()

      encoded_turn_metadata =
        CodexPooler.JSON.encode!(%{"turn_id" => "encoded-turn", "nonce" => "ignored"})

      reordered_and_volatile = %{
        "client_metadata" => %{
          "ws_request_header_tracestate" => "volatile-b",
          "meaningful" => "kept",
          "x-codex-turn-metadata" => encoded_turn_metadata,
          "ws_request_header_traceparent" => "volatile-a",
          "x-codex-ws-stream-request-start-ms" => 999,
          "turn_id" => "direct-turn"
        },
        "request_id" => "request-b",
        "input" => [
          %{
            "output" => %{"status" => "ok"},
            "call_id" => "call_1",
            "type" => "function_call_output"
          }
        ],
        "previous_response_id" => "resp_1",
        "model" => "gpt-example",
        "type" => "response.create",
        "turn_id" => "turn-b"
      }

      claim = WebsocketTurnIdentity.request_claim_key(semantic_turn_key, base)

      assert claim ==
               WebsocketTurnIdentity.request_claim_key(
                 semantic_turn_key,
                 reordered_and_volatile
               )

      for changed <- [
            put_in(base, ["previous_response_id"], "resp_2"),
            put_in(base, ["input", Access.at(0), "call_id"], "call_2"),
            put_in(base, ["input", Access.at(0), "output"], %{"status" => "changed"}),
            Map.put(base, "input", [
              %{
                "type" => "function_call_output",
                "call_id" => "call_2",
                "output" => %{"status" => "second"}
              },
              hd(base["input"])
            ]),
            Map.put(base, "input", [
              hd(base["input"]),
              %{
                "type" => "function_call_output",
                "call_id" => "call_2",
                "output" => %{"status" => "second"}
              }
            ])
          ] do
        refute claim == WebsocketTurnIdentity.request_claim_key(semantic_turn_key, changed)
      end
    end
  end

  describe "replay_claim_digest/2" do
    test "pins the deterministic replay claim vector" do
      previous = Application.fetch_env!(:codex_pooler, CodexPoolerWeb.Endpoint)

      Application.put_env(
        :codex_pooler,
        CodexPoolerWeb.Endpoint,
        Keyword.put(previous, :secret_key_base, String.duplicate("s", 64))
      )

      on_exit(fn -> Application.put_env(:codex_pooler, CodexPoolerWeb.Endpoint, previous) end)

      semantic_turn_key = :binary.list_to_bin(Enum.to_list(0..31))
      payload = %{"input" => [], "model" => "gpt-test", "type" => "response.create"}

      assert {:ok, digest} =
               WebsocketTurnIdentity.replay_claim_digest(semantic_turn_key, payload)

      assert Base.encode16(digest, case: :lower) ==
               "ed1a420441e79e685f882012d046b00e267dfe8665ca86b01b43e7b26c23b190"
    end

    test "normalizes canonical metadata maps and JSON while retaining meaningful changes" do
      semantic_turn_key = :crypto.hash(:sha256, "replay-metadata")

      map_payload = %{
        "type" => "response.create",
        "model" => "gpt-test",
        "input" => [],
        "turn_id" => "top-a",
        "request_id" => "request-a",
        "client_metadata" => %{
          "turn_id" => "direct-a",
          "x-codex-ws-stream-request-start-ms" => 1,
          "ws_request_header_traceparent" => "trace-a",
          "ws_request_header_tracestate" => "state-a",
          "x-codex-turn-metadata" => %{
            "turn_id" => "nested-a",
            "nested" => %{"turn_id" => "nested-b", "kept" => 1},
            "kept" => true
          }
        }
      }

      json_payload =
        put_in(
          map_payload,
          ["client_metadata", "x-codex-turn-metadata"],
          CodexPooler.JSON.encode!(%{
            "kept" => true,
            "nested" => %{"kept" => 1, "turn_id" => "different-removed"},
            "turn_id" => "different-removed"
          })
        )
        |> put_in(["client_metadata", "turn_id"], "direct-b")
        |> put_in(["client_metadata", "x-codex-ws-stream-request-start-ms"], 2)
        |> Map.put("turn_id", "top-b")
        |> Map.put("request_id", "request-b")

      assert {:ok, digest} =
               WebsocketTurnIdentity.replay_claim_digest(semantic_turn_key, map_payload)

      assert {:ok, ^digest} =
               WebsocketTurnIdentity.replay_claim_digest(semantic_turn_key, json_payload)

      assert {:ok, changed_digest} =
               WebsocketTurnIdentity.replay_claim_digest(
                 semantic_turn_key,
                 put_in(map_payload, ["client_metadata", "x-codex-turn-metadata", "kept"], false)
               )

      refute digest == changed_digest
    end

    test "rejects malformed canonical metadata and invalid digest inputs" do
      semantic_turn_key = :crypto.hash(:sha256, "replay-malformed")

      for metadata <- ["not-json", CodexPooler.JSON.encode!([]), [], 42] do
        assert {:error, %{status: 400, code: "invalid_request"}} =
                 WebsocketTurnIdentity.replay_claim_digest(semantic_turn_key, %{
                   "type" => "response.create",
                   "client_metadata" => %{"x-codex-turn-metadata" => metadata}
                 })
      end

      assert {:error, %{status: 400, code: "invalid_request"}} =
               WebsocketTurnIdentity.replay_claim_digest(<<1>>, %{"type" => "response.create"})
    end

    test "is stable across processes and fails closed without the endpoint secret" do
      semantic_turn_key = :crypto.hash(:sha256, "replay-process")
      payload = %{"type" => "response.create", "model" => "gpt-test", "input" => []}

      assert {:ok, digest} =
               WebsocketTurnIdentity.replay_claim_digest(semantic_turn_key, payload)

      assert {:ok, ^digest} =
               Task.async(fn ->
                 WebsocketTurnIdentity.replay_claim_digest(semantic_turn_key, payload)
               end)
               |> Task.await()

      previous = Application.fetch_env!(:codex_pooler, CodexPoolerWeb.Endpoint)

      # Also on_exit: the ExUnit timeout kills the test before `after` runs, and every later
      # replay digest in the run would then fail closed without the endpoint secret.
      on_exit(fn -> Application.put_env(:codex_pooler, CodexPoolerWeb.Endpoint, previous) end)

      Application.put_env(
        :codex_pooler,
        CodexPoolerWeb.Endpoint,
        Keyword.delete(previous, :secret_key_base)
      )

      try do
        assert {:error, %{status: 400, code: "invalid_request", param: "secret_key_base"}} =
                 WebsocketTurnIdentity.replay_claim_digest(semantic_turn_key, payload)
      after
        Application.put_env(:codex_pooler, CodexPoolerWeb.Endpoint, previous)
      end
    end
  end

  describe "replay_tail_digest/2 and replay_claim_alternates/2" do
    # The released Codex client sends every turn after the first on a socket as an
    # anchored delta (`previous_response_id` plus the items it adds). After a
    # reconnect it resends the same turn as full history without the anchor:
    # the history the anchor stood for followed by exactly the anchored
    # request's items, every other field unchanged but the stream start stamp
    # (measured with the released client, findings#232 row 232-160).
    setup do
      thread_id = "019a0000-0000-7000-8000-000000000001"
      semantic = :crypto.hash(:sha256, "tail-turn")

      metadata = %{
        "session_id" => thread_id,
        "thread_id" => thread_id,
        "turn_id" => "turn-b",
        "root_turn_id" => "turn-b",
        "x-codex-installation-id" => "install-a",
        "x-codex-window-id" => thread_id <> ":0",
        "x-codex-turn-metadata" => CodexPooler.JSON.encode!(%{"thread_id" => thread_id, "turn_id" => "turn-b", "request_kind" => "turn"}),
        "x-codex-ws-stream-request-start-ms" => 100
      }

      history = [
        %{"type" => "message", "role" => "developer", "content" => [%{"type" => "input_text", "text" => "synthetic instructions"}]},
        %{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic turn a"}]},
        %{"type" => "message", "role" => "assistant", "content" => [%{"type" => "output_text", "text" => "synthetic answer a"}]}
      ]

      turn_items = [%{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic turn b"}]}]

      anchored = %{
        "type" => "response.create",
        "model" => "gpt-test",
        "instructions" => "synthetic base",
        "tools" => [%{"type" => "function", "name" => "exec_command"}],
        "reasoning" => %{"effort" => "low"},
        "store" => false,
        "stream" => true,
        "client_metadata" => metadata,
        "previous_response_id" => "resp_synthetic_turn_a",
        "input" => turn_items
      }

      full =
        anchored
        |> Map.delete("previous_response_id")
        |> Map.put("input", history ++ turn_items)
        |> put_in(["client_metadata", "x-codex-ws-stream-request-start-ms"], 200)

      %{semantic: semantic, anchored: anchored, full: full, history: history}
    end

    test "the full-history resend of an anchored request carries that request's tail digest",
         %{semantic: semantic, anchored: anchored, full: full} do
      assert {:ok, tail} = WebsocketTurnIdentity.replay_tail_digest(semantic, anchored)
      assert {:ok, alternates} = WebsocketTurnIdentity.replay_claim_alternates(semantic, full)

      assert tail in alternates
      assert length(alternates) == 3
      assert :unanchored = WebsocketTurnIdentity.replay_tail_digest(semantic, full)
      assert {:ok, []} = WebsocketTurnIdentity.replay_claim_alternates(semantic, anchored)

      # The replay claim still binds the anchor: the two forms differ, and a
      # byte-identical anchored resend keeps its own claim.
      assert {:ok, anchored_claim} = WebsocketTurnIdentity.replay_claim_digest(semantic, anchored)
      assert {:ok, full_claim} = WebsocketTurnIdentity.replay_claim_digest(semantic, full)
      refute anchored_claim == full_claim
      refute anchored_claim in alternates
      assert {:ok, ^anchored_claim} = WebsocketTurnIdentity.replay_claim_digest(semantic, anchored)
    end

    test "a different request of the same turn is not among the alternates",
         %{semantic: semantic, anchored: anchored, full: full, history: history} do
      assert {:ok, tail} = WebsocketTurnIdentity.replay_tail_digest(semantic, anchored)

      altered_item = put_in(full, ["input", Access.at(3), "content"], [%{"type" => "input_text", "text" => "other turn b"}])
      other_model = Map.put(full, "model", "gpt-other")
      other_tools = Map.put(full, "tools", [])
      other_metadata = put_in(full, ["client_metadata", "x-codex-window-id"], "other-window")
      extra_item = Map.put(full, "input", full["input"] ++ [%{"type" => "message", "role" => "user", "content" => "more"}])
      no_history = Map.put(full, "input", anchored["input"])

      for resend <- [altered_item, other_model, other_tools, other_metadata, extra_item, no_history] do
        assert {:ok, alternates} = WebsocketTurnIdentity.replay_claim_alternates(semantic, resend)
        refute tail in alternates
      end

      assert {:ok, alternates} = WebsocketTurnIdentity.replay_claim_alternates(:crypto.hash(:sha256, "other-turn"), full)
      refute tail in alternates

      # A different anchor is a different anchored request (the replay claim
      # changes), yet the same anchor-free tail: only an unanchored resend is
      # ever matched through it.
      assert {:ok, ^tail} = WebsocketTurnIdentity.replay_tail_digest(semantic, Map.put(anchored, "previous_response_id", "resp_altered"))

      assert {:ok, claim} = WebsocketTurnIdentity.replay_claim_digest(semantic, anchored)
      refute {:ok, claim} == WebsocketTurnIdentity.replay_claim_digest(semantic, Map.put(anchored, "previous_response_id", "resp_altered"))

      # An unanchored original is never found through a longer resend that
      # prepends items: its witness is its replay claim, another domain.
      short = Map.put(full, "input", tl(history) ++ anchored["input"])
      assert {:ok, short_claim} = WebsocketTurnIdentity.replay_claim_digest(semantic, short)
      assert {:ok, alternates} = WebsocketTurnIdentity.replay_claim_alternates(semantic, full)
      refute short_claim in alternates
    end

    test "only trailing slices with a history item before them, at most 256, are alternates",
         %{semantic: semantic, full: full} do
      assert {:ok, []} = WebsocketTurnIdentity.replay_claim_alternates(semantic, Map.put(full, "input", [hd(full["input"])]))
      assert {:ok, []} = WebsocketTurnIdentity.replay_claim_alternates(semantic, Map.put(full, "input", "text input"))

      items = for n <- 1..300, do: %{"type" => "message", "role" => "user", "content" => "item #{n}"}
      long = Map.put(full, "input", items)
      assert {:ok, alternates} = WebsocketTurnIdentity.replay_claim_alternates(semantic, long)
      assert length(alternates) == 256

      within = Map.put(full, "input", Enum.take(items, -256)) |> Map.put("previous_response_id", "resp_synthetic")
      beyond = Map.put(full, "input", Enum.take(items, -257)) |> Map.put("previous_response_id", "resp_synthetic")
      assert {:ok, within_tail} = WebsocketTurnIdentity.replay_tail_digest(semantic, within)
      assert {:ok, beyond_tail} = WebsocketTurnIdentity.replay_tail_digest(semantic, beyond)
      assert within_tail in alternates
      refute beyond_tail in alternates
    end
  end

  describe "completed_item_digest/1 and grown_resend_candidates/2" do
    # After a cut in which the client received completed items and no terminal,
    # the released Codex client resends the turn as the original request with
    # those items appended, each re-serialized by its own model (measured with
    # Codex 0.156.1 through a recording proxy, findings#232 row 232-232).
    setup do
      thread_id = "019a0000-0000-7000-8000-000000000002"
      semantic = :crypto.hash(:sha256, "grown-turn")

      original = %{
        "type" => "response.create",
        "model" => "gpt-test",
        "instructions" => "synthetic base",
        "store" => false,
        "stream" => true,
        "client_metadata" => %{
          "thread_id" => thread_id,
          "turn_id" => "turn-g",
          "x-codex-turn-metadata" => CodexPooler.JSON.encode!(%{"thread_id" => thread_id, "turn_id" => "turn-g", "request_kind" => "turn"}),
          "x-codex-ws-stream-request-start-ms" => 100
        },
        "input" => [
          %{"type" => "message", "role" => "developer", "content" => [%{"type" => "input_text", "text" => "synthetic instructions"}]},
          %{"type" => "message", "role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic prompt"}]}
        ]
      }

      # provenance: observed findings#232 row 232-232 (the provider's item as pushed, and the same item as the released client resends it)
      provider_message = %{"id" => "msg_grown", "type" => "message", "role" => "assistant", "status" => "completed", "content" => [%{"type" => "output_text", "text" => "synthetic answer", "annotations" => [], "logprobs" => []}]}
      client_message = %{"id" => "msg_grown", "type" => "message", "role" => "assistant", "content" => [%{"type" => "output_text", "text" => "synthetic answer"}]}
      provider_reasoning = %{"id" => "rs_grown", "type" => "reasoning", "summary" => [%{"type" => "summary_text", "text" => "synthetic summary"}], "encrypted_content" => "enc_synthetic"}
      client_reasoning = Map.put(provider_reasoning, "content", nil)

      %{semantic: semantic, original: original, provider_message: provider_message, client_message: client_message, provider_reasoning: provider_reasoning, client_reasoning: client_reasoning}
    end

    test "names the pushed item and the item the client resends alike, and nothing else alike", ctx do
      assert {:ok, message_digest} = WebsocketTurnIdentity.completed_item_digest(ctx.provider_message)
      assert message_digest =~ ~r/\A[0-9a-f]{12}\z/
      assert {:ok, ^message_digest} = WebsocketTurnIdentity.completed_item_digest(ctx.client_message)
      assert {:ok, reasoning_digest} = WebsocketTurnIdentity.completed_item_digest(ctx.provider_reasoning)
      assert {:ok, ^reasoning_digest} = WebsocketTurnIdentity.completed_item_digest(ctx.client_reasoning)

      altered = [
        put_in(ctx.client_message, ["content", Access.at(0), "text"], "synthetic answer!"),
        Map.put(ctx.client_message, "id", "msg_other"),
        Map.put(ctx.client_message, "role", "user"),
        Map.put(ctx.client_message, "phase", "commentary"),
        Map.put(ctx.client_reasoning, "encrypted_content", "enc_other"),
        put_in(ctx.client_reasoning, ["summary", Access.at(0), "text"], "other summary")
      ]

      for item <- altered do
        assert {:ok, digest} = WebsocketTurnIdentity.completed_item_digest(item)
        refute digest in [message_digest, reasoning_digest]
      end

      assert :error = WebsocketTurnIdentity.completed_item_digest("synthetic answer")
      assert :error = WebsocketTurnIdentity.completed_item_digest(%{"text" => "no type"})
    end

    test "the grown resend names its original and the items appended to it", ctx do
      assert {:ok, original_claim} = WebsocketTurnIdentity.replay_claim_digest(ctx.semantic, ctx.original)
      {:ok, message_digest} = WebsocketTurnIdentity.completed_item_digest(ctx.provider_message)
      {:ok, reasoning_digest} = WebsocketTurnIdentity.completed_item_digest(ctx.provider_reasoning)

      grown =
        ctx.original
        |> Map.update!("input", &(&1 ++ [ctx.client_message]))
        |> put_in(["client_metadata", "x-codex-ws-stream-request-start-ms"], 200)

      assert {:ok, [%{items: [^message_digest], digest: ^original_claim}]} = WebsocketTurnIdentity.grown_resend_candidates(ctx.semantic, grown)

      two = Map.update!(ctx.original, "input", &(&1 ++ [ctx.client_reasoning, ctx.client_message]))
      assert {:ok, [one_item, two_items]} = WebsocketTurnIdentity.grown_resend_candidates(ctx.semantic, two)
      assert one_item.items == [message_digest]
      refute one_item.digest == original_claim
      assert %{items: [^reasoning_digest, ^message_digest], digest: ^original_claim} = two_items
    end

    test "the grown resend of an anchored request carries that request's tail digest among a candidate's alternates", ctx do
      anchored = Map.merge(ctx.original, %{"previous_response_id" => "resp_synthetic_prewarm", "input" => [List.last(ctx.original["input"])]})
      assert {:ok, tail} = WebsocketTurnIdentity.replay_tail_digest(ctx.semantic, anchored)

      grown = Map.update!(ctx.original, "input", &(&1 ++ [ctx.client_message]))
      assert {:ok, [%{alternates: alternates}]} = WebsocketTurnIdentity.grown_resend_candidates(ctx.semantic, grown)
      assert tail in alternates
    end

    test "names no candidate for a request that ends with the client's own input, an anchored request or a lone item", ctx do
      assert {:ok, []} = WebsocketTurnIdentity.grown_resend_candidates(ctx.semantic, ctx.original)

      tool_result = Map.update!(ctx.original, "input", &(&1 ++ [ctx.client_message, %{"type" => "function_call_output", "call_id" => "call_1", "output" => "ok"}]))
      assert {:ok, []} = WebsocketTurnIdentity.grown_resend_candidates(ctx.semantic, tool_result)

      anchored = ctx.original |> Map.put("previous_response_id", "resp_synthetic") |> Map.update!("input", &(&1 ++ [ctx.client_message]))
      assert {:ok, []} = WebsocketTurnIdentity.grown_resend_candidates(ctx.semantic, anchored)

      assert {:ok, []} = WebsocketTurnIdentity.grown_resend_candidates(ctx.semantic, Map.put(ctx.original, "input", [ctx.client_message]))
      assert {:ok, []} = WebsocketTurnIdentity.grown_resend_candidates(ctx.semantic, Map.put(ctx.original, "input", "text input"))
    end

    test "tries at most four trailing items", ctx do
      items = for n <- 1..6, do: put_in(ctx.client_message, ["content", Access.at(0), "text"], "answer #{n}")
      long = Map.update!(ctx.original, "input", &(&1 ++ items))
      assert {:ok, candidates} = WebsocketTurnIdentity.grown_resend_candidates(ctx.semantic, long)
      assert Enum.map(candidates, &length(&1.items)) == [1, 2, 3, 4]
    end
  end

  defp assert_identity(payload, raw_turn_id) do
    expected = :crypto.hash(:sha256, @session_id <> <<0>> <> raw_turn_id)

    assert {:ok,
            %{
              semantic_turn_key: ^expected,
              turn_claim_key: "codex-turn:" <> encoded
            }} = WebsocketTurnIdentity.resolve(payload, @session_id)

    assert encoded == Base.url_encode64(expected, padding: false)
  end

  defp assert_invalid(payload, param) do
    assert {:error,
            %{
              status: 400,
              code: "invalid_request",
              message: "native websocket turn identity is invalid",
              param: ^param
            }} = WebsocketTurnIdentity.resolve(payload, @session_id)
  end

  defp resolve!(payload, session_id) do
    assert {:ok, identity} = WebsocketTurnIdentity.resolve(payload, session_id)
    identity
  end

  defp request_claim_payload do
    %{
      "type" => "response.create",
      "model" => "gpt-example",
      "previous_response_id" => "resp_1",
      "input" => [
        %{
          "type" => "function_call_output",
          "call_id" => "call_1",
          "output" => %{"status" => "ok"}
        }
      ],
      "turn_id" => "turn-a",
      "request_id" => "request-a",
      "client_metadata" => %{
        "turn_id" => "direct-turn",
        "x-codex-turn-metadata" => %{"turn_id" => "encoded-turn", "nonce" => "ignored"},
        "x-codex-ws-stream-request-start-ms" => 1,
        "ws_request_header_traceparent" => "volatile-x",
        "ws_request_header_tracestate" => "volatile-y",
        "meaningful" => "kept"
      }
    }
  end
end
