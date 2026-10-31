defmodule CodexPoolerWeb.UserSessionController do
  use CodexPoolerWeb, :controller

  alias CodexPooler.Accounts
  alias CodexPoolerWeb.UserAuth

  def bootstrap(conn, %{"user" => user_params}) do
    case Accounts.bootstrap_owner(user_params, UserAuth.request_metadata(conn)) do
      {:ok, %{user: user, token: token}} ->
        conn
        |> put_flash(:info, gettext("Instance owner created."))
        |> delete_session(:user_return_to)
        |> UserAuth.log_in_user(user, token)

      {:error, :bootstrap_already_completed} ->
        conn
        |> put_flash(:error, gettext("Bootstrap has already been completed."))
        |> redirect(to: ~p"/login")

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_flash(:error, localized_changeset_error(changeset))
        |> put_flash(:email, Map.get(user_params, "email"))
        |> redirect(to: ~p"/bootstrap")

      {:error, _reason} ->
        conn
        |> put_flash(:error, gettext("Bootstrap failed."))
        |> redirect(to: ~p"/bootstrap")
    end
  end

  def create(conn, %{"user" => user_params}) do
    if pending_mfa_user_id = pending_mfa_user_id(conn, user_params) do
      complete_second_factor_login(conn, pending_mfa_user_id, user_params)
    else
      conn
      |> delete_session(:pending_mfa_user_id)
      |> delete_session(:pending_mfa_email)
      |> start_login(user_params)
    end
  end

  defp start_login(conn, user_params) do
    case Accounts.login_user(user_params, UserAuth.request_metadata(conn)) do
      {:ok, %{user: user, token: token}} ->
        conn
        |> put_flash(:info, gettext("Welcome back."))
        |> UserAuth.log_in_user(user, token)

      {:error, :totp_required} ->
        user = Accounts.get_user_by_email(user_params["email"])

        conn
        |> put_session(:pending_mfa_user_id, user.id)
        |> put_session(:pending_mfa_email, user.email)
        |> put_flash(:info, gettext("Enter your authenticator code to finish signing in."))
        |> redirect(to: ~p"/login?mfa=1")

      {:error, :invalid_totp_code} ->
        redirect_login_failure(conn, user_params, gettext("Authenticator code is invalid."), true)

      {:error, :invalid_recovery_code} ->
        redirect_login_failure(conn, user_params, gettext("Recovery code is invalid."), true)

      {:error, _reason} ->
        redirect_login_failure(conn, user_params, gettext("Invalid email or password."), false)
    end
  end

  defp complete_second_factor_login(conn, user_id, user_params) do
    case Accounts.complete_second_factor_login(
           user_id,
           user_params,
           UserAuth.request_metadata(conn)
         ) do
      {:ok, %{user: user, token: token}} ->
        conn
        |> delete_session(:pending_mfa_user_id)
        |> delete_session(:pending_mfa_email)
        |> put_flash(:info, gettext("Welcome back."))
        |> UserAuth.log_in_user(user, token)

      {:error, :invalid_totp_code} ->
        redirect_mfa_failure(conn, gettext("Authenticator code is invalid."))

      {:error, :invalid_recovery_code} ->
        redirect_mfa_failure(conn, gettext("Recovery code is invalid."))

      {:error, :totp_required} ->
        redirect_mfa_failure(conn, gettext("Second factor required."))

      {:error, _reason} ->
        conn
        |> delete_session(:pending_mfa_user_id)
        |> delete_session(:pending_mfa_email)
        |> redirect_login_failure(%{}, gettext("Invalid email or password."), false)
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, gettext("Logged out successfully."))
    |> UserAuth.log_out_user()
  end

  def bootstrap_status(conn, _params) do
    json(conn, %{status: "ok", bootstrap: Accounts.bootstrap_status()})
  end

  def session(conn, params) do
    current_scope = conn.assigns.current_scope

    cond do
      current_scope && current_scope.user ->
        json(conn, %{
          status: "ok",
          authenticated: true,
          user: %{
            id: current_scope.user.id,
            email: current_scope.user.email,
            display_name: current_scope.user.display_name
          },
          auth: %{roles: current_scope.roles}
        })

      params["optional"] == "1" ->
        json(conn, %{status: "ok", authenticated: false})

      true ->
        conn
        |> put_status(:unauthorized)
        |> json(%{
          error: %{code: "invalid_session", message: "operator session is invalid or expired"}
        })
    end
  end

  def change_password(conn, %{"user" => user_params}) do
    current_token = get_session(conn, :user_token)

    with %{user: user} <- conn.assigns.current_scope,
         {:ok, user} <-
           Accounts.change_current_user_password(
             user,
             user_params,
             UserAuth.request_metadata(conn),
             current_token
           ) do
      disconnect_parallel_sessions(user, current_token)

      conn
      |> json(%{status: "ok", authenticated: true})
    else
      nil ->
        invalid_session(conn)

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_password", message: changeset_error(changeset)}})

      {:error, :invalid_session} ->
        invalid_session(conn)

      {:error, :invalid_current_password} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: %{code: "invalid_current_password", message: "Current password is invalid"}
        })

      {:error, _reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: %{code: "password_change_failed", message: "Password change failed"}})
    end
  end

  def change_password(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: %{code: "invalid_request", message: "new password is required"}})
  end

  defp redirect_login_failure(conn, user_params, message, mfa?) do
    path = if mfa?, do: ~p"/login?mfa=1", else: ~p"/login"

    conn
    |> put_flash(:error, message)
    |> put_flash(:email, String.slice(to_string(user_params["email"] || ""), 0, 160))
    |> redirect(to: path)
  end

  defp redirect_mfa_failure(conn, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/login?mfa=1")
  end

  defp pending_mfa_user_id(conn, user_params) do
    if to_string(user_params["password"] || "") == "" do
      get_session(conn, :pending_mfa_user_id)
    end
  end

  defp localized_changeset_error(changeset) do
    case List.first(changeset.errors) do
      {field, {message, opts}} ->
        gettext("%{field} %{message}",
          field: localized_field_name(field),
          message: localized_error_message(message, opts)
        )

      nil ->
        gettext("Invalid bootstrap details.")
    end
  end

  defp localized_field_name(:email), do: gettext("Email")
  defp localized_field_name(:display_name), do: gettext("Display name")
  defp localized_field_name(:password), do: gettext("Password")
  defp localized_field_name(field), do: Phoenix.Naming.humanize(field)

  defp localized_error_message(message, opts) do
    if count = opts[:count] do
      Gettext.dngettext(CodexPoolerWeb.Gettext, "errors", message, message, count, opts)
    else
      Gettext.dgettext(CodexPoolerWeb.Gettext, "errors", message, opts)
    end
  end

  defp changeset_error(changeset) do
    changeset.errors
    |> Enum.map(fn {field, {message, _opts}} ->
      "#{Phoenix.Naming.humanize(field)} #{message}"
    end)
    |> List.first()
    |> Kernel.||("Invalid bootstrap details.")
  end

  defp invalid_session(conn) do
    conn
    |> put_status(:unauthorized)
    |> json(%{
      error: %{code: "invalid_session", message: "operator session is invalid or expired"}
    })
  end

  defp disconnect_parallel_sessions(user, current_token) when is_binary(current_token) do
    UserAuth.disconnect_user_sessions(user.id,
      except_live_socket_id: UserAuth.live_socket_id_for_token(current_token)
    )
  end

  defp disconnect_parallel_sessions(_user, _current_token), do: :ok
end
