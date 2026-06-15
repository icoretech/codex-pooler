defmodule CodexPooler.Gateway.Runtime.FinalizationMetadataCompressionTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Runtime.Finalization.Metadata

  test "HTTP attempt metadata includes safe payload compression savings" do
    sensitive_placeholder =
      "placeholder raw tool output with bearer example-token and private prompt text"

    options =
      request_options()
      |> RequestOptions.put_runtime_context(
        payload_compression:
          compression_metadata(%{
            "raw_candidate" => sensitive_placeholder,
            "call_id" => "call_sensitive_placeholder",
            "json_path" => "$.input[0].output"
          })
      )

    response = %Req.Response{
      status: 200,
      headers: [
        {"content-type", ["application/json"]},
        {"x-request-id", ["req_payload_compression"]}
      ]
    }

    metadata = Metadata.response_metadata(response, nil, options)

    assert metadata["payload_compression"] == expected_compression_metadata()

    assert Metadata.request_metadata(options) == %{
             "payload_compression" => metadata["payload_compression"]
           }

    metadata_text = inspect(metadata["payload_compression"])
    refute metadata_text =~ sensitive_placeholder
    refute metadata_text =~ "call_sensitive_placeholder"
    refute metadata_text =~ "$.input[0].output"
  end

  test "HTTP finalization allowlists payload compression strategy metadata" do
    options =
      request_options()
      |> RequestOptions.put_runtime_context(
        payload_compression:
          compression_metadata(%{
            "strategies" => ["log_output", "call_probe_secret", "json_array_lossless"],
            "candidate_count" => 1
          })
      )

    response = %Req.Response{status: 200, headers: [{"content-type", ["application/json"]}]}
    metadata = Metadata.response_metadata(response, nil, options)

    assert metadata["payload_compression"]["strategies"] == [
             "log_output",
             "json_array_lossless"
           ]

    refute inspect(metadata["payload_compression"]) =~ "call_probe_secret"
  end

  test "HTTP finalization keeps tokenizer input limit metadata without raw skipped content" do
    sensitive_placeholder = "placeholder skipped tokenizer input body"

    options =
      request_options()
      |> RequestOptions.put_runtime_context(
        payload_compression: %{
          "attempted" => true,
          "status" => "skipped",
          "reason" => "tokenizer_input_limit",
          "candidate_count" => 2,
          "compressed_count" => 0,
          "skipped_count" => 2,
          "tokenizer_input_skipped_count" => 2,
          "raw_candidate" => sensitive_placeholder
        }
      )

    response = %Req.Response{status: 200, headers: [{"content-type", ["application/json"]}]}
    metadata = Metadata.response_metadata(response, nil, options)

    assert metadata["payload_compression"] == %{
             "attempted" => true,
             "status" => "skipped",
             "reason" => "tokenizer_input_limit",
             "candidate_count" => 2,
             "compressed_count" => 0,
             "skipped_count" => 2,
             "tokenizer_input_skipped_count" => 2
           }

    assert Metadata.request_metadata(options) == %{
             "payload_compression" => metadata["payload_compression"]
           }

    refute inspect(metadata["payload_compression"]) =~ sensitive_placeholder
  end

  test "websocket attempt metadata includes safe payload compression savings" do
    options =
      request_options()
      |> RequestOptions.for_websocket(%{"model" => "example-model"})
      |> RequestOptions.put_runtime_context(payload_compression: compression_metadata())

    metadata =
      Metadata.websocket_response_metadata(
        [{"openai-request-id", "req_payload_compression_ws"}],
        nil,
        options
      )

    assert metadata["payload_compression"] == expected_compression_metadata()
    assert metadata["upstream_transport"] == "websocket"
  end

  test "payload compression ratios are omitted when denominators are zero" do
    options =
      request_options()
      |> RequestOptions.put_runtime_context(
        payload_compression: %{
          "attempted" => true,
          "status" => "no_change",
          "reason" => "no_token_shrink",
          "original_bytes" => 0,
          "compressed_bytes" => 0,
          "original_tokens" => 0,
          "compressed_tokens" => 0
        }
      )

    response = %Req.Response{status: 200, headers: [{"content-type", ["application/json"]}]}
    metadata = Metadata.response_metadata(response, nil, options)["payload_compression"]

    assert metadata["saved_bytes"] == 0
    assert metadata["saved_tokens"] == 0
    refute Map.has_key?(metadata, "byte_savings_ratio")
    refute Map.has_key?(metadata, "byte_savings_percent")
    refute Map.has_key?(metadata, "token_savings_ratio")
    refute Map.has_key?(metadata, "token_savings_percent")
    refute Map.has_key?(metadata, "compression_ratio")
  end

  test "payload compression metadata stays absent when compression was not attempted" do
    response = %Req.Response{status: 200, headers: [{"content-type", ["application/json"]}]}

    without_metadata = request_options()

    not_attempted =
      RequestOptions.put_runtime_context(without_metadata,
        payload_compression: %{"enabled" => true, "attempted" => false, "status" => "disabled"}
      )

    refute Map.has_key?(
             Metadata.response_metadata(response, nil, without_metadata),
             "payload_compression"
           )

    refute Map.has_key?(
             Metadata.websocket_response_metadata([], nil, without_metadata),
             "payload_compression"
           )

    assert Metadata.request_metadata(without_metadata) == %{}

    refute Map.has_key?(
             Metadata.response_metadata(response, nil, not_attempted),
             "payload_compression"
           )

    assert Metadata.request_metadata(not_attempted) == %{}
  end

  defp request_options do
    RequestOptions.build(
      %{transport: "http_json", upstream_endpoint: "/backend-api/codex/responses"},
      "/backend-api/codex/responses",
      %{"model" => "example-model"}
    )
  end

  defp compression_metadata(extra \\ %{}) do
    Map.merge(
      %{
        "enabled" => true,
        "attempted" => true,
        "status" => "compressed",
        "route_class" => "proxy_stream",
        "transport" => "http",
        "tokenizer" => "local:o200k_base",
        "candidate_count" => 3,
        "compressed_count" => 2,
        "skipped_count" => 1,
        "original_bytes" => 1200,
        "compressed_bytes" => 300,
        "original_tokens" => 600,
        "compressed_tokens" => 150,
        "strategies" => ["log_output", "diff"],
        "elapsed_ms" => 5
      },
      extra
    )
  end

  defp expected_compression_metadata do
    %{
      "enabled" => true,
      "attempted" => true,
      "status" => "compressed",
      "route_class" => "proxy_stream",
      "transport" => "http",
      "tokenizer" => "local:o200k_base",
      "candidate_count" => 3,
      "compressed_count" => 2,
      "skipped_count" => 1,
      "original_bytes" => 1200,
      "compressed_bytes" => 300,
      "saved_bytes" => 900,
      "byte_savings_ratio" => 0.75,
      "byte_savings_percent" => 75.0,
      "compression_ratio" => 0.25,
      "original_tokens" => 600,
      "compressed_tokens" => 150,
      "saved_tokens" => 450,
      "token_savings_ratio" => 0.75,
      "token_savings_percent" => 75.0,
      "strategies" => ["log_output", "diff"],
      "elapsed_ms" => 5
    }
  end
end
