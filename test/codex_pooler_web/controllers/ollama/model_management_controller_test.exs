defmodule CodexPoolerWeb.Ollama.ModelManagementControllerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 2, start_upstream: 1]

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  @fixed_error "gemma3 is a fixed virtual model"
  @embedding_error "embeddings are not supported by virtual gemma3"

  @tag :facade_task8
  test "pulling gemma3 is a streamed or collected immutable no-op", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"must" => "not dispatch"}))
    setup = facade_gateway_setup(upstream)

    collected =
      conn
      |> auth(setup)
      |> post("/api/pull", %{"name" => "gemma3", "stream" => false})

    assert json_response(collected, 200) == %{"status" => "success"}

    streamed =
      conn
      |> recycle()
      |> auth(setup)
      |> post("/api/pull", %{"model" => "gemma3:latest"})

    assert streamed.status == 200
    assert get_resp_header(streamed, "content-type") == ["application/x-ndjson"]

    assert streamed.resp_body
           |> String.split("\n", trim: true)
           |> Enum.map(&Jason.decode!/1) == [%{"status" => "success"}]

    refute streamed.resp_body =~ "gpt-5.6-sol"
    assert_no_work!(upstream)
  end

  @tag :facade_task8
  test "other pulls and every model/blob mutation return the fixed virtual-model error", %{
    conn: conn
  } do
    upstream = start_upstream(FakeUpstream.json_response(%{"must" => "not dispatch"}))
    setup = facade_gateway_setup(upstream)

    requests = [
      {:post, "/api/pull", %{"name" => "llama3"}},
      {:post, "/api/create", %{"model" => "gemma3"}},
      {:post, "/api/copy", %{"source" => "gemma3", "destination" => "other"}},
      {:post, "/api/push", %{"model" => "gemma3"}},
      {:delete, "/api/delete", %{"model" => "gemma3"}},
      {:post, "/api/blobs/sha256:deadbeef", %{}}
    ]

    for {method, path, payload} <- requests do
      response = perform_request(recycle(conn) |> auth(setup), method, path, payload)
      assert json_response(response, 400) == %{"error" => @fixed_error}
    end

    head_response = conn |> recycle() |> auth(setup) |> head("/api/blobs/sha256:deadbeef")
    assert head_response.status == 400
    assert head_response.resp_body == ""

    assert_no_work!(upstream)
  end

  @tag :facade_task8
  test "embedding routes fail stably and never fabricate vectors", %{conn: conn} do
    upstream = start_upstream(FakeUpstream.json_response(%{"must" => "not dispatch"}))
    setup = facade_gateway_setup(upstream)

    for {path, payload} <- [
          {"/api/embed", %{"model" => "anything", "input" => ["one", "two"]}},
          {"/api/embeddings", %{"model" => "gemma3", "prompt" => "one"}}
        ] do
      response = conn |> recycle() |> auth(setup) |> post(path, payload)
      assert json_response(response, 400) == %{"error" => @embedding_error}
      refute response.resp_body =~ "[0."
      refute response.resp_body =~ "\"embeddings\":["
    end

    assert_no_work!(upstream)
  end

  @tag :facade_task8
  test "management routes require the Pool API key before parsing semantics", %{conn: conn} do
    for {method, path, payload} <- [
          {:post, "/api/pull", %{"name" => "gemma3"}},
          {:post, "/api/create", %{}},
          {:post, "/api/embed", %{}},
          {:delete, "/api/delete", %{}}
        ] do
      response = perform_request(recycle(conn), method, path, payload)
      assert json_response(response, 401) == %{"error" => "Pool API key is required or invalid"}
    end
  end

  defp perform_request(conn, :post, path, payload), do: post(conn, path, payload)
  defp perform_request(conn, :delete, path, payload), do: delete(conn, path, payload)

  defp assert_no_work!(upstream) do
    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

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
        "default_reasoning_level" => "max"
      }
    )
  end
end
