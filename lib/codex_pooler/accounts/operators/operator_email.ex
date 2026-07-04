defmodule CodexPooler.Accounts.OperatorEmail do
  @moduledoc """
  Email builders and delivery helpers for operator account access flows.
  """

  import Swoosh.Email

  require Logger

  alias CodexPooler.Accounts.User
  alias CodexPooler.InstanceSettings
  alias CodexPooler.Mailer

  @access_subject "Codex Pooler operator access"
  @temporary_password_subject "Codex Pooler temporary password"
  @password_change_required_notice "You will be asked to change this password after sign in."

  @type temporary_password_result :: %{
          required(:user) => User.t(),
          required(:temporary_password) => binary(),
          optional(:emailed?) => boolean(),
          optional(:email_error?) => boolean()
        }
  @type operator_result ::
          {:ok, temporary_password_result()} | {:error, Ecto.Changeset.t() | atom()}
  @type delivery_result :: {:ok, term()} | {:error, term()}

  @spec operator_access_email(String.t(), binary(), boolean()) :: Swoosh.Email.t()
  def operator_access_email(operator_email, temporary_password, password_change_required \\ true) do
    build_email(@access_subject, operator_email, temporary_password, password_change_required)
  end

  @spec temporary_password_email(String.t(), binary(), boolean()) :: Swoosh.Email.t()
  def temporary_password_email(
        operator_email,
        temporary_password,
        password_change_required \\ true
      ) do
    build_email(
      @temporary_password_subject,
      operator_email,
      temporary_password,
      password_change_required
    )
  end

  @spec deliver_operator_access(String.t(), binary(), boolean()) :: delivery_result()
  def deliver_operator_access(
        operator_email,
        temporary_password,
        password_change_required \\ true
      ) do
    operator_access_email(operator_email, temporary_password, password_change_required)
    |> Mailer.deliver()
  end

  @spec deliver_temporary_password(String.t(), binary(), boolean()) :: delivery_result()
  def deliver_temporary_password(
        operator_email,
        temporary_password,
        password_change_required \\ true
      ) do
    temporary_password_email(operator_email, temporary_password, password_change_required)
    |> Mailer.deliver()
  end

  @spec maybe_deliver_operator_access(operator_result(), boolean()) :: operator_result()
  def maybe_deliver_operator_access({:ok, result}, send_email?) do
    result
    |> put_email_flags(send_email?, :operator_access_email, fn ->
      deliver_operator_access(
        result.user.email,
        result.temporary_password,
        result.user.password_change_required
      )
    end)
    |> then(&{:ok, &1})
  end

  def maybe_deliver_operator_access(error, _send_email?), do: error

  @spec maybe_deliver_temporary_password(operator_result(), boolean()) :: operator_result()
  def maybe_deliver_temporary_password({:ok, result}, send_email?) do
    result
    |> put_email_flags(send_email?, :temporary_password_email, fn ->
      deliver_temporary_password(
        result.user.email,
        result.temporary_password,
        result.user.password_change_required
      )
    end)
    |> then(&{:ok, &1})
  end

  def maybe_deliver_temporary_password(error, _send_email?), do: error

  defp build_email(subject, operator_email, temporary_password, password_change_required) do
    new()
    |> from(Mailer.default_sender())
    |> to(operator_email)
    |> subject(subject)
    |> text_body(text_body(operator_email, temporary_password, password_change_required))
  end

  defp text_body(operator_email, temporary_password, password_change_required) do
    [
      "An administrator created or updated Codex Pooler operator access for this email.",
      "If you did not expect this email, do not sign in with this password. Contact your system administrator or ignore this email.",
      "Never forward this temporary password. Codex Pooler administrators will not ask you to send it back.",
      "",
      "Login URL: #{login_url()}",
      "Operator email: #{operator_email}",
      "Temporary password: #{temporary_password}",
      password_change_required && @password_change_required_notice
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp login_url do
    public_operator_app_url() <> "/login"
  end

  defp public_operator_app_url do
    InstanceSettings.current().operator.login_base_url
    |> to_string()
    |> String.trim_trailing("/")
  end

  defp put_email_flags(result, false, _operation, _deliver_fun) do
    result
    |> Map.put(:emailed?, false)
    |> Map.put(:email_error?, false)
  end

  defp put_email_flags(result, true, operation, deliver_fun) do
    case deliver_fun.() do
      {:ok, _email} ->
        result
        |> Map.put(:emailed?, true)
        |> Map.put(:email_error?, false)

      {:error, reason} ->
        log_operator_email_failure(operation, reason)

        result
        |> Map.put(:emailed?, false)
        |> Map.put(:email_error?, true)
    end
  rescue
    error ->
      log_operator_email_exception(operation, error)

      result
      |> Map.put(:emailed?, false)
      |> Map.put(:email_error?, true)
  end

  defp log_operator_email_failure(operation, reason) do
    Logger.warning(fn ->
      "operator email delivery failed operation=#{operation} reason=#{delivery_failure_class(reason)}"
    end)
  end

  defp log_operator_email_exception(operation, error) do
    Logger.warning(fn ->
      "operator email delivery raised operation=#{operation} exception=#{exception_class(error)}"
    end)
  end

  defp delivery_failure_class(%{__struct__: struct}), do: inspect(struct)
  defp delivery_failure_class({class, _details}) when is_atom(class), do: Atom.to_string(class)
  defp delivery_failure_class(class) when is_atom(class), do: Atom.to_string(class)
  defp delivery_failure_class(_reason), do: "unknown"

  defp exception_class(%{__struct__: struct}), do: inspect(struct)
end
