defmodule CodexPooler.Gateway.Payloads.ToolResultShapeTest do
  use ExUnit.Case, async: false

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.DebugPayloadSummary
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

  test "preserves depth-first ordering across mixed keys and repeated tool outputs" do
    input = [
      %{
        :type => "response",
        "items" => [
          %{"call_id" => "call_first", "output" => "ok", "type" => "function_call_output"},
          %{
            "nested" => %{
              :type => "future_tool_output",
              "call_id" => "call_nested",
              "result" => %{"ok" => true}
            }
          }
        ]
      },
      %{"call_id" => "call_last", "output" => ["ok"], "type" => "custom_tool_call_output"}
    ]

    assert ToolResultShape.items(input) == [
             %{type: "function_call_output", call_id: "call_first"},
             %{type: "unknown_tool_output", call_id: "call_nested"},
             %{type: "custom_tool_call_output", call_id: "call_last"}
           ]
  end

  @tag :structured_tool_result_pass_through
  test "debug payload summary keeps structured tool output shape-only" do
    previous_config = Application.get_env(:codex_pooler, OperationalSettings, [])

    Application.put_env(
      :codex_pooler,
      OperationalSettings,
      previous_config
      |> Keyword.put(:settings, %OperationalSettings{gateway_debug?: true})
      |> Keyword.put(:use_instance_settings?, false)
    )

    on_exit(fn ->
      Application.put_env(:codex_pooler, OperationalSettings, previous_config)
    end)

    previous_response_id = "resp_payload_shape_previous"
    call_id = "call_payload_shape_structured"

    payload = %{
      "model" => "gpt-fixture-text",
      "previous_response_id" => previous_response_id,
      "input" => [
        %{
          "type" => "function_call_output",
          "call_id" => call_id,
          "output" => structured_tool_result_output()
        }
      ]
    }

    assert summary =
             DebugPayloadSummary.record(
               "/backend-api/codex/responses",
               payload,
               payload,
               %{request_id: "req_payload_shape"},
               "http_sse"
             )

    assert get_in(summary, ["shape", "client", "entries", "tool_result_count"]) == 1
    assert get_in(summary, ["items", "tool_result_types"]) == ["function_call_output"]
    assert get_in(summary, ["previous_response_id_summary", "action"]) == "preserved"
    assert get_in(summary, ["previous_response_id_summary", "preview"]) != previous_response_id
    assert get_in(summary, ["items", "tool_result_call_id_previews"]) != [call_id]

    summary_text = inspect(summary)
    assert_no_sentinel_echo!(summary_text, structured_tool_result_sentinels())
    refute summary_text =~ previous_response_id
    refute summary_text =~ call_id
  end

  defp structured_tool_result_output do
    %{
      "command" => "TASK7_RAW_TOOL_COMMAND_SENTINEL run private command",
      "files" => [
        %{
          "path" => "sample-output.txt",
          "content" => "TASK7_RAW_TOOL_OUTPUT_SENTINEL\n" <> String.duplicate("line\n", 200)
        }
      ],
      "nested" => %{
        "list" => [
          %{"stdout_preview" => String.duplicate("TASK7_LONG_NESTED_VALUE_", 40)},
          %{"secret_like" => "TASK7_SECRET_LIKE_TOOL_SENTINEL"}
        ]
      }
    }
  end

  defp structured_tool_result_sentinels do
    [
      "TASK7_RAW_TOOL_COMMAND_SENTINEL",
      "TASK7_RAW_TOOL_OUTPUT_SENTINEL",
      "TASK7_LONG_NESTED_VALUE_",
      "TASK7_SECRET_LIKE_TOOL_SENTINEL"
    ]
  end

  defp assert_no_sentinel_echo!(text, sentinels) when is_binary(text) do
    Enum.each(sentinels, fn sentinel ->
      if text =~ sentinel,
        do: flunk("debug payload summary leaked structured tool-result sentinel")
    end)
  end
end
