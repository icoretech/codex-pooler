defmodule CodexPoolerWeb.Admin.UpstreamOAuthDialogComponents do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.DateTimeDisplay

  attr :id_prefix, :string, required: true
  attr :browser_event, :string, required: true
  attr :device_event, :string, required: true
  attr :active, :atom, default: nil, values: [nil, :browser, :device]
  attr :disabled, :boolean, default: false
  attr :disabled_hint, :string, default: nil

  @doc """
  The two authorization routes, offered as peers.

  Browser and device are not a route and its fallback: they are two ways the
  same proof arrives, so neither is styled above the other. Each is an action
  that *starts* a flow, which is why nothing is marked until one is running —
  and once one is, the other stays available as a way to switch rather than
  cancel and start again.
  """
  def method_doors(assigns) do
    ~H"""
    <div class="grid gap-2" data-role="oauth-method-doors">
      <div class="grid gap-2 sm:grid-cols-2">
        <.method_door
          id={"#{@id_prefix}-browser-start"}
          event={@browser_event}
          icon="hero-arrow-top-right-on-square"
          label="via OAuth (browser)"
          hint={
            if @active == :device,
              do: "Switch to pasting a URL.",
              else: "Approve in a tab, paste the URL back."
          }
          active={@active == :browser}
          disabled={@disabled}
        />
        <.method_door
          id={"#{@id_prefix}-device-start"}
          event={@device_event}
          icon="hero-device-phone-mobile"
          label="via Device Code"
          hint={
            if @active == :browser,
              do: "Switch to a device code.",
              else: "Approve elsewhere, nothing to paste."
          }
          active={@active == :device}
          disabled={@disabled}
        />
      </div>
      <p :if={@disabled && @disabled_hint} class="text-xs leading-4 text-base-content/55">
        {@disabled_hint}
      </p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :event, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :hint, :string, required: true
  attr :active, :boolean, required: true
  attr :disabled, :boolean, required: true

  # The selection-card anatomy from DESIGN.md: `rounded-box` shell, 13px title
  # over an 11px description, `border-primary/60 bg-primary/5` when carried, and
  # the corner check as the non-colour channel. The one deliberate departure is
  # the control: these start a flow rather than select a value, so the card is a
  # button and there is no radio behind it. The check therefore reads "this is
  # the route running" rather than "this is the option chosen".
  defp method_door(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      phx-click={@event}
      disabled={@disabled}
      aria-current={@active && "true"}
      class={[
        "relative min-w-0 rounded-box border p-2.5 text-left transition-colors",
        "outline-none focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary",
        @active && "border-primary/60 bg-primary/5",
        !@active && "border-base-300 bg-base-100 hover:border-primary/50",
        @disabled && "cursor-not-allowed opacity-45 hover:border-base-300"
      ]}
    >
      <span
        :if={@active}
        class="pointer-events-none absolute right-2.5 top-3 inline-flex items-center gap-1"
      >
        <.icon name="hero-check" class="size-3 text-primary" />
      </span>
      <span class="flex min-w-0 items-start gap-2.5">
        <.icon name={@icon} class="mt-0.5 size-3.5 shrink-0 text-base-content/55" />
        <span class="grid min-w-0 gap-0.5">
          <span class="text-[13px] font-semibold leading-tight text-base-content">{@label}</span>
          <span class="text-[11px] leading-4 text-base-content/55">{@hint}</span>
        </span>
      </span>
    </button>
    """
  end

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
    <section id={@root_id} data-role="oauth-browser-flow" class="grid gap-4">
      <div id={@authorization_step_id} data-role="oauth-authorization-step" class="grid min-w-0 gap-2">
        <label for={@authorization_url_id} class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
          Authorization page
        </label>
        <div class="grid min-w-0 items-stretch gap-2 sm:grid-cols-[minmax(0,1fr)_auto]">
          <input
            id={@authorization_url_id}
            type="url"
            value={@authorization_url}
            readonly
            aria-label="OpenAI authorization URL"
            class="input input-bordered h-8 min-h-8 w-full min-w-0 bg-base-200/60 px-2 font-mono text-xs"
          />
          <div class="flex min-w-0 items-stretch gap-2">
            <a
              id={"#{@id_prefix}-authorization-open"}
              href={@authorization_url}
              target="_blank"
              rel="noopener noreferrer"
              class="btn btn-secondary btn-sm h-8 min-h-8 shrink-0 gap-1.5"
            >
              <.icon name="hero-arrow-top-right-on-square" class="size-3.5 shrink-0" />
              <span>Open</span>
            </a>
            <AdminComponents.clipboard_button
              id={@authorization_copy_id}
              copy_text={@authorization_url}
              label="Copy link"
              aria_label="Copy OpenAI authorization URL"
              class="btn btn-secondary btn-sm h-8 min-h-8 shrink-0 gap-1.5"
              icon_class="size-3.5"
            />
          </div>
        </div>
      </div>

      <.form
        id={@callback_form_id}
        for={@form}
        phx-submit={@submit_event}
        autocomplete="off"
        class="grid min-w-0 gap-2 border-t border-base-300 pt-4"
      >
        <div id={@callback_step_id} data-role="oauth-callback-step" class="grid min-w-0 gap-2">
          <label
            for={@callback_url_id}
            class="text-xs font-semibold uppercase tracking-wide text-base-content/60"
          >
            Callback URL
          </label>
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
            class="input input-bordered h-8 min-h-8 w-full px-2 font-mono text-xs"
          />
          <p id={@callback_help_id} class="text-xs leading-4 text-base-content/55">
            After OpenAI redirects, copy the full URL from the browser address bar and paste it here.
          </p>
        </div>
      </.form>
    </section>
    """
  end

  attr :id_prefix, :string, required: true
  attr :user_code, :string, required: true
  attr :verification_uri, :string, default: nil
  attr :status, :string, default: nil
  attr :interval_seconds, :integer, default: nil
  attr :expires_at, :any, default: nil
  attr :datetime_preferences, :map, default: %{}

  @doc """
  The device route, in the same shape as the browser one.

  Both routes hand back the same proof, so they read the same way: labelled
  rows, a readonly field carrying the value, and a labelled Open and Copy pair
  beside it. The status line stays here and only here — on this route a poll is
  actually running, and the operator has no other signal for it.
  """
  def device_authorization_step(assigns) do
    ~H"""
    <section id={"#{@id_prefix}-device-code"} data-role="oauth-device-flow" class="grid gap-4">
      <div class="grid min-w-0 gap-2">
        <span class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
          Device code
        </span>
        <p class="text-xs leading-4 text-base-content/55">
          Open the verification page below and enter this code to approve the account.<span
            :if={@expires_at}
            id={"#{@id_prefix}-device-expires-at"}
            phx-hook="RelativeCountdown"
            data-countdown-at={DateTime.to_iso8601(@expires_at)}
            title={DateTimeDisplay.format_datetime(@expires_at, @datetime_preferences)}
          > It expires in <span data-role="relative-countdown-value">{countdown_label(@expires_at)}</span>.</span>
        </p>
        <div class="grid min-w-0 gap-2 rounded-box border border-base-300 bg-base-200/40 px-3 py-2">
          <div class="flex min-w-0 items-center gap-2">
            <p class="min-w-0 flex-1 break-all font-mono text-lg font-semibold tracking-wider text-base-content">
              {@user_code}
            </p>
            <AdminComponents.clipboard_button
              id={"#{@id_prefix}-device-code-copy"}
              copy_text={@user_code}
              label="Copy code"
              aria_label="Copy device code"
              class="btn btn-secondary btn-sm h-8 min-h-8 shrink-0 gap-1.5"
              icon_class="size-3.5"
            />
          </div>
          <p
            :if={@status}
            id={"#{@id_prefix}-status"}
            data-role="oauth-pending-status"
            role="status"
            class="flex items-center gap-1.5 border-t border-base-300/70 pt-2 text-xs font-medium leading-4 text-base-content/55"
          >
            <span class="loading loading-spinner loading-xs shrink-0 text-base-content/40"></span>
            <span>{@status}{device_recheck_suffix(@interval_seconds)}</span>
          </p>
        </div>
      </div>

      <div :if={@verification_uri} class="grid min-w-0 gap-2 border-t border-base-300 pt-4">
        <label
          for={"#{@id_prefix}-device-verification-url"}
          class="text-xs font-semibold uppercase tracking-wide text-base-content/60"
        >
          Verification page
        </label>
        <div class="grid min-w-0 items-stretch gap-2 sm:grid-cols-[minmax(0,1fr)_auto]">
          <input
            id={"#{@id_prefix}-device-verification-url"}
            type="url"
            value={@verification_uri}
            readonly
            aria-label="Device verification URL"
            class="input input-bordered h-8 min-h-8 w-full min-w-0 bg-base-200/60 px-2 font-mono text-xs"
          />
          <div class="flex min-w-0 items-stretch gap-2">
            <a
              id={"#{@id_prefix}-device-verification-open"}
              href={@verification_uri}
              target="_blank"
              rel="noopener noreferrer"
              class="btn btn-secondary btn-sm h-8 min-h-8 shrink-0 gap-1.5"
            >
              <.icon name="hero-arrow-top-right-on-square" class="size-3.5 shrink-0" />
              <span>Open</span>
            </a>
            <AdminComponents.clipboard_button
              id={"#{@id_prefix}-device-verification-url-copy"}
              copy_text={@verification_uri}
              label="Copy link"
              aria_label="Copy device verification URL"
              class="btn btn-secondary btn-sm h-8 min-h-8 shrink-0 gap-1.5"
              icon_class="size-3.5"
            />
          </div>
        </div>
      </div>

    </section>
    """
  end

  # Mirrors `formatRelativeCountdown` in `relative_countdown.mjs` so the server's
  # first paint and the hook's first repaint agree, and the label never jumps.
  # The hook keeps it honest from there; the absolute time stays on `title` for
  # when it matters exactly, or when the hook never runs.
  @minute 60
  @hour 60 * @minute
  @day 24 * @hour

  defp countdown_label(%DateTime{} = expires_at) do
    seconds = DateTime.diff(expires_at, DateTime.utc_now())

    cond do
      seconds <= 0 -> "due"
      seconds >= @day -> duration_parts([{div(seconds, @day), "d"}, {rem(div(seconds, @hour), 24), "h"}])
      seconds >= @hour -> hour_label(ceil(seconds / @minute))
      seconds >= @minute -> "#{ceil(seconds / @minute)}m"
      true -> "<1m"
    end
  end

  defp countdown_label(_expires_at), do: "due"

  defp hour_label(total_minutes),
    do: duration_parts([{div(total_minutes, 60), "h"}, {rem(total_minutes, 60), "m"}])

  defp duration_parts(parts) do
    parts
    |> Enum.filter(fn {value, _unit} -> value > 0 end)
    |> Enum.map_join(" ", fn {value, unit} -> "#{value}#{unit}" end)
  end

  # How often the poll re-checks is the one thing about this wait the operator
  # cannot work out from the screen, and the flow already carries it.
  defp device_recheck_suffix(seconds) when is_integer(seconds) and seconds > 0,
    do: ", rechecking every #{seconds}s"

  defp device_recheck_suffix(_seconds), do: ""

  @doc """
  Id of the callback form, so a dialog footer can submit it from outside.
  """
  @spec callback_form_id(String.t()) :: String.t()
  def callback_form_id(id_prefix), do: "#{id_prefix}-callback-form"

  @spec callback_submit_id(String.t()) :: String.t()
  def callback_submit_id(id_prefix), do: "#{id_prefix}-submit-callback"
end
