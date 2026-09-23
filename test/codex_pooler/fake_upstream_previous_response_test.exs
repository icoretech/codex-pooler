defmodule CodexPooler.FakeUpstreamPreviousResponseTest do
  # The Codex backend resolves `previous_response_id` only on the websocket
  # connection that produced the response and refuses the parameter over HTTP
  # with `400 {"detail":"Unsupported parameter: previous_response_id"}`,
  # whatever `store` or a forwarded `session-id` (findings#232 rows 232-275 and
  # 232-276, live probe 2026-09-23). FakeUpstream answers the same way, so no
  # gateway test can certify an anchored HTTP continuation the provider never
  # serves.
  use ExUnit.Case, async: true

  alias CodexPooler.FakeUpstream

  @anchor "resp_fake_upstream_anchor"

  setup do
    {:ok, upstream} =
      FakeUpstream.start_link(
        FakeUpstream.strict_sequence([
          FakeUpstream.json_response(%{"id" => "resp_fake_upstream_scripted"})
        ])
      )

    on_exit(fn -> FakeUpstream.stop(upstream) end)
    %{upstream: upstream}
  end

  test "an HTTP responses request carrying previous_response_id gets the provider's refusal without consuming a scripted response", %{upstream: upstream} do
    anchored = post!(upstream, "/backend-api/codex/responses", %{"previous_response_id" => @anchor, "store" => false, "input" => []})

    assert anchored.status == 400
    assert anchored.body == FakeUpstream.http_previous_response_id_rejection_body()
    assert CodexPooler.JSON.decode!(anchored.body) == %{"detail" => "Unsupported parameter: previous_response_id"}
    assert ["application/json" <> _charset] = anchored.headers["content-type"]

    plain = post!(upstream, "/backend-api/codex/responses", %{"store" => false, "input" => []})

    assert plain.status == 200
    assert CodexPooler.JSON.decode!(plain.body) == %{"id" => "resp_fake_upstream_scripted"}
    assert [%{json: %{"previous_response_id" => @anchor}}, %{json: plain_json}] = FakeUpstream.requests(upstream)
    refute Map.has_key?(plain_json, "previous_response_id")
    assert :ok = FakeUpstream.verify!(upstream)
  end

  test "a null previous_response_id keeps the scripted response", %{upstream: upstream} do
    response = post!(upstream, "/backend-api/codex/responses", %{"previous_response_id" => nil, "input" => []})

    assert response.status == 200
    assert :ok = FakeUpstream.verify!(upstream)
  end

  test "the compact route, whose provider answer to an anchor was not probed, keeps its scripted response", %{upstream: upstream} do
    response = post!(upstream, "/backend-api/codex/responses/compact", %{"previous_response_id" => @anchor, "input" => []})

    assert response.status == 200
    assert :ok = FakeUpstream.verify!(upstream)
  end

  defp post!(upstream, path, body) do
    Req.post!(FakeUpstream.url(upstream) <> path,
      body: CodexPooler.JSON.encode!(body),
      headers: [{"content-type", "application/json"}],
      decode_body: false,
      retry: false
    )
  end
end
