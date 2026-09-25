defmodule CodexPoolerWeb.V1.ChatReasoningAliasControllerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport, only: [auth: 2, gateway_setup: 1, start_upstream: 1]
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3]

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  test "Full and Lite streaming and collected Chat aliases reach the real HTTP upstream with canonical effort", %{conn: conn} do
    scope = model_serving_scope()

    for mode <- ["full", "lite"], stream <- [true, false] do
      upstream = strict_upstream(completed_response())
      setup = gateway_setup(upstream)
      set_model_serving_mode!(scope, setup, mode)
      response = conn |> recycle() |> auth(setup) |> post("/v1/chat/completions", payload(setup, "medium", stream))
      assert response.status == 200

      if stream do
        assert response.resp_body =~ "chat.completion.chunk"
        assert response.resp_body =~ "data: [DONE]"
      else
        assert %{"object" => "chat.completion"} = json_response(response, 200)
      end

      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.json["reasoning"]["effort"] == "medium"
      refute Map.has_key?(captured.json, "reasoning_effort")
      refute Map.has_key?(captured.json, "user")

      if mode == "full",
        do: assert(Enum.map(captured.json["tools"], & &1["type"]) == ["function", "custom"]),
        else: refute(Map.has_key?(captured.json, "tools"))

      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert request.status == "succeeded"
      assert request.reasoning_effort == "medium"
      assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) == 1
      FakeUpstream.verify!(upstream)
    end
  end

  test "alias cannot bypass maximum reasoning policy and reports the client field", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "must_not_dispatch"}))
    setup = gateway_setup(upstream)
    setup.api_key |> Ecto.Changeset.change(maximum_reasoning_effort: "medium") |> Repo.update!()
    response = conn |> auth(setup) |> post("/v1/chat/completions", payload(setup, "high", false))
    assert %{"error" => %{"code" => "reasoning_effort_not_allowed", "param" => "reasoning"}} = json_response(response, 400)
    assert FakeUpstream.count(upstream) == 0
    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "rejected"
    assert Repo.aggregate(from(a in Attempt, where: a.request_id == ^request.id), :count) == 0
    assert Repo.aggregate(from(l in LedgerEntry, where: l.request_id == ^request.id), :count) == 0
  end

  test "enforced reasoning policy still replaces the alias", %{conn: conn} do
    upstream = strict_upstream(completed_response())
    setup = gateway_setup(upstream)
    setup.api_key |> Ecto.Changeset.change(enforced_reasoning_effort: "high") |> Repo.update!()
    response = conn |> auth(setup) |> post("/v1/chat/completions", payload(setup, "low", false))
    assert response.status == 200
    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.json["reasoning"]["effort"] == "high"
    FakeUpstream.verify!(upstream)
  end

  test "upstream effort validation refers to the alias the client sent", %{conn: conn} do
    upstream = strict_upstream(FakeUpstream.json_response(%{"error" => %{"type" => "invalid_request_error", "code" => "unsupported_value", "param" => "reasoning.effort", "message" => "synthetic upstream rejection"}}, 400))
    setup = gateway_setup(upstream)
    response = conn |> auth(setup) |> post("/v1/chat/completions", payload(setup, "focused", false))
    assert %{"error" => %{"param" => "reasoning"}} = json_response(response, 400)
    FakeUpstream.verify!(upstream)
  end

  test "invalid or conflicting aliases reject before dispatch or accounting", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "must_not_dispatch"}))
    setup = gateway_setup(upstream)

    for extra <- [%{"reasoning" => "invalid value"}, %{"reasoning_effort" => "high"}] do
      response = conn |> recycle() |> auth(setup) |> post("/v1/chat/completions", Map.merge(payload(setup, "medium", false), extra))
      assert %{"error" => %{"param" => "reasoning"}} = json_response(response, 400)
    end

    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 0
  end

  defp strict_upstream(response) do
    start_upstream(
      # provenance: synthetic_adversarial; synthetic upstream reply, HTTP Responses boundary
      FakeUpstream.strict_sequence([
        FakeUpstream.expect_request(method: "POST", path: "/backend-api/codex/responses", json: [valid: true, forbidden: ["reasoning_effort", "user"]], respond: response)
      ])
    )
  end

  defp completed_response do
    FakeUpstream.sse_stream([
      {"response.completed", %{"type" => "response.completed", "response" => %{"id" => "resp_synthetic_reasoning_alias", "status" => "completed", "model" => "sample-model", "output" => [], "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}}}}
    ])
  end

  # Observed Cursor 3.22.7 envelope shape; content, user, and tool names/schema are synthetic.
  defp payload(setup, effort, stream) do
    %{
      "model" => setup.model.exposed_model_id,
      "messages" => [%{"role" => "user", "content" => "synthetic"}],
      "reasoning" => effort,
      "stream" => stream,
      "stream_options" => %{"include_usage" => true},
      "user" => "synthetic-user",
      "tools" => [
        %{"type" => "function", "function" => %{"name" => "read_fixture", "parameters" => %{"type" => "object", "properties" => %{}}}},
        %{"type" => "custom", "name" => "apply_fixture", "format" => %{"type" => "text"}}
      ]
    }
  end
end
