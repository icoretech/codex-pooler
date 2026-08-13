defmodule CodexPooler.Gateway.Transports.NativeCodexResponseControlTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Transports.NativeCodexResponseControl

  describe "http_headers/1" do
    test "projects exactly the four controls in canonical deterministic order" do
      headers = [
        {"X-Codex-Safety-Buffering-Faster-Model", "gpt-fast"},
        {"X-Reasoning-Included", 1},
        {"X-OpenAI-Model", "gpt-alias"},
        {"OpenAI-Model", "gpt-canonical"},
        {"X-Codex-Safety-Buffering-Enabled", false}
      ]

      assert NativeCodexResponseControl.http_headers(headers) == [
               {"openai-model", "gpt-canonical"},
               {"x-reasoning-included", "true"},
               {"x-codex-safety-buffering-enabled", "true"},
               {"x-codex-safety-buffering-faster-model", "gpt-fast"}
             ]
    end

    test "normalizes mixed case, aliases, repeated values, and presence scalars" do
      assert NativeCodexResponseControl.http_headers([
               {"OPENAI-MODEL", "first-model"},
               {"OPENAI-MODEL", "second-model"},
               {"x-OpenAI-model", "alias-model"},
               {"X-REASONING-INCLUDED", "present"},
               {"x-codex-safety-buffering-enabled", 1.5},
               {"X-CODEX-SAFETY-BUFFERING-FASTER-MODEL", "fast-model"}
             ]) == [
               {"openai-model", "first-model"},
               {"x-reasoning-included", "true"},
               {"x-codex-safety-buffering-enabled", "true"},
               {"x-codex-safety-buffering-faster-model", "fast-model"}
             ]

      assert NativeCodexResponseControl.http_headers([
               {"x-reasoning-included", true},
               {"x-codex-safety-buffering-enabled", 0}
             ]) == [
               {"x-reasoning-included", "true"},
               {"x-codex-safety-buffering-enabled", "true"}
             ]
    end

    test "uses exact canonical spelling then lexicographic case precedence" do
      assert NativeCodexResponseControl.http_headers(%{
               "OPENAI-MODEL" => "upper-model",
               "OpenAI-Model" => "mixed-model",
               "openai-model" => "canonical-model",
               "x-openai-model" => "alias-model"
             }) == [{"openai-model", "canonical-model"}]

      assert NativeCodexResponseControl.http_headers(%{
               "OPENAI-MODEL" => "upper-model",
               "OpenAI-Model" => "mixed-model",
               "x-openai-model" => "alias-model"
             }) == [{"openai-model", "upper-model"}]

      assert NativeCodexResponseControl.http_headers(%{
               "X-OPENAI-MODEL" => "upper-alias",
               "x-openai-model" => "canonical-alias"
             }) == [{"openai-model", "canonical-alias"}]
    end

    test "uses the first repeated value and fails closed for an invalid exact canonical value" do
      assert NativeCodexResponseControl.http_headers([
               {"openai-model", "valid-model"},
               {"openai-model", "second-model"},
               {"OPENAI-MODEL", "case-fallback"},
               {"x-openai-model", "alias-fallback"}
             ]) == [{"openai-model", "valid-model"}]

      assert NativeCodexResponseControl.http_headers(%{
               "openai-model" => "",
               "OPENAI-MODEL" => "case-fallback",
               "x-openai-model" => "alias-fallback"
             }) == []

      assert NativeCodexResponseControl.http_headers(%{
               "OPENAI-MODEL" => "",
               "OpenAI-Model" => "case-fallback",
               "x-openai-model" => "alias-fallback"
             }) == [{"openai-model", "case-fallback"}]
    end

    test "enforces string validity and exact byte limits" do
      valid_boundary = String.duplicate("m", 1_024)
      oversized = valid_boundary <> "m"

      assert NativeCodexResponseControl.http_headers(%{
               "openai-model" => valid_boundary,
               "x-codex-safety-buffering-faster-model" => valid_boundary
             }) == [
               {"openai-model", valid_boundary},
               {"x-codex-safety-buffering-faster-model", valid_boundary}
             ]

      for invalid <- [
            "",
            oversized,
            "model\rvalue",
            "model\nvalue",
            "model\0value",
            "model\tvalue",
            "model\u007Fvalue",
            <<255>>
          ] do
        assert NativeCodexResponseControl.http_headers(%{
                 "openai-model" => invalid,
                 "x-codex-safety-buffering-faster-model" => invalid
               }) == []
      end

      for invalid <- [oversized, "present\rvalue", "present\nvalue", "present\0value", <<255>>] do
        assert NativeCodexResponseControl.http_headers(%{
                 "x-reasoning-included" => invalid,
                 "x-codex-safety-buffering-enabled" => invalid
               }) == []
      end
    end

    test "fails closed for malformed containers and hostile or unknown headers" do
      hostile = %{
        "authorization" => "hostile-authorization-sentinel",
        "cookie" => "hostile-cookie-sentinel",
        "etag" => "hostile-etag-sentinel",
        "openai-request-id" => "hostile-request-id-sentinel",
        "x-codex-quota" => "hostile-quota-sentinel",
        "x-models-etag" => "hostile-models-etag-sentinel",
        "x-ratelimit-limit-requests" => "hostile-rate-limit-sentinel",
        "x-unknown-control" => "hostile-unknown-sentinel"
      }

      assert NativeCodexResponseControl.http_headers(hostile) == []

      for malformed <- [nil, [], ["not-a-header"], [1, 2], "headers", 1] do
        assert NativeCodexResponseControl.http_headers(malformed) == []
      end

      for invalid <- [nil, %{}, [], ["value"]] do
        assert NativeCodexResponseControl.http_headers(%{
                 "openai-model" => invalid,
                 "x-reasoning-included" => invalid,
                 "x-codex-safety-buffering-enabled" => invalid,
                 "x-codex-safety-buffering-faster-model" => invalid
               }) == []
      end
    end

    test "rejects the entire container when any header name is malformed" do
      assert NativeCodexResponseControl.http_headers([
               {"openai-model", "gpt-safe"},
               {<<255>>, "hostile-invalid-name-sentinel"}
             ]) == []

      assert NativeCodexResponseControl.http_headers(%{
               :"openai-model" => "hostile-atom-name-sentinel"
             }) == []
    end

    test "fails closed for improper header lists" do
      for malformed <- [
            [{"openai-model", "safe"} | "bad-tail"],
            [{"openai-model", "safe"} | ~c"bad-tail"],
            [{"openai-model", [{"nested", "value"} | "bad-tail"]}]
          ] do
        assert NativeCodexResponseControl.http_headers(malformed) == []
      end
    end
  end

  describe "sanitize_websocket_event/1" do
    test "detects an unchanged map when no header rewrite is needed" do
      event = %{
        "type" => "response.created",
        "headers" => %{
          "openai-model" => "gpt-example",
          "x-reasoning-included" => "true"
        },
        "response" => %{"id" => "resp_example"}
      }

      assert NativeCodexResponseControl.sanitize_websocket_event(event) == :unchanged

      assert NativeCodexResponseControl.sanitize_websocket_event(%{"type" => "response.created"}) ==
               :unchanged
    end

    test "canonicalizes top-level and nested headers while preserving non-header fields" do
      event = %{
        "type" => "response.completed",
        "sequence_number" => 7,
        "headers" => %{
          "X-OpenAI-Model" => "gpt-top",
          "x-request-id" => "hostile-top-request-id-sentinel"
        },
        "response" => %{
          "id" => "resp_example",
          "status" => "completed",
          "headers" => %{
            "OPENAI-MODEL" => "gpt-nested",
            "x-models-etag" => "hostile-nested-etag-sentinel"
          }
        },
        "metadata" => %{"trusted_access_for_cyber" => true},
        "safety_buffering" => %{"model" => "safe-model"}
      }

      assert {:changed, sanitized} =
               NativeCodexResponseControl.sanitize_websocket_event(event)

      assert sanitized == %{
               "type" => "response.completed",
               "sequence_number" => 7,
               "headers" => %{"openai-model" => "gpt-top"},
               "response" => %{
                 "id" => "resp_example",
                 "status" => "completed",
                 "headers" => %{"openai-model" => "gpt-nested"}
               },
               "metadata" => %{"trusted_access_for_cyber" => true},
               "safety_buffering" => %{"model" => "safe-model"}
             }

      encoded = Jason.encode!(sanitized)
      refute encoded =~ "hostile-top-request-id-sentinel"
      refute encoded =~ "hostile-nested-etag-sentinel"
    end

    test "removes invalid header containers without changing their parent fields" do
      event = %{
        "type" => "response.output_text.delta",
        "delta" => "safe synthetic output",
        "headers" => nil,
        "response" => %{"id" => "resp_example", "headers" => ["invalid"]}
      }

      assert {:changed, sanitized} =
               NativeCodexResponseControl.sanitize_websocket_event(event)

      assert sanitized == %{
               "type" => "response.output_text.delta",
               "delta" => "safe synthetic output",
               "response" => %{"id" => "resp_example"}
             }
    end

    test "omits header fields when no provider header control is safe to relay" do
      event = %{
        "type" => "response.failed",
        "headers" => %{"authorization" => "hostile-top-secret"},
        "response" => %{
          "id" => "resp_example",
          "headers" => %{"cookie" => "hostile-nested-secret"}
        }
      }

      assert {:changed, sanitized} = NativeCodexResponseControl.sanitize_websocket_event(event)

      assert sanitized == %{
               "type" => "response.failed",
               "response" => %{"id" => "resp_example"}
             }
    end

    test "fails closed for a non-map event" do
      for malformed <- [nil, [], "event", 1] do
        assert NativeCodexResponseControl.sanitize_websocket_event(malformed) ==
                 {:error, :invalid_event}
      end
    end
  end

  describe "pooler_metadata_event/2" do
    test "constructs Pooler-owned metadata from the trusted ETag and safe provider model only" do
      provider_headers = %{
        "OpenAI-Model" => "gpt-provider",
        "x-models-etag" => "hostile-provider-etag-sentinel",
        "x-reasoning-included" => "hostile-reasoning-sentinel",
        "x-codex-safety-buffering-enabled" => "hostile-buffering-sentinel"
      }

      assert NativeCodexResponseControl.pooler_metadata_event(
               ~s(W/"cp-models-v1-safe"),
               provider_headers
             ) == %{
               "type" => "codex.response.metadata",
               "headers" => %{
                 "openai-model" => "gpt-provider",
                 "x-models-etag" => ~s(W/"cp-models-v1-safe")
               }
             }
    end

    test "never substitutes an invalid trusted ETag or provider ETag" do
      assert NativeCodexResponseControl.pooler_metadata_event("", %{
               "openai-model" => "gpt-provider",
               "x-models-etag" => "hostile-provider-etag-sentinel"
             }) == {:error, :invalid_models_etag}

      assert NativeCodexResponseControl.pooler_metadata_event(nil, %{}) ==
               {:error, :invalid_models_etag}
    end

    test "preserves the trusted ETag and excludes provider models from improper lists" do
      for malformed <- [
            [{"openai-model", "safe"} | "bad-tail"],
            [{"openai-model", "safe"} | ~c"bad-tail"],
            [{"openai-model", [{"nested", "value"} | "bad-tail"]}]
          ] do
        assert NativeCodexResponseControl.pooler_metadata_event("trusted-etag", malformed) == %{
                 "type" => "codex.response.metadata",
                 "headers" => %{"x-models-etag" => "trusted-etag"}
               }
      end
    end
  end
end
