defmodule CodexPooler.Gateway.OpenAICompatibility.ImagesProtocolTest do
  use ExUnit.Case, async: true
  alias CodexPooler.Gateway.OpenAICompatibility.{Images, Responses}

  @image_26_models ~w(gpt-image-2.6-flare gpt-image-2.6-sunburst)
  @edit_upload_limit 50 * 1024 * 1024
  # Detection only: N=4 scheduling can delay trace delivery or writer teardown;
  # successful cases finish on messages without spending this budget.
  @fixture_detection_timeout_ms 15_000

  test "edit upload limit rejects oversized images, arrays and masks before reading any file" do
    oversized = sized_upload(@edit_upload_limit + 1)
    half = sized_upload(div(@edit_upload_limit, 2))
    over_half = sized_upload(div(@edit_upload_limit, 2) + 1)

    for inputs <- [
          %{"image" => oversized},
          %{"image[]" => [half, over_half]},
          %{"image" => half, "mask" => over_half}
        ] do
      {result, read_calls} = image_file_reads(fn -> Images.coerce_edit(Map.merge(payload(), inputs)) end)
      assert edit_result_status(result) == {413, "request_too_large"}
      assert read_calls == 0
    end
  end

  @tag slow: "encodes real uploads at the 50 MiB aggregate boundary"
  test "edit upload limit accepts exactly 50 MiB for native, array and masked translations" do
    complete = sized_upload(@edit_upload_limit)
    half = sized_upload(div(@edit_upload_limit, 2))

    for {model, inputs} <- [
          {"gpt-image-2", %{"image" => complete}},
          {"gpt-image-2", %{"image[]" => [half, half]}},
          {"gpt-image-1", %{"image" => half, "mask" => half}}
        ] do
      {result, read_calls} = image_file_reads(fn -> Images.coerce_edit(Map.merge(payload(), Map.put(inputs, "model", model))) end)
      assert edit_result_status(result) == :ok
      assert read_calls > 0
    end
  end

  @tag slow: "reads a finite real pipe whose byte count exceeds its stat metadata"
  test "edit upload limit also bounds actual bytes when file metadata understates them" do
    supervisor = image_fixture_supervisor()
    path = Path.join(System.tmp_dir!(), "image-growing-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(path) end)
    assert {"", 0} = System.cmd("mkfifo", [path])
    assert {:ok, %{size: 0}} = File.stat(path)
    upload = %Plug.Upload{path: path, filename: "sample.png", content_type: "image/png"}

    half = sized_upload(div(@edit_upload_limit, 2))

    for {inputs, bytes} <- [
          {%{"image" => upload}, @edit_upload_limit + 1},
          {%{"image[]" => [half, upload]}, div(@edit_upload_limit, 2) + 1},
          {%{"image" => half, "mask" => upload}, div(@edit_upload_limit, 2) + 1}
        ] do
      {writer, monitor} = start_image_writer(supervisor, path, bytes)

      try do
        result = Images.coerce_edit(Map.merge(payload(), inputs))
        assert_receive {:DOWN, ^monitor, :process, ^writer, :normal}, @fixture_detection_timeout_ms
        assert edit_result_status(result) == {413, "request_too_large"}
      after
        stop_image_fixture_child(supervisor, writer)
        Process.demonitor(monitor, [:flush])
      end
    end
  end

  test "image fixture supervision stops a pending writer and collector before file cleanup" do
    supervisor_id = make_ref()
    supervisor = image_fixture_supervisor(supervisor_id)
    path = Path.join(System.tmp_dir!(), "image-partial-#{System.unique_integer([:positive])}")
    sibling = path <> "-unrelated"
    on_exit(fn -> Enum.each([path, sibling], &File.rm/1) end)
    File.touch!(sibling)
    assert {"", 0} = System.cmd("mkfifo", [path])
    {writer, writer_monitor} = start_image_writer(supervisor, path, 1)
    {:ok, collector} = Task.Supervisor.start_child(supervisor, fn -> collect_image_reads(0) end)
    collector_monitor = Process.monitor(collector)

    stop_supervised!(supervisor_id)
    assert_receive {:DOWN, ^writer_monitor, :process, ^writer, :shutdown}, @fixture_detection_timeout_ms
    assert_receive {:DOWN, ^collector_monitor, :process, ^collector, :shutdown}, @fixture_detection_timeout_ms
    assert :ok = File.rm(path)
    refute File.exists?(path)
    assert File.exists?(sibling)
  end

  test "image read tracing tears down its session and collector after a callback assertion" do
    supervisor = image_fixture_supervisor()
    sessions_before = :trace.session_info(self())

    assert_raise ExUnit.AssertionError, fn ->
      image_file_reads(fn -> flunk("controlled image trace callback failure") end, supervisor)
    end

    assert Task.Supervisor.children(supervisor) == []
    assert :trace.session_info(self()) == sessions_before
  end

  defp image_fixture_supervisor(id \\ make_ref()) do
    start_supervised!({Task.Supervisor, []}, id: id)
  end

  defp start_image_writer(supervisor, path, bytes) do
    owner = self()

    {:ok, writer} =
      Task.Supervisor.start_child(supervisor, fn ->
        send(owner, {:image_writer_started, self()})
        # A raw writer leaves the file server free to open the reader.
        File.open!(path, [:write, :binary, :raw], fn file ->
          :ok = :file.write(file, :binary.copy(<<0>>, bytes))
        end)
      end)

    monitor = Process.monitor(writer)
    assert_receive {:image_writer_started, ^writer}, @fixture_detection_timeout_ms
    {writer, monitor}
  end

  defp stop_image_fixture_child(supervisor, pid) do
    case Task.Supervisor.terminate_child(supervisor, pid) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  defp edit_result_status({:ok, _response}), do: :ok
  defp edit_result_status({:error, reason}), do: {reason.status, reason.code}

  defp sized_upload(bytes) do
    path = Path.join(System.tmp_dir!(), "image-limit-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(path) end)

    File.open!(path, [:write, :binary], fn file ->
      {:ok, _position} = :file.position(file, bytes - 1)
      :ok = IO.binwrite(file, <<0>>)
    end)

    %Plug.Upload{path: path, filename: "sample.png", content_type: "image/png"}
  end

  defp image_file_reads(fun, supervisor \\ image_fixture_supervisor()) do
    session_name = :"image_upload_trace_#{System.unique_integer([:positive])}"
    on_exit(fn -> destroy_image_trace_sessions(session_name) end)
    {:ok, collector} = Task.Supervisor.start_child(supervisor, fn -> collect_image_reads(0) end)
    monitor = Process.monitor(collector)
    session = :trace.session_create(session_name, collector, [])

    try do
      for mfa <- [{:file, :read_file, 2}, {:file, :open, 2}] do
        1 = :trace.function(session, mfa, true, [:global])
      end

      1 = :trace.process(session, self(), true, [:call, :arity])
      result = fun.()
      delivered = :trace.delivered(session, self())
      assert_receive {:trace_delivered, _tracee, ^delivered}, @fixture_detection_timeout_ms
      send(collector, {:count, self()})
      assert_receive {:image_read_count, count}, @fixture_detection_timeout_ms
      assert_receive {:DOWN, ^monitor, :process, ^collector, :normal}, @fixture_detection_timeout_ms
      {result, count}
    after
      :trace.session_destroy(session)
      stop_image_fixture_child(supervisor, collector)
      Process.demonitor(monitor, [:flush])
    end
  end

  defp destroy_image_trace_sessions(name) do
    for {^name, _id} = session <- :trace.session_info(:all) do
      :trace.session_destroy(session)
    end
  end

  defp collect_image_reads(count) do
    receive do
      {:trace, _pid, :call, _mfa} -> collect_image_reads(count + 1)
      {:count, from} -> send(from, {:image_read_count, count})
    end
  end

  test "GPT Image 2.6 preserves extended qualities and custom size boundaries" do
    for model <- @image_26_models,
        quality <- ~w(auto low medium high xhigh max),
        size <- ~w(auto 1536x864 864x1536 1024x640 640x1024 3840x2160 2160x3840 1536x512) do
      assert {:ok, response} =
               Images.coerce_generation(%{
                 "model" => model,
                 "prompt" => "synthetic",
                 "quality" => quality,
                 "size" => size,
                 "background" => "transparent"
               })

      assert response.endpoint == "/backend-api/codex/images/generations"
      assert response.payload["model"] == model
      assert response.payload["quality"] == quality
      assert response.payload["size"] == size
      assert response.payload["background"] == "transparent"
    end
  end

  test "GPT Image 2.6 rejects malformed and out-of-range options" do
    for model <- @image_26_models,
        {key, value} <- [
          {"quality", "ultra"},
          {"quality", 1},
          {"quality", %{}},
          {"size", 1024},
          {"size", %{}},
          {"size", "1536X864"},
          {"size", "1536x864suffix"},
          {"size", "1537x864"},
          {"size", "1536x865"},
          {"size", "0x1024"},
          {"size", "-1024x1024"},
          {"size", "3856x2048"},
          {"size", "2048x3856"},
          {"size", "1024x624"},
          {"size", "3840x2176"},
          {"size", "1552x512"},
          {"size", "512x1552"}
        ] do
      assert {:error, %{status: 400, param: ^key}} =
               Images.coerce_generation(%{
                 "model" => model,
                 "prompt" => "synthetic",
                 key => value
               })
    end
  end

  test "older image models retain their quality boundary" do
    for model <- ~w(gpt-image-1 gpt-image-1-mini gpt-image-1.5 gpt-image-2),
        quality <- ~w(xhigh max) do
      assert {:error, %{status: 400, param: "quality"}} =
               Images.coerce_generation(%{
                 "model" => model,
                 "prompt" => "synthetic",
                 "quality" => quality
               })
    end
  end

  test "generation rejects edit-only fields and unsupported response formats" do
    for {key, value} <- [
          {"mask", nil},
          {"input_fidelity", "high"},
          {"response_format", "url"},
          {"response_format", %{}},
          {"user", 12}
        ] do
      assert {:error, %{status: 400, param: ^key}} =
               Images.validate_generation(Map.put(payload(), key, value))
    end
  end

  test "base64 response format is accepted and user identifiers are discarded" do
    for user <- [nil, "synthetic-user"] do
      assert {:ok, normalized} =
               Images.validate_generation(Map.merge(payload(), %{"response_format" => "b64_json", "user" => user}))

      refute Map.has_key?(normalized, "user")
    end
  end

  test "completed output does not duplicate the output-item event" do
    for id <- [nil, "ig_fixture"] do
      item = %{
        "type" => "image_generation_call",
        "status" => "completed",
        "result" => encoded_image()
      }

      item = if id, do: Map.put(item, "id", id), else: item

      body =
        stream([
          %{"type" => "response.output_item.done", "item" => item},
          %{"type" => "response.completed", "response" => %{"output" => [item]}}
        ])

      assert {:ok, %{"data" => [_one]}} = Images.image_response_from_sse(body)
    end
  end

  test "failed item errors are fixed public errors" do
    body =
      stream([
        %{
          "type" => "response.output_item.done",
          "item" => %{
            "type" => "image_generation_call",
            "status" => "failed",
            "error" => %{
              "type" => "invalid_request_error",
              "code" => "synthetic-private-code",
              "message" => "synthetic-private-message",
              "param" => "synthetic-private-param"
            }
          }
        }
      ])

    assert {:error,
            %{
              status: 400,
              code: "image_generation_failed",
              message: "upstream image generation failed",
              param: nil
            }} = Images.image_response_from_sse(body)
  end

  test "malformed image results fail the whole response instead of being relabeled or dropped" do
    valid = image_item(encoded_image())

    for result <- [nil, "", 42, %{"url" => "https://example.com/image.png"}, "https://example.com/image.png", "%%%", Base.encode64("not an image")],
        invalid <- [image_item(result), Map.delete(image_item(result), "result")],
        items <- [[invalid], [valid, invalid], [invalid, valid]] do
      assert {:error, %{status: 502, code: "image_generation_failed"}} =
               Images.image_response_from_sse(stream([%{"type" => "response.completed", "response" => %{"output" => items}}]))
    end
  end

  test "valid image results retain order and terminal replacements are authoritative" do
    first = encoded_image(0)
    second = encoded_image(255)
    one = Map.put(image_item(first), "id", "ig_one")
    two = Map.put(image_item(second), "id", "ig_two")

    assert {:ok, %{"data" => [%{"b64_json" => ^first}, %{"b64_json" => ^second}]}} =
             Images.image_response_from_sse(stream([%{"type" => "response.completed", "response" => %{"output" => [one, two]}}]))

    invalid = Map.put(one, "result", "https://example.com/image.png")

    assert {:ok, %{"data" => [%{"b64_json" => ^first}]}} =
             Images.image_response_from_sse(stream([%{"type" => "response.output_item.done", "item" => invalid}, %{"type" => "response.completed", "response" => %{"output" => [one]}}]))

    assert {:error, %{code: "image_generation_failed"}} =
             Images.image_response_from_sse(stream([%{"type" => "response.output_item.done", "item" => one}, %{"type" => "response.completed", "response" => %{"output" => [invalid]}}]))
  end

  test "edit mask is carried by the image tool without modifying prompt" do
    path = Path.join(System.tmp_dir!(), "image-protocol-#{System.unique_integer([:positive])}")
    File.write!(path, <<0, 1, 2>>)
    on_exit(fn -> File.rm(path) end)
    upload = %Plug.Upload{path: path, filename: "sample.png", content_type: "image/png"}

    assert {:ok, response} =
             Images.coerce_edit(Map.merge(payload(), %{"image" => upload, "mask" => upload}))

    assert [%{"content" => [%{"text" => "synthetic"}, %{"type" => "input_image"}]}] =
             response.payload["input"]

    assert [%{"input_image_mask" => %{"image_url" => url}}] = response.payload["tools"]
    assert String.starts_with?(url, "data:image/png;base64,")
    assert response.payload["tool_choice"] == %{"type" => "image_generation"}
  end

  test "GPT Image 2.6 masked edits preserve extended options in Responses translation" do
    path =
      Path.join(System.tmp_dir!(), "image-mask-options-#{System.unique_integer([:positive])}")

    File.write!(path, <<0, 1, 2>>)
    on_exit(fn -> File.rm(path) end)
    upload = %Plug.Upload{path: path, filename: "sample.png", content_type: "image/png"}

    for model <- @image_26_models, quality <- ~w(xhigh max) do
      assert {:ok, response} =
               Images.coerce_edit(%{
                 "model" => model,
                 "prompt" => "synthetic",
                 "image" => upload,
                 "mask" => upload,
                 "quality" => quality,
                 "size" => "1536x864"
               })

      assert response.endpoint == "/backend-api/codex/responses"
      assert response.payload["tool_choice"] == %{"type" => "image_generation"}

      assert [
               %{
                 "model" => ^model,
                 "quality" => ^quality,
                 "size" => "1536x864",
                 "input_image_mask" => %{"image_url" => _}
               }
             ] = response.payload["tools"]
    end
  end

  test "terminal output supersedes earlier same-id items and ignores created snapshots" do
    item = %{"id" => "ig_fixture", "type" => "image_generation_call", "status" => "in_progress"}
    encoded = encoded_image()
    final = Map.merge(item, %{"status" => "completed", "result" => encoded})

    body =
      stream([
        %{"type" => "response.created", "response" => %{"output" => [item]}},
        %{"type" => "response.output_item.done", "item" => item},
        %{"type" => "response.completed", "response" => %{"output" => [final]}}
      ])

    assert {:ok, %{"data" => [%{"b64_json" => ^encoded}]}} = Images.image_response_from_sse(body)
  end

  test "null item ids do not collapse distinct results and failed final items remain errors" do
    one = %{
      "id" => nil,
      "type" => "image_generation_call",
      "status" => "completed",
      "result" => encoded_image(0)
    }

    two = Map.put(one, "result", encoded_image(255))

    assert {:ok, %{"data" => [_, _]}} =
             Images.image_response_from_sse(
               stream([
                 %{"type" => "response.completed", "response" => %{"output" => [one, two]}}
               ])
             )

    failed = Map.put(one, "status", "failed")

    assert {:error, %{code: "image_generation_failed"}} =
             Images.image_response_from_sse(
               stream([
                 %{"type" => "response.output_item.done", "item" => one},
                 %{"type" => "response.completed", "response" => %{"output" => [failed]}}
               ])
             )
  end

  test "Responses mask admission rejects malformed mask shapes" do
    for mask <- [
          nil,
          "invalid",
          %{},
          %{"image_url" => 12},
          %{"image_url" => ""},
          %{"image_url" => "data:image/png;base64,AAEC", "extra" => true}
        ] do
      tool = %{
        "type" => "image_generation",
        "model" => "gpt-image-1",
        "size" => "auto",
        "quality" => "auto",
        "input_image_mask" => mask
      }

      assert {:error, %{param: "tools"}} =
               Responses.validate(%{
                 "model" => "gpt-image-1",
                 "input" => "synthetic",
                 "tools" => [tool]
               })
    end
  end

  test "failed terminal cannot expose an earlier successful image" do
    item = %{"type" => "image_generation_call", "status" => "completed", "result" => encoded_image()}

    for type <- ["response.failed", "response.incomplete", "error"] do
      assert {:error, %{code: "image_generation_failed"}} =
               Images.image_response_from_sse(
                 stream([
                   %{"type" => "response.output_item.done", "item" => item},
                   %{"type" => type}
                 ])
               )
    end
  end

  test "native generation preserves all supported quality values and sizes" do
    for quality <- ~w(auto low medium high), size <- ~w(auto 1024x1024 1024x1536 1536x1024) do
      assert {:ok,
              %{
                endpoint: "/backend-api/codex/images/generations",
                payload: %{
                  "quality" => ^quality,
                  "size" => ^size,
                  "background" => "opaque",
                  "n" => 1
                }
              }} =
               Images.coerce_generation(%{
                 "model" => "gpt-image-2",
                 "prompt" => "synthetic",
                 "quality" => quality,
                 "size" => size,
                 "background" => "opaque",
                 "n" => 1
               })
    end
  end

  defp payload, do: %{"model" => "gpt-image-1", "prompt" => "synthetic"}

  defp image_item(result), do: %{"type" => "image_generation_call", "status" => "completed", "result" => result}

  defp encoded_image(color \\ 0) do
    header = <<1::32, 1::32, 8, 2, 0, 0, 0>>
    pixels = :zlib.compress(<<0, color, color, color>>)
    Base.encode64(<<137, 80, 78, 71, 13, 10, 26, 10>> <> png_chunk("IHDR", header) <> png_chunk("IDAT", pixels) <> png_chunk("IEND", ""))
  end

  defp png_chunk(type, data), do: <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>>

  defp stream(events),
    do: Enum.map_join(events, "", &("data: " <> CodexPooler.JSON.encode!(&1) <> "\n\n"))
end
