defmodule CodexPoolerWeb.AuthLive.Bootstrap do
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
              <Layouts.public_logo id="bootstrap-logo" />
              <h1 class="text-3xl font-bold uppercase text-primary sm:text-4xl">
                Bootstrap
              </h1>
              <p class="max-w-md text-sm leading-6 text-base-content/70">
                Set up the local owner account that will manage Pools, upstream accounts, API keys, and operators.
              </p>
            </div>
          </div>

          <div class="p-6 sm:p-8">
            <div class="mb-6 space-y-2">
              <h2 class="text-xl font-semibold text-base-content">Owner details</h2>
              <p class="text-sm leading-6 text-base-content/70">
                Choose the email address and password the instance owner will use to sign in.
              </p>
            </div>

            <.form for={@form} id="bootstrap-form" action={~p"/bootstrap"} class="grid gap-5">
              <.input field={@form[:email]} type="email" label="Email" autocomplete="email" required />
              <.input
                field={@form[:display_name]}
                type="text"
                label="Display name"
                autocomplete="name"
                required
              />
              <.input
                field={@form[:password]}
                type="password"
                label="Password"
                autocomplete="new-password"
                minlength="8"
                required
              />
              <.button
                class="btn btn-primary w-full gap-2 sm:w-fit"
                phx-disable-with="Creating owner..."
              >
                <span>Create owner</span>
                <.icon name="hero-arrow-right" class="size-4" />
              </.button>
            </.form>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if Accounts.bootstrap_pending?() do
      email = Phoenix.Flash.get(socket.assigns.flash, :email)
      {:ok, assign(socket, form: to_form(%{"email" => email}, as: "user"))}
    else
      {:ok, push_navigate(socket, to: ~p"/login")}
    end
  end
end
