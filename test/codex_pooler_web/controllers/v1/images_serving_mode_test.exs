defmodule CodexPoolerWeb.V1.ImagesServingModeTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [auth: 2, gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.RoutingCircuitState
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
      assert tool["model"] == "gpt-image-1"
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
      assert request.request_metadata["requested_model"] == "gpt-image-1"
      assert request.request_metadata["effective_model"] == "gpt-image-1"
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

      original_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: original_level) end)

      {response, log} =
        ExUnit.CaptureLog.with_log([level: :info], fn ->
          image_request(auth(conn, setup), "generations", nil)
        end)

      assert %{"error" => %{"code" => "image_generation_failed"}} = json_response(response, 502)
      assert FakeUpstream.count(upstream) == 1
      assert Repo.aggregate(Request, :count) == 1
      assert Repo.aggregate(Attempt, :count) == 1
      assert [request] = Repo.all(Request)
      assert request.status == "failed"
      assert request.last_error_code == "image_generation_failed"
      assert request.response_status_code == 502
      assert [attempt] = Repo.all(Attempt)
      assert attempt.status == "failed"
      assert attempt.upstream_status_code == 200
      assert attempt.network_error_code == "image_generation_failed"
      assert log =~ "image_collection_failure request_id=#{request.id} attempt_id=#{attempt.id}"

      expected =
        %{absent: "no_image_item", empty: "empty_image_result", invalid: "nonstring_image_result"}[
          @result
        ]

      assert log =~ expected
      assert attempt.response_metadata["status_code"] == 200
      assert_usage_settled_once(request, attempt)
      refute Repo.exists?(from(c in RoutingCircuitState, where: c.failure_count > 0))
    end
  end

  for mode <- ["full", "lite"], chunk_size <- [257, 8191] do
    @mode mode
    @chunk_size chunk_size
    test "#{@mode} image output larger than retained diagnostics survives #{@chunk_size} byte chunks",
         %{conn: conn} do
      encoded = Base.encode64(:binary.copy(<<0, 1, 2, 3>>, 30_000))
      {:sse, chunks} = image_stream(encoded)
      stream = IO.iodata_to_binary(chunks)
      upstream = start_upstream({:sse, split_chunks(stream, @chunk_size)})
      setup = setup_host(upstream, @mode)

      response = image_request(auth(conn, setup), "generations", nil)

      assert %{"data" => [%{"b64_json" => actual}]} = json_response(response, 200)
      assert byte_size(actual) == byte_size(encoded)
      assert :crypto.hash(:sha256, actual) == :crypto.hash(:sha256, encoded)
      assert [request] = Repo.all(Request)
      assert request.status == "succeeded"
      assert [attempt] = Repo.all(Attempt)
      assert attempt.status == "succeeded"
      assert_usage_settled_once(request, attempt)
      assert FakeUpstream.count(upstream) == 1
    end
  end

  defp split_chunks(body, size) when byte_size(body) <= size, do: [body]

  defp split_chunks(body, size) do
    <<chunk::binary-size(^size), rest::binary>> = body
    [chunk | split_chunks(rest, size)]
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

  for mode <- ["full", "lite"],
      {model, options, fidelity} <-
        Enum.map(~w(gpt-image-2 gpt-image-2.5-flare gpt-image-2.5-sunburst), &{&1, :mask, nil}) ++
          for(
            model <- ~w(gpt-image-2 gpt-image-2.5-flare gpt-image-2.5-sunburst gpt-image-1-mini),
            options <- [:fidelity, :both],
            fidelity <- ["low", "high"],
            do: {model, options, fidelity}
          ) ++
          for(
            model <- ["gpt-image-1", "gpt-image-1.5"],
            fidelity <- ["low", "high"],
            do: {model, :fidelity, fidelity}
          ) do
    @mode mode
    @options options
    @image_model model
    @fidelity fidelity
    test "#{@image_model} edit with #{@options} #{@fidelity} obeys #{@mode} fidelity policy", %{
      conn: conn
    } do
      source = png(255, 0, 0)
      mask = png(0, 255, 0)
      upstream = start_upstream(image_stream(Base.encode64(png(0, 0, 255))))
      setup = setup_host(upstream, @mode, @image_model)
      fields = [{"model", @image_model}, {"prompt", "synthetic image"}, {"quality", "high"}]

      fields =
        if @options in [:fidelity, :both],
          do: fields ++ [{"input_fidelity", @fidelity}],
          else: fields

      parts =
        for {key, value} <- fields,
            do:
              "--edit-options\r\nContent-Disposition: form-data; name=\"#{key}\"\r\n\r\n#{value}\r\n"

      uploads =
        if @options in [:mask, :both],
          do: [{"image", source}, {"mask", mask}],
          else: [{"image", source}]

      files =
        for {key, bytes} <- uploads,
            do: [
              "--edit-options\r\nContent-Disposition: form-data; name=\"#{key}\"; filename=\"sample.png\"\r\nContent-Type: image/png\r\n\r\n",
              bytes,
              "\r\n"
            ]

      response =
        conn
        |> auth(setup)
        |> put_req_header("content-type", "multipart/form-data; boundary=edit-options")
        |> post("/v1/images/edits", IO.iodata_to_binary([parts, files, "--edit-options--\r\n"]))

      if @image_model in ~w(gpt-image-2 gpt-image-2.5-flare gpt-image-2.5-sunburst gpt-image-1-mini) and
           @options != :mask do
        assert %{"error" => %{"param" => "input_fidelity", "type" => "invalid_request_error"}} =
                 json_response(response, 400)

        assert FakeUpstream.count(upstream) == 0
        assert Repo.aggregate(Request, :count) == 0
        assert Repo.aggregate(Attempt, :count) == 0
        assert Repo.aggregate(LedgerEntry, :count) == 0
      else
        assert %{"data" => [_]} = json_response(response, 200)
        assert [captured] = FakeUpstream.requests(upstream)
        assert captured.path == "/backend-api/codex/responses"
        assert [tool] = image_tools(captured.json, @mode)
        assert tool["model"] == @image_model
        assert tool["quality"] == "high"
        assert Map.has_key?(tool, "input_fidelity") == @options in [:fidelity, :both]
        if @options in [:fidelity, :both], do: assert(tool["input_fidelity"] == @fidelity)
        assert Map.has_key?(tool, "input_image_mask") == @options in [:mask, :both]

        if @options in [:mask, :both] do
          assert %{"image_url" => "data:image/png;base64," <> encoded} = tool["input_image_mask"]
          assert Base.decode64!(encoded) == mask
        end

        content = captured.json["input"] |> Enum.flat_map(&Map.get(&1, "content", []))

        assert [
                 %{"type" => "input_text", "text" => "synthetic image"},
                 %{"type" => "input_image", "image_url" => "data:image/png;base64," <> encoded}
               ] = content

        assert Base.decode64!(encoded) == source
        assert [request] = Repo.all(Request)
        assert request.status == "succeeded"
        assert request.request_metadata["effective_model"] == @image_model
        assert [attempt] = Repo.all(Attempt)
        assert attempt.response_metadata["routing"]["model_serving_mode"] == @mode
        assert_usage_settled_once(request, attempt)
      end
    end
  end

  defp setup_host(upstream, mode, image_model \\ "gpt-image-1") do
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
    |> Ecto.Changeset.change(allowed_model_identifiers: [image_model])
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
      "model" => "gpt-image-1",
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
            {"model", "gpt-image-1"},
            {"prompt", "synthetic image"},
            {"quality", "medium"},
            {"input_fidelity", "high"}
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
           "output" => output,
           "usage" => %{"input_tokens" => 7, "output_tokens" => 13, "total_tokens" => 20}
         }
       }}
    ])
  end

  defp assert_usage_settled_once(request, attempt) do
    assert request.usage_status == "usage_known"
    assert attempt.usage_status == "usage_known"

    assert [settlement] =
             Repo.all(
               from(e in LedgerEntry,
                 where: e.request_id == ^request.id and e.entry_kind == "settlement"
               )
             )

    assert {settlement.input_tokens, settlement.output_tokens, settlement.total_tokens} ==
             {7, 13, 20}
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
