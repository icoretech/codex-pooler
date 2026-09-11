defmodule CodexPooler.Upstreams.ResponsesAPIToolsTest do
  use ExUnit.Case, async: true
  alias CodexPooler.Upstreams.ResponsesAPITools, as: Tools

  defp payload do
    %{
      "input" => [
        %{
          "type" => "additional_tools",
          "role" => "developer",
          "tools" => [
            %{
              "type" => "namespace",
              "name" => "functions",
              "tools" => [
                %{
                  "type" => "custom",
                  "name" => "exec",
                  "description" => "Run JavaScript",
                  "format" => %{"type" => "grammar"}
                },
                %{"type" => "function", "name" => "wait", "parameters" => %{"type" => "object"}}
              ]
            }
          ]
        },
        %{"type" => "message", "role" => "user", "content" => "hello"}
      ]
    }
  end

  test "lifts additional_tools and lowers namespace/custom declarations" do
    {lowered, bindings} = Tools.prepare(payload())
    assert [%{"type" => "message"}] = lowered["input"]
    assert length(lowered["tools"]) == 2
    assert Enum.all?(lowered["tools"], &(&1["type"] == "function"))
    exec = Enum.find(lowered["tools"], &bindings[&1["name"]].custom?)
    assert exec["parameters"]["required"] == ["input"]
    assert bindings[exec["name"]] == %{name: "exec", namespace: "functions", custom?: true}
  end

  test "custom calls and results round-trip through function history" do
    {lowered, bindings} = Tools.prepare(payload())
    name = Enum.find_value(bindings, fn {name, binding} -> if binding.custom?, do: name end)

    call = %{
      "type" => "function_call",
      "id" => "fc1",
      "call_id" => "c1",
      "name" => name,
      "arguments" => JSON.encode!(%{"input" => "await run()"})
    }

    response = Tools.response(%Req.Response{body: JSON.encode!(%{"output" => [call]})}, bindings)
    [restored] = JSON.decode!(response.body)["output"]
    assert restored["type"] == "custom_tool_call"
    assert restored["input"] == "await run()"
    assert restored["namespace"] == "functions"

    history =
      lowered
      |> Map.put("input", [
        restored,
        %{"type" => "custom_tool_call_output", "call_id" => "c1", "output" => "ok"}
      ])

    {next, _bindings} = Tools.prepare(history)

    assert [
             %{"type" => "function_call", "name" => ^name},
             %{"type" => "function_call_output", "call_id" => "c1"}
           ] = next["input"]
  end

  test "current tool declarations replace earlier definitions and explicit empty tools stay empty" do
    declaration = %{
      "type" => "additional_tools",
      "tools" => [%{"type" => "function", "name" => "run", "description" => "old"}]
    }

    updated = put_in(declaration, ["tools", Access.at(0), "description"], "new")
    payload = %{"input" => [declaration, updated]}
    {lowered, _bindings} = Tools.prepare(payload)
    assert [%{"name" => "run", "description" => "new"}] = lowered["tools"]
    {disabled, bindings} = Tools.prepare(Map.put(payload, "tools", []))
    assert disabled["tools"] == []
    assert bindings == %{}
  end

  test "fragmented SSE restores custom tool input without forwarding JSON argument deltas" do
    {_lowered, bindings} = Tools.prepare(payload())
    name = Enum.find_value(bindings, fn {name, binding} -> if binding.custom?, do: name end)
    input = "await tools.exec_command({cmd: 'echo hello'})"
    arguments = JSON.encode!(%{"input" => input})

    item = %{
      "type" => "function_call",
      "id" => "fc1",
      "call_id" => "c1",
      "name" => name,
      "arguments" => ""
    }

    events = [
      %{"type" => "response.output_item.added", "item" => item},
      %{
        "type" => "response.function_call_arguments.delta",
        "item_id" => "fc1",
        "delta" => arguments
      },
      %{
        "type" => "response.function_call_arguments.done",
        "item_id" => "fc1",
        "arguments" => arguments
      },
      %{"type" => "response.output_item.done", "item" => Map.put(item, "arguments", arguments)},
      %{
        "type" => "response.completed",
        "response" => %{"output" => [Map.put(item, "arguments", arguments)]}
      }
    ]

    bytes = Enum.map_join(events, "", &("data: " <> JSON.encode!(&1) <> "\r\n\r\n"))

    {parts, _state} =
      Enum.map_reduce(:binary.bin_to_list(bytes), nil, fn byte, state ->
        Tools.stream(<<byte>>, bindings, state)
      end)

    output = IO.iodata_to_binary(parts)

    decoded =
      output
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data: "))
      |> Enum.map(&JSON.decode!(String.replace_prefix(&1, "data: ", "")))

    assert Enum.any?(
             decoded,
             &(&1["type"] == "response.custom_tool_call_input.delta" and &1["delta"] == input)
           )

    refute Enum.any?(decoded, &(&1["type"] == "response.function_call_arguments.delta"))
    assert Enum.map(decoded, & &1["sequence_number"]) == Enum.to_list(0..(length(decoded) - 1))
    done = List.last(decoded)["response"]["output"] |> hd()
    assert done["name"] == "exec" and done["namespace"] == "functions" and done["input"] == input
  end
end
