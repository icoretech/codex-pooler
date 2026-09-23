defmodule CodexPooler.Gateway.OpenAICompatibility.PublicResponseTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.OpenAICompatibility.PublicResponse
  alias CodexPooler.Gateway.Transports.MisalignmentPolicyViolation

  describe "Pooler-authored policy denials on /v1" do
    # The exemption is keyed on the `pooler_policy` marker `Denials.log_policy/1`
    # sets by construction, never on the wire code (findings#221).
    test "Pooler-authored policy denials are not redacted, the same codes without the marker are" do
      for code <- PublicResponse.unredacted_policy_denial_codes(),
          status <- [401, 403, 429] do
        refute PublicResponse.redacted_gateway_error?(%{
                 status: status,
                 code: code,
                 message: "own",
                 pooler_policy: true
               })

        refute PublicResponse.redacted_gateway_error?(%{
                 status: status,
                 code: String.to_atom(code),
                 message: "own",
                 pooler_policy: true
               })

        # An upstream-derived error that happens to carry one of the four
        # codes carries no marker and stays redacted: privacy by construction,
        # not by the accident of today's provider vocabulary.
        assert PublicResponse.redacted_gateway_error?(%{
                 status: status,
                 code: code,
                 message: "provider prose that must not leak"
               })
      end

      # A string-keyed marker, the only shape a decoded provider or client body
      # could carry, is not the marker.
      assert PublicResponse.redacted_gateway_error?(%{
               "pooler_policy" => true,
               status: 403,
               code: "model_not_allowed",
               message: "provider prose that must not leak"
             })

      # Quota denials share the 503 status and the redaction with upstream failures.
      assert PublicResponse.redacted_gateway_error?(%{
               status: 503,
               code: "quota_exhausted",
               message: "upstream quota is exhausted until its reset time"
             })

      # An upstream-derived 401/403/429 never carries one of the four codes and
      # stays redacted whatever its message says.
      for {status, code} <- [
            {403, "upstream_status"},
            {401, "upstream_unauthorized"},
            {429, "upstream_rate_limited"},
            {403, "provider_specific_code"}
          ] do
        assert PublicResponse.redacted_gateway_error?(%{
                 status: status,
                 code: code,
                 message: "provider prose that must not leak"
               })
      end

      matrix = CodexPooler.CompatibilityMatrix.fixture!(:v1_supported_surface)

      assert PublicResponse.unredacted_policy_denial_codes() ==
               matrix.public_error_redaction.pooler_policy_denials_unredacted

      assert matrix.public_error_redaction.pooler_policy_denial_marker == "pooler_policy"
    end
  end

  describe "generic error redaction" do
    test "preserves decoded-map projections across existing error classes" do
      generic_error = %{
        "message" => "provider detail",
        "type" => "api_error",
        "code" => "provider_code",
        "param" => "private_param",
        "sibling" => "private_sibling"
      }

      for status <- [401, 403, 404, 500] do
        assert PublicResponse.normalize_error(generic_error, status: status) == %{
                 "code" => "provider_code",
                 "message" => "upstream request failed",
                 "type" => "server_error"
               }
      end

      # A redacted 429 is the classifier's throttle class, OpenAI's
      # `rate_limit_error`, not the retryable server class (findings#254 row
      # 254-72); the SDKs retry it on the status alone.
      assert PublicResponse.normalize_error(generic_error, status: 429) == %{
               "code" => "provider_code",
               "message" => "upstream request failed",
               "type" => "rate_limit_error"
             }

      # Only that rendered throttle keeps its type on a second terminal
      # normalization (findings#254 row 254-82).
      assert PublicResponse.redacted_throttle_error?(PublicResponse.normalize_error(generic_error, status: 429))
      refute PublicResponse.redacted_throttle_error?(PublicResponse.normalize_error(generic_error, status: 500))
      refute PublicResponse.redacted_throttle_error?(%{generic_error | "type" => "rate_limit_error"})

      # A refused 4xx outside the gateway failure statuses is the client's
      # error class, whatever type the provider wrote (findings#254 row
      # 254-51).
      for status <- [400, 409, 422] do
        assert PublicResponse.normalize_error(generic_error, status: status) == %{
                 "code" => "provider_code",
                 "message" => "upstream request failed",
                 "type" => "invalid_request_error"
               }
      end

      assert PublicResponse.normalize_error(
               Map.put(generic_error, "type", "invalid_request_error"),
               status: 400
             ) == %{
               "code" => "provider_code",
               "message" => "upstream request failed",
               "type" => "invalid_request_error"
             }

      assert PublicResponse.normalize_error(
               %{
                 "code" => "server_is_overloaded",
                 "internal_reason" => "bulkhead_rejected",
                 "message" => "private overload detail",
                 "param" => "private_param"
               },
               status: 503
             ) == %{
               "code" => "server_is_overloaded",
               "message" => "gateway route class is temporarily overloaded",
               "param" => nil,
               "type" => "server_error"
             }

      assert PublicResponse.normalize_error(
               %{
                 "code" => "unsupported_parameter",
                 "message" => "Unsupported parameter",
                 "param" => "tools",
                 "sibling" => "private_sibling",
                 "type" => "invalid_request_error"
               },
               status: 400,
               origin: :local_validation
             ) == %{
               "code" => "unsupported_parameter",
               "message" => "Unsupported parameter",
               "param" => "tools",
               "type" => "invalid_request_error"
             }
    end
  end

  describe "upstream input-file capability boundary" do
    test "exposes only a trusted typed 404 classification" do
      upstream_error = %{
        "code" => "provider_not_found",
        "message" => "private upstream input-file limitation",
        "param" => "input[0].content[1].file_id",
        "request_body" => "private request body",
        "type" => "api_error"
      }

      opts = [status: 404, input_file_upstream_404?: true]

      assert PublicResponse.terminal_error_status(upstream_error, opts) == 404

      assert PublicResponse.normalize_error(upstream_error, opts) == %{
               "code" => "upstream_status",
               "message" => "upstream request failed",
               "type" => "invalid_request_error",
               "upstream_status" => 404
             }

      body = CodexPooler.JSON.encode!(%{"error" => upstream_error})

      assert PublicResponse.normalize_raw_body(404, body, &Function.identity/1, input_file_upstream_404?: true) ==
               {:ok,
                %{
                  "error" => %{
                    "code" => "upstream_status",
                    "message" => "upstream request failed",
                    "type" => "invalid_request_error",
                    "upstream_status" => 404
                  }
                }}

      encoded = CodexPooler.JSON.encode!(PublicResponse.normalize_error(upstream_error, opts))
      refute encoded =~ "private upstream input-file limitation"
      refute encoded =~ "input[0].content[1].file_id"
      refute encoded =~ "private request body"
    end

    test "keeps non-capability upstream rejections redacted" do
      upstream_error = %{
        "code" => "provider_not_found",
        "message" => "private upstream detail",
        "param" => "input[0].content[1].file_id",
        "type" => "invalid_request_error"
      }

      assert PublicResponse.terminal_error_status(upstream_error, status: 404) == 502

      assert PublicResponse.normalize_error(upstream_error, status: 404) == %{
               "code" => "provider_not_found",
               "message" => "upstream request failed",
               "type" => "server_error"
             }
    end

    test "does not classify upstream_status without the observed upstream type" do
      upstream_error = %{
        "code" => "upstream_status",
        "message" => "private upstream detail",
        "param" => "input[0].content[1].file_id",
        "type" => "api_error"
      }

      assert PublicResponse.terminal_error_status(upstream_error, status: 404) == 502

      assert PublicResponse.normalize_error(upstream_error, status: 404) == %{
               "code" => "upstream_status",
               "message" => "upstream request failed",
               "type" => "server_error"
             }
    end
  end

  describe "misalignment policy violation" do
    test "projects direct HTTP error bodies through the same narrow shape" do
      body =
        CodexPooler.JSON.encode!(%{
          "error" => %{
            "code" => MisalignmentPolicyViolation.code(),
            "message" => "policy blocked this request",
            "param" => "private_param",
            "sibling" => "private_sibling"
          }
        })

      for status <- [400, 403] do
        assert PublicResponse.normalize_raw_body(status, body, &Function.identity/1) ==
                 {:ok,
                  %{
                    "error" => %{
                      "code" => MisalignmentPolicyViolation.code(),
                      "message" => "policy blocked this request",
                      "type" => "invalid_request_error"
                    }
                  }}
      end
    end

    test "projects only the exact public fields for HTTP and synthetic terminal statuses" do
      fallback = MisalignmentPolicyViolation.fallback_message()

      message_cases = [
        {"policy blocked this request", "policy blocked this request"},
        {nil, fallback},
        {"", fallback},
        {" \t\r\n", fallback}
      ]

      for status <- [400, 403, 502, nil], {message, expected_message} <- message_cases do
        error = %{
          "code" => MisalignmentPolicyViolation.code(),
          "message" => message,
          "param" => "private_param",
          "sibling" => "private_sibling",
          "type" => "api_error"
        }

        assert PublicResponse.normalize_error(error, status: status) == %{
                 "code" => MisalignmentPolicyViolation.code(),
                 "message" => expected_message,
                 "type" => "invalid_request_error"
               }
      end
    end
  end
end
