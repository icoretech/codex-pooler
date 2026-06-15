defmodule CodexPooler.Accounting.MetadataTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounting

  describe "sanitize_metadata/1" do
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
            "strategies" => ["log_output", "call_probe_secret", "diff"],
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
      assert compression["strategies"] == ["log_output", "diff"]
      assert compression["candidate_count"] == 2
      assert compression["tokenizer_input_skipped_count"] == 2
      assert compression["raw_candidate"] == "[REDACTED]"
      assert compression["json_path"] == "[REDACTED]"

      compression_text = inspect(compression)
      refute compression_text =~ "call_probe_secret"
      refute compression_text =~ "secretValue"
      refute compression_text =~ "$.input[0].output"
    end
  end
end
