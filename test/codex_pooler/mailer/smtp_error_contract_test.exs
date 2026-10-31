defmodule CodexPooler.Mailer.SmtpErrorContractTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Mailer
  alias CodexPooler.Mailer.Config

  test "test-email delivery exposes missing STARTTLS through the real mailer" do
    {port, monitor, receipt} = start_smtp!(:no_capabilities)
    {:ok, config} = Config.from_settings(settings(port, %{tls: "always"}))

    assert Mailer.send_smtp_test_email("recipient@example.com", config, "en") ==
             {:error, %{code: :smtp_test_email_tls_unavailable, message: "SMTP server does not support the requested TLS mode"}}

    assert_server_closed(monitor, receipt)
  end

  test "test-email delivery classifies a malformed multiline reply through Swoosh" do
    {port, monitor, receipt} = start_smtp!(:malformed)
    {:ok, config} = Config.from_settings(settings(port))

    assert Mailer.send_smtp_test_email("recipient@example.com", config, "en") ==
             {:error, %{code: :smtp_test_email_unexpected_response, message: "SMTP server returned an unexpected response"}}

    assert_server_closed(monitor, receipt)
  end

  test "credential probe classifies missing AUTH using real gen_smtp" do
    {port, monitor, receipt} = start_smtp!(:no_capabilities)
    {:ok, options} = Config.probe_options(settings(port, %{username: "synthetic", password: "synthetic"}))
    assert options[:auth] == :always

    assert Mailer.probe(options) ==
             {:error, %{code: :smtp_probe_auth_unavailable, message: "SMTP server does not support the requested authentication flow"}}

    assert_server_closed(monitor, receipt)
  end

  test "probe classifies missing TLS and malformed replies" do
    for {mode, overrides, code, message} <- [
          {:no_capabilities, %{tls: "always"}, :smtp_probe_tls_unavailable, "SMTP server does not support the requested TLS mode"},
          {:malformed, %{}, :smtp_probe_unexpected_response, "SMTP server returned an unexpected response"}
        ] do
      {port, monitor, receipt} = start_smtp!(mode)
      {:ok, options} = Config.probe_options(settings(port, overrides))
      assert Mailer.probe(options) == {:error, %{code: code, message: message}}
      assert_server_closed(monitor, receipt)
    end
  end

  defp settings(port, overrides \\ %{}) do
    Map.merge(%{enabled: true, host: "127.0.0.1", port: port, username: nil, password: nil, from: "sender@example.com", ssl: false, tls: "never", retries: 0}, overrides)
  end

  defp start_smtp!(mode) do
    parent = self()
    receipt = make_ref()

    pid =
      start_supervised!(%{
        id: receipt,
        start: {Task, :start_link, [fn -> serve(parent, receipt, mode) end]},
        restart: :temporary
      })

    monitor = Process.monitor(pid)
    assert_receive {:smtp_ready, ^receipt, port}, 10_000
    {port, monitor, receipt}
  end

  defp serve(parent, receipt, mode) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: :line, active: false, ip: {127, 0, 0, 1}])

    try do
      {:ok, {_ip, port}} = :inet.sockname(listener)
      send(parent, {:smtp_ready, receipt, port})
      {:ok, socket} = :gen_tcp.accept(listener, 10_000)

      try do
        :ok = :gen_tcp.send(socket, "220 localhost ready\r\n")
        {:ok, "EHLO " <> _hostname} = :gen_tcp.recv(socket, 0, 10_000)
        reply = if mode == :malformed, do: "250-untrusted relay detail\r\n500 mismatched reply\r\n", else: "250 localhost\r\n"
        :ok = :gen_tcp.send(socket, reply)
        {:ok, "QUIT\r\n"} = :gen_tcp.recv(socket, 0, 10_000)
      after
        :gen_tcp.close(socket)
      end
    after
      :gen_tcp.close(listener)
    end

    send(parent, {:smtp_closed, receipt})
  end

  defp assert_server_closed(monitor, receipt) do
    assert_receive {:smtp_closed, ^receipt}, 10_000
    assert_receive {:DOWN, ^monitor, :process, _pid, :normal}, 10_000
  end
end
