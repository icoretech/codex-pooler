defmodule CodexPooler.Gateway.Payloads.WebsocketTurnIdentityTest do
  use ExUnit.Case, async: false

  alias CodexPooler.Gateway.Payloads.WebsocketTurnIdentity

  @session_id "018f60df-713f-7ca8-b9a0-0d12c508a123"

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
            "x-codex-turn-metadata" => Jason.encode!(%{"turn_id" => "canonical-json"})
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
      for invalid <- ["not-json", Jason.encode!([]), [], 42] do
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
      encoded_turn_metadata = Jason.encode!(%{"turn_id" => "encoded-turn", "nonce" => "ignored"})

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
          Jason.encode!(%{
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

      for metadata <- ["not-json", Jason.encode!([]), [], 42] do
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
