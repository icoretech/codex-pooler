defmodule CodexPoolerWeb.V1.ChatFunctionStrictDefaultControllerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport, only: [auth: 2, gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  test "Full Chat sends explicit non-strict defaults and retains explicit true and false on real HTTP egress", %{conn: conn} do
    for flag <- [%{}, %{"strict" => nil}, %{"strict" => false}, %{"strict" => true}], stream <- [false, true] do
      upstream = start_upstream(completed_upstream())
      setup = gateway_setup(upstream)
      tool = function_tool(flag)
      payload = %{"model" => setup.model.exposed_model_id, "messages" => [%{"role" => "user", "content" => "synthetic"}], "tools" => [tool], "stream" => stream}
      response = conn |> recycle() |> auth(setup) |> post("/v1/chat/completions", payload)
      assert response.status == 200
      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.method == "POST"
      assert captured.path == "/backend-api/codex/responses"
      assert [captured_tool] = captured.json["tools"]
      assert Map.fetch(captured_tool, "strict") == {:ok, flag["strict"] == true}
      assert captured_tool["parameters"] == tool["function"]["parameters"]
      FakeUpstream.verify!(upstream)
    end
  end

  test "direct Responses and Chat input fallback keep the Responses default on HTTP egress", %{conn: conn} do
    for route <- ["/v1/responses", "/v1/chat/completions"], flag <- [%{}, %{"strict" => nil}] do
      upstream = start_upstream(completed_upstream())
      setup = gateway_setup(upstream)
      tool = function_tool(flag)["function"] |> Map.put("type", "function")
      payload = %{"model" => setup.model.exposed_model_id, "input" => "synthetic", "tools" => [tool]}
      response = conn |> recycle() |> auth(setup) |> post(route, payload)
      assert response.status == 200
      assert [captured] = FakeUpstream.requests(upstream)
      assert [captured_tool] = captured.json["tools"]
      refute Map.has_key?(captured_tool, "strict")
      FakeUpstream.verify!(upstream)
    end
  end

  test "malformed Chat strict still rejects before upstream dispatch and accounting", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "must_not_dispatch"}))
    setup = gateway_setup(upstream)

    for strict <- ["false", 0, %{}, []] do
      payload = %{"model" => setup.model.exposed_model_id, "messages" => [%{"role" => "user", "content" => "synthetic"}], "tools" => [function_tool(%{"strict" => strict})]}
      response = conn |> recycle() |> auth(setup) |> post("/v1/chat/completions", payload)
      assert %{"error" => %{"param" => "tools"}} = json_response(response, 400)
    end

    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 0
  end

  defp completed_upstream do
    # provenance: synthetic_adversarial; synthetic response proving outgoing HTTP schema, not model output quality
    FakeUpstream.strict_sequence([
      FakeUpstream.expect_request(
        method: "POST",
        path: "/backend-api/codex/responses",
        json: [valid: true],
        respond:
          FakeUpstream.sse_stream([
            {"response.completed", %{"type" => "response.completed", "response" => %{"id" => "resp_synthetic_strict_default", "status" => "completed", "model" => "sample-model", "output" => [], "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}}}}
          ])
      )
    ])
  end

  # Observed nested function shape with required path and optional integer limit/offset; name/content are synthetic.
  defp function_tool(flag) do
    parameters = %{
      "type" => "object",
      "properties" => %{"path" => %{"type" => "string"}, "limit" => %{"type" => "integer"}, "offset" => %{"type" => "integer"}},
      "required" => ["path"]
    }

    parameters = if flag["strict"] == true, do: Map.merge(parameters, %{"required" => ["path", "limit", "offset"], "additionalProperties" => false}), else: parameters
    %{"type" => "function", "function" => Map.merge(%{"name" => "read_fixture", "parameters" => parameters}, flag)}
  end
end
