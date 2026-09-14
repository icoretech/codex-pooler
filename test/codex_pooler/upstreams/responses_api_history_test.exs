defmodule CodexPooler.Upstreams.ResponsesAPIHistoryTest do
  use ExUnit.Case, async: true
  alias CodexPooler.Upstreams.ResponsesAPIHistory, as: History

  test "history is isolated by pool and key, bounded by bytes and least recent use" do
    server = start_supervised!({History, name: nil, max_entries: 2, max_bytes: 300})
    scope = {"pool", "key"}
    assert :ok = History.put(scope, "a", %{"input" => "a"}, server)
    assert :ok = History.put(scope, "b", %{"input" => "b"}, server)
    assert {:ok, _} = History.get(scope, "a", server)
    assert :ok = History.put(scope, "c", %{"input" => "c"}, server)
    assert :missing = History.get(scope, "b", server)
    assert :missing = History.get({"pool", "other-key"}, "a", server)
    assert :missing = History.get({"other-pool", "key"}, "a", server)
    assert :ok = History.put(scope, "large", %{"input" => String.duplicate("a", 400)}, server)
    assert :missing = History.get(scope, "large", server)
  end

  test "expired entries cannot be retrieved" do
    server = start_supervised!({History, name: nil, ttl_ms: 0})
    History.put({"pool", "key"}, "expired", %{}, server)
    assert :missing = History.get({"pool", "key"}, "expired", server)
  end

  test "continuations restore input and options without forwarding previous_response_id" do
    auth = %{pool: %{id: Ecto.UUID.generate()}, api_key: %{id: Ecto.UUID.generate()}}

    call = %{
      "type" => "custom_tool_call",
      "call_id" => "c1",
      "name" => "exec",
      "input" => "run()"
    }

    context =
      History.context(auth, %{"model" => "api", "instructions" => "original", "input" => "hello"})

    History.remember(context, %{"id" => "r1", "status" => "completed", "output" => [call]})
    result = %{"type" => "custom_tool_call_output", "call_id" => "c1", "output" => "done"}

    assert {:ok, expanded} =
             History.expand(%{"previous_response_id" => "r1", "input" => [result]}, auth, true)

    assert expanded["instructions"] == "original"
    assert [%{"content" => "hello"}, ^call, ^result] = expanded["input"]
    refute Map.has_key?(expanded, "previous_response_id")

    assert {:error, %{status: 400, code: "previous_response_not_found"}} =
             History.expand(%{"previous_response_id" => "missing"}, auth, true)

    assert {:ok, %{"previous_response_id" => "r1"}} =
             History.expand(%{"previous_response_id" => "r1"}, auth, false)
  end

  test "compaction replaces history while preserving native tool declarations" do
    auth = %{pool: %{id: Ecto.UUID.generate()}, api_key: %{id: Ecto.UUID.generate()}}
    tools = %{"type" => "additional_tools", "tools" => []}
    compact = %{"type" => "compaction", "encrypted_content" => "sealed"}

    context =
      History.context(auth, %{"input" => [tools, %{"role" => "user", "content" => "old"}]})

    History.remember(context, %{
      "id" => "c1",
      "object" => "response.compaction",
      "status" => "completed",
      "output" => [compact]
    })

    assert {:ok, %{"input" => [^tools, ^compact]}} =
             History.expand(%{"previous_response_id" => "c1"}, auth, true)
  end
end
