defmodule CodexPoolerWeb.V1.PromptCacheBreakpointTTLTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport, only: [auth: 2, gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Pools.ModelServingOverride
  alias CodexPooler.Repo

  for mode <- ~w(full lite), endpoint <- ~w(responses chat/completions), stream <- [false, true] do
    test "#{endpoint} admits a 12h content breakpoint and adapts it at #{mode} egress, stream=#{stream}", %{conn: conn} do
      terminal = %{"type" => "response.completed", "response" => %{"id" => "resp_cache_ttl", "status" => "completed", "output" => [], "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}}}
      upstream = start_upstream(FakeUpstream.sse_stream([{"response.completed", terminal}]))
      setup = gateway_setup(upstream)
      set_serving_mode!(setup, unquote(mode))
      payload = payload(unquote(endpoint), setup.model.exposed_model_id) |> Map.put("stream", unquote(stream))

      conn = conn |> auth(setup) |> post("/v1/" <> unquote(endpoint), payload)

      if unquote(stream) do
        terminal = if unquote(endpoint) == "responses", do: "event: response.completed", else: "data: [DONE]"
        assert response(conn, 200) =~ terminal
      else
        assert %{"id" => "resp_cache_ttl"} = json_response(conn, 200)
      end

      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.path == "/backend-api/codex/responses"
      assert captured.json["prompt_cache_key"] == "synthetic-cache-key"
      refute Map.has_key?(captured.json, "prompt_cache_options")
      refute breakpoint_present?(captured.json)
      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
      assert attempt.response_metadata["prompt_cache_controls_downgraded"] == true
    end
  end

  defp payload(endpoint, model) do
    {key, type} = if endpoint == "responses", do: {"input", "input_text"}, else: {"messages", "text"}

    %{
      "model" => model,
      "prompt_cache_key" => "synthetic-cache-key",
      "prompt_cache_options" => %{"mode" => "explicit", "ttl" => "30m"},
      key => [%{"role" => "user", "content" => [%{"type" => type, "text" => "synthetic", "prompt_cache_breakpoint" => %{"mode" => "explicit", "ttl" => "12h"}}]}]
    }
  end

  defp set_serving_mode!(setup, mode) do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    override = Repo.get_by(ModelServingOverride, pool_id: setup.pool.id, exposed_model_id: setup.model.exposed_model_id)

    if override do
      override |> Ecto.Changeset.change(mode: mode, updated_at: timestamp) |> Repo.update!()
    else
      Repo.insert!(%ModelServingOverride{pool_id: setup.pool.id, exposed_model_id: setup.model.exposed_model_id, mode: mode, created_at: timestamp, updated_at: timestamp})
    end
  end

  defp breakpoint_present?(%{} = value), do: Map.has_key?(value, "prompt_cache_breakpoint") or Enum.any?(value, fn {_key, child} -> breakpoint_present?(child) end)
  defp breakpoint_present?(value) when is_list(value), do: Enum.any?(value, &breakpoint_present?/1)
  defp breakpoint_present?(_value), do: false
end
