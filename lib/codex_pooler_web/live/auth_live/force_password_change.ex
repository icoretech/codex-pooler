defmodule CodexPoolerWeb.AuthLive.ForcePasswordChange do
  use CodexPoolerWeb, :live_view

  alias CodexPooler.Accounts

  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} locale={@locale} locale_preference={@locale_preference} auth_surface>
      <section class="mx-auto grid min-h-[calc(100svh-10rem)] w-full max-w-4xl items-center px-4 py-10">
        <div class="grid overflow-hidden rounded-box border border-warning/30 bg-base-100 shadow-sm lg:grid-cols-[minmax(0,0.9fr)_minmax(0,1.1fr)]">
          <div class="grid content-between gap-8 border-b border-warning/30 bg-warning/10 p-6 sm:p-8 lg:border-b-0 lg:border-r">
            <div class="space-y-3">
              <Layouts.public_logo id="password-change-logo" />
              <p class="font-mono text-xs font-semibold uppercase tracking-[0.2em] text-warning">
                {gettext("password update required")}
              </p>
              <h1 class="text-3xl font-bold uppercase text-primary sm:text-4xl">
                {gettext("Choose a private password")}
              </h1>
              <p class="max-w-md text-sm leading-6 text-base-content/70">
                {gettext("Your current password was issued temporarily. Set a new password before opening the admin workspace.")}
              </p>
            </div>

            <div class="grid gap-3 rounded-box border border-warning/30 bg-base-100/75 p-4 text-sm text-base-content/70">
              <div class="flex gap-3">
                <span class="grid size-8 shrink-0 place-items-center rounded-box bg-warning/15 text-warning">
                  <.icon name="hero-exclamation-triangle" class="size-4" />
                </span>
                <p>
                  {gettext("After the password is updated, other active sessions for this operator are revoked.")}
                </p>
              </div>
            </div>
          </div>

          <div class="p-6 sm:p-8">
            <div class="mb-6 space-y-2">
              <h2 class="text-xl font-semibold text-base-content">{gettext("New password")}</h2>
              <p class="text-sm leading-6 text-base-content/70">
                {gettext("Enter and confirm the password you will use for future sign-ins.")}
              </p>
            </div>

            <div id="password-change-required-form">
              <.form
                for={@form}
                id="password-change-form"
                phx-submit="change_password"
                class="grid gap-5"
              >
                <.input
                  field={@form[:new_password]}
                  type="password"
                  label={gettext("New password")}
                  autocomplete="new-password"
                  required
                />
                <.input
                  field={@form[:new_password_confirmation]}
                  type="password"
                  label={gettext("Confirm new password")}
                  autocomplete="new-password"
                  required
                />
                <.button
                  class="btn btn-primary w-full gap-2 sm:w-fit"
                  phx-disable-with={gettext("Updating password...")}
                >
                  <span>{gettext("Update password")}</span>
                  <.icon name="hero-arrow-right" class="size-4" />
                </.button>
              </.form>
            </div>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, session, socket) do
    if socket.assigns.current_scope.user.password_change_required do
      {:ok,
       assign(socket,
         page_title: gettext("Choose a private password"),
         current_user_token: session["user_token"],
         form: to_form(%{}, as: :user)
       )}
    else
      {:ok,
       push_navigate(socket,
         to: CodexPoolerWeb.UserAuth.signed_in_path(socket.assigns.current_scope.user)
       )}
    end
  end

  @impl true
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("change_password", %{"user" => user_params}, socket) do
    with :ok <- validate_password_confirmation(user_params),
         {:ok, _user} <-
           Accounts.complete_required_password_change(
             socket.assigns.current_scope.user,
             user_params,
             %{},
             socket.assigns.current_user_token
           ) do
      CodexPoolerWeb.UserAuth.disconnect_user_sessions(socket.assigns.current_scope.user.id,
        except_live_socket_id: CodexPoolerWeb.UserAuth.live_socket_id_for_token(socket.assigns.current_user_token)
      )

      {:noreply,
       push_navigate(socket,
         to: CodexPoolerWeb.UserAuth.signed_in_path(socket.assigns.current_scope.user)
       )}
    else
      {:error, :password_confirmation_mismatch} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Passwords do not match."))
         |> assign(:form, to_form(user_params, as: :user))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, changeset_error(changeset))
         |> assign(:form, to_form(user_params, as: :user))}
    end
  end

  defp validate_password_confirmation(%{
         "new_password" => password,
         "new_password_confirmation" => password
       })
       when password not in [nil, ""] do
    :ok
  end

  defp validate_password_confirmation(%{
         "new_password" => password,
         "new_password_confirmation" => confirmation
       })
       when password != confirmation or confirmation in [nil, ""] do
    {:error, :password_confirmation_mismatch}
  end

  defp validate_password_confirmation(_params), do: {:error, :password_confirmation_mismatch}

  defp changeset_error(changeset) do
    case List.first(changeset.errors) do
      {field, error} ->
        gettext("%{field} %{message}", field: password_field_label(field), message: CodexPoolerWeb.CoreComponents.translate_error(error))

      nil ->
        gettext("Password change failed.")
    end
  end

  defp password_field_label(:new_password), do: gettext("New password")
  defp password_field_label(:password), do: gettext("Password")
  defp password_field_label(:new_password_confirmation), do: gettext("New password confirmation")
end
