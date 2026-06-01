defmodule CodexPooler.MailerTest do
  use CodexPooler.DataCase, async: false

  import Swoosh.TestAssertions

  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.Settings
  alias CodexPooler.Mailer
  alias CodexPooler.Repo

  setup do
    mailer_config = Application.get_env(:codex_pooler, Mailer)
    swoosh_local = Application.get_env(:swoosh, :local)

    Repo.delete_all(Settings)
    InstanceSettings.reset_cache_for_test()

    on_exit(fn ->
      restore_env(:codex_pooler, Mailer, mailer_config)
      restore_env(:swoosh, :local, swoosh_local)
      Repo.delete_all(Settings)
      InstanceSettings.reset_cache_for_test()
    end)

    :ok
  end

  test "reports delivery unavailable without a mailer adapter" do
    Application.put_env(:codex_pooler, Mailer, [])

    refute Mailer.configured?()
  end

  test "reports delivery unavailable when the local mailbox is disabled" do
    Application.put_env(:codex_pooler, Mailer, adapter: Swoosh.Adapters.Local)
    Application.put_env(:swoosh, :local, false)

    refute Mailer.configured?()
  end

  test "reports delivery available for SMTP" do
    Application.put_env(:codex_pooler, Mailer, adapter: Swoosh.Adapters.SMTP)

    assert Mailer.configured?()
  end

  test "uses instance settings SMTP overrides at delivery time without restart" do
    Application.put_env(:codex_pooler, Mailer,
      adapter: Swoosh.Adapters.Test,
      use_instance_settings?: true
    )

    server_name = unique_server_name()
    port = free_port()

    start_smtp_server!(server_name, port)

    settings = InstanceSettings.ensure_singleton!()

    attrs =
      %{
        "smtp" => %{
          "enabled" => true,
          "host" => "localhost",
          "port" => port,
          "username" => "username",
          "from" => "instance-sender@example.com",
          "ssl" => false,
          "tls" => "never",
          "retries" => 2
        }
      }
      |> InstanceSettings.put_smtp_password("PaSSw0rd")

    assert {:ok, _updated} = InstanceSettings.update(settings, attrs)
    assert Mailer.configured?()
    assert Mailer.default_sender() == {"Codex Pooler", "instance-sender@example.com"}

    email =
      Swoosh.Email.new()
      |> Swoosh.Email.from(Mailer.default_sender())
      |> Swoosh.Email.to("recipient@example.com")
      |> Swoosh.Email.subject("Runtime SMTP")
      |> Swoosh.Email.text_body("runtime override works")

    assert {:ok, _receipt} = Mailer.deliver(email)
  end

  test "send_smtp_test_email/2 composes the deterministic subject and body" do
    assert {:ok, %{code: :smtp_test_email_sent}} =
             Mailer.send_smtp_test_email("recipient@example.com", %{
               from: "instance-sender@example.com",
               adapter_config: [adapter: Swoosh.Adapters.Test]
             })

    assert_email_sent(
      from: {"Codex Pooler", "instance-sender@example.com"},
      to: "recipient@example.com",
      subject: "Codex Pooler SMTP test email",
      text_body:
        "This test email confirms Codex Pooler can send email with the current SMTP settings."
    )
  end

  test "send_smtp_test_email/2 sanitizes SMTP delivery failures" do
    port = start_closing_tcp_server!()

    assert {:error, %{code: :smtp_test_email_connection_failed, message: message} = error} =
             Mailer.send_smtp_test_email("recipient@example.com", %{
               from: "instance-sender@example.com",
               adapter_config: [
                 adapter: Swoosh.Adapters.SMTP,
                 relay: "127.0.0.1",
                 port: port,
                 username: "username",
                 password: "wrong-password",
                 ssl: false,
                 tls: :never,
                 retries: 0
               ]
             })

    assert message == "SMTP connection failed"
    refute inspect(error) =~ "wrong-password"
  end

  defp start_smtp_server!(server_name, port) do
    assert {:ok, _pid} =
             :gen_smtp_server.start(server_name, :smtp_server_example, [
               {:port, port},
               {:sessionoptions, [{:callbackoptions, [{:auth, true}]}]}
             ])

    on_exit(fn ->
      :ok = :gen_smtp_server.stop(server_name)
    end)
  end

  defp start_closing_tcp_server! do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    test_pid = self()

    pid =
      spawn_link(fn ->
        send(test_pid, {:closing_tcp_server_ready, self()})

        with {:ok, socket} <- :gen_tcp.accept(listener) do
          :gen_tcp.close(socket)
        end

        :gen_tcp.close(listener)
      end)

    assert_receive {:closing_tcp_server_ready, ^pid}

    on_exit(fn ->
      Process.exit(pid, :shutdown)
      :gen_tcp.close(listener)
    end)

    port
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp unique_server_name do
    String.to_atom("codex_pooler_smtp_test_#{System.unique_integer([:positive])}")
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
