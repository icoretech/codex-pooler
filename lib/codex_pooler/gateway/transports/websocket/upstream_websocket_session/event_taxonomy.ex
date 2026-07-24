defmodule CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.EventTaxonomy do
  @moduledoc false

  @terminal_success_event_types ["response.completed", "response.done"]
  @terminal_failure_event_types ["response.failed", "response.incomplete", "error"]
  @response_lifecycle_event_types ["response.created", "response.in_progress", "response.queued"]
  # Exact upstream event names only: a new sibling must surface as response.unknown.
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
  @known_response_event_family_by_type @known_response_event_families
                                       |> Enum.flat_map(fn {family, event_types} ->
                                         Enum.map(event_types, &{&1, family})
                                       end)
                                       |> Map.new()
  # response.other remains readable only for failures forwarded by an older owner.
  @allowed_event_types Enum.uniq(
                         ~w(
                           none
                           invalid_json
                           non_object_json
                           invalid_type
                           missing_type
                           response.unknown
                           response.other
                           codex.rate_limits
                           codex.other
                           other
                         ) ++
                           @terminal_success_event_types ++
                           @terminal_failure_event_types ++
                           @response_lifecycle_event_types ++
                           Map.values(@known_response_event_family_by_type)
                       )
  @allowed_event_classes ~w(
    none
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

  @spec classify(term()) :: {String.t(), String.t()}
  def classify(type) when type in @terminal_success_event_types,
    do: {type, "terminal_success_candidate"}

  def classify(type) when type in @terminal_failure_event_types,
    do: {type, "terminal_failure_candidate"}

  def classify(type) when type in @response_lifecycle_event_types,
    do: {type, "response_lifecycle"}

  def classify("codex.rate_limits"), do: {"codex.rate_limits", "rate_limit_event"}

  def classify(type) when is_binary(type) do
    case Map.fetch(@known_response_event_family_by_type, type) do
      {:ok, family} ->
        {family, "response_event"}

      :error ->
        cond do
          String.starts_with?(type, "response.") ->
            {"response.unknown", "response_unknown_event"}

          String.starts_with?(type, "codex.") ->
            {"codex.other", "codex_event"}

          true ->
            {"other", "other_event"}
        end
    end
  end

  def classify(_type), do: {"invalid_type", "invalid_frame"}

  @spec allowed_event_type?(term()) :: boolean()
  def allowed_event_type?(value) when value in @allowed_event_types, do: true
  def allowed_event_type?(_value), do: false

  @spec allowed_event_class?(term()) :: boolean()
  def allowed_event_class?(value) when value in @allowed_event_classes, do: true
  def allowed_event_class?(_value), do: false
end
