defmodule CodexPoolerWeb.Runtime.ModelDeclarationEvidenceTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Pools.ModelServingOverride
  alias CodexPooler.Repo

  @usage %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}

  for mode <- ~w(full lite), route <- ["/backend-api/codex/responses", "/v1/responses", "/v1/chat/completions"], streaming <- [true, false] do
    @tag mode: mode, route: route, streaming: streaming
    test "#{mode} #{route} stream=#{streaming} records response evidence and preserves settlement", ctx do
      events = declaration_events()
      json? = not ctx.streaming and ctx.route == "/backend-api/codex/responses"
      upstream = start_upstream(if(json?, do: FakeUpstream.json_response(List.last(events)["response"]), else: FakeUpstream.sse_stream(Enum.map(events, &sse/1))))
      setup = gateway_setup(upstream)
      set_mode(setup, ctx.mode)
      input = if ctx.route == "/v1/chat/completions", do: %{"messages" => [%{"role" => "user", "content" => "synthetic model observation"}]}, else: %{"input" => [%{"role" => "user", "content" => [%{"type" => "input_text", "text" => "synthetic model observation"}]}]}
      payload = Map.merge(input, %{"model" => setup.model.exposed_model_id, "stream" => ctx.streaming})
      response = ctx.conn |> auth(setup) |> post(ctx.route, payload)
      assert response.status == 200

      if ctx.streaming and ctx.route == "/backend-api/codex/responses", do: assert(response.resp_body == Enum.map_join(events, &sse/1) <> "data: [DONE]\n\n")
      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert request.status == "succeeded"
      assert request.retry_count == 0
      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
      assert attempt.served_model == "model-a"
      assert attempt.model_observation["version"] == 1
      assert attempt.model_observation["conflict"] == not json?
      assert attempt.model_observation["first_conflicting_model"] == if(json?, do: nil, else: "model-b")
      assert attempt.model_observation["terminal_model"] == "model-a"
      assert attempt.model_observation["terminal_status"] in ["completed", "json"]
      assert attempt.response_metadata["routing"]["model_serving_mode"] == ctx.mode
      assert [settlement] = Repo.all(from(l in LedgerEntry, where: l.request_id == ^request.id and l.entry_kind == "settlement"))
      assert {settlement.input_tokens, settlement.output_tokens, settlement.total_tokens} == {3, 2, 5}
      assert Decimal.equal?(settlement.settled_cost_micros, Decimal.new(70))
      assert length(FakeUpstream.requests(upstream)) == 1
    end
  end

  for mode <- ~w(full lite), failure <- [:interrupted, :failed] do
    @tag mode: mode, failure: failure
    test "#{mode} #{failure} SSE keeps earlier conflicts in its single settled attempt", ctx do
      events = Enum.take(declaration_events(), 3)

      source =
        if ctx.failure == :interrupted do
          FakeUpstream.abrupt_close_mid_stream(Enum.map(events, &sse/1))
        else
          failed = %{"type" => "response.failed", "response" => %{"id" => "resp_model_observation", "model" => "model-a", "status" => "failed", "error" => %{"code" => "server_error", "message" => "synthetic failure"}}}
          FakeUpstream.sse_stream(Enum.map(events ++ [failed], &sse/1))
        end

      upstream = start_upstream(source)
      setup = gateway_setup(upstream)
      set_mode(setup, ctx.mode)
      response = ctx.conn |> auth(setup) |> post("/v1/responses", %{"model" => setup.model.exposed_model_id, "input" => "synthetic failure observation", "stream" => true})
      assert response.status in [200, 502]
      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert request.status == "failed"
      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
      assert attempt.served_model == "model-a"
      assert attempt.model_observation["conflict"] == true
      assert attempt.model_observation["first_conflicting_model"] == "model-b"
      assert attempt.model_observation["terminal_status"] == if(ctx.failure == :failed, do: "failed", else: nil)
      assert Repo.aggregate(from(l in LedgerEntry, where: l.request_id == ^request.id and l.entry_kind == "settlement"), :count) == 1
      assert FakeUpstream.count(upstream) == 1
    end
  end

  defp set_mode(setup, mode) do
    timestamp = DateTime.utc_now()
    Repo.insert!(%ModelServingOverride{pool_id: setup.pool.id, exposed_model_id: setup.model.exposed_model_id, mode: mode, created_at: timestamp, updated_at: timestamp})
  end

  defp declaration_events do
    for {type, model} <- [{"response.created", "model-a"}, {"response.in_progress", "model-b"}, {"response.in_progress", "model-c"}, {"response.completed", "model-a"}] do
      response = %{"id" => "resp_model_observation", "object" => "response", "status" => if(type == "response.completed", do: "completed", else: "in_progress"), "model" => model, "output" => []}
      response = if type == "response.completed", do: Map.put(response, "usage", @usage), else: response
      %{"type" => type, "response" => response}
    end
  end

  defp sse(event), do: "event: #{event["type"]}\ndata: #{CodexPooler.JSON.encode!(event)}\n\n"
end
