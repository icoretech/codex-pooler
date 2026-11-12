defmodule CodexPooler.Mailer.ConfigTest do
  use ExUnit.Case, async: true

  alias CodexPooler.InstanceSettings.Settings
  alias CodexPooler.Mailer.Config, as: MailerConfig

  describe "from_settings/1" do
    test "returns nil when SMTP is disabled" do
      assert MailerConfig.from_settings(%{enabled: false}) == {:ok, nil}
    end

    test "probe options preserve the disabled SMTP return shape" do
      assert MailerConfig.probe_options(%{enabled: false}) == {:ok, nil}
    end

    test "builds SMTP config from typed instance settings" do
      smtp_settings = %{
        enabled: true,
        host: "smtp.example.com",
        port: 2525,
        username: "mailer",
        password: "secret-password",
        from: "sender@example.com",
        ssl: false,
        tls: "never",
        retries: 4
      }

      assert {:ok, %{adapter_config: config, from: from}} =
               MailerConfig.from_settings(smtp_settings)

      assert config[:adapter] == Swoosh.Adapters.SMTP
      assert config[:relay] == "smtp.example.com"
      assert config[:port] == 2525
      assert config[:username] == "mailer"
      assert config[:password] == "secret-password"
      assert config[:ssl] == false
      assert config[:tls] == :never
      assert config[:retries] == 4
      assert from == "sender@example.com"
    end

    test "adds verified STARTTLS options derived from the relay host" do
      assert {:ok, %{adapter_config: config}} =
               MailerConfig.from_settings(%{
                 enabled: true,
                 host: "smtp.example.com",
                 port: 587,
                 username: nil,
                 password: nil,
                 from: "sender@example.com",
                 ssl: false,
                 tls: "always",
                 retries: 2
               })

      assert_secure_tls_options(config[:tls_options], "smtp.example.com")
      refute Keyword.has_key?(config, :sockopts)
    end

    test "adds verified socket options for implicit TLS" do
      assert {:ok, %{adapter_config: config}} =
               MailerConfig.from_settings(%{
                 enabled: true,
                 host: "smtp.example.com",
                 port: 465,
                 username: nil,
                 password: nil,
                 from: "sender@example.com",
                 ssl: true,
                 tls: "never",
                 retries: 2
               })

      assert_secure_tls_options(config[:sockopts], "smtp.example.com")
      refute Keyword.has_key?(config, :tls_options)
    end

    test "implicit TLS disables STARTTLS for every accepted requested mode" do
      for tls <- ["always", "if_available", "never", :always, :if_available, :never] do
        assert {:ok, %{adapter_config: config}} = MailerConfig.from_settings(smtp_settings(%{ssl: true, tls: tls}))
        assert config[:tls] == :never
        assert_secure_tls_options(config[:sockopts], "smtp.example.com")
        refute Keyword.has_key?(config, :tls_options)
      end
    end

    test "existing typed settings with implicit TLS and required STARTTLS remain usable" do
      changeset = Settings.changeset(Settings.default(), %{smtp: smtp_settings(%{ssl: true, tls: "always", retries: 2})})
      assert changeset.valid?
      settings = Ecto.Changeset.apply_changes(changeset)
      assert settings.smtp.tls == "always"
      assert {:ok, %{adapter_config: config}} = MailerConfig.from_settings(settings)
      assert config[:tls] == :never
      assert_secure_tls_options(config[:sockopts], "smtp.example.com")
    end

    test "implicit TLS still rejects an invalid requested STARTTLS mode" do
      assert {:error, %{code: :invalid_mailer_config}} = MailerConfig.from_settings(smtp_settings(%{ssl: true, tls: "invalid"}))
    end

    test "plain connections preserve every accepted STARTTLS mode" do
      for tls <- [:always, :if_available, :never], requested <- [tls, Atom.to_string(tls)] do
        assert {:ok, %{adapter_config: config}} = MailerConfig.from_settings(smtp_settings(%{tls: requested}))
        assert config[:tls] == tls
        refute Keyword.has_key?(config, :sockopts)

        if tls == :never do
          refute Keyword.has_key?(config, :tls_options)
        else
          assert_secure_tls_options(config[:tls_options], "smtp.example.com")
        end
      end
    end

    test "requires a password when username-based auth is configured" do
      assert {:error, %{code: :invalid_mailer_config, message: message}} =
               MailerConfig.from_settings(%{
                 enabled: true,
                 host: "smtp.example.com",
                 port: 587,
                 username: "mailer",
                 password: nil,
                 from: "sender@example.com",
                 ssl: false,
                 tls: "if_available",
                 retries: 2
               })

      assert message == "SMTP password must be present when SMTP username is set"
    end

    test "hydrates encrypted SMTP password from typed instance settings" do
      password = "config-test-password"

      settings =
        Settings.default()
        |> Settings.changeset(%{
          "smtp" => %{
            "enabled" => true,
            "host" => "smtp.example.com",
            "port" => 2525,
            "username" => "mailer",
            "from" => "sender@example.com",
            "ssl" => false,
            "tls" => "never",
            "retries" => 4,
            "password" => password,
            "password_action" => "set"
          }
        })
        |> Ecto.Changeset.apply_changes()

      assert {:ok, %{adapter_config: config}} = MailerConfig.from_settings(settings)
      assert config[:password] == password
    end

    test "hydrates an SMTP password with outer spaces unchanged" do
      password = " spaced password "

      settings =
        Settings.default()
        |> Settings.changeset(%{
          "smtp" => %{"enabled" => true, "host" => "smtp.example.com", "port" => 2525, "username" => "mailer", "from" => "sender@example.com", "ssl" => false, "tls" => "never", "retries" => 0, "password" => password, "password_action" => "set"}
        })
        |> Ecto.Changeset.apply_changes()

      assert {:ok, %{adapter_config: config}} = MailerConfig.from_settings(settings)
      assert config[:password] == password
      assert config[:retries] == 0
    end

    test "probe options cap retries and add a timeout" do
      assert {:ok, options} =
               MailerConfig.probe_options(%{
                 enabled: true,
                 host: "smtp.example.com",
                 port: 587,
                 username: nil,
                 password: nil,
                 from: "sender@example.com",
                 ssl: false,
                 tls: "if_available",
                 retries: 8
               })

      assert options[:timeout] == 5_000
      assert options[:retries] == 0
      assert options[:relay] == "smtp.example.com"
    end
  end

  describe "sanitize_probe_error/1" do
    test "redacts auth failures and network failures" do
      assert %{code: :smtp_probe_auth_failed, message: "SMTP authentication failed"} =
               MailerConfig.sanitize_probe_error({:error, {:permanent_failure, :auth_failed}})

      assert %{code: :smtp_probe_connection_failed, message: "SMTP connection failed"} =
               MailerConfig.sanitize_probe_error({:error, {:network_failure, {:error, :econnrefused}}})
    end

    test "classifies nested timeout and delivery-status failures" do
      assert %{code: :smtp_probe_timeout, message: "SMTP probe timed out"} =
               MailerConfig.sanitize_probe_error({:error, :no_more_hosts, {:network_failure, "smtp.example.com", {:error, :timeout}}})

      assert %{
               code: :smtp_probe_temporary_failure,
               message: "SMTP server temporarily rejected the probe"
             } =
               MailerConfig.sanitize_probe_error({:error, {:smtp, {:temporary_failure, "smtp.example.com", "451 try later"}}})

      assert %{code: :smtp_probe_rejected, message: "SMTP server rejected the probe"} =
               MailerConfig.sanitize_probe_error({:error, {:smtp, {:permanent_failure, "smtp.example.com", "550 rejected"}}})
    end

    test "classifies nested TLS handshake failures before temporary and network failures" do
      for reason <- tls_failure_reasons() do
        assert %{
                 code: :smtp_probe_tls_failed,
                 message: "SMTP TLS handshake failed; verify SSL/TLS mode and certificate settings"
               } = MailerConfig.sanitize_probe_error(reason)
      end
    end
  end

  describe "sanitize_delivery_error/1" do
    test "redacts auth failures and network failures" do
      assert %{code: :smtp_test_email_auth_failed, message: "SMTP authentication failed"} =
               MailerConfig.sanitize_delivery_error({:error, {:permanent_failure, :auth_failed}})

      assert %{code: :smtp_test_email_connection_failed, message: "SMTP connection failed"} =
               MailerConfig.sanitize_delivery_error({:error, {:network_failure, {:error, :econnrefused}}})
    end

    test "classifies nested TLS handshake failures before temporary and network failures" do
      for reason <- tls_failure_reasons() do
        assert %{
                 code: :smtp_test_email_tls_failed,
                 message: "SMTP TLS handshake failed; verify SSL/TLS mode and certificate settings"
               } = MailerConfig.sanitize_delivery_error(reason)
      end
    end
  end

  describe "SMTP session error envelopes" do
    test "classifies capability and reply errors without exposing relay or response details" do
      cases = [
        {{:missing_requirement, "smtp.example.com", :tls}, :smtp_test_email_tls_unavailable, :smtp_probe_tls_unavailable, "SMTP server does not support the requested TLS mode"},
        {{:missing_requirement, ~c"smtp.example.com", :auth}, :smtp_test_email_auth_unavailable, :smtp_probe_auth_unavailable, "SMTP server does not support the requested authentication flow"},
        {{:unexpected_response, "smtp.example.com", ["250-untrusted relay detail", "500 mismatched reply"]}, :smtp_test_email_unexpected_response, :smtp_probe_unexpected_response, "SMTP server returned an unexpected response"},
        {{:unexpected_response, ~c"smtp.example.com", "malformed relay detail"}, :smtp_test_email_unexpected_response, :smtp_probe_unexpected_response, "SMTP server returned an unexpected response"}
      ]

      for {failure, delivery_code, probe_code, message} <- cases,
          reason <- smtp_error_envelopes(failure) do
        assert MailerConfig.sanitize_delivery_error(reason) == %{code: delivery_code, message: message}
        assert MailerConfig.sanitize_probe_error(reason) == %{code: probe_code, message: message}
      end
    end

    test "unknown or malformed envelopes do not promote embedded capability and reply markers" do
      for reason <- [
            {:unknown, {:missing_requirement, "smtp.example.com", :tls}},
            {:error, :unknown, {:missing_requirement, "smtp.example.com", :auth}},
            {:error, {:unknown, {:unexpected_response, "smtp.example.com", "reply"}}},
            {:retries_exceeded, {:missing_requirement, "smtp.example.com", :unknown}},
            {:retries_exceeded, {:unexpected_response, "smtp.example.com", %{detail: "reply"}}},
            {:retries_exceeded, {:missing_requirement, nil, :tls}},
            {:retries_exceeded, {:retries_exceeded, {:missing_requirement, "smtp.example.com", :tls}}},
            [{:missing_requirement, "smtp.example.com", :tls}],
            nil
          ] do
        assert MailerConfig.sanitize_delivery_error(reason) == %{code: :smtp_test_email_failed, message: "SMTP test email failed"}
        assert MailerConfig.sanitize_probe_error(reason) == %{code: :smtp_probe_failed, message: "SMTP probe failed"}
      end
    end

    test "existing failure priorities survive real native and Swoosh envelopes" do
      cases = [
        {{:permanent_failure, "smtp.example.com", :auth_failed}, :smtp_test_email_auth_failed, :smtp_probe_auth_failed},
        {{:temporary_failure, "smtp.example.com", :tls_failed}, :smtp_test_email_tls_failed, :smtp_probe_tls_failed},
        {{:network_failure, "smtp.example.com", {:error, :timeout}}, :smtp_test_email_timeout, :smtp_probe_timeout},
        {{:network_failure, "smtp.example.com", {:error, :econnrefused}}, :smtp_test_email_connection_failed, :smtp_probe_connection_failed},
        {{:temporary_failure, "smtp.example.com", "451 rejected"}, :smtp_test_email_temporary_failure, :smtp_probe_temporary_failure},
        {{:permanent_failure, "smtp.example.com", "550 rejected"}, :smtp_test_email_rejected, :smtp_probe_rejected}
      ]

      for {failure, delivery_code, probe_code} <- cases,
          reason <- smtp_error_envelopes(failure) do
        assert MailerConfig.sanitize_delivery_error(reason).code == delivery_code
        assert MailerConfig.sanitize_probe_error(reason).code == probe_code
      end
    end
  end

  defp smtp_error_envelopes(failure) do
    [failure, {:error, failure}] ++
      for outer <- [:retries_exceeded, :no_more_hosts],
          reason <- [{outer, failure}, {:error, {outer, failure}}, {:error, outer, failure}],
          do: reason
  end

  defp smtp_settings(overrides) do
    Map.merge(%{enabled: true, host: "smtp.example.com", port: 465, username: nil, password: nil, from: "sender@example.com", ssl: false, tls: "always", retries: 0}, overrides)
  end

  defp assert_secure_tls_options(options, host) do
    assert options[:versions] == [:"tlsv1.2", :"tlsv1.3"]
    assert options[:verify] == :verify_peer
    assert options[:cacerts] == :public_key.cacerts_get()
    assert options[:server_name_indication] == String.to_charlist(host)
    assert options[:depth] == 99

    match_fun = get_in(options, [:customize_hostname_check, :match_fun])
    assert is_function(match_fun, 2)
  end

  defp tls_failure_reasons do
    [
      {:error, :retries_exceeded, {:temporary_failure, "smtp.example.com", :tls_failed}},
      {:error, :no_more_hosts, {:temporary_failure, "smtp.example.com", :tls_failed}},
      {:error, {:retries_exceeded, {:temporary_failure, ~c"smtp.example.com", :tls_failed}}},
      {:error, {:network_failure, {:error, :tls_failed}}},
      {:error, :retries_exceeded, {:network_failure, "smtp.example.com", {:error, {:tls_alert, {:unexpected_message, ~c"TLS client received plaintext"}}}}},
      {:error, {:retries_exceeded, {:network_failure, ~c"smtp.example.com", {:error, {:tls_alert, {:unexpected_message, ~c"TLS client received plaintext"}}}}}}
    ]
  end
end
