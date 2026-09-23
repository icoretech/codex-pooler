defmodule CodexPoolerWeb.Runtime.PromptCacheLocalityReasonTest do
  # `routing_locality_unhonored_reason` states why prompt-cache locality did not
  # order the shortlist. A key the client sent must never read
  # `prompt_cache_key_absent`: a blank or oversized key is refused as a routing
  # seed and says which bound refused it (findings#255 row 255-81).
  # Diagnostic only: the routing copy stays nil, so the order is the same as
  # before.
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, native_text_input: 1, start_upstream: 1]

  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  @oversized_key "oversized-locality-reason-key-" <> String.duplicate("x", 257)

  for {label, key, reason} <- [
        {"no key", :omit, "prompt_cache_key_absent"},
        {"a null key", nil, "prompt_cache_key_absent"},
        {"a blank key", "   ", "prompt_cache_key_blank"},
        {"an oversized key", @oversized_key, "prompt_cache_key_oversized"}
      ] do
    @tag prompt_cache_key: key, expected_reason: reason
    test "POST /backend-api/codex/responses with #{label} records #{reason}", %{conn: conn, prompt_cache_key: key, expected_reason: reason} do
      upstream = start_upstream(FakeUpstream.json_response(response_body()))
      setup = gateway_setup(upstream)

      payload = with_key(%{"model" => setup.model.exposed_model_id, "input" => native_text_input("locality reason")}, key)

      response = conn |> auth(setup) |> post("/backend-api/codex/responses", payload)

      assert json_response(response, 200)["object"] == "response"
      assert_locality_reason!(setup, "/backend-api/codex/responses", reason, key)
    end
  end

  defp assert_locality_reason!(setup, endpoint, reason, key) do
    assert [request] = Repo.all(from(request in Request, where: request.pool_id == ^setup.pool.id))
    assert request.endpoint == endpoint

    routing = request.request_metadata["routing"]
    assert routing["routing_locality_status"] == "unavailable"
    assert routing["routing_locality_applied"] == false
    assert routing["routing_locality_unhonored_reason"] == reason
    refute Map.has_key?(routing, "routing_locality_seed_fingerprint")

    if is_binary(key) and String.trim(key) != "", do: refute(inspect(request.request_metadata) =~ key)
  end

  defp with_key(payload, :omit), do: payload
  defp with_key(payload, key), do: Map.put(payload, "prompt_cache_key", key)

  defp response_body do
    %{"id" => "resp_locality_reason", "object" => "response", "usage" => %{"input_tokens" => 4, "output_tokens" => 1, "total_tokens" => 5}}
  end
end
