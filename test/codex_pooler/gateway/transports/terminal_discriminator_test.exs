defmodule CodexPooler.Gateway.Transports.Websocket.TerminalDiscriminatorTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.TerminalDiscriminator

  @bounded_event_types ~w(
    invalid_json
    non_object_json
    invalid_type
    missing_type
    response.completed
    response.done
    response.failed
    response.incomplete
    error
    response.created
    response.in_progress
    response.queued
    response.output_text
    response.output_item
    response.content_part
    response.reasoning
    response.refusal
    response.audio
    response.function_call
    response.custom_tool_call
    response.code_interpreter
    response.file_search
    response.web_search
    response.image_generation
    response.mcp_call
    response.mcp_list_tools
    response.metadata
    response.moderation
    response.unknown
    codex.rate_limits
    codex.other
    other
  )
  @bounded_event_classes ~w(
    invalid_frame
    terminal_success_candidate
    terminal_failure_candidate
    legacy_success_candidate
    response_lifecycle
    response_event
    response_unknown_event
    rate_limit_event
    codex_event
    untyped_event
    other_event
  )
  @bounded_candidate_types [
    "response.completed",
    "response.done",
    "response.failed",
    "response.incomplete",
    "error",
    "legacy_response"
  ]
  @bounded_candidate_classes ~w(success failure legacy_success)
  @bounded_candidate_rejections ~w(
    missing_response_object
    invalid_response_status
    invalid_legacy_id
    parser_rejected
  )
  @bounded_terminals [
    "response.completed",
    "response.failed",
    "response.incomplete",
    "error"
  ]
  @known_response_event_families [
    {"response.output_text", ~w(
       response.output_text.delta
       response.output_text.done
       response.output_text.annotation.added
     )},
    {"response.output_item", ~w(response.output_item.added response.output_item.done)},
    {"response.content_part", ~w(response.content_part.added response.content_part.done)},
    {"response.reasoning", ~w(
       response.reasoning_text.delta
       response.reasoning_text.done
       response.reasoning_summary.delta
       response.reasoning_summary.done
       response.reasoning_summary_text.delta
       response.reasoning_summary_text.done
       response.reasoning_summary_part.added
       response.reasoning_summary_part.done
     )},
    {"response.refusal", ~w(response.refusal.delta response.refusal.done)},
    {"response.audio", ~w(
       response.audio.delta
       response.audio.done
       response.audio.transcript.delta
       response.audio.transcript.done
     )},
    {"response.function_call",
     ~w(response.function_call_arguments.delta response.function_call_arguments.done)},
    {"response.custom_tool_call",
     ~w(response.custom_tool_call_input.delta response.custom_tool_call_input.done)},
    {"response.code_interpreter", ~w(
       response.code_interpreter_call.in_progress
       response.code_interpreter_call.interpreting
       response.code_interpreter_call.completed
       response.code_interpreter_call_code.delta
       response.code_interpreter_call_code.done
     )},
    {"response.file_search", ~w(
       response.file_search_call.in_progress
       response.file_search_call.searching
       response.file_search_call.completed
     )},
    {"response.web_search", ~w(
       response.web_search_call.in_progress
       response.web_search_call.searching
       response.web_search_call.completed
     )},
    {"response.image_generation", ~w(
       response.image_generation_call.in_progress
       response.image_generation_call.generating
       response.image_generation_call.partial_image
       response.image_generation_call.completed
     )},
    {"response.mcp_call", ~w(
       response.mcp_call.in_progress
       response.mcp_call_arguments.delta
       response.mcp_call_arguments.done
       response.mcp_call.completed
       response.mcp_call.failed
     )},
    {"response.mcp_list_tools", ~w(
       response.mcp_list_tools.in_progress
       response.mcp_list_tools.completed
       response.mcp_list_tools.failed
     )},
    {"response.metadata", ~w(response.metadata)},
    {"response.moderation", ~w(response.moderation.started response.moderation.completed)}
  ]

  test "classifies upstream response websocket event families without treating sibling events as terminals" do
    cases = [
      {%{"type" => "response.created"}, "response.created", "response_lifecycle"},
      {%{"type" => "response.in_progress"}, "response.in_progress", "response_lifecycle"},
      {%{"type" => "response.queued"}, "response.queued", "response_lifecycle"},
      {%{"type" => "response.create"}, "response.unknown", "response_unknown_event"},
      {%{"type" => "response.private_event"}, "response.unknown", "response_unknown_event"},
      {%{"type" => "codex.rate_limits"}, "codex.rate_limits", "rate_limit_event"},
      {%{"type" => "codex.keepalive"}, "codex.other", "codex_event"},
      {%{"type" => "provider.private"}, "other", "other_event"}
    ]

    for {event, expected_type, expected_class} <- cases do
      discriminator = classify(event)

      assert discriminator.last_upstream_event_type == expected_type
      assert discriminator.last_upstream_event_class == expected_class
      refute discriminator.terminal_candidate?
      assert discriminator.terminal == nil
    end
  end

  test "uses the shared protocol outcome for official and Codex terminal variants" do
    completed = classify(%{"type" => "response.completed", "response" => %{"id" => "resp_1"}})
    done = classify(%{"type" => "response.done", "response" => %{"id" => "resp_2"}})
    failed = classify(%{"type" => "response.failed"})
    incomplete = classify(%{"type" => "response.incomplete"})
    error = classify(%{"type" => "error"})

    assert completed.terminal == "response.completed"
    assert done.terminal == "response.completed"
    assert failed.terminal == "response.failed"
    assert incomplete.terminal == "response.incomplete"
    assert error.terminal == "error"

    for discriminator <- [completed, done, failed, incomplete, error] do
      assert discriminator.terminal_candidate?
      assert discriminator.terminal_candidate_rejection == nil
    end
  end

  test "maps every allowlisted nonterminal response event to its finite family" do
    for {family, event_types} <- @known_response_event_families,
        event_type <- event_types do
      discriminator = classify(%{"type" => event_type})

      assert discriminator.last_upstream_event_type == family
      assert discriminator.last_upstream_event_class == "response_event"
      refute discriminator.terminal_candidate?
      assert discriminator.terminal == nil
    end
  end

  test "records why a success-shaped terminal was rejected without retaining controlled fields" do
    sentinel = "private-terminal-status-deadbeef"

    discriminator =
      classify(%{
        "type" => "response.done",
        "response" => %{
          "id" => "private-response-id-cafefeed",
          "status" => sentinel
        }
      })

    assert discriminator.terminal == nil
    assert discriminator.terminal_candidate?
    assert discriminator.terminal_candidate_type == "response.done"
    assert discriminator.terminal_candidate_class == "success"
    assert discriminator.terminal_candidate_rejection == "invalid_response_status"
    refute inspect(discriminator) =~ sentinel
    refute inspect(discriminator) =~ "private-response-id"
  end

  test "arbitrary upstream values collapse into finite metadata buckets" do
    for index <- 1..256 do
      sentinel = "private-event-#{index}-deadbeef"

      discriminator =
        classify(%{
          "type" =>
            case rem(index, 3) do
              0 -> "response.#{sentinel}"
              1 -> "codex.#{sentinel}"
              2 -> sentinel
            end,
          "response" => %{"id" => sentinel, "status" => sentinel},
          "payload" => sentinel
        })

      assert discriminator.last_upstream_event_type in @bounded_event_types
      assert discriminator.last_upstream_event_class in @bounded_event_classes
      assert discriminator.terminal_candidate_type in [nil | @bounded_candidate_types]
      assert discriminator.terminal_candidate_class in [nil | @bounded_candidate_classes]

      assert discriminator.terminal_candidate_rejection in [
               nil | @bounded_candidate_rejections
             ]

      assert discriminator.terminal in [nil | @bounded_terminals]
      refute inspect(discriminator) =~ sentinel
    end
  end

  defp classify(event), do: event |> Jason.encode!() |> TerminalDiscriminator.classify()
end
