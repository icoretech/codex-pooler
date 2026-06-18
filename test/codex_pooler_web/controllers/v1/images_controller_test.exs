defmodule CodexPoolerWeb.V1.ImagesControllerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Accounting.Request
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo

  test "image endpoints use the shared coerced v1 dispatch boundary" do
    source = File.read!("lib/codex_pooler_web/controllers/v1/images_controller.ex")

    assert source =~ "PublicGatewayDispatch.coerced("
    refute source =~ "PublicGatewayDispatch.authenticated("
    refute source =~ "Service.execute"
    refute source =~ "RouteClass.proxy_stream"
    refute source =~ "RequestOptions.route_class"
  end

  @tag :image_generation_success
  test "POST /v1/images/generations returns OpenAI image response from Responses stream", %{
    conn: conn
  } do
    upstream = start_upstream(image_success_stream("B64_GENERATED", "refined prompt"))
    setup = upstream |> gateway_setup() |> use_image_model!("gpt-image-1")

    conn =
      conn
      |> auth(setup)
      |> post("/v1/images/generations", %{
        "model" => setup.model.exposed_model_id,
        "prompt" => "synthetic image request",
        "size" => "1024x1024",
        "quality" => "low",
        "n" => 1
      })

    assert %{
             "created" => created,
             "data" => [%{"b64_json" => "B64_GENERATED", "revised_prompt" => "refined prompt"}],
             "usage" => %{"input_tokens" => 7, "output_tokens" => 13, "total_tokens" => 20}
           } = json_response(conn, 200)

    assert is_integer(created)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["model"] == setup.model.upstream_model_id
    assert captured.json["stream"] == true
    assert [%{"type" => "image_generation", "model" => "gpt-image-1"}] = captured.json["tools"]

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.endpoint == "/backend-api/codex/responses"
    assert request.transport == "http_sse"
    assert request.status == "succeeded"
    assert get_in(request.request_metadata, ["openai_compatibility", "surface"]) == "openai_v1"

    assert get_in(request.request_metadata, ["openai_compatibility", "source_endpoint"]) ==
             "/v1/images/generations"

    assert get_in(request.request_metadata, ["openai_compatibility", "translated_endpoint"]) ==
             "/backend-api/codex/responses"

    refute inspect(request.request_metadata) =~ "synthetic image request"
    refute inspect(request.request_metadata) =~ "B64_GENERATED"
  end

  test "POST /v1/images/generations accepts idless image generation output items", %{
    conn: conn
  } do
    upstream = start_upstream(image_success_stream("B64_IDLESS", nil, id: false))
    setup = upstream |> gateway_setup() |> use_image_model!("gpt-image-1")

    conn =
      conn
      |> auth(setup)
      |> post("/v1/images/generations", %{
        "model" => setup.model.exposed_model_id,
        "prompt" => "synthetic idless image request",
        "size" => "1024x1024",
        "quality" => "low",
        "n" => 1
      })

    assert %{"data" => [%{"b64_json" => "B64_IDLESS"}]} = json_response(conn, 200)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    refute inspect(request.request_metadata) =~ "synthetic idless image request"
    refute inspect(request.request_metadata) =~ "B64_IDLESS"
  end

  test "POST /v1/images/generations routes through a visible host model when image model is not listed",
       %{conn: conn} do
    upstream = start_upstream(image_success_stream("B64_HIDDEN", "hidden prompt"))

    setup =
      upstream
      |> gateway_setup()
      |> allow_models!(["gpt-image-2"])

    conn =
      conn
      |> auth(setup)
      |> post("/v1/images/generations", %{
        "model" => "gpt-image-2",
        "prompt" => "synthetic hidden image request",
        "size" => "1024x1024",
        "quality" => "low",
        "n" => 1
      })

    assert %{"data" => [%{"b64_json" => "B64_HIDDEN", "revised_prompt" => "hidden prompt"}]} =
             json_response(conn, 200)

    assert [captured] = FakeUpstream.requests(upstream)
    assert captured.path == "/backend-api/codex/responses"
    assert captured.json["model"] == setup.model.upstream_model_id
    assert [%{"type" => "image_generation", "model" => "gpt-image-2"}] = captured.json["tools"]

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert request.request_metadata["requested_model"] == "gpt-image-2"
    assert request.request_metadata["effective_model"] == "gpt-image-2"
    refute inspect(request.request_metadata) =~ "synthetic hidden image request"
    refute inspect(request.request_metadata) =~ "B64_HIDDEN"
  end

  test "POST /v1/images/edits sends uploaded image as transient input_image", %{conn: conn} do
    upstream = start_upstream(image_success_stream("B64_EDITED", "edited prompt"))
    setup = upstream |> gateway_setup() |> use_image_model!("gpt-image-1")
    image_bytes = <<137, 80, 78, 71, 13, 10, 26, 10, 0, 1, 2, 3>>

    conn =
      conn
      |> auth(setup)
      |> post("/v1/images/edits", %{
        "model" => setup.model.exposed_model_id,
        "prompt" => "synthetic edit request",
        "size" => "1024x1024",
        "input_fidelity" => "high",
        "image" => upload_fixture("source-private.png", "image/png", image_bytes)
      })

    assert %{"data" => [%{"b64_json" => "B64_EDITED", "revised_prompt" => "edited prompt"}]} =
             json_response(conn, 200)

    assert [captured] = FakeUpstream.requests(upstream)
    assert [%{"content" => content}] = captured.json["input"]
    assert Enum.any?(content, &match?(%{"type" => "input_text"}, &1))

    assert Enum.any?(content, fn part ->
             part["type"] == "input_image" and
               String.starts_with?(part["image_url"], "data:image/png;base64,")
           end)

    refute captured.body =~ "source-private.png"

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    refute inspect(request.request_metadata) =~ "source-private.png"
    refute inspect(request.request_metadata) =~ Base.encode64(image_bytes)
  end

  test "POST /v1/images/generations rejects invalid image params before dispatch", %{conn: conn} do
    upstream = start_upstream(image_success_stream("SHOULD_NOT_DISPATCH", nil))
    setup = upstream |> gateway_setup() |> use_image_model!("gpt-image-1")

    conn =
      conn
      |> auth(setup)
      |> post("/v1/images/generations", %{
        "model" => setup.model.exposed_model_id,
        "prompt" => "invalid image request",
        "size" => "2048x2048"
      })

    assert %{"error" => %{"code" => "invalid_request", "param" => "size"}} =
             json_response(conn, 400)

    assert FakeUpstream.requests(upstream) == []
    assert Repo.aggregate(Request, :count) == 0
  end

  @tag :variations_unsupported
  test "POST /v1/images/variations returns deterministic unsupported error without admission side effects",
       %{
         conn: conn
       } do
    upstream = start_upstream(image_success_stream("SHOULD_NOT_DISPATCH", nil))
    setup = upstream |> gateway_setup() |> use_image_model!("gpt-image-1")

    conn = conn |> auth(setup) |> post("/v1/images/variations", %{"model" => "gpt-image-1"})

    assert %{"error" => %{"code" => "unsupported_endpoint"}} = json_response(conn, 404)
    assert FakeUpstream.requests(upstream) == []
    assert Repo.aggregate(Request, :count) == 0
  end

  defp use_image_model!(setup, model_id) do
    model =
      setup.model
      |> Ecto.Changeset.change(%{
        exposed_model_id: model_id,
        upstream_model_id: "provider-host-responses-model",
        supports_responses: true,
        supports_streaming: true,
        metadata: %{"source_assignment_ids" => [setup.assignment.id]}
      })
      |> Repo.update!()

    %{setup | model: model}
  end

  defp allow_models!(setup, allowed_model_identifiers) do
    api_key =
      setup.api_key
      |> Ecto.Changeset.change(%{allowed_model_identifiers: allowed_model_identifiers})
      |> Repo.update!()

    %{setup | api_key: api_key}
  end

  defp image_success_stream(result, revised_prompt, opts \\ []) do
    image_item =
      %{
        "type" => "image_generation_call",
        "status" => "completed",
        "result" => result
      }
      |> maybe_put_id(opts)
      |> maybe_put("revised_prompt", revised_prompt)

    FakeUpstream.sse_stream([
      {"response.output_item.done",
       %{
         "type" => "response.output_item.done",
         "output_index" => 0,
         "item" => image_item
       }},
      {"response.completed",
       %{
         "type" => "response.completed",
         "response" => %{
           "id" => "resp_image_fixture",
           "status" => "completed",
           "tool_usage" => %{"image_gen" => %{"input_tokens" => 7, "output_tokens" => 13}}
         }
       }}
    ])
  end

  defp maybe_put_id(map, opts) do
    if Keyword.get(opts, :id, true), do: Map.put(map, "id", "ig_fixture"), else: map
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp upload_fixture(filename, content_type, contents) do
    path =
      Path.join(System.tmp_dir!(), "codex-pooler-v1-image-#{System.unique_integer([:positive])}")

    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    %Plug.Upload{path: path, filename: filename, content_type: content_type}
  end
end
