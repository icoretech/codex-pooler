defmodule CodexPooler.Gateway.Transports.ModelUnavailabilityTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Transports.ModelUnavailability
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol.ErrorCodes

  describe "http_response?/3" do
    test "accepts exact model_not_found from every structured error envelope" do
      for envelope <- supported_envelopes() do
        body =
          envelope
          |> error_payload(%{
            "code" => "model_not_found",
            "type" => "invalid_request_error",
            "param" => "model"
          })
          |> Jason.encode!()

        assert ModelUnavailability.http_response?(400, body, false),
               "expected #{envelope} to expose model_not_found"
      end
    end

    test "accepts exact model_not_found at retryable statuses without assignment provenance" do
      body = http_error(%{"code" => "model_not_found", "param" => "model"})

      assert ModelUnavailability.http_response?(429, body, false)
      assert ModelUnavailability.http_response?(500, body, false)
    end

    test "accepts invalid_request_error model misses only at 404 with assignment provenance" do
      for envelope <- supported_envelopes() do
        error =
          if envelope == :wrapped_top_level do
            %{"code" => "invalid_request_error", "param" => "model"}
          else
            %{"type" => "invalid_request_error", "param" => "model"}
          end

        body = envelope |> error_payload(error) |> Jason.encode!()

        assert ModelUnavailability.http_response?(404, body, true),
               "expected #{envelope} to expose the provenance-backed model miss"

        refute ModelUnavailability.http_response?(404, body, false),
               "expected #{envelope} to require assignment provenance"

        refute ModelUnavailability.http_response?(400, body, true),
               "expected #{envelope} to require HTTP 404"
      end
    end

    test "rejects malformed, plain, unrelated, continuation, and message-only errors" do
      fixtures = [
        {404, "not-json"},
        {404, Jason.encode!(%{})},
        {404, http_error(%{"type" => "invalid_request_error"})},
        {404, http_error(%{"type" => "invalid_request_error", "param" => "input"})},
        {404, http_error(%{"code" => "unknown_model_error", "param" => "model"})},
        {404, http_error(%{"code" => "invalid_model", "param" => "model"})},
        {404,
         http_error(%{
           "code" => "previous_response_not_found",
           "param" => "previous_response_id"
         })},
        {404, http_error(%{"message" => "model not found", "param" => "model"})}
      ]

      for {status, body} <- fixtures do
        refute ModelUnavailability.http_response?(status, body, true)
      end
    end

    test "returns only a boolean and does not retain raw error values" do
      raw_sentinel = "raw-upstream-message-sentinel"

      body =
        http_error(%{
          "type" => "invalid_request_error",
          "param" => "model",
          "message" => raw_sentinel
        })

      result = ModelUnavailability.http_response?(404, body, true)

      assert result == true
      refute inspect(result) =~ raw_sentinel
    end

    test "uses the structured error envelope precedence" do
      decoded = %{
        "type" => "error",
        "code" => "fifth",
        "status_details" => %{"error" => %{"code" => "fourth"}},
        "error" => %{"code" => "second"},
        "response" => %{
          "error" => %{"code" => "first"},
          "status_details" => %{"error" => %{"code" => "third"}}
        }
      }

      assert ErrorCodes.structured_error_code(decoded) == "first"
    end
  end

  describe "terminal_failure?/2" do
    test "accepts exact model_not_found without assignment provenance" do
      assert ModelUnavailability.terminal_failure?(terminal_failure("model_not_found"), false)
    end

    test "accepts invalid_request_error model misses only with assignment provenance" do
      failure = terminal_failure("invalid_request_error")

      assert ModelUnavailability.terminal_failure?(failure, true)
      refute ModelUnavailability.terminal_failure?(failure, false)
    end

    test "rejects other params, unknown codes, invalid_model, and continuation misses" do
      fixtures = [
        terminal_failure("invalid_request_error", "input"),
        terminal_failure("unknown_model_error"),
        terminal_failure("invalid_model"),
        terminal_failure("previous_response_not_found", "previous_response_id"),
        terminal_failure("stream_incomplete", "previous_response_id")
      ]

      for failure <- fixtures do
        refute ModelUnavailability.terminal_failure?(failure, true)
      end
    end

    test "does not retain data outside the sanitized terminal failure" do
      raw_sentinel = "raw-terminal-message-sentinel"
      failure = Map.put(terminal_failure("invalid_request_error"), :raw_message, raw_sentinel)

      result = ModelUnavailability.terminal_failure?(failure, true)

      assert result == true
      refute inspect(result) =~ raw_sentinel
    end
  end

  defp supported_envelopes do
    [
      :response_error,
      :error,
      :response_status_details_error,
      :status_details_error,
      :wrapped_top_level
    ]
  end

  defp error_payload(:response_error, error), do: %{"response" => %{"error" => error}}
  defp error_payload(:error, error), do: %{"error" => error}

  defp error_payload(:response_status_details_error, error),
    do: %{"response" => %{"status_details" => %{"error" => error}}}

  defp error_payload(:status_details_error, error),
    do: %{"status_details" => %{"error" => error}}

  defp error_payload(:wrapped_top_level, error), do: Map.put(error, "type", "error")

  defp http_error(error), do: Jason.encode!(%{"error" => error})

  defp terminal_failure(code, param \\ "model") do
    %{
      code: code,
      upstream_code: code,
      upstream_error_param: param,
      event_type: "response.failed",
      data_type: "response.failed"
    }
  end
end
