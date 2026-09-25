defmodule CodexPoolerWeb.V1.ChatTextPartsControllerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport, only: [auth: 2, gateway_setup: 1, start_upstream: 1]
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3]

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  @limit 10_485_760

  for mode <- ["full", "lite"], surface <- [:user, :assistant, :tool, :instructions] do
    @mode mode
    @surface surface
    test "#{mode} serializes oversized #{@surface} as lossless parts on real HTTP", %{conn: conn} do
      scope = model_serving_scope()
      text = String.duplicate("x", @limit - 1) <> "🧪\r\nfixture"
      expected = :crypto.hash(:sha256, text)
      mode = @mode
      surface = @surface
      upstream = start_upstream(completed_upstream())
      setup = gateway_setup(upstream)
      set_model_serving_mode!(scope, setup, mode)
      response = conn |> recycle() |> auth(setup) |> post("/v1/chat/completions", %{"model" => setup.model.exposed_model_id, "messages" => messages(surface, text), "stream" => true})
      assert response.status == 200
      assert response.resp_body =~ "data: [DONE]"
      assert [captured] = FakeUpstream.requests(upstream)
      item = find_item(captured.json["input"], surface)
      assert is_map(item)
      parts = content_parts(item, surface)
      assert length(parts) > 1
      texts = Enum.map(parts, & &1["text"])
      assert :crypto.hash(:sha256, texts) == expected
      assert Enum.max(Enum.map(texts, &byte_size/1)) <= 262_144
      assert Enum.all?(texts, &String.valid?/1)
      assert_surface_metadata(surface, captured.json, item)
      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
      assert request.status == "succeeded"
      assert attempt.status == "succeeded"
      FakeUpstream.verify!(upstream)
    end
  end

  defp content_parts(item, :tool), do: item["output"]
  defp content_parts(item, _surface), do: item["content"]
  defp assert_surface_metadata(:instructions, payload, _item), do: assert(payload["instructions"] in [nil, ""])
  defp assert_surface_metadata(:tool, _payload, item), do: assert(item["call_id"] == "call_fixture")
  defp assert_surface_metadata(_surface, _payload, _item), do: :ok

  defp messages(:user, text), do: [%{"role" => "user", "content" => text}]
  defp messages(:assistant, text), do: [%{"role" => "assistant", "content" => text}, %{"role" => "user", "content" => "synthetic"}]
  defp messages(:instructions, text), do: [%{"role" => "system", "content" => text}, %{"role" => "user", "content" => "synthetic"}]
  defp messages(:tool, text), do: [%{"role" => "assistant", "content" => nil, "tool_calls" => [%{"id" => "call_fixture", "type" => "function", "function" => %{"name" => "fixture", "arguments" => "{}"}}]}, %{"role" => "tool", "tool_call_id" => "call_fixture", "content" => text}]
  defp find_item(input, :tool), do: Enum.find(input, &(&1["type"] == "function_call_output"))
  defp find_item(input, :instructions), do: Enum.find(input, &(&1["type"] == "message" and &1["role"] == "developer"))
  defp find_item(input, role), do: Enum.find(input, &(&1["type"] == "message" and &1["role"] == Atom.to_string(role)))

  defp completed_upstream do
    # provenance: synthetic_adversarial; actual serialized request boundary with synthetic completed response
    FakeUpstream.strict_sequence([
      FakeUpstream.expect_request(
        method: "POST",
        path: "/backend-api/codex/responses",
        json: [valid: true],
        respond:
          FakeUpstream.sse_stream([
            {"response.completed", %{"type" => "response.completed", "response" => %{"id" => "resp_text_parts_fixture", "status" => "completed", "model" => "sample-model", "output" => [], "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}}}}
          ])
      )
    ])
  end
end
