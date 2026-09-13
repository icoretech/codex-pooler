defmodule CodexPooler.Accounts.OperatorPasswordLifecycleTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounts
  alias CodexPooler.Accounts.{Scope, SessionNotifier}
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.Repo

  import ExUnit.CaptureLog
  import CodexPooler.AccountsFixtures

  defmodule DeliveryErrorAdapter do
    @behaviour Swoosh.Adapter

    @impl true
    def validate_config(_config), do: :ok

    @impl true
    def deliver(_email, _config), do: {:error, :smtp_unavailable}
  end

  defmodule DeliveryRaiseAdapter do
    @behaviour Swoosh.Adapter

    @impl true
    def validate_config(_config), do: :ok

    @impl true
    def deliver(_email, _config), do: raise(RuntimeError, "adapter unavailable")
  end

  describe "operator password lifecycle contract" do
    @tag :operator_passwords
    test "resets and resends temporary passwords without storing plaintext and keeps forced password change" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      %{user: operator, temporary_password: original_password} = operator_fixture(owner)
      scope = Scope.for_user(owner, ["instance_owner"])

      assert {:ok, %{user: password_key_user, temporary_password: password_key_password}} =
               call_operator_api!(
                 :create_operator,
                 [
                   owner,
                   valid_operator_attributes(%{
                     "email" => "password-key-operator@example.com",
                     "password" => "manual-pass-123"
                   })
                   |> Map.delete("temporary_password"),
                   operator_metadata(%{request_id: "operator-create-password-key-contract"})
                 ]
               )

      assert password_key_password == "manual-pass-123"

      assert Accounts.get_user_by_email_and_password(
               password_key_user.email,
               password_key_password
             )

      assert {:ok,
              %{
                user: reset_user,
                temporary_password: reset_password,
                emailed?: reset_emailed?,
                email_error?: reset_email_error?
              }} =
               call_operator_api!(
                 :reset_operator_password,
                 [
                   scope,
                   operator.id,
                   %{
                     "new_password" => "manual-reset-pass-123",
                     "password_change_required" => false
                   },
                   operator_metadata(%{request_id: "operator-reset-contract"})
                 ]
               )

      assert reset_password == "manual-reset-pass-123"
      assert reset_user.password_change_required == false
      refute reset_user.password_hash == reset_password
      assert reset_emailed? == false
      assert reset_email_error? == false
      refute Accounts.get_user_by_email_and_password(operator.email, original_password)
      assert Accounts.get_user_by_email_and_password(operator.email, reset_password)

      assert reset_audit =
               Repo.get_by(AuditEvent, action: "operator.password_reset", actor_user_id: owner.id)

      refute inspect(reset_audit.details) =~ reset_password

      assert {:ok,
              %{
                user: resent_user,
                temporary_password: resent_password,
                emailed?: resent_emailed?,
                email_error?: resent_email_error?
              }} =
               call_operator_api!(
                 :resend_operator_temporary_password,
                 [
                   owner,
                   reset_user,
                   %{},
                   operator_metadata(%{request_id: "operator-resend-contract"})
                 ]
               )

      assert resent_user.password_change_required == true
      assert is_binary(resent_password)
      assert byte_size(resent_password) >= 8
      refute resent_password == reset_password
      refute resent_user.password_hash == resent_password
      assert resent_emailed? == false
      assert resent_email_error? == false
      refute Accounts.get_user_by_email_and_password(operator.email, reset_password)
      assert Accounts.get_user_by_email_and_password(operator.email, resent_password)

      assert resend_audit =
               Repo.get_by(AuditEvent,
                 action: "operator.temporary_password_resend",
                 actor_user_id: owner.id
               )

      refute inspect(resend_audit.details) =~ resent_password
    end

    @tag :operator_passwords
    test "operator lifecycle password operations broadcast target-user session revocation" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      %{user: operator} = operator_fixture(owner)

      Phoenix.PubSub.subscribe(
        CodexPooler.PubSub,
        SessionNotifier.user_sessions_topic(operator.id)
      )

      assert {:ok, _result} =
               Accounts.reset_operator_password(
                 owner,
                 operator,
                 %{"new_password" => "manual-reset-pass-123"},
                 operator_metadata(%{request_id: "operator-reset-broadcast-contract"})
               )

      assert_receive {:disconnect_user_sessions, %{user_id: user_id, except_live_socket_id: nil}}
      assert user_id == operator.id

      reset_user = Accounts.get_user!(operator.id)

      assert {:ok, _result} =
               Accounts.resend_operator_temporary_password(
                 owner,
                 reset_user,
                 %{},
                 operator_metadata(%{request_id: "operator-resend-broadcast-contract"})
               )

      assert_receive {:disconnect_user_sessions, %{user_id: user_id, except_live_socket_id: nil}}
      assert user_id == operator.id

      resent_user = Accounts.get_user!(operator.id)

      assert {:ok, _result} =
               Accounts.reactivate_operator(
                 owner,
                 resent_user,
                 %{},
                 operator_metadata(%{request_id: "operator-reactivate-broadcast-contract"})
               )

      assert_receive {:disconnect_user_sessions, %{user_id: user_id, except_live_socket_id: nil}}
      assert user_id == operator.id

      reactivated_user = Accounts.get_user!(operator.id)

      assert {:ok, _result} =
               Accounts.deactivate_operator(
                 owner,
                 reactivated_user,
                 %{"reason" => "broadcast check"},
                 operator_metadata(%{request_id: "operator-deactivate-broadcast-contract"})
               )

      assert_receive {:disconnect_user_sessions, %{user_id: user_id, except_live_socket_id: nil}}
      assert user_id == operator.id
    end

    @tag :operator_passwords
    test "optionally emails temporary passwords after successful account mutation" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})

      assert {:ok,
              %{
                user: operator,
                temporary_password: temporary_password,
                emailed?: true,
                email_error?: false
              }} =
               call_operator_api!(
                 :create_operator,
                 [
                   owner,
                   valid_operator_attributes(%{
                     "email" => "emailed.operator@example.com",
                     "send_email" => true
                   }),
                   operator_metadata(%{request_id: "operator-create-email-contract"})
                 ]
               )

      assert Accounts.get_user_by_email_and_password(operator.email, temporary_password)
    end

    test "logs sanitized operator email delivery errors" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      temporary_password = "SanitizedTempPass123!"

      log =
        capture_log(fn ->
          with_mailer_adapter(DeliveryErrorAdapter, fn ->
            assert {:ok, %{emailed?: false, email_error?: true}} =
                     call_operator_api!(
                       :create_operator,
                       [
                         owner,
                         valid_operator_attributes(%{
                           "email" => "email-error.operator@example.com",
                           "temporary_password" => temporary_password,
                           "send_email" => true
                         }),
                         operator_metadata(%{request_id: "operator-email-error-contract"})
                       ]
                     )
          end)
        end)

      assert log =~ "operator email delivery failed operation=operator_access_email"
      assert log =~ "reason=smtp_unavailable"
      refute log =~ temporary_password
    end

    test "logs sanitized operator email delivery exceptions" do
      %{user: owner} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      temporary_password = "RaisedTempPass123!"

      log =
        capture_log(fn ->
          with_mailer_adapter(DeliveryRaiseAdapter, fn ->
            assert {:ok, %{emailed?: false, email_error?: true}} =
                     call_operator_api!(
                       :create_operator,
                       [
                         owner,
                         valid_operator_attributes(%{
                           "email" => "email-exception.operator@example.com",
                           "temporary_password" => temporary_password,
                           "send_email" => true
                         }),
                         operator_metadata(%{request_id: "operator-email-exception-contract"})
                       ]
                     )
          end)
        end)

      assert log =~ "operator email delivery raised operation=operator_access_email"
      assert log =~ "exception=RuntimeError"
      refute log =~ temporary_password
    end
  end

  defp assert_operator_api!(name, arity) do
    Code.ensure_loaded!(Accounts)

    assert function_exported?(Accounts, name, arity),
           "expected CodexPooler.Accounts.#{name}/#{arity} to define the operator lifecycle contract"
  end

  defp call_operator_api!(name, args) when is_atom(name) and is_list(args) do
    assert_operator_api!(name, length(args))
    apply(Accounts, name, args)
  end

  # `on_exit` rather than `after`: a scoped restore runs only while the test process is alive,
  # so a killed test would leave the fault-injecting adapter configured for every later test in
  # the partition. Restoring an absent key means deleting it, not writing back the `nil` that
  # `get_env/2` returns for one.
  defp with_mailer_adapter(adapter, fun) do
    previous_config = Application.fetch_env(:codex_pooler, CodexPooler.Mailer)
    on_exit(fn -> restore_mailer_config(previous_config) end)
    Application.put_env(:codex_pooler, CodexPooler.Mailer, adapter: adapter)
    fun.()
  end

  defp restore_mailer_config({:ok, config}),
    do: Application.put_env(:codex_pooler, CodexPooler.Mailer, config)

  defp restore_mailer_config(:error),
    do: Application.delete_env(:codex_pooler, CodexPooler.Mailer)
end
