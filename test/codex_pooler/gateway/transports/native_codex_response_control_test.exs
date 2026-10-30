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

      encoded = CodexPooler.JSON.encode!(sanitized)
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

    test "keeps validated retry advice only on 429 terminal events" do
      for type <- ["error", "response.failed", "response.incomplete"] do
        event = %{"type" => type, "status" => 429, "headers" => %{"Retry-After" => "30", "authorization" => "synthetic-secret", "openai-model" => "gpt-safe"}}
        assert {:changed, sanitized} = NativeCodexResponseControl.sanitize_websocket_event(event)
        assert sanitized["headers"] == %{"retry-after" => "30", "openai-model" => "gpt-safe"}
      end

      for {type, status, value} <- [{"response.completed", 429, "30"}, {"response.failed", 500, "30"}, {"error", 429, "later"}, {"error", 429, String.duplicate("0", 129)}] do
        event = %{"type" => type, "status" => status, "headers" => %{"retry-after" => value}}
        assert {:changed, sanitized} = NativeCodexResponseControl.sanitize_websocket_event(event)
        refute Map.has_key?(sanitized, "headers")
      end

      assert NativeCodexResponseControl.http_headers(%{"retry-after" => "30"}) == []
    end

    test "fails closed for a non-map event" do
      for malformed <- [nil, [], "event", 1] do
        assert NativeCodexResponseControl.sanitize_websocket_event(malformed) ==
                 {:error, :invalid_event}
      end
    end
  end

  describe "strip_untrusted_models_etag/1" do
    test "removes every provider models ETag spelling and keeps the other fields" do
      event = %{
        "type" => "codex.response.metadata",
        "headers" => %{
          "x-models-etag" => "hostile-provider-etag-sentinel",
          "X-Models-Etag" => "hostile-provider-etag-sentinel-mixed",
          "x-reasoning-included" => "true"
        },
        "sequence_number" => 3
      }

      assert NativeCodexResponseControl.strip_untrusted_models_etag(event) ==
               {:changed,
                %{
                  "type" => "codex.response.metadata",
                  "headers" => %{"x-reasoning-included" => "true"},
                  "sequence_number" => 3
                }}
    end

    test "omits an emptied or malformed header container" do
      assert NativeCodexResponseControl.strip_untrusted_models_etag(%{
               "type" => "codex.response.metadata",
               "headers" => %{"x-models-etag" => "hostile-provider-etag-sentinel"}
             }) == {:changed, %{"type" => "codex.response.metadata"}}

      for malformed <- [[["x-models-etag", "hostile"]], "x-models-etag: hostile", 1, nil] do
        assert NativeCodexResponseControl.strip_untrusted_models_etag(%{
                 "type" => "codex.response.metadata",
                 "headers" => malformed
               }) == {:changed, %{"type" => "codex.response.metadata"}}
      end
    end

    test "leaves other events and metadata without a models ETag unchanged" do
      for event <- [
            %{"type" => "codex.response.metadata", "headers" => %{"openai-model" => "gpt-x"}},
            %{"type" => "codex.response.metadata"},
            %{"type" => "response.output_text.delta", "delta" => "synthetic"}
          ] do
        assert NativeCodexResponseControl.strip_untrusted_models_etag(event) == :unchanged
      end

      assert NativeCodexResponseControl.strip_untrusted_models_etag("event") ==
               {:error, :invalid_event}
    end
  end

  describe "pooler_metadata_event/2" do
    test "constructs Pooler-owned metadata from the trusted ETag and observed provider controls" do
      provider_headers = %{
        "OpenAI-Model" => "gpt-provider",
        "x-models-etag" => "hostile-provider-etag-sentinel",
        "x-reasoning-included" => "false",
        "x-codex-safety-buffering-enabled" => "hostile-buffering-sentinel"
      }

      assert NativeCodexResponseControl.pooler_metadata_event(
               ~s(W/"cp-models-v1-safe"),
               provider_headers
             ) == %{
               "type" => "codex.response.metadata",
               "headers" => %{
                 "openai-model" => "gpt-provider",
                 "x-reasoning-included" => "true",
                 "x-models-etag" => ~s(W/"cp-models-v1-safe")
               }
             }
    end

    test "never invents reasoning inclusion when the current upstream omits the header" do
      assert NativeCodexResponseControl.pooler_metadata_event("pooler-etag", %{}) == %{
               "type" => "codex.response.metadata",
               "headers" => %{"x-models-etag" => "pooler-etag"}
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

  # findings#239: public surfaces drop every provider event header object.
  describe "drop_event_headers/1" do
    test "drops the top-level and nested response header objects" do
      event = %{
        "type" => "response.created",
        "headers" => %{"openai-model" => "gpt-event-header"},
        "response" => %{"id" => "resp_1", "headers" => %{"openai-model" => "gpt-nested-header"}}
      }

      assert NativeCodexResponseControl.drop_event_headers(event) ==
               {:changed, %{"type" => "response.created", "response" => %{"id" => "resp_1"}}}
    end

    test "drops a non-map header value and leaves other fields alone" do
      assert NativeCodexResponseControl.drop_event_headers(%{
               "type" => "response.output_text.delta",
               "delta" => "hi",
               "headers" => "not-a-map"
             }) == {:changed, %{"type" => "response.output_text.delta", "delta" => "hi"}}
    end

    test "reports an event without header objects as unchanged" do
      assert NativeCodexResponseControl.drop_event_headers(%{
               "type" => "response.completed",
               "response" => %{"id" => "resp_2", "status" => "completed"}
             }) == :unchanged

      assert NativeCodexResponseControl.drop_event_headers(%{"type" => "response.in_progress"}) ==
               :unchanged
    end

    test "rejects a non-map event" do
      assert NativeCodexResponseControl.drop_event_headers("frame") == {:error, :invalid_event}
      assert NativeCodexResponseControl.drop_event_headers(nil) == {:error, :invalid_event}
    end
  end
end
