defmodule CodexPooler.Gateway.Transports.FileBridgeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.{RequestOptions, TransportEnvelope}
  alias CodexPooler.Gateway.Transports.FileBridge
  alias CodexPooler.UpstreamConnPoolTelemetry

  @request_detection_timeout_ms 15_000

  setup do
    CodexPooler.TestAppEnv.restore_on_exit(FileBridge)
    Application.put_env(:codex_pooler, FileBridge, upload_retry_interval_ms: 0)
    :ok
  end

  test "presigned upload replays the complete body at the same URL after a storage 503" do
    contents = String.duplicate("synthetic upload chunk", 8_000)
    path = upload_tempfile!(contents)
    %{url: url, served_ref: ref} = start_upload_capture_server!([503, 201])

    assert :ok = FileBridge.upload_file(url, %{"path" => path, "content_type" => "text/plain"})

    for _attempt <- 1..2 do
      assert_receive {^ref, request}, @request_detection_timeout_ms
      {head, body} = split_raw_http_request!(request)
      assert String.starts_with?(head, "PUT /upload HTTP/1.1\r\n")
      assert :crypto.hash(:sha256, decode_request_body!(head, body)) == :crypto.hash(:sha256, contents)
      assert raw_header_values(head, "authorization") == []
    end
  end

  test "an interrupted body is reopened and replayed from the beginning" do
    contents = String.duplicate("synthetic upload chunk", 200_000)
    path = upload_tempfile!(contents)
    %{url: url, served_ref: ref} = start_upload_capture_server!([:interrupt, 201])

    assert :ok = FileBridge.upload_file(url, %{"path" => path, "content_type" => "text/plain"})
    assert_receive {^ref, :interrupted}, @request_detection_timeout_ms
    assert_receive {^ref, request}, @request_detection_timeout_ms
    {head, body} = split_raw_http_request!(request)
    assert :crypto.hash(:sha256, decode_request_body!(head, body)) == :crypto.hash(:sha256, contents)
  end

  test "storage response decoding cannot mask a retryable status" do
    path = upload_tempfile!("synthetic upload")

    %{url: url, served_ref: ref} =
      start_upload_capture_server!([
        {503, [{"content-type", "application/json"}, {"content-encoding", "gzip"}], "invalid compressed json"},
        201
      ])

    assert :ok = FileBridge.upload_file(url, %{"path" => path, "content_type" => "text/plain"})
    for _attempt <- 1..2, do: assert_receive({^ref, _request}, @request_detection_timeout_ms)
  end

  test "five unsuccessful PUTs exhaust the attempt limit without leaking the signed URL" do
    path = upload_tempfile!("private synthetic upload")
    %{url: url, served_ref: ref} = start_upload_capture_server!(List.duplicate(503, 6))

    log =
      capture_log(fn ->
        assert {:error, error} = FileBridge.upload_file(url <> "?sig=synthetic-secret", %{"path" => path, "content_type" => "text/plain"})
        assert error.code == "upstream_file_upload_failed"
        refute inspect(error) =~ "synthetic-secret"
        refute inspect(error) =~ "private synthetic upload"
      end)

    for _attempt <- 1..5, do: assert_receive({^ref, _request}, @request_detection_timeout_ms)
    refute_received {^ref, _request}
    refute log =~ "synthetic-secret"
    refute log =~ "private synthetic upload"
  end

  test "nonretryable statuses including redirects perform only one PUT" do
    path = upload_tempfile!("synthetic upload")

    for status <- [301, 307, 400, 403, 408, 429, 500, 502, 504] do
      %{url: url, served_ref: ref} = start_upload_capture_server!([status, 201])
      assert {:error, %{code: "upstream_file_upload_failed"}} = FileBridge.upload_file(url, %{"path" => path, "content_type" => "text/plain"})
      assert_receive {^ref, _request}, @request_detection_timeout_ms
      refute_received {^ref, _request}
    end
  end

  @tag slow: "exercises the real one-second Retry-After delay"
  test "storage retry delays are honored with millisecond header precedence" do
    path = upload_tempfile!("synthetic upload")

    for {headers, minimum_ms} <- [
          {[{"x-ms-retry-after-ms", "40"}, {"retry-after", "999999"}], 40},
          {[{"x-ms-retry-after-ms", "invalid"}, {"retry-after", "1"}], 1_000}
        ] do
      %{url: url} = start_upload_capture_server!([{503, headers}, 201])
      started = System.monotonic_time(:millisecond)
      assert :ok = FileBridge.upload_file(url, %{"path" => path, "content_type" => "text/plain"})
      assert System.monotonic_time(:millisecond) - started >= minimum_ms
    end
  end

  test "malformed and duplicate retry delays fall back without crashing" do
    path = upload_tempfile!("synthetic upload")

    for headers <- [
          [{"retry-after", "1suffix"}],
          [{"retry-after", "-1"}],
          [{"retry-after", "not-a-date"}],
          [{"retry-after", "0"}, {"retry-after", "1"}],
          [{"retry-after", "Mon, 01 Jan 2024 09:00:00 GMT"}]
        ] do
      %{url: url} = start_upload_capture_server!([{503, headers}, 201])
      assert :ok = FileBridge.upload_file(url, %{"path" => path, "content_type" => "text/plain"})
    end
  end

  test "a retry delay outside the shared budget stops without retrying early" do
    path = upload_tempfile!("synthetic upload")

    for headers <- [
          [{"x-ms-retry-after-ms", "300000"}],
          [{"x-ms-retry-after-ms", String.duplicate("9", 129)}],
          [{"retry-after", "300"}],
          [{"retry-after", Calendar.strftime(~U[2099-09-25 09:00:00Z], "%a, %d %b %Y %H:%M:%S GMT")}]
        ] do
      %{url: url, served_ref: ref} = start_upload_capture_server!([{503, headers}, 201])
      assert {:error, %{code: "upstream_file_upload_failed"}} = FileBridge.upload_file(url, %{"path" => path, "content_type" => "text/plain"})
      assert_receive {^ref, _request}, @request_detection_timeout_ms
      refute_received {^ref, _request}
    end
  end

  @tag slow: "waits for the one-second shared upload deadline and socket closure"
  test "the shared deadline cancels an in-flight PUT and closes its socket" do
    Application.put_env(:codex_pooler, FileBridge, upload_timeout_ms: 1_000, upload_retry_interval_ms: 0)
    path = upload_tempfile!("synthetic upload")
    %{url: url, served_ref: ref} = start_upload_capture_server!([:stall, 201])

    capture_log(fn ->
      assert {:error, %{code: "upstream_file_upload_failed"}} = FileBridge.upload_file(url, %{"path" => path, "content_type" => "text/plain"})
    end)

    assert_receive {^ref, _request}, @request_detection_timeout_ms
    assert_receive {^ref, :closed}, @request_detection_timeout_ms
    refute_received {^ref, _request}
  end

  test "an exhausted deadline or unreadable tempfile dispatches no PUT" do
    %{url: url, served_ref: ref} = start_upload_capture_server!([201])
    path = upload_tempfile!("synthetic upload")
    File.rm!(path)
    assert {:error, %{code: "invalid_request"}} = FileBridge.upload_file(url, %{"path" => path, "content_type" => "text/plain"})
    Application.put_env(:codex_pooler, FileBridge, upload_timeout_ms: 0)
    assert {:error, %{code: "upstream_file_upload_failed"}} = FileBridge.upload_file(url, %{"path" => path, "content_type" => "text/plain"})
    refute_received {^ref, _request}
  end

  test "request process cancellation closes the in-flight upload without retrying" do
    path = upload_tempfile!("synthetic upload")
    %{url: url, served_ref: ref} = start_upload_capture_server!([:stall, 201])
    caller = spawn(fn -> FileBridge.upload_file(url, %{"path" => path, "content_type" => "text/plain"}) end)
    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    monitor = Process.monitor(caller)
    assert_receive {^ref, _request}, @request_detection_timeout_ms
    Process.exit(caller, :shutdown)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :shutdown}, @request_detection_timeout_ms
    assert_receive {^ref, :closed}, @request_detection_timeout_ms
    refute_received {^ref, _request}
  end

  test "a tempfile removed after the first attempt is rejected before a second PUT" do
    path = upload_tempfile!("synthetic upload")
    %{url: url, served_ref: ref} = start_upload_capture_server!([{:remove_file, path}, 201])
    assert {:error, %{code: "invalid_request"}} = FileBridge.upload_file(url, %{"path" => path, "content_type" => "text/plain"})
    assert_receive {^ref, _request}, @request_detection_timeout_ms
    refute_received {^ref, _request}
  end

  test "logs upload transport failures with safe request context" do
    request_id = Ecto.UUID.generate()
    assignment_id = Ecto.UUID.generate()
    identity_id = Ecto.UUID.generate()
    path = upload_tempfile!("sample upload")

    request_options =
      %{request_id: request_id}
      |> RequestOptions.build("/v1/files", %{})
      |> RequestOptions.put_file_bridge(
        operation: :upload,
        endpoint: "/v1/files/upload",
        pool_upstream_assignment_id: assignment_id,
        upstream_identity_id: identity_id,
        route_metadata: %{"route_class" => "file_upload", "routing_strategy" => "test_strategy"}
      )

    log =
      capture_log(fn ->
        assert {:error, %{code: "upstream_file_upload_failed"}} =
                 FileBridge.upload_file(
                   "http://127.0.0.1:1/upload",
                   %{"path" => path, "content_type" => "text/plain"},
                   request_options
                 )
      end)

    assert log =~ "file bridge transport failed"
    assert log =~ "operation=upload"
    assert log =~ "endpoint=/v1/files/upload"
    assert log =~ "request_id=#{request_id}"
    assert log =~ "pool_upstream_assignment_id=#{assignment_id}"
    assert log =~ "upstream_identity_id=#{identity_id}"
    assert log =~ "route_class=file_upload"
    assert log =~ "routing_strategy=test_strategy"
    assert log =~ "exception="
    assert log =~ "reason="
    refute log =~ "sample upload"
  end

  test "logs upload HTTP protocol failures with safe request context" do
    request_id = Ecto.UUID.generate()
    assignment_id = Ecto.UUID.generate()
    identity_id = Ecto.UUID.generate()
    path = upload_tempfile!(String.duplicate("x", 32_768))

    %{url: upload_url, served_ref: served_ref, server_pid: server_pid} =
      start_invalid_content_length_server!()

    request_options =
      %{request_id: request_id}
      |> RequestOptions.build("/v1/files", %{})
      |> RequestOptions.put_file_bridge(
        operation: :upload,
        endpoint: "/v1/files/upload",
        pool_upstream_assignment_id: assignment_id,
        upstream_identity_id: identity_id,
        route_metadata: %{"route_class" => "file_upload", "routing_strategy" => "test_strategy"}
      )

    log =
      capture_log(fn ->
        assert {:error, %{code: "upstream_file_upload_failed"}} =
                 FileBridge.upload_file(
                   upload_url,
                   %{"path" => path, "content_type" => "text/plain"},
                   request_options
                 )
      end)

    assert_receive {^served_ref, :served}, @request_detection_timeout_ms

    assert log =~ "file bridge transport failed"
    assert log =~ "operation=upload"
    assert log =~ "endpoint=/v1/files/upload"
    assert log =~ "request_id=#{request_id}"
    assert log =~ "pool_upstream_assignment_id=#{assignment_id}"
    assert log =~ "upstream_identity_id=#{identity_id}"
    assert log =~ "route_class=file_upload"
    assert log =~ "routing_strategy=test_strategy"
    assert log =~ "exception=Req.HTTPError"
    assert log =~ "reason=invalid_content_length_header"
    refute log =~ "authorization"
    send(server_pid, :close)
  end

  test "presigned upload sends only storage protocol headers" do
    contents = "synthetic direct upload bytes"
    path = upload_tempfile!(contents)

    %{url: upload_url, served_ref: served_ref} = start_upload_capture_server!()

    request_options =
      %{request_id: Ecto.UUID.generate()}
      |> RequestOptions.build("/v1/files", %{})
      |> RequestOptions.put_file_bridge(
        operation: :upload,
        endpoint: "/v1/files/upload",
        forwarded_headers: [
          {"x-openai-internal-codex-residency", "must-not-reach-storage"}
        ]
      )

    log =
      capture_log(fn ->
        assert :ok =
                 FileBridge.upload_file(
                   upload_url,
                   %{"path" => path, "content_type" => "text/plain"},
                   request_options
                 )
      end)

    assert_receive {^served_ref, request}, @request_detection_timeout_ms
    {request_head, encoded_request_body} = split_raw_http_request!(request)
    request_body = decode_request_body!(request_head, encoded_request_body)

    assert String.starts_with?(request_head, "PUT /upload HTTP/1.1\r\n")
    assert raw_header_values(request_head, "content-type") == ["text/plain"]

    assert raw_header_values(request_head, "content-length") == [
             Integer.to_string(byte_size(contents))
           ]

    assert raw_header_values(request_head, "transfer-encoding") == []
    assert raw_header_values(request_head, "x-ms-blob-type") == ["BlockBlob"]
    assert raw_header_values(request_head, "x-openai-internal-codex-residency") == []
    assert raw_header_values(request_head, "authorization") == []
    assert byte_size(request_body) == byte_size(contents)
    assert :crypto.hash(:sha256, request_body) == :crypto.hash(:sha256, contents)
    refute log =~ "file bridge transport failed"
  end

  test "presigned upload PUTs carry the outbound connection idle bound from settings" do
    {:ok, storage} = FakeUpstream.start_link({:raw_body, 201, "", []})
    on_exit(fn -> FakeUpstream.stop(storage) end)
    upload_url = FakeUpstream.url(storage) <> "/upload"

    UpstreamConnPoolTelemetry.put_idle_bound!(0)
    UpstreamConnPoolTelemetry.attach!(upload_url)

    request_options =
      %{request_id: Ecto.UUID.generate()}
      |> RequestOptions.build("/v1/files", %{})
      |> RequestOptions.put_file_bridge(operation: :upload, endpoint: "/v1/files/upload")

    for index <- 1..2 do
      path = upload_tempfile!("synthetic upload #{index}")

      assert :ok =
               FileBridge.upload_file(
                 upload_url,
                 %{"path" => path, "content_type" => "text/plain"},
                 request_options
               )
    end

    assert FakeUpstream.count(storage) == 2
    assert UpstreamConnPoolTelemetry.drain_events() == [:conn_max_idle_time_exceeded]
  end

  test "file control-plane envelope removes mixed-case residency forwarding" do
    headers =
      TransportEnvelope.headers(
        %{chatgpt_account_id: "synthetic-account"},
        residency_token("file-region-authoritative"),
        [{"accept", "application/json"}],
        forwarded_headers: [
          {"X-OpenAI-Internal-Codex-Residency", "caller-copy-one"},
          {"x-OPENAI-internal-codex-residency", "caller-copy-two"}
        ]
      )

    assert header_values(headers, "x-openai-internal-codex-residency") == [
             "file-region-authoritative"
           ]
  end

  defp upload_tempfile!(contents) do
    path =
      Path.join(
        System.tmp_dir!(),
        "codex-pooler-upload-#{System.unique_integer([:positive])}.txt"
      )

    File.write!(path, contents)
    ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)
    path
  end

  defp residency_token(value) do
    header = Base.url_encode64(CodexPooler.JSON.encode!(%{"alg" => "none"}), padding: false)

    payload =
      Base.url_encode64(CodexPooler.JSON.encode!(%{"chatgpt_compute_residency" => value}),
        padding: false
      )

    Enum.join([header, payload, "signature"], ".")
  end

  defp header_values(headers, expected_name) do
    for {name, value} <- headers, String.downcase(name) == expected_name, do: value
  end

  defp start_invalid_content_length_server! do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, port} = :inet.port(listen_socket)
    parent = self()
    served_ref = make_ref()

    pid =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen_socket)
        _request = read_raw_http_request(socket)

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\n",
            "content-type: application/json\r\n",
            "content-length: +0\r\n",
            "connection: close\r\n\r\n"
          ])

        send(parent, {served_ref, :served})

        receive do
          :close -> :ok
        end

        :gen_tcp.close(socket)
        :gen_tcp.close(listen_socket)
      end)

    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
      :gen_tcp.close(listen_socket)
    end)

    %{
      url: "http://127.0.0.1:#{port}/upload",
      served_ref: served_ref,
      server_pid: pid
    }
  end

  defp start_upload_capture_server!(statuses \\ [200]) do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, port} = :inet.port(listen_socket)
    parent = self()
    served_ref = make_ref()

    pid =
      spawn_link(fn ->
        Enum.each(statuses, fn action ->
          {:ok, socket} = :gen_tcp.accept(listen_socket)
          serve_upload(socket, action, parent, served_ref)
          :gen_tcp.close(socket)
        end)

        :gen_tcp.close(listen_socket)
      end)

    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
      :gen_tcp.close(listen_socket)
    end)

    %{url: "http://127.0.0.1:#{port}/upload", served_ref: served_ref}
  end

  defp serve_upload(socket, :interrupt, parent, ref) do
    {:ok, _partial_request} = :gen_tcp.recv(socket, 1_024, @request_detection_timeout_ms)
    :ok = :inet.setopts(socket, linger: {true, 0})
    send(parent, {ref, :interrupted})
  end

  defp serve_upload(socket, :stall, parent, ref) do
    request = read_raw_http_request(socket)
    send(parent, {ref, request})
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, @request_detection_timeout_ms)
    send(parent, {ref, :closed})
  end

  defp serve_upload(socket, {:remove_file, path}, parent, ref) do
    # File.stream! opens lazily during the first send. Delete only after that
    # PUT is complete so this action tests revalidation before the retry.
    request = read_raw_http_request(socket)
    File.rm!(path)
    send_upload_response(socket, 503, [{"x-ms-retry-after-ms", "0"}], "")
    send(parent, {ref, request})
  end

  defp serve_upload(socket, status, parent, ref) when is_integer(status),
    do: serve_upload(socket, {status, [{"x-ms-retry-after-ms", "0"}]}, parent, ref)

  defp serve_upload(socket, {status, headers}, parent, ref) do
    serve_upload(socket, {status, headers, ""}, parent, ref)
  end

  defp serve_upload(socket, {status, headers, body}, parent, ref) do
    request = read_raw_http_request(socket)
    send_upload_response(socket, status, headers, body)
    send(parent, {ref, request})
  end

  defp send_upload_response(socket, status, headers, body) do
    :ok =
      :gen_tcp.send(socket, [
        "HTTP/1.1 #{status} Response\r\n",
        Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
        "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n",
        body
      ])
  end

  defp split_raw_http_request!(request) do
    case :binary.split(request, "\r\n\r\n") do
      [head, body] -> {head <> "\r\n", body}
      _other -> flunk("captured upload request was incomplete")
    end
  end

  defp raw_header_values(request_head, expected_name) do
    request_head
    |> String.split("\r\n", trim: true)
    |> Enum.drop(1)
    |> Enum.flat_map(&matching_header_values(&1, expected_name))
  end

  defp matching_header_values(line, expected_name) do
    case String.split(line, ":", parts: 2) do
      [name, value] -> matching_header_value(name, value, expected_name)
      _other -> []
    end
  end

  defp matching_header_value(name, value, expected_name) do
    if String.downcase(name) == expected_name, do: [String.trim(value)], else: []
  end

  defp decode_request_body!(request_head, body) do
    if raw_header_values(request_head, "transfer-encoding") == ["chunked"] do
      decode_chunked_body!(body, [])
    else
      body
    end
  end

  defp decode_chunked_body!("0\r\n\r\n", chunks),
    do: chunks |> Enum.reverse() |> IO.iodata_to_binary()

  defp decode_chunked_body!(body, chunks) do
    with [hex_size, rest] <- :binary.split(body, "\r\n"),
         {size, ""} <- Integer.parse(hex_size, 16),
         <<chunk::binary-size(^size), "\r\n", remaining::binary>> <- rest do
      decode_chunked_body!(remaining, [chunk | chunks])
    else
      _other -> flunk("captured upload request had invalid chunk framing")
    end
  end

  defp read_raw_http_request(socket, acc \\ "") do
    case :gen_tcp.recv(socket, 0, @request_detection_timeout_ms) do
      {:ok, data} ->
        acc = acc <> data

        if raw_http_request_complete?(acc) do
          acc
        else
          read_raw_http_request(socket, acc)
        end

      {:error, reason} ->
        raise "failed to read complete raw HTTP request: #{inspect(reason)}"
    end
  end

  defp raw_http_request_complete?(data) do
    case :binary.split(data, "\r\n\r\n") do
      [headers, body] ->
        if chunked_request?(headers) do
          String.ends_with?(body, "0\r\n\r\n")
        else
          content_length_body_complete?(headers, body)
        end

      _incomplete ->
        false
    end
  end

  defp chunked_request?(headers) do
    Regex.match?(~r/\r\ntransfer-encoding:\s*chunked(?:\r\n|$)/i, "\r\n" <> headers)
  end

  defp content_length_body_complete?(headers, body) do
    case Regex.run(~r/\r\ncontent-length:\s*(\d+)/i, "\r\n" <> headers, capture: :all_but_first) do
      [length] -> byte_size(body) >= String.to_integer(length)
      nil -> true
    end
  end
end
