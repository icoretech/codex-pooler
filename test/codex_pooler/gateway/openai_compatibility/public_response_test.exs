defmodule CodexPooler.Gateway.OpenAICompatibility.PublicResponseTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.OpenAICompatibility.PublicResponse
  alias CodexPooler.Gateway.Transports.MisalignmentPolicyViolation

  describe "generic error redaction" do
    test "preserves decoded-map projections across existing error classes" do
      generic_error = %{
        "message" => "provider detail",
        "type" => "api_error",
        "code" => "provider_code",
        "param" => "private_param",
        "sibling" => "private_sibling"
      }

      for status <- [400, 401, 403, 429, 500] do
        assert PublicResponse.normalize_error(generic_error, status: status) == %{
                 "code" => "provider_code",
                 "message" => "upstream request failed",
                 "type" => "server_error"
               }
      end

      assert PublicResponse.normalize_error(
               Map.put(generic_error, "type", "invalid_request_error"),
               status: 400
             ) == %{
               "code" => "provider_code",
               "message" => "upstream request failed",
               "type" => "server_error"
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

  describe "misalignment policy violation" do
    test "projects direct HTTP error bodies through the same narrow shape" do
      body =
        Jason.encode!(%{
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
