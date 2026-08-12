defmodule CodexPoolerWeb.Ollama.DiscoveryControllerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 2, start_upstream: 1]

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  @tag :facade_task8
  test "authenticated discovery exposes exactly one stable local gemma3 contract", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"must" => "not dispatch"}))
    setup = facade_gateway_setup(upstream)

    tags = conn |> auth(setup) |> get("/api/tags")
    assert %{"models" => [tag]} = json_response(tags, 200)
    assert tag["name"] == "gemma3"
    assert tag["model"] == "gemma3"
    assert tag["size"] == 0
    assert tag["details"] == %{"family" => "gemma3", "parameter_size" => "virtual"}
    assert tag["digest"] =~ ~r/^sha256:[0-9a-f]{64}$/
    assert {:ok, _timestamp, 0} = DateTime.from_iso8601(tag["modified_at"])

    show =
      conn
      |> recycle()
      |> auth(setup)
      |> post("/api/show", %{"name" => "arbitrary-client-selector", "verbose" => true})

    assert %{
             "model" => "gemma3",
             "digest" => digest,
             "details" => %{"family" => "gemma3", "parameter_size" => "virtual"},
             "capabilities" => capabilities
           } = json_response(show, 200)

    assert digest == tag["digest"]
    assert capabilities == ["completion", "tools", "vision", "thinking"]

    ps = conn |> recycle() |> auth(setup) |> get("/api/ps")
    assert %{"models" => [running]} = json_response(ps, 200)
    assert running["name"] == "gemma3"
    assert running["model"] == "gemma3"
    assert running["digest"] == tag["digest"]
    assert running["size"] == 0
    assert running["size_vram"] == 0

    version = conn |> recycle() |> auth(setup) |> get("/api/version")
    assert json_response(version, 200) == %{"version" => "0.1.0"}

    public_text = Enum.map_join([tags, show, ps, version], "\n", & &1.resp_body)

    for hidden <- [
          "gpt-5.6-sol",
          "provider-hidden-ollama-model",
          "Provider Hidden Ollama Model",
          "codex-pooler",
          setup.identity.chatgpt_account_id,
          setup.assignment.id
        ] do
      refute public_text =~ hidden
    end

    assert FakeUpstream.count(upstream) == 0
  end

  @tag :facade_task8
  test "unroutable fixed target yields empty tags and ps plus unavailable show", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"must" => "not dispatch"}))
    setup = facade_gateway_setup(upstream)

    setup.assignment
    |> Ecto.Changeset.change(health_status: "errored")
    |> Repo.update!()

    tags = conn |> auth(setup) |> get("/api/tags")
    assert json_response(tags, 200) == %{"models" => []}

    ps = conn |> recycle() |> auth(setup) |> get("/api/ps")
    assert json_response(ps, 200) == %{"models" => []}

    show = conn |> recycle() |> auth(setup) |> post("/api/show", %{"name" => "gemma3"})
    assert json_response(show, 503) == %{"error" => "gemma3 is temporarily unavailable"}
    assert FakeUpstream.count(upstream) == 0
  end

  @tag :facade_task8
  test "every Ollama discovery route requires the Pool API key", %{conn: conn} do
    requests = [
      {:get, "/api/tags"},
      {:post, "/api/show"},
      {:get, "/api/ps"},
      {:get, "/api/version"}
    ]

    for {method, path} <- requests do
      response = perform_request(recycle(conn), method, path)
      assert json_response(response, 401) == %{"error" => "Pool API key is required or invalid"}
    end
  end

  defp perform_request(conn, :get, path), do: get(conn, path)
  defp perform_request(conn, :post, path), do: post(conn, path, %{})

  defp facade_gateway_setup(upstream) do
    reasoning_levels =
      Enum.map(~w(low medium high xhigh max ultra), &%{"effort" => &1, "description" => &1})

    gateway_setup(upstream,
      exposed_model_id: "gpt-5.6-sol",
      upstream_model_id: "provider-hidden-ollama-model",
      pricing_ref: "gpt-5.6-sol",
      display_name: "Provider Hidden Ollama Model",
      model_metadata: %{
        "supported_reasoning_levels" => reasoning_levels,
        "default_reasoning_level" => "max",
        "input_modalities" => ["text", "image"]
      }
    )
  end
end
