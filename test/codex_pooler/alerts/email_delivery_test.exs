defmodule CodexPooler.Alerts.Delivery.EmailDeliveryTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures
  import Swoosh.TestAssertions

  alias CodexPooler.Alerts.Delivery.AttemptLifecycle
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

  defmodule ExceptionAdapter do
    @behaviour Swoosh.Adapter

    @impl true
    def validate_config(_config), do: :ok

    @impl true
    def deliver(_email, _config), do: raise(ArgumentError, "synthetic sensitive adapter detail")
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

  test "later notification retries use their own retry budget" do
    pool = pool_fixture()
    channel = alert_channel_fixture()
    incident = alert_incident_fixture(pool: pool)
    now = DateTime.utc_now()

    for number <- 1..5 do
      assert {:ok, _} =
               AttemptLifecycle.insert_sent_attempt(
                 incident,
                 channel,
                 number,
                 DateTime.add(now, -3600, :second),
                 %{}
               )
    end

    assert {:error, %{retryable: true}} =
             EmailDelivery.deliver_incident_to_channel(incident.id, channel.id, 6, retry_attempt: 1)

    id =
      Repo.one!(
        from attempt in AlertDeliveryAttempt,
          where: attempt.incident_id == ^incident.id and attempt.attempt_number == 6,
          select: attempt.id
      )

    attempt = Repo.get!(AlertDeliveryAttempt, id)
    assert attempt.attempt_number == 6
    assert attempt.max_attempts == 5
    assert DateTime.diff(attempt.next_retry_at, attempt.completed_at, :second) == 60
    assert {:ok, _} = EmailDelivery.deliver_incident_to_channel(incident.id, channel.id, 7, retry_attempt: 5)

    terminal =
      Repo.one!(
        from row in AlertDeliveryAttempt,
          where: row.incident_id == ^incident.id and row.attempt_number == 7
      )

    assert terminal.status == "failed"
    refute terminal.retryable
    assert terminal.next_retry_at == nil
  end

  test "sixth successful notification keeps its receipt" do
    Application.put_env(:codex_pooler, Mailer, adapter: Swoosh.Adapters.Test)
    pool = pool_fixture()
    channel = alert_channel_fixture()
    incident = alert_incident_fixture(pool: pool)
    now = ~U[2026-09-07 12:00:00.000000Z]

    for number <- 1..5 do
      assert {:ok, _} =
               AttemptLifecycle.insert_sent_attempt(
                 incident,
                 channel,
                 number,
                 DateTime.add(now, -3600, :second),
                 %{}
               )
    end

    assert {:ok, attempt} =
             EmailDelivery.deliver_incident_to_channel(incident.id, channel.id, 6,
               now: now,
               retry_attempt: 1
             )

    assert attempt.status == "sent"
    assert attempt.attempt_number == 6
    assert Repo.get!(AlertDeliveryAttempt, attempt.id).status == "sent"
  end

  test "adapter exceptions finalize the pending row without persisting exception details" do
    Application.put_env(:codex_pooler, Mailer, adapter: ExceptionAdapter)
    pool = pool_fixture()
    channel = alert_channel_fixture()
    incident = alert_incident_fixture(pool: pool)

    assert {:ok, attempt} = EmailDelivery.deliver_incident_to_channel(incident.id, channel.id, 1)
    assert attempt.status == "failed"
    assert attempt.failure_code == "alert_email_delivery_exception"
    assert attempt.failure_message == "ArgumentError raised during alert email delivery"
    assert Repo.aggregate(from(a in AlertDeliveryAttempt, where: a.incident_id == ^incident.id), :count) == 1
  end

  test "alert delivery renders the channel language without changing stable severity and rule identifiers" do
    Application.put_env(:codex_pooler, Mailer, adapter: Swoosh.Adapters.Test)
    pool = pool_fixture()
    channel = alert_channel_fixture()
    {:ok, channel} = channel |> Ecto.Changeset.change(locale: "zh-CN") |> Repo.update()
    incident = alert_incident_fixture(pool: pool, occurrence_count: 3)
    Gettext.put_locale("en")

    assert {:ok, %{status: "sent"}} = EmailDelivery.deliver_incident_to_channel(incident.id, channel.id, 1)

    assert_email_sent(fn email ->
      assert email.subject == "Codex Pooler 告警: critical: pool_no_usable_assignments"
      assert email.text_body =~ "告警事件 ID：#{incident.id}"
      assert email.text_body =~ "发生次数：3"
      assert email.text_body =~ "此告警仅包含元数据。"
      true
    end)

    assert Gettext.get_locale() == "en"
  end

  test "null and unsupported stored channel languages render English without using the process locale" do
    pool = pool_fixture()
    channel = alert_channel_fixture()
    incident = alert_incident_fixture(pool: pool)
    Gettext.put_locale("zh_CN")

    for locale <- [nil, "retired-locale"] do
      email = EmailDelivery.alert_email(incident, %{channel | locale: locale})
      assert email.subject == "Codex Pooler alert: critical: pool_no_usable_assignments"
      assert email.text_body =~ "Codex Pooler alert notification"
      assert email.text_body =~ "Incident id: #{incident.id}"
    end

    assert Gettext.get_locale() == "zh_CN"
    assert_no_email_sent()
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
