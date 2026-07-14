defmodule CodexPooler.Gateway.Transports.AssignmentModelServingFailoverTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Runtime.Streaming.StreamAttempt

  describe "classification-only contract at the provenance-aware seam" do
    test "structured model_not_found is retryable before visible output" do
      terminal = terminal_event(error_payload("model_not_found", "model"))

      assert {{:retry,
               %{
                 code: "model_not_found",
                 upstream_code: "model_not_found",
                 upstream_error_param: "model"
               }}, %{classified?: true, buffer: ""}} =
               StreamAttempt.classify_first_event(
                 terminal,
                 StreamAttempt.first_event_state(),
                 true
               )
    end

    test "code-less model-param shape is retryable before visible output" do
      terminal = terminal_event(code_less_model_param_payload())

      assert {{:retry,
               %{
                 code: "invalid_request_error",
                 upstream_code: "invalid_request_error",
                 upstream_error_param: "model"
               }}, %{classified?: true, buffer: ""}} =
               StreamAttempt.classify_first_event(
                 terminal,
                 StreamAttempt.first_event_state(),
                 true
               )
    end

    test "leading SSE comment does not hide a coalesced structured model miss" do
      terminal = terminal_event(error_payload("model_not_found", "model"))
      coalesced = ": upstream keepalive\n\n" <> terminal

      assert {{:retry, %{code: "model_not_found", upstream_error_param: "model"}},
              %{classified?: true, buffer: ""}} =
               StreamAttempt.classify_first_event(
                 coalesced,
                 StreamAttempt.first_event_state(),
                 true
               )
    end

    test "leading rate-limit event does not hide a coalesced provenance-backed model miss" do
      rate_limits =
        sse_event("codex.rate_limits", %{
          "type" => "codex.rate_limits",
          "rate_limits" => []
        })

      terminal = terminal_event(code_less_model_param_payload())

      assert {{:retry, %{code: "invalid_request_error", upstream_error_param: "model"}},
              %{classified?: true, buffer: ""}} =
               StreamAttempt.classify_first_event(
                 rate_limits <> terminal,
                 StreamAttempt.first_event_state(),
                 true
               )
    end

    test "bounded leading-block scan fails closed after its classification limit" do
      comments = Enum.map_join(1..33, &": keepalive-#{&1}\n\n")
      terminal = terminal_event(error_payload("model_not_found", "model"))
      stream = comments <> terminal

      assert {{:write, ^stream}, %{classified?: true, buffer: ""}} =
               StreamAttempt.classify_first_event(
                 stream,
                 StreamAttempt.first_event_state(),
                 true
               )
    end

    test "leading comment does not leave a coalesced completed event unclassified" do
      completed =
        sse_event("response.completed", %{
          "type" => "response.completed",
          "response" => %{"id" => "resp_completed"}
        })

      stream = ": upstream keepalive\n\n" <> completed

      assert {{:write, ^stream}, %{classified?: true, buffer: ""}} =
               StreamAttempt.classify_first_event(
                 stream,
                 StreamAttempt.first_event_state(),
                 true
               )
    end
  end

  describe "current non-retry controls" do
    test "structured model_not_found remains terminal when assignment failover is disabled" do
      terminal = terminal_event(error_payload("model_not_found", "model"))

      assert {{:write_terminal_failure, ^terminal,
               %{code: "model_not_found", upstream_error_param: "model"}},
              %{classified?: true, buffer: ""}} =
               StreamAttempt.classify_first_event(
                 terminal,
                 StreamAttempt.first_event_state()
               )
    end

    test "code-less model-param shape requires exact assignment provenance" do
      terminal = terminal_event(code_less_model_param_payload())

      assert {{:write_terminal_failure, ^terminal,
               %{
                 code: "invalid_request_error",
                 upstream_code: "invalid_request_error",
                 upstream_error_param: "model"
               }}, %{classified?: true, buffer: ""}} =
               StreamAttempt.classify_first_event(
                 terminal,
                 StreamAttempt.first_event_state(),
                 false
               )
    end

    test "generic, invalid-model, and continuation misses are written as terminal failures" do
      controls = [
        {"generic", generic_error_payload()},
        {"invalid_model", error_payload("invalid_model", "model")},
        {"previous_response_not_found",
         error_payload("previous_response_not_found", "previous_response_id")}
      ]

      for {_label, payload} <- controls do
        terminal = terminal_event(payload)

        assert {{:write_terminal_failure, ^terminal, _failure}, %{classified?: true, buffer: ""}} =
                 StreamAttempt.classify_first_event(terminal, StreamAttempt.first_event_state())
      end
    end

    test "structured model_not_found after visible output cannot enter the retry branch" do
      created =
        sse_event("response.created", %{
          "type" => "response.created",
          "response" => %{"id" => "resp_example_visible", "status" => "in_progress"}
        })

      assert {{:write, ^created}, state} =
               StreamAttempt.classify_first_event(
                 created,
                 StreamAttempt.first_event_state(),
                 true
               )

      terminal = terminal_event(error_payload("model_not_found", "model"))

      assert {{:write_terminal_failure, ^terminal,
               %{code: "model_not_found", upstream_error_param: "model"}},
              %{classified?: true, buffer: ""}} =
               StreamAttempt.classify_first_event(terminal, state, true)
    end
  end

  defp code_less_model_param_payload do
    %{
      "type" => "response.failed",
      "response" => %{
        "status" => "failed",
        "error" => %{"type" => "invalid_request_error", "param" => "model"}
      }
    }
  end

  defp generic_error_payload do
    %{
      "type" => "response.failed",
      "response" => %{"status" => "failed", "error" => %{"type" => "request_failed"}}
    }
  end

  defp error_payload(code, param) do
    %{
      "type" => "response.failed",
      "response" => %{
        "status" => "failed",
        "error" => %{"code" => code, "type" => "invalid_request_error", "param" => param}
      }
    }
  end

  defp terminal_event(payload), do: sse_event("response.failed", payload)

  defp sse_event(event, payload) do
    "event: #{event}\n" <> "data: #{Jason.encode!(payload)}\n\n"
  end
end
