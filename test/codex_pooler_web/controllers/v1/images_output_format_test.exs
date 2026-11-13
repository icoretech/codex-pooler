defmodule CodexPoolerWeb.V1.ImagesOutputFormatTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.OpenAICompatibility.Images
  alias CodexPooler.Pools.ModelServingOverride
  alias CodexPooler.Repo

  @native_models ~w(gpt-image-2 gpt-image-2.6-flare gpt-image-2.6-sunburst)
  @legacy_models ~w(gpt-image-1 gpt-image-1.5 gpt-image-1-mini)
  @png Base.decode64!("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==")

  for model <- @native_models, mode <- ~w(full lite), operation <- ~w(generations edits) do
    @model model
    @mode mode
    @operation operation
    test "explicit PNG reaches native #{@model} #{@operation} in #{@mode}", %{conn: conn} do
      encoded = Base.encode64(@png)
      upstream = start_upstream({:json, 200, %{"created" => 1, "data" => [%{"b64_json" => encoded}]}})
      setup = gateway_setup(upstream)
      now = DateTime.utc_now()
      Repo.insert!(%ModelServingOverride{pool_id: setup.pool.id, exposed_model_id: setup.model.exposed_model_id, mode: @mode, created_at: now, updated_at: now})
      payload = image_payload(@model) |> Map.put("output_format", "png") |> with_upload(@operation)

      response = conn |> auth(setup) |> post("/v1/images/#{@operation}", payload)

      assert %{"data" => [%{"b64_json" => ^encoded}]} = json_response(response, 200)
      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.path == "/backend-api/codex/images/#{@operation}"
      assert captured.json["output_format"] == "png"
      assert captured.json["model"] == @model
      assert [attempt] = Repo.all(Attempt)
      assert attempt.status == "succeeded"
      assert attempt.response_metadata["routing"]["model_serving_mode"] == @mode
      assert [request] = Repo.all(Request)
      assert request.status == "succeeded"
    end
  end

  test "explicit PNG survives legacy generation and edit tool translation" do
    for model <- @legacy_models do
      payload = image_payload(model) |> Map.put("output_format", "png")
      assert {:ok, generation} = Images.coerce_generation(payload)
      assert generation.endpoint == "/backend-api/codex/responses"
      assert [%{"output_format" => "png"}] = generation.payload["tools"]
      assert {:ok, edit} = Images.coerce_edit(with_upload(payload, "edits"))
      assert [%{"output_format" => "png"}] = edit.payload["tools"]
    end
  end

  test "omitted format remains omitted on both image transports" do
    for model <- @native_models ++ @legacy_models do
      assert {:ok, result} = Images.coerce_generation(image_payload(model))
      wire = if model in @native_models, do: result.payload, else: hd(result.payload["tools"])
      refute Map.has_key?(wire, "output_format")
    end
  end

  test "other encodings and malformed formats reject before dispatch or reservation", %{conn: conn} do
    upstream = start_upstream({:json, 200, %{}})
    setup = gateway_setup(upstream)

    for model <- ["gpt-image-2.6-flare", "gpt-image-1.5"],
        operation <- ~w(generations edits),
        format <- ["jpeg", "webp", "gif", "svg", "PNG", "", nil, 1, %{}] do
      payload = image_payload(model) |> Map.put("output_format", format)
      response = conn |> recycle() |> auth(setup) |> post("/v1/images/#{operation}", payload)
      assert %{"error" => %{"code" => "invalid_request", "param" => "output_format"}} = json_response(response, 400)
    end

    assert FakeUpstream.requests(upstream) == []
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  defp image_payload(model), do: %{"model" => model, "prompt" => "synthetic image", "quality" => "low", "n" => 1}

  defp with_upload(payload, "generations"), do: payload

  defp with_upload(payload, "edits") do
    file = Path.join(System.tmp_dir!(), "image-format-#{System.unique_integer([:positive])}.png")
    on_exit(fn -> File.rm(file) end)
    File.write!(file, @png)
    Map.put(payload, "image", %Plug.Upload{path: file, filename: "sample.png", content_type: "image/png"})
  end
end
