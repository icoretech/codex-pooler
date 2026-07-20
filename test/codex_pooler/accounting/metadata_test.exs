defmodule CodexPooler.Accounting.MetadataTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounting

  describe "sanitize_metadata/1" do
    test "routing serving mode metadata keeps only a valid bounded snapshot" do
      assert %{
               "routing" => %{
                 "model_serving_mode_configured" => "auto",
                 "model_serving_mode" => "lite",
                 "model_serving_mode_source" => "catalog",
                 "strategy" => "bridge_ring"
               }
             } =
               Accounting.sanitize_metadata(%{
                 "routing" => %{
                   "model_serving_mode_configured" => "auto",
                   "model_serving_mode" => "lite",
                   "model_serving_mode_source" => "catalog",
                   "strategy" => "bridge_ring"
                 }
               })

      assert %{"routing" => %{"strategy" => "bridge_ring"}} =
               Accounting.sanitize_metadata(%{
                 "routing" => %{
                   "model_serving_mode_configured" => "auto",
                   "model_serving_mode" => "turbo",
                   "model_serving_mode_source" => "client",
                   "strategy" => "bridge_ring"
                 }
               })
    end

    test "preserves API key prefixes while redacting raw key material" do
      sanitized =
        Accounting.sanitize_metadata(%{
          "key_prefix" => "sk-cxp-abcdef123456",
          "previous_key_prefix" => "sk-cxp-fedcba654321",
          "raw_api_key" => "sk-cxp-abcdef123456-secretValue",
          "safe_label" => "sk-proj-abcdefghijklmnopqrstuvwxyz123456",
          "nested" => %{
            "key_prefix" => "sk-cxp-111111111111",
            "raw_key" => "sk-cxp-111111111111-secretValue",
            "unsafe_prefix_field" => %{"key_prefix" => "sk-cxp-222222222222-secretValue"}
          }
        })

      assert sanitized["key_prefix"] == "sk-cxp-abcdef123456"
      assert sanitized["previous_key_prefix"] == "sk-cxp-fedcba654321"
      assert sanitized["nested"]["key_prefix"] == "sk-cxp-111111111111"
      assert sanitized["raw_api_key"] == "[REDACTED]"
      assert sanitized["safe_label"] == "[REDACTED]"
      assert sanitized["nested"]["raw_key"] == "[REDACTED]"
      assert sanitized["nested"]["unsafe_prefix_field"]["key_prefix"] == "[REDACTED]"

      sanitized_text = inspect(sanitized)
      refute sanitized_text =~ "secretValue"
      refute sanitized_text =~ "sk-proj-abcdefghijklmnopqrstuvwxyz123456"
    end

    test "payload compression metadata keeps allowlisted fields and redacts unknown raw fields" do
      sanitized =
        Accounting.sanitize_metadata(%{
          "payload_compression" => %{
            "attempted" => true,
            "status" => "compressed",
            "reason" => "tokenizer_input_limit",
            "strategies" => [
              "log_output",
              "call_probe_secret",
              "json_document_lossless",
              "diff"
            ],
            "candidate_count" => 2,
            "tokenizer_input_skipped_count" => 2,
            "raw_candidate" => "Bearer sk-cxp-abcdef123456-secretValue",
            "json_path" => "$.input[0].output"
          }
        })

      compression = sanitized["payload_compression"]

      assert compression["attempted"] == true
      assert compression["status"] == "compressed"
      assert compression["reason"] == "tokenizer_input_limit"
      assert compression["strategies"] == ["log_output", "json_document_lossless", "diff"]
      assert compression["candidate_count"] == 2
      assert compression["tokenizer_input_skipped_count"] == 2
      assert compression["raw_candidate"] == "[REDACTED]"
      assert compression["json_path"] == "[REDACTED]"

      compression_text = inspect(compression)
      refute compression_text =~ "call_probe_secret"
      refute compression_text =~ "secretValue"
      refute compression_text =~ "$.input[0].output"
    end

    test "public Responses stream summary keeps only allowlisted fields" do
      sanitized =
        Accounting.sanitize_metadata(%{
          "public_openai_responses_stream" => %{
            "schema_version" => 1,
            "mode" => "normalized",
            "created_seen" => true,
            "visible_seen" => true,
            "delta_count" => 2,
            "delta_bytes" => 16,
            "text_done_count" => 1,
            "text_done_bytes" => 8,
            "item_done_count" => 1,
            "terminal_seen" => true,
            "terminal_kind" => "completed",
            "terminal_status" => "completed",
            "finish_class" => "completed",
            "synthetic_terminal_sent" => false,
            "source_chunk_count" => 3,
            "stream_bytes" => 256,
            "relay_bytes" => 192,
            "passthrough_seen" => false,
            "foo" => "unbounded prose value",
            "raw_payload" => "Bearer sk-cxp-abcdef123456-secretValue"
          }
        })

      summary = sanitized["public_openai_responses_stream"]

      assert summary["schema_version"] == 1
      assert summary["mode"] == "normalized"
      assert summary["created_seen"] == true
      assert summary["visible_seen"] == true
      assert summary["delta_count"] == 2
      assert summary["delta_bytes"] == 16
      assert summary["text_done_count"] == 1
      assert summary["text_done_bytes"] == 8
      assert summary["item_done_count"] == 1
      assert summary["terminal_seen"] == true
      assert summary["terminal_kind"] == "completed"
      assert summary["terminal_status"] == "completed"
      assert summary["finish_class"] == "completed"
      assert summary["synthetic_terminal_sent"] == false
      assert summary["source_chunk_count"] == 3
      assert summary["stream_bytes"] == 256
      assert summary["relay_bytes"] == 192
      assert summary["passthrough_seen"] == false
      refute Map.has_key?(summary, "foo")
      refute Map.has_key?(summary, "raw_payload")

      summary_text = inspect(summary)
      refute inspect(summary) =~ "secretValue"
      refute summary_text =~ "unbounded prose value"
    end

    test "public Responses stream summary rejects raw-looking classification values" do
      raw_value = "unbounded freeform sentence"

      sanitized =
        Accounting.sanitize_metadata(%{
          "public_openai_responses_stream" => %{
            "finish_class" => raw_value,
            "terminal_kind" => raw_value,
            "terminal_status" => raw_value
          }
        })

      summary = sanitized["public_openai_responses_stream"]

      assert summary["finish_class"] == nil
      assert summary["terminal_kind"] == nil
      assert summary["terminal_status"] == nil
      refute Jason.encode!(summary) =~ raw_value
    end

    test "public Responses stream summary rejects a raw binary value" do
      raw_value = "unbounded freeform binary value"

      sanitized =
        Accounting.sanitize_metadata(%{
          "public_openai_responses_stream" => raw_value
        })

      assert sanitized["public_openai_responses_stream"] == %{}
      refute Jason.encode!(sanitized) =~ raw_value
    end

    test "public Responses stream summary rejects a raw list value" do
      raw_value = "unbounded freeform list value"

      sanitized =
        Accounting.sanitize_metadata(%{
          "public_openai_responses_stream" => [raw_value]
        })

      assert sanitized["public_openai_responses_stream"] == %{}
      refute Jason.encode!(sanitized) =~ raw_value
    end

    test "public Responses stream summary rejects a scalar value" do
      raw_value = 123

      sanitized =
        Accounting.sanitize_metadata(%{
          "public_openai_responses_stream" => raw_value
        })

      assert sanitized["public_openai_responses_stream"] == %{}
      refute sanitized["public_openai_responses_stream"] == raw_value
    end

    test "public Responses stream summary keeps valid bounded values" do
      sanitized =
        Accounting.sanitize_metadata(%{
          "public_openai_responses_stream" => %{
            "schema_version" => 1,
            "mode" => "passthrough",
            "created_seen" => false,
            "visible_seen" => true,
            "delta_count" => 0,
            "delta_bytes" => 0,
            "text_done_count" => 0,
            "text_done_bytes" => 0,
            "item_done_count" => 1,
            "terminal_seen" => true,
            "terminal_kind" => "failed",
            "terminal_status" => "failed",
            "finish_class" => "failed",
            "synthetic_terminal_sent" => true,
            "source_chunk_count" => 2,
            "stream_bytes" => 64,
            "relay_bytes" => 32,
            "passthrough_seen" => true
          }
        })

      assert sanitized["public_openai_responses_stream"] == %{
               "schema_version" => 1,
               "mode" => "passthrough",
               "created_seen" => false,
               "visible_seen" => true,
               "delta_count" => 0,
               "delta_bytes" => 0,
               "text_done_count" => 0,
               "text_done_bytes" => 0,
               "item_done_count" => 1,
               "terminal_seen" => true,
               "terminal_kind" => "failed",
               "terminal_status" => "failed",
               "finish_class" => "failed",
               "synthetic_terminal_sent" => true,
               "source_chunk_count" => 2,
               "stream_bytes" => 64,
               "relay_bytes" => 32,
               "passthrough_seen" => true
             }
    end
  end
end
