defmodule CodexPooler.Gateway.Transports.PinnedUploadTest do
  use ExUnit.Case, async: false

  alias CodexPooler.Files.UploadUrlPolicy
  alias CodexPooler.Gateway.Transports.PinnedUpload
  alias CodexPooler.Platform.OutboundHTTP

  setup_all do
    certificate =
      :public_key.pkix_test_data(%{
        root: [digest: :sha256, key: {:rsa, 2048, 65_537}],
        peer: [digest: :sha256, key: {:rsa, 2048, 65_537}, extensions: [{:Extension, {2, 5, 29, 17}, false, [{:dNSName, ~c"upload.example"}]}]]
      })

    %{certificate: certificate}
  end

  setup do
    CodexPooler.TestAppEnv.restore_on_exit(OutboundHTTP)
    configure_proxy([], [])
    %{supervisor: start_supervised!(Task.Supervisor)}
  end

  test "direct TLS pins the socket, retains Host/SNI/path/query, streams bytes and discards response bytes", context do
    children = DynamicSupervisor.count_children(Req.FinchSupervisor)

    for _attempt <- 1..3 do
      {port, server} = start_tls_server(context)
      request = upload_request(port)

      assert {^request, %Req.Response{status: 201, body: "", headers: %{"x-upload-status" => ["stored"]}}} =
               PinnedUpload.run(request, {127, 0, 0, 1}, 5_000, transport_opts: [cacerts: context.certificate[:cacerts]])

      assert_receive {:tls_identity, ~c"upload.example"}
      assert_receive {:upload_received, method, host, bytes, proxy_auth}
      assert method == "PUT /object?signature=synthetic HTTP/1.1"
      assert host == "upload.example:#{port}"
      assert bytes == 6
      assert proxy_auth == nil
      assert :closed = Task.await(server, 5_000)
    end

    assert DynamicSupervisor.count_children(Req.FinchSupervisor) == children
  end

  test "real CONNECT relay receives literal address and only proxy receives proxy authorization", context do
    {port, server} = start_tls_server(context)
    {proxy_port, proxy} = start_proxy(context, port)
    authorization = "Basic " <> Base.encode64("synthetic:credential")
    configure_proxy([proxy: {:http, "127.0.0.1", proxy_port, []}, proxy_headers: [{"proxy-authorization", authorization}]], [])
    request = upload_request(port)

    assert {^request, %Req.Response{status: 201}} =
             PinnedUpload.run(request, {127, 0, 0, 1}, 5_000, transport_opts: [cacerts: context.certificate[:cacerts]])

    assert_receive {:connect_received, target, headers}
    assert target == "CONNECT 127.0.0.1:#{port} HTTP/1.1"
    assert headers["host"] == "127.0.0.1:#{port}"
    assert headers["proxy-authorization"] == authorization
    assert_receive {:tls_identity, ~c"upload.example"}
    assert_receive {:upload_received, _, host, 6, nil}
    assert host == "upload.example:#{port}"
    assert :closed = Task.await(server, 5_000)
    assert :closed = Task.await(proxy, 5_000)
  end

  test "a validated DNS answer stays pinned after the resolver changes", context do
    {port, server} = start_tls_server(context)
    {proxy_port, proxy} = start_proxy(context, port)
    configure_proxy([proxy: {:http, "127.0.0.1", proxy_port, []}], [])
    request = upload_request(port)
    owner = self()

    resolver = fn host, family ->
      send(owner, {:dns_lookup, host, family})
      if family == :inet, do: {:ok, [{93, 184, 216, 34}]}, else: {:error, :nxdomain}
    end

    assert {:ok, target} = UploadUrlPolicy.resolve(URI.to_string(request.url), resolver)
    assert_received {:dns_lookup, ~c"upload.example", :inet}
    assert_received {:dns_lookup, ~c"upload.example", :inet6}
    CodexPooler.TestAppEnv.restore_on_exit(UploadUrlPolicy)

    Application.put_env(:codex_pooler, UploadUrlPolicy,
      resolver: fn _, _ ->
        send(owner, :rebound_lookup)
        {:ok, [{127, 0, 0, 1}]}
      end
    )

    assert {^request, %Req.Response{status: 201}} = PinnedUpload.run(request, target.address, 5_000, transport_opts: [cacerts: context.certificate[:cacerts]])
    assert_receive {:connect_received, authority, _headers}
    assert authority == "CONNECT 93.184.216.34:#{port} HTTP/1.1"
    assert_receive {:tls_identity, ~c"upload.example"}
    assert :closed = Task.await(server, 5_000)
    assert :closed = Task.await(proxy, 5_000)
    refute_received :rebound_lookup
  end

  test "CONNECT brackets a pinned IPv6 literal without asking the proxy to resolve the hostname", context do
    {proxy_port, proxy} = start_proxy(context, :reject)
    configure_proxy([proxy: {:http, "127.0.0.1", proxy_port, []}], [])
    request = upload_request(443)
    assert {^request, %Mint.HTTPError{reason: {:proxy, {:unexpected_status, 502}}}} = PinnedUpload.run(request, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}, 5_000)
    assert_receive {:connect_received, "CONNECT [2001:db8::1]:443 HTTP/1.1", headers}
    assert headers["host"] == "[2001:db8::1]:443"
    assert :closed = Task.await(proxy, 5_000)
  end

  test "no_proxy matches original hostname even when socket destination is pinned", context do
    {port, server} = start_tls_server(context)
    configure_proxy([proxy: {:http, "unresolvable.invalid", 1, []}], ["upload.example"])
    request = upload_request(port)
    assert {^request, %Req.Response{status: 201}} = PinnedUpload.run(request, {127, 0, 0, 1}, 5_000, transport_opts: [cacerts: context.certificate[:cacerts]])
    assert :closed = Task.await(server, 5_000)
  end

  test "trusted certificate for another hostname is rejected before upload", context do
    {port, server} = start_tls_server(context, :handshake_failure)
    request = %{upload_request(port) | url: URI.parse("https://wrong.example:#{port}/object")}
    assert {^request, %Req.TransportError{reason: {:tls_alert, _}}} = PinnedUpload.run(request, {127, 0, 0, 1}, 5_000, transport_opts: [cacerts: context.certificate[:cacerts]])
    assert :rejected = Task.await(server, 5_000)
    refute_received {:upload_received, _, _, _, _}
  end

  test "absolute response deadline closes the upload socket", context do
    {port, server} = start_tls_server(context, :hold)
    request = upload_request(port)
    assert {^request, %Req.TransportError{reason: :timeout}} = PinnedUpload.run(request, {127, 0, 0, 1}, 500, transport_opts: [cacerts: context.certificate[:cacerts]])
    assert_receive {:upload_received, _, _, 6, nil}
    assert :closed = Task.await(server, 5_000)
  end

  test "killing upload owner closes held socket", context do
    {port, server} = start_tls_server(context, :hold)
    request = upload_request(port)
    upload = Task.Supervisor.async_nolink(context.supervisor, fn -> PinnedUpload.run(request, {127, 0, 0, 1}, 10_000, transport_opts: [cacerts: context.certificate[:cacerts]]) end)
    assert_receive {:upload_received, _, _, 6, nil}
    assert nil == Task.shutdown(upload, :brutal_kill)
    assert :closed = Task.await(server, 5_000)
  end

  test "Req module adapter uses private validated destination with no function adapter warning", context do
    {listener, port} = listener()

    server =
      Task.Supervisor.async_nolink(context.supervisor, fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5_000)

        try do
          {_line, _headers, _body} = receive_headers(:gen_tcp, socket)
          :ok = :gen_tcp.send(socket, "HTTP/1.1 204 No Content\r\n\r\n")
          assert {:error, :closed} = :gen_tcp.recv(socket, 0, 5_000)
        after
          :gen_tcp.close(socket)
          :gen_tcp.close(listener)
        end
      end)

    request =
      Req.new(method: :put, url: "http://upload.example:#{port}/object", body: "", headers: [{"content-length", "0"}], retry: false, redirect: false, raw: true, adapter: PinnedUpload)
      |> Req.Request.put_private(:codex_pooler_pinned_upload, {{127, 0, 0, 1}, 5_000})

    assert ExUnit.CaptureIO.capture_io(:stderr, fn -> assert {:ok, %Req.Response{status: 204}} = Req.request(request) end) == ""
    assert {:error, :closed} = Task.await(server, 5_000)
  end

  defp upload_request(port) do
    Req.new(method: :put, url: "https://upload.example:#{port}/object?signature=synthetic", body: Stream.map(["abc", "def"], & &1), headers: [{"content-length", "6"}], retry: false, redirect: false)
  end

  defp configure_proxy(proxy, no_proxy) do
    Application.put_env(:codex_pooler, OutboundHTTP, proxy_config: %{http: [], https: proxy, no_proxy: no_proxy})
  end

  defp listener do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, {_, port}} = :inet.sockname(listener)
    {listener, port}
  end

  defp start_tls_server(context, behavior \\ :respond) do
    {listener, port} = listener()
    parent = self()

    task =
      Task.Supervisor.async_nolink(context.supervisor, fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5_000)

        try do
          options = [cert: context.certificate[:cert], key: context.certificate[:key], active: false, mode: :binary]

          case :ssl.handshake(socket, options, 5_000) do
            {:ok, tls} ->
              try do
                {:ok, info} = :ssl.connection_information(tls, [:sni_hostname])
                send(parent, {:tls_identity, info[:sni_hostname]})
                {line, headers, body} = receive_headers(:ssl, tls)
                bytes = receive_body(tls, body, String.to_integer(headers["content-length"]))
                send(parent, {:upload_received, line, headers["host"], bytes, headers["proxy-authorization"]})
                if behavior == :respond, do: :ok = :ssl.send(tls, "HTTP/1.1 201 Created\r\nx-upload-status: stored\r\ncontent-length: 7\r\n\r\ndiscard")
                assert {:error, :closed} = :ssl.recv(tls, 0, 5_000)
                :closed
              after
                :ssl.close(tls)
              end

            {:error, _reason} ->
              assert behavior == :handshake_failure
              :rejected
          end
        after
          :gen_tcp.close(socket)
          :gen_tcp.close(listener)
        end
      end)

    {port, task}
  end

  defp receive_body(_socket, buffer, length) when byte_size(buffer) == length, do: length

  defp receive_body(socket, buffer, length) do
    {:ok, chunk} = :ssl.recv(socket, 0, 5_000)
    receive_body(socket, buffer <> chunk, length)
  end

  defp start_proxy(context, upstream_port) do
    {listener, port} = listener()
    parent = self()

    task =
      Task.Supervisor.async_nolink(context.supervisor, fn ->
        {:ok, downstream} = :gen_tcp.accept(listener, 5_000)

        try do
          {line, headers, ""} = receive_headers(:gen_tcp, downstream)
          send(parent, {:connect_received, line, headers})

          if upstream_port == :reject do
            :ok = :gen_tcp.send(downstream, "HTTP/1.1 502 Bad Gateway\r\ncontent-length: 0\r\n\r\n")
            assert {:error, :closed} = :gen_tcp.recv(downstream, 0, 5_000)
            :closed
          else
            {:ok, upstream} = :gen_tcp.connect({127, 0, 0, 1}, upstream_port, [:binary, active: false], 5_000)

            try do
              :ok = :gen_tcp.send(downstream, "HTTP/1.1 200 Connection Established\r\n\r\n")
              :ok = :inet.setopts(downstream, active: true)
              :ok = :inet.setopts(upstream, active: true)
              relay(downstream, upstream)
            after
              :gen_tcp.close(upstream)
            end
          end
        after
          :gen_tcp.close(downstream)
          :gen_tcp.close(listener)
        end
      end)

    {port, task}
  end

  defp relay(downstream, upstream) do
    receive do
      {:tcp, ^downstream, data} ->
        :ok = :gen_tcp.send(upstream, data)
        relay(downstream, upstream)

      {:tcp, ^upstream, data} ->
        :ok = :gen_tcp.send(downstream, data)
        relay(downstream, upstream)

      {:tcp_closed, socket} when socket in [downstream, upstream] ->
        :closed
    after
      5_000 -> flunk("proxy tunnel remained open")
    end
  end

  defp receive_headers(transport, socket, buffer \\ "") do
    case String.split(buffer, "\r\n\r\n", parts: 2) do
      [head, body] ->
        [line | headers] = String.split(head, "\r\n")

        headers =
          Map.new(headers, fn header ->
            [name, value] = String.split(header, ":", parts: 2)
            {String.downcase(name), String.trim(value)}
          end)

        {line, headers, body}

      [_incomplete] ->
        {:ok, chunk} = transport.recv(socket, 0, 5_000)
        receive_headers(transport, socket, buffer <> chunk)
    end
  end
end
