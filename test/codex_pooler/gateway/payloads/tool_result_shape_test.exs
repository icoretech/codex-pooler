defmodule CodexPooler.Gateway.Payloads.ToolResultShapeTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Payloads.ToolResultShape

  test "finds nested current and future tool output shapes" do
    input = [
      %{"type" => "message", "content" => "ordinary"},
      %{
        "type" => "response",
        "items" => [
          %{
            "type" => "function_call_output",
            "call_id" => "call_current",
            "output" => "ok"
          },
          %{
            "type" => "future_tool_result",
            "call_id" => "call_future",
            "result" => %{"ok" => true}
          }
        ]
      }
    ]

    assert ToolResultShape.items(input) == [
             %{type: "function_call_output", call_id: "call_current"},
             %{type: "future_tool_result", call_id: "call_future"}
           ]
  end

  test "requires a call id and result-like payload" do
    refute ToolResultShape.tool_result?(%{"type" => "function_call_output", "output" => "ok"})
    refute ToolResultShape.tool_result?(%{"type" => "message", "call_id" => "call_message"})
    refute ToolResultShape.tool_result?(%{"type" => "function_call_output", "call_id" => " "})

    assert ToolResultShape.items([
             %{"type" => "item_reference", "id" => "msg_existing_fixture"},
             %{"type" => "function_call_output", "call_id" => "call_current", "output" => "ok"}
           ]) == [
             %{type: "function_call_output", call_id: "call_current"}
           ]

    assert ToolResultShape.tool_result?(%{
             "type" => "custom_tool_call_output",
             "call_id" => "call_custom"
           })
  end
end
