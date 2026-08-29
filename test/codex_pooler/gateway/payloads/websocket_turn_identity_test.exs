defmodule CodexPooler.Gateway.Payloads.WebsocketTurnIdentityTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Payloads.WebsocketTurnIdentity

  @session_id "018f60df-713f-7ca8-b9a0-0d12c508a123"

  describe "resolve/2" do
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
end
