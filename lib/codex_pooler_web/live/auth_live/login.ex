defmodule CodexPoolerWeb.AuthLive.Login do
  use CodexPoolerWeb, :live_view

  alias CodexPooler.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} auth_surface>
      <section class="mx-auto grid min-h-[calc(100svh-10rem)] w-full max-w-4xl items-center px-4 py-10">
        <div class="grid overflow-hidden rounded-box border border-base-300 bg-base-100 shadow-sm lg:grid-cols-[minmax(0,0.9fr)_minmax(0,1.1fr)]">
          <div class="grid content-between gap-8 border-b border-base-300 bg-base-200/60 p-6 sm:p-8 lg:border-b-0 lg:border-r">
            <div class="space-y-3">
              <Layouts.public_logo id="login-logo" />
              <h1 class="text-3xl font-bold uppercase text-primary sm:text-4xl">
                Sign in
              </h1>
              <p :if={!@mfa?} class="max-w-md text-sm leading-6 text-base-content/70">
                Enter your email and password to continue to the admin workspace.
              </p>
            </div>
          </div>

          <div class="p-6 sm:p-8">
            <div :if={@mfa?} class="mb-6 space-y-2">
              <h2 class="text-xl font-semibold text-base-content">
                Second factor
              </h2>
              <p class="text-sm leading-6 text-base-content/70">
                Enter the six-digit code from your authenticator app, or use one recovery code.
              </p>
            </div>

            <div :if={@mfa?} class="alert alert-warning mb-5 items-start" role="status">
              <.icon name="hero-key" class="size-5 shrink-0" />
              <div>
                <p class="font-semibold">Second factor required</p>
                <p class="text-sm leading-6">
                  Signing in as <span class="font-semibold">{@pending_mfa_email}</span>.
                </p>
              </div>
            </div>

            <.form :if={!@mfa?} for={@form} id="login-form" action={~p"/login"} class="grid gap-5">
              <.input field={@form[:email]} type="email" label="Email" autocomplete="email" required />
              <.input
                field={@form[:password]}
                type="password"
                label="Password"
                autocomplete="current-password"
                required
              />
              <.button class="btn btn-primary w-full gap-2 sm:w-fit" phx-disable-with="Signing in...">
                <span>Continue</span>
                <.icon name="hero-arrow-right" class="size-4" />
              </.button>
            </.form>

            <.form :if={@mfa?} for={@form} id="login-mfa-form" action={~p"/login"} class="grid gap-5">
              <div
                id="login-mfa-tabs"
                class="join w-full"
                role="tablist"
                aria-label="Second factor method"
              >
                <.link
                  href={~p"/login?mfa=1&method=totp"}
                  id="login-mfa-tab-totp"
                  role="tab"
                  aria-selected={@mfa_method == "totp"}
                  class={mfa_tab_class(@mfa_method, "totp")}
                >
                  Authenticator code
                </.link>
                <.link
                  href={~p"/login?mfa=1&method=recovery"}
                  id="login-mfa-tab-recovery"
                  role="tab"
                  aria-selected={@mfa_method == "recovery"}
                  class={mfa_tab_class(@mfa_method, "recovery")}
                >
                  Recovery code
                </.link>
              </div>

              <section
                :if={@mfa_method == "totp"}
                id="login-totp-panel"
                role="tabpanel"
                aria-labelledby="login-mfa-tab-totp"
                class="grid gap-4 rounded-box border border-base-300 bg-base-200/40 p-4"
              >
                <div class="flex items-start gap-3 text-base-content/70">
                  <span class="grid size-8 shrink-0 place-items-center rounded-box bg-primary/10 text-primary">
                    <.icon name="hero-device-phone-mobile" class="size-4" />
                  </span>
                  <div>
                    <p class="text-sm font-semibold text-base-content">Authenticator app</p>
                    <p class="text-sm leading-6">
                      Use the current six-digit code for this operator account.
                    </p>
                  </div>
                </div>
                <.otp_input
                  field={@form[:totp_code]}
                  label="Six-digit code"
                  hint="Enter the six digits from your authenticator app."
                  autocomplete="one-time-code"
                  inputmode="numeric"
                  pattern="[0-9]*"
                  maxlength="6"
                  class="grid gap-2"
                />
              </section>

              <section
                :if={@mfa_method == "recovery"}
                id="login-recovery-panel"
                role="tabpanel"
                aria-labelledby="login-mfa-tab-recovery"
                class="grid gap-4 rounded-box border border-base-300 bg-base-200/40 p-4"
              >
                <div class="flex items-start gap-3 text-base-content/70">
                  <span class="grid size-8 shrink-0 place-items-center rounded-box bg-warning/15 text-warning">
                    <.icon name="hero-key" class="size-4" />
                  </span>
                  <div>
                    <p class="text-sm font-semibold text-base-content">Recovery code</p>
                    <p class="text-sm leading-6">
                      Use one unused recovery code if your authenticator is unavailable.
                    </p>
                  </div>
                </div>
                <.input
                  field={@form[:recovery_code]}
                  type="text"
                  label="Recovery code"
                  autocomplete="one-time-code"
                  class="input validator w-full font-mono tracking-wide"
                />
              </section>

              <div class="flex flex-col gap-3 sm:flex-row sm:items-center">
                <.button class="btn btn-primary w-full gap-2 sm:w-fit" phx-disable-with="Verifying...">
                  <span>Verify and sign in</span>
                  <.icon name="hero-arrow-right" class="size-4" />
                </.button>
                <.link href={~p"/login"} class="btn btn-ghost w-full sm:w-fit">
                  Use another account
                </.link>
              </div>
            </.form>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def mount(params, session, socket) do
    cond do
      Accounts.bootstrap_pending?() ->
        {:ok, push_navigate(socket, to: ~p"/bootstrap")}

      socket.assigns.current_scope && socket.assigns.current_scope.user ->
        {:ok, push_navigate(socket, to: ~p"/")}

      true ->
        email = Phoenix.Flash.get(socket.assigns.flash, :email)
        mfa? = params["mfa"] == "1" && is_binary(session["pending_mfa_user_id"])

        {:ok,
         assign(socket,
           form: to_form(%{"email" => email}, as: "user"),
           mfa?: mfa?,
           mfa_method: mfa_method(params["method"]),
           pending_mfa_email: session["pending_mfa_email"] || "this operator"
         )}
    end
  end

  defp mfa_method("recovery"), do: "recovery"
  defp mfa_method(_method), do: "totp"

  defp mfa_tab_class(selected_method, method) do
    [
      "join-item btn min-h-10 flex-1 border-base-300",
      selected_method == method && "btn-primary",
      selected_method != method && "btn-outline bg-base-100 text-base-content"
    ]
  end
end
