defmodule CodexPoolerWeb.V1.ChatToolChoiceControllerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport, only: [auth: 2, gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Pools.ModelServingOverride
  alias CodexPooler.Repo

  for mode <- ~w(full lite), stream <- [false, true] do
    test "translated Chat preserves omitted and scalar tool choices on #{mode} HTTP egress with stream=#{stream}", %{conn: conn} do
      for choice <- [:omitted, "auto", "none", "required"] do
        upstream = start_upstream(completed_upstream())
        setup = gateway_setup(upstream)
        put_serving_mode!(setup, unquote(mode))
        tool = %{"type" => "function", "function" => %{"name" => "lookup_fixture", "parameters" => %{"type" => "object", "properties" => %{}}}}
        payload = %{"model" => setup.model.exposed_model_id, "messages" => [%{"role" => "user", "content" => "synthetic"}], "tools" => [tool], "stream" => unquote(stream)}
        payload = if choice == :omitted, do: payload, else: Map.put(payload, "tool_choice", choice)

        response = conn |> recycle() |> auth(setup) |> post("/v1/chat/completions", payload)

        assert response.status == 200
        assert get_resp_header(response, "content-type") == if(unquote(stream), do: ["text/event-stream"], else: ["application/json; charset=utf-8"])
        assert [captured] = FakeUpstream.requests(upstream)
        assert captured.path == "/backend-api/codex/responses"
        assert Map.new(captured.headers)["x-openai-internal-codex-responses-lite"] == if(unquote(mode) == "lite", do: "true", else: nil)
        assert Map.fetch(captured.json, "tool_choice") == if(choice == :omitted, do: :error, else: {:ok, choice})

        if unquote(mode) == "full" do
          assert [%{"name" => "lookup_fixture"}] = captured.json["tools"]
        else
          assert Map.fetch(captured.json, "tools") == :error
          assert [%{"tools" => [%{"name" => "lookup_fixture"}]}] = Enum.filter(captured.json["input"], &(&1["type"] == "additional_tools"))
        end

        FakeUpstream.verify!(upstream)
      end
    end

    test "translated Chat without tools leaves tool choice absent on #{mode} HTTP egress with stream=#{stream}", %{conn: conn} do
      for tools <- [:omitted, []] do
        upstream = start_upstream(completed_upstream())
        setup = gateway_setup(upstream)
        put_serving_mode!(setup, unquote(mode))
        payload = %{"model" => setup.model.exposed_model_id, "messages" => [%{"role" => "user", "content" => "synthetic"}], "stream" => unquote(stream)}
        payload = if tools == :omitted, do: payload, else: Map.put(payload, "tools", tools)

        response = conn |> recycle() |> auth(setup) |> post("/v1/chat/completions", payload)

        assert response.status == 200
        assert [captured] = FakeUpstream.requests(upstream)
        assert Map.new(captured.headers)["x-openai-internal-codex-responses-lite"] == if(unquote(mode) == "lite", do: "true", else: nil)
        assert Map.fetch(captured.json, "tool_choice") == :error
        FakeUpstream.verify!(upstream)
      end
    end
  end

  defp put_serving_mode!(setup, mode) do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    Repo.insert!(%ModelServingOverride{pool_id: setup.pool.id, exposed_model_id: setup.model.exposed_model_id, mode: mode, created_at: timestamp, updated_at: timestamp})
  end

  defp completed_upstream do
    # Synthetic transport fixture: checks outgoing choices, not model tool-selection policy.
    terminal = %{"type" => "response.completed", "response" => %{"id" => "resp_synthetic_choice", "status" => "completed", "output" => [], "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}}}
    FakeUpstream.strict_sequence([FakeUpstream.expect_request(method: "POST", path: "/backend-api/codex/responses", json: [valid: true], respond: FakeUpstream.sse_stream([terminal]))])
  end
end
