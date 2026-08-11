defmodule CodexPoolerWeb.FacadeAuthenticationTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Pools.Routing
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Plugs.RuntimeIngress

  setup do
    previous = Application.get_env(:codex_pooler, OperationalSettings)

    Application.put_env(:codex_pooler, OperationalSettings, settings: %OperationalSettings{})

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:codex_pooler, OperationalSettings)
        value -> Application.put_env(:codex_pooler, OperationalSettings, value)
      end
    end)

    :ok
  end

  test "every facade family authenticates before discovery or dispatch" do
    for {method, path, expected} <- [
          {:get, "/api/tags", %{"error" => "Pool API key is required or invalid"}},
          {:post, "/v1/messages", %{"type" => "error"}},
          {:get, "/v1/models", %{"error" => %{"code" => "api_key_missing"}}},
          {:get, "/backend-api/codex/models", %{"error" => %{"code" => "api_key_missing"}}},
          {:get, "/api/codex/usage", %{"error" => %{"code" => "api_key_missing"}}}
        ] do
      conn = dispatch(build_conn(), method, path)

      assert conn.status == 401
      assert subset?(Jason.decode!(conn.resp_body), expected)
      assert conn.halted
      refute conn.private[:runtime_api_auth]
    end
  end

  test "rejects an invalid Bearer key using the selected protocol envelope" do
    for {path, shape} <- [
          {"/api/tags", :ollama},
          {"/v1/messages", :anthropic},
          {"/v1/models", :openai},
          {"/backend-api/codex/models", :openai}
        ] do
      conn =
        build_conn(:get, path)
        |> put_req_header("authorization", "Bearer cp_invalid")
        |> RuntimeIngress.call([])

      assert conn.status == 401
      assert_protocol_error(conn, shape)
      refute conn.private[:runtime_api_auth]
    end
  end

  test "accepts an Anthropic x-api-key and stores only the auth context" do
    setup = active_api_key_fixture()

    conn =
      build_conn(:post, "/v1/messages")
      |> put_req_header("x-api-key", setup.raw_key)
      |> RuntimeIngress.call([])

    refute conn.halted
    assert conn.private.runtime_api_auth.api_key_id == setup.api_key.id
    assert conn.private.runtime_api_auth.pool_id == setup.pool.id
    refute Map.has_key?(conn.private, :runtime_api_key)
    refute inspect(conn.private.runtime_api_auth) =~ setup.raw_key
  end

  test "accepts equal dual credentials using constant-time comparison semantics" do
    setup = active_api_key_fixture()

    conn =
      build_conn(:post, "/v1/messages")
      |> put_req_header("authorization", setup.authorization)
      |> put_req_header("x-api-key", setup.raw_key)
      |> RuntimeIngress.call([])

    refute conn.halted
    assert conn.private.runtime_api_auth.api_key_id == setup.api_key.id
  end

  test "rejects unequal dual credentials instead of choosing a header" do
    setup = active_api_key_fixture()
    other_setup = active_api_key_fixture(setup.pool)

    conn =
      build_conn(:post, "/v1/messages")
      |> put_req_header("authorization", setup.authorization)
      |> put_req_header("x-api-key", other_setup.raw_key)
      |> RuntimeIngress.call([])

    assert conn.status == 401

    assert %{
             "type" => "error",
             "error" => %{
               "type" => "authentication_error",
               "message" => "Pool API key is required or invalid"
             }
           } = Jason.decode!(conn.resp_body)

    refute conn.private[:runtime_api_auth]
  end

  test "disabled compatibility is a local-policy denial for every facade protocol" do
    setup = active_api_key_fixture()

    setup.pool
    |> Routing.ensure_routing_settings()
    |> Ecto.Changeset.change(v1_compatibility_enabled: false)
    |> Repo.update!()

    for {path, shape} <- [
          {"/api/tags", :ollama},
          {"/v1/messages", :anthropic},
          {"/v1/models", :openai},
          {"/backend-api/codex/models", :openai}
        ] do
      conn =
        build_conn(:get, path)
        |> put_req_header("authorization", setup.authorization)
        |> RuntimeIngress.call([])

      assert conn.status == 403
      assert_protocol_error(conn, shape)
      refute conn.resp_body =~ "OpenAI"
      refute conn.private[:runtime_api_auth]
    end
  end

  test "firewall denial uses the selected protocol envelope before authentication" do
    Application.put_env(:codex_pooler, OperationalSettings,
      settings: %OperationalSettings{firewall_allowlist: ["203.0.113.10"]}
    )

    for {path, shape} <- [
          {"/api/tags", :ollama},
          {"/v1/messages", :anthropic},
          {"/v1/models", :openai},
          {"/backend-api/codex/models", :openai}
        ] do
      conn =
        build_conn(:get, path)
        |> Map.put(:remote_ip, {198, 51, 100, 20})
        |> RuntimeIngress.call([])

      assert conn.status == 403
      assert_protocol_error(conn, shape)
      assert conn.resp_body =~ "client IP is not allowed"
      refute conn.private[:runtime_api_auth]
    end
  end

  defp dispatch(conn, :get, path), do: get(conn, path)
  defp dispatch(conn, :post, path), do: post(conn, path, %{})

  defp assert_protocol_error(conn, :ollama) do
    assert %{"error" => message} = Jason.decode!(conn.resp_body)
    assert is_binary(message)
  end

  defp assert_protocol_error(conn, :anthropic) do
    assert %{"type" => "error", "error" => %{"type" => type, "message" => message}} =
             Jason.decode!(conn.resp_body)

    assert is_binary(type)
    assert is_binary(message)
  end

  defp assert_protocol_error(conn, :openai) do
    assert %{"error" => %{"type" => type, "message" => message}} =
             Jason.decode!(conn.resp_body)

    assert is_binary(type)
    assert is_binary(message)
  end

  defp subset?(actual, expected) when is_map(actual) and is_map(expected) do
    Enum.all?(expected, fn {key, value} ->
      Map.has_key?(actual, key) and subset?(actual[key], value)
    end)
  end

  defp subset?(actual, expected), do: actual == expected
end
