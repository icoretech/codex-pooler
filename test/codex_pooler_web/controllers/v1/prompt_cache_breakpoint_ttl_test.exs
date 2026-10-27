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
      assert_cache_adaptation!(conn, unquote(mode), unquote(endpoint), unquote(stream), :content)
    end
  end

  for mode <- ~w(full lite), endpoint <- ~w(responses chat/completions), stream <- [false, true] do
    test "#{endpoint} admits a 12h request cache TTL with an inherited breakpoint at #{mode} egress, stream=#{stream}", %{conn: conn} do
      assert_cache_adaptation!(conn, unquote(mode), unquote(endpoint), unquote(stream), :request)
    end
  end

  for endpoint <- ~w(responses chat/completions) do
    test "#{endpoint} rejects unsupported request cache TTL before dispatch", %{conn: conn} do
      upstream = start_upstream(FakeUpstream.sse_stream([]))
      setup = gateway_setup(upstream)

      payload =
        payload(unquote(endpoint), setup.model.exposed_model_id)
        |> Map.put("prompt_cache_options", %{"mode" => "explicit", "ttl" => "24h"})

      conn = conn |> auth(setup) |> post("/v1/" <> unquote(endpoint), payload)

      assert %{"error" => %{"code" => "invalid_request", "param" => "prompt_cache_options.ttl"}} = json_response(conn, 400)
      assert FakeUpstream.count(upstream) == 0
      assert Repo.aggregate(from(r in Request, where: r.pool_id == ^setup.pool.id), :count) == 0
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

  defp assert_cache_adaptation!(conn, mode, endpoint, stream, kind) do
    {response_id, request_payload} =
      case kind do
        :content -> {"resp_cache_ttl", payload(endpoint, "sample-model")}
        :request -> {"resp_request_cache_ttl", request_ttl_payload(endpoint, "sample-model")}
      end

    terminal = %{"type" => "response.completed", "response" => %{"id" => response_id, "status" => "completed", "output" => [], "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}}}
    upstream = start_upstream(FakeUpstream.sse_stream([{"response.completed", terminal}]))
    setup = gateway_setup(upstream)
    set_serving_mode!(setup, mode)
    request_payload = Map.put(request_payload, "model", setup.model.exposed_model_id) |> Map.put("stream", stream)
    conn = conn |> auth(setup) |> post("/v1/" <> endpoint, request_payload)

    if stream do
      terminal_label = if endpoint == "responses", do: "event: response.completed", else: "data: [DONE]"
      assert response(conn, 200) =~ terminal_label
    else
      assert %{"id" => ^response_id} = json_response(conn, 200)
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

  defp request_ttl_payload(endpoint, model) do
    {key, type} = if endpoint == "responses", do: {"input", "input_text"}, else: {"messages", "text"}

    %{
      "model" => model,
      "prompt_cache_key" => "synthetic-cache-key",
      "prompt_cache_options" => %{"mode" => "explicit", "ttl" => "12h"},
      key => [%{"role" => "user", "content" => [%{"type" => type, "text" => "synthetic", "prompt_cache_breakpoint" => %{"mode" => "explicit"}}]}]
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
