defmodule CodexPoolerWeb.Admin.UpstreamOAuthDialogComponents do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.Components, as: AdminComponents

  attr :id_prefix, :string, required: true
  attr :authorization_url, :string, required: true
  attr :form, :any, required: true
  attr :submit_event, :string, required: true
  attr :submit_label, :string, required: true

  def browser_authorization_step(assigns) do
    assigns =
      assigns
      |> assign(:root_id, "#{assigns.id_prefix}-browser-flow")
      |> assign(:authorization_step_id, "#{assigns.id_prefix}-authorization-step")
      |> assign(:authorization_url_id, "#{assigns.id_prefix}-authorization-url")
      |> assign(:authorization_copy_id, "#{assigns.id_prefix}-authorization-url-copy")
      |> assign(:callback_step_id, "#{assigns.id_prefix}-callback-step")
      |> assign(:callback_form_id, "#{assigns.id_prefix}-callback-form")
      |> assign(:callback_url_id, "#{assigns.id_prefix}-callback-url")
      |> assign(:callback_help_id, "#{assigns.id_prefix}-callback-help")
      |> assign(:submit_id, "#{assigns.id_prefix}-submit-callback")

    ~H"""
    <section id={@root_id} data-role="oauth-browser-flow" class="grid gap-5">
      <div
        id={@authorization_step_id}
        data-role="oauth-authorization-step"
        class="grid min-w-0 grid-cols-[2rem_minmax(0,1fr)] gap-3"
      >
        <span class="grid size-8 place-items-center rounded-box bg-primary/15 text-sm font-bold tabular-nums text-primary">
          1
        </span>
        <div class="min-w-0">
          <h3 class="text-base font-semibold text-base-content">Authorize with OpenAI</h3>
          <p class="mt-1 max-w-xl text-sm leading-5 text-base-content/65">
            Open the authorization page in a new tab and keep this dialog open.
          </p>
          <div class="mt-3 grid min-w-0 gap-2 sm:grid-cols-[minmax(0,1fr)_auto]">
            <a
              id={@authorization_url_id}
              href={@authorization_url}
              target="_blank"
              rel="noopener noreferrer"
              class="btn btn-primary h-10 min-h-10 min-w-0 justify-start gap-2 px-4 text-left"
            >
              <.icon name="hero-arrow-top-right-on-square" class="size-4 shrink-0" />
              <span class="truncate">Open authorization page</span>
            </a>
            <AdminComponents.clipboard_button
              id={@authorization_copy_id}
              copy_text={@authorization_url}
              label="Copy link"
              aria_label="Copy OpenAI authorization URL"
              class="btn btn-secondary h-10 min-h-10 w-full shrink-0 gap-2 px-3 sm:w-auto"
            />
          </div>
        </div>
      </div>

      <.form
        id={@callback_form_id}
        for={@form}
        phx-submit={@submit_event}
        autocomplete="off"
        class="grid min-w-0 grid-cols-[2rem_minmax(0,1fr)] gap-3 border-t border-base-300 pt-5"
      >
        <span class="grid size-8 place-items-center rounded-box bg-base-200 text-sm font-bold tabular-nums text-base-content/60">
          2
        </span>
        <div id={@callback_step_id} data-role="oauth-callback-step" class="min-w-0">
          <label for={@callback_url_id} class="text-base font-semibold text-base-content">
            Paste the callback URL
          </label>
          <p id={@callback_help_id} class="mt-1 max-w-xl text-sm leading-5 text-base-content/65">
            After OpenAI redirects, copy the full URL from the browser address bar and paste it here.
          </p>
          <input
            id={@callback_url_id}
            name={@form[:callback_url].name}
            value=""
            type="url"
            placeholder="https://..."
            autocomplete="off"
            autocapitalize="none"
            spellcheck="false"
            required
            aria-describedby={@callback_help_id}
            class="input input-bordered mt-3 w-full font-mono text-sm"
          />
          <div class="mt-3 flex justify-end">
            <AdminComponents.action_button
              id={@submit_id}
              icon="hero-check"
              label={@submit_label}
              type="submit"
              size={:md}
            />
          </div>
        </div>
      </.form>
    </section>
    """
  end
end
