defmodule CodexPoolerWeb.V1.ChatStreamArgumentsContractControllerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport, only: [auth: 2, gateway_setup: 1, start_upstream: 1]
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  test "done-only and partial snapshots stream complete arguments and settle the real HTTP attempt", %{conn: conn} do
    for prefix <- ["", "{"], failure? <- [false, true] do
      arguments = CodexPooler.JSON.encode!(%{"prompt" => "synthetic", "description" => "fixture"})
      item = %{"type" => "function_call", "id" => "fc_fixture", "call_id" => "call_fixture", "name" => "fixture_task", "arguments" => arguments, "status" => "completed"}
      snapshot_id = if failure?, do: "fc_wrong", else: item["id"]

      events = [
        {"response.created", %{"type" => "response.created", "response" => %{"id" => "resp_fixture", "status" => "in_progress", "output" => []}}},
        {"response.output_item.added", %{"type" => "response.output_item.added", "output_index" => 0, "item" => Map.put(item, "arguments", prefix)}},
        {"response.function_call_arguments.done", %{"type" => "response.function_call_arguments.done", "output_index" => 0, "item_id" => snapshot_id, "arguments" => arguments}},
        {"response.output_item.done", %{"type" => "response.output_item.done", "output_index" => 0, "item" => item}},
        {"response.completed", %{"type" => "response.completed", "response" => %{"id" => "resp_fixture", "status" => "completed", "output" => [item], "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}}}}
      ]

      upstream =
        start_upstream(
          # provenance: synthetic_adversarial; finalized argument snapshots and conflicting identity controls
          FakeUpstream.strict_sequence([FakeUpstream.expect_request(method: "POST", path: "/backend-api/codex/responses", json: [valid: true], respond: FakeUpstream.sse_stream(events))])
        )

      setup = gateway_setup(upstream)
      response = conn |> recycle() |> auth(setup) |> post("/v1/chat/completions", %{"model" => setup.model.exposed_model_id, "messages" => [%{"role" => "user", "content" => "synthetic"}], "stream" => true})
      assert response.status == 200
      chunks = response.resp_body |> String.split("\n\n", trim: true) |> Enum.reject(&(&1 == "data: [DONE]")) |> Enum.map(fn "data: " <> json -> CodexPooler.JSON.decode!(json) end)
      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
      assert [settlement] = Repo.all(from(e in LedgerEntry, where: e.request_id == ^request.id and e.entry_kind == "settlement"))
      assert settlement.attempt_id == attempt.id
      assert settlement.usage_status == "usage_known"
      assert settlement.total_tokens == 2
      assert request.usage_status == "usage_known"
      assert attempt.usage_status == "usage_known"

      if failure? do
        assert [%{"error" => %{"code" => "server_error"}}] = Enum.filter(chunks, &Map.has_key?(&1, "error"))
        refute response.resp_body =~ "data: [DONE]"
        assert request.status == "failed"
        assert attempt.status == "failed"
        assert request.last_error_code == "upstream_stream_error"
      else
        emitted = chunks |> Enum.flat_map(&(get_in(&1, ["choices", Access.at(0), "delta", "tool_calls"]) || [])) |> Enum.map_join(&(get_in(&1, ["function", "arguments"]) || ""))
        assert :crypto.hash(:sha256, emitted) == :crypto.hash(:sha256, arguments)
        assert response.resp_body =~ "data: [DONE]"
        assert request.status == "succeeded"
        assert attempt.status == "succeeded"
      end

      FakeUpstream.verify!(upstream)
    end
  end
end
