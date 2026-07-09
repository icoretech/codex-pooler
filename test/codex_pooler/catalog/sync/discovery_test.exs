defmodule CodexPooler.Catalog.Sync.DiscoveryTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Catalog.Sync.Discovery
  alias CodexPooler.FakeUpstream

  @secret_config [
    upstream_secret_key: Base.encode64(:crypto.hash(:sha256, "test-upstream-secret-key")),
    upstream_secret_key_version: "test-v1"
  ]
  @minimum_codex_client_version "0.144.0"

  setup do
    previous = Application.get_env(:codex_pooler, CodexPooler.Upstreams.Secrets)
    Application.put_env(:codex_pooler, CodexPooler.Upstreams.Secrets, @secret_config)

    on_exit(fn ->
      if previous do
        Application.put_env(:codex_pooler, CodexPooler.Upstreams.Secrets, previous)
      else
        Application.delete_env(:codex_pooler, CodexPooler.Upstreams.Secrets)
      end
    end)
  end

  test "model discovery does not reuse Cloudflare cookies for non-ChatGPT upstream origins" do
    {:ok, upstream} =
      FakeUpstream.start_link(
        {:sequence,
         [
           FakeUpstream.json_response_with_headers(
             %{"data" => [%{"id" => "gpt-example"}]},
             [{"set-cookie", "__cf_bm=models-token; Path=/; HttpOnly; Secure"}]
           ),
           FakeUpstream.json_response(%{"data" => [%{"id" => "gpt-example"}]})
         ]}
      )

    on_exit(fn -> FakeUpstream.stop(upstream) end)

    pool = pool_fixture()

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool,
        chatgpt_account_id: "acct_models_#{System.unique_integer([:positive])}",
        metadata: %{"base_url" => FakeUpstream.url(upstream)}
      )

    source = %{identity: identity, assignment: assignment}

    assert {:ok, [%{"id" => "gpt-example"}]} = Discovery.fetch_models_for_assignment(source)
    assert {:ok, [%{"id" => "gpt-example"}]} = Discovery.fetch_models_for_assignment(source)

    [first_request, second_request] = FakeUpstream.requests(upstream)
    first_headers = Map.new(first_request.headers)
    second_headers = Map.new(second_request.headers)

    assert first_request.path == "/backend-api/codex/models"

    assert Version.compare(
             URI.decode_query(first_request.query_string)["client_version"],
             @minimum_codex_client_version
           ) in [:eq, :gt]

    assert second_request.path == "/backend-api/codex/models"

    assert Version.compare(
             URI.decode_query(second_request.query_string)["client_version"],
             @minimum_codex_client_version
           ) in [:eq, :gt]

    refute Map.has_key?(first_headers, "cookie")
    refute Map.has_key?(second_headers, "cookie")
  end
end
