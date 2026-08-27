defmodule CodexPooler.Alerts.Delivery.EmailDeliveryTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Alerts.Delivery.EmailDelivery
  alias CodexPooler.Alerts.Schemas.AlertDeliveryAttempt
  alias CodexPooler.Mailer
  alias CodexPooler.Repo

  defmodule TLSFailureAdapter do
    @behaviour Swoosh.Adapter

    @impl true
    def validate_config(_config), do: :ok

    @impl true
    def deliver(_email, _config) do
      {:error, {:retries_exceeded, {:temporary_failure, ~c"smtp.example.com", :tls_failed}}}
    end
  end

  setup do
    mailer_config = Application.get_env(:codex_pooler, Mailer)
    Application.put_env(:codex_pooler, Mailer, adapter: TLSFailureAdapter)

    on_exit(fn -> restore_env(:codex_pooler, Mailer, mailer_config) end)
  end

  test "TLS delivery failures keep their retryable alert-delivery behavior" do
    pool = pool_fixture(%{slug: "smtp-tls-retry-#{System.unique_integer([:positive])}"})
    channel = alert_channel_fixture(email_to: "alerts@example.com")
    incident = alert_incident_fixture(pool: pool)
    now = ~U[2026-08-27 18:15:00Z]

    assert {:error,
            %{
              code: "smtp_test_email_tls_failed",
              retryable: true,
              attempt_id: attempt_id
            }} = EmailDelivery.deliver_incident_to_channel(incident.id, channel.id, 1, now: now)

    attempt = Repo.get!(AlertDeliveryAttempt, attempt_id)
    assert attempt.status == AlertDeliveryAttempt.retryable_status()
    assert attempt.retryable
    assert attempt.failure_code == "smtp_test_email_tls_failed"

    assert attempt.failure_message ==
             "SMTP TLS handshake failed; verify SSL/TLS mode and certificate settings"

    assert DateTime.compare(attempt.next_retry_at, DateTime.add(now, 60, :second)) == :eq
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
