defmodule CodexPoolerWeb.V1.ImagesServingModeTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Pools.ModelServingOverride
  alias CodexPooler.Repo

  for mode <- ["full", "lite"], operation <- ["generations", "edits"] do
    @mode mode
    @operation operation
    test "hidden image model #{@operation} uses the selected #{@mode} host", %{conn: conn} do
      source = png(255, 0, 0)
      generated = png(0, 0, 255)
      upstream = start_upstream(image_stream(Base.encode64(generated)))
      setup = setup_host(upstream, @mode)

      response = image_request(auth(conn, setup), @operation, source)

      assert %{"data" => [%{"b64_json" => encoded}]} = json_response(response, 200)
      assert {:ok, decoded} = Base.decode64(encoded)
      assert decoded == generated
      assert_png(decoded)
      refute decoded == source

      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.path == "/backend-api/codex/responses"
      assert captured.json["model"] == setup.model.upstream_model_id
      assert captured.json["stream"] == true
      assert [tool] = image_tools(captured.json, @mode)
      assert tool["type"] == "image_generation"
      assert tool["model"] == "gpt-image-2"
      assert tool["quality"] == "medium"

      if @operation == "edits" do
        image =
          captured.json["input"]
          |> Enum.flat_map(&Map.get(&1, "content", []))
          |> Enum.find(&(&1["type"] == "input_image"))

        assert %{"image_url" => "data:image/png;base64," <> input} = image
        assert {:ok, transmitted} = Base.decode64(input)
        assert transmitted == source
      end

      assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
      assert request.status == "succeeded"
      assert request.request_metadata["requested_model"] == "gpt-image-2"
      assert request.request_metadata["effective_model"] == "gpt-image-2"
      assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
      assert attempt.status == "succeeded"

      expected = %{
        "model_serving_mode_configured" => @mode,
        "model_serving_mode" => @mode,
        "model_serving_mode_source" => "override"
      }

      for metadata <- [request.request_metadata, attempt.response_metadata] do
        assert Map.take(metadata["routing"], Map.keys(expected)) == expected
        refute inspect(metadata) =~ Base.encode64(source)
        refute inspect(metadata) =~ encoded
      end
    end
  end

  for mode <- ["full", "lite"], result <- [:absent, :empty, :invalid] do
    @mode mode
    @result result
    test "#{@mode} image response with #{@result} output fails truthfully", %{conn: conn} do
      result = %{absent: :absent, empty: "", invalid: 42}[@result]
      upstream = start_upstream(image_stream(result))
      setup = setup_host(upstream, @mode)

      response = image_request(auth(conn, setup), "generations", nil)

      assert %{"error" => %{"code" => "image_generation_failed"}} = json_response(response, 502)
      assert FakeUpstream.count(upstream) == 1
      assert Repo.aggregate(Request, :count) == 1
      assert Repo.aggregate(Attempt, :count) == 1
    end
  end

  test "authentication and malformed multipart fail before upstream work", %{conn: conn} do
    upstream = start_upstream(image_stream(:absent))
    setup = setup_host(upstream, "lite")

    for operation <- ["generations", "edits"] do
      assert conn |> recycle() |> image_request(operation, png(255, 0, 0)) |> response(401)
    end

    malformed =
      conn
      |> recycle()
      |> auth(setup)
      |> put_req_header("content-type", "multipart/form-data; boundary=missing-image")
      |> post("/v1/images/edits", multipart("missing-image", nil))

    assert %{"error" => %{"code" => "invalid_request", "param" => "image"}} =
             json_response(malformed, 400)

    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Request, :count) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  test "caller typed Responses tool choice remains rejected on Lite", %{conn: conn} do
    upstream = start_upstream(image_stream(:absent))
    setup = setup_host(upstream, "lite")

    setup.api_key
    |> Ecto.Changeset.change(allowed_model_identifiers: [setup.model.exposed_model_id])
    |> Repo.update!()

    response =
      conn
      |> auth(setup)
      |> post("/v1/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "synthetic image",
        "tools" => [%{"type" => "image_generation"}],
        "tool_choice" => %{"type" => "image_generation"}
      })

    assert %{"error" => %{"code" => "unsupported_parameter", "param" => "tool_choice"}} =
             json_response(response, 400)

    assert FakeUpstream.count(upstream) == 0
    assert Repo.aggregate(Attempt, :count) == 0
  end

  defp setup_host(upstream, mode) do
    setup = gateway_setup(upstream)

    setup.model
    |> Ecto.Changeset.change(
      metadata:
        put_in(
          setup.model.metadata,
          ["source_assignment_models", setup.assignment.id, "input_modalities"],
          ["text", "image"]
        )
    )
    |> Repo.update!()

    setup.api_key
    |> Ecto.Changeset.change(allowed_model_identifiers: ["gpt-image-2"])
    |> Repo.update!()

    timestamp = DateTime.utc_now()

    Repo.insert!(%ModelServingOverride{
      pool_id: setup.pool.id,
      exposed_model_id: setup.model.exposed_model_id,
      mode: mode,
      created_at: timestamp,
      updated_at: timestamp
    })

    setup
  end

  defp image_request(conn, "generations", _source) do
    post(conn, "/v1/images/generations", %{
      "model" => "gpt-image-2",
      "prompt" => "synthetic image",
      "quality" => "medium"
    })
  end

  defp image_request(conn, "edits", source) do
    conn
    |> put_req_header("content-type", "multipart/form-data; boundary=image-fixture")
    |> post("/v1/images/edits", multipart("image-fixture", source))
  end

  defp multipart(boundary, source) do
    fields =
      for {key, value} <- [
            {"model", "gpt-image-2"},
            {"prompt", "synthetic image"},
            {"quality", "medium"}
          ] do
        "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{key}\"\r\n\r\n#{value}\r\n"
      end

    image =
      if source do
        [
          "--#{boundary}\r\nContent-Disposition: form-data; name=\"image\"; filename=\"source.png\"\r\nContent-Type: image/png\r\n\r\n",
          source,
          "\r\n"
        ]
      else
        []
      end

    IO.iodata_to_binary([fields, image, "--#{boundary}--\r\n"])
  end

  defp image_tools(payload, "full"), do: payload["tools"]

  defp image_tools(payload, "lite") do
    payload["input"] |> Enum.find(&(&1["type"] == "additional_tools")) |> Map.fetch!("tools")
  end

  defp image_stream(result) do
    output =
      if result == :absent,
        do: [],
        else: [%{"type" => "image_generation_call", "status" => "completed", "result" => result}]

    FakeUpstream.sse_stream([
      {"response.completed",
       %{
         "type" => "response.completed",
         "response" => %{
           "id" => "resp_synthetic_image",
           "status" => "completed",
           "output" => output
         }
       }}
    ])
  end

  defp png(red, green, blue) do
    IO.iodata_to_binary([
      <<137, 80, 78, 71, 13, 10, 26, 10>>,
      png_chunk("IHDR", <<1::32, 1::32, 8, 2, 0, 0, 0>>),
      png_chunk("IDAT", :zlib.compress(<<0, red, green, blue>>)),
      png_chunk("IEND", <<>>)
    ])
  end

  defp png_chunk(type, data),
    do: <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>>

  defp assert_png(<<137, 80, 78, 71, 13, 10, 26, 10, chunks::binary>>) do
    <<13::32, "IHDR", header::binary-size(13), header_crc::32, size::32, "IDAT",
      data::binary-size(size), data_crc::32, 0::32, "IEND", end_crc::32>> = chunks

    assert header == <<1::32, 1::32, 8, 2, 0, 0, 0>>
    assert header_crc == :erlang.crc32("IHDR" <> header)
    assert data_crc == :erlang.crc32("IDAT" <> data)
    assert end_crc == :erlang.crc32("IEND")
    assert <<0, 0, 0, 255>> == :zlib.uncompress(data)
  end
end
