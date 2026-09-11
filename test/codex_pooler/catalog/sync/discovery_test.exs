defmodule CodexPooler.Catalog.Sync.DiscoveryTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Catalog.Sync.Discovery
  alias CodexPooler.FakeUpstream
  alias CodexPooler.UpstreamConnPoolTelemetry
  alias CodexPooler.Upstreams.CodexClientIdentity

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
        FakeUpstream.strict_sequence([
          FakeUpstream.expect_request(
            method: "GET",
            path: "/backend-api/codex/models",
            headers: [forbidden: ["cookie"]],
            respond:
              FakeUpstream.json_response_with_headers(
                %{"data" => [%{"id" => "gpt-example"}]},
                [{"set-cookie", "__cf_bm=models-token; Path=/; HttpOnly; Secure"}]
              )
          ),
          FakeUpstream.expect_request(
            method: "GET",
            path: "/backend-api/codex/models",
            headers: [forbidden: ["cookie"]],
            respond: FakeUpstream.json_response(%{"data" => [%{"id" => "gpt-example"}]})
          )
        ])
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

    assert_codex_client_identity_headers(first_headers)

    assert second_request.path == "/backend-api/codex/models"

    assert Version.compare(
             URI.decode_query(second_request.query_string)["client_version"],
             @minimum_codex_client_version
           ) in [:eq, :gt]

    assert_codex_client_identity_headers(second_headers)

    refute Map.has_key?(first_headers, "cookie")
    refute Map.has_key?(second_headers, "cookie")
    assert :ok = FakeUpstream.verify!(upstream)
  end

  test "model discovery carries the upstream connection idle bound from settings" do
    {:ok, upstream} =
      FakeUpstream.start_link(
        {:path_json,
         %{"/backend-api/codex/models" => {200, %{"data" => [%{"id" => "gpt-example"}]}}}}
      )

    on_exit(fn -> FakeUpstream.stop(upstream) end)

    UpstreamConnPoolTelemetry.put_idle_bound!(0)
    UpstreamConnPoolTelemetry.attach!(FakeUpstream.url(upstream))

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool_fixture(),
        chatgpt_account_id: "acct_models_#{System.unique_integer([:positive])}",
        metadata: %{"base_url" => FakeUpstream.url(upstream)}
      )

    source = %{identity: identity, assignment: assignment}

    assert {:ok, [%{"id" => "gpt-example"}]} = Discovery.fetch_models_for_assignment(source)
    assert {:ok, [%{"id" => "gpt-example"}]} = Discovery.fetch_models_for_assignment(source)

    assert FakeUpstream.count(upstream) == 2
    assert UpstreamConnPoolTelemetry.drain_events() == [:conn_max_idle_time_exceeded]
  end

  defp assert_codex_client_identity_headers(headers) do
    version = CodexClientIdentity.version()

    assert headers["user-agent"] == "codex_cli_rs/#{version}"
    assert headers["originator"] == CodexClientIdentity.originator()
    assert headers["version"] == version
  end
end
