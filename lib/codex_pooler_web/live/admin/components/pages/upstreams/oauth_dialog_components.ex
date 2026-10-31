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
  @spec method_doors(map()) :: Phoenix.LiveView.Rendered.t()
  def method_doors(assigns) do
    ~H"""
    <div class="grid gap-2" data-role="oauth-method-doors">
      <div class="grid gap-2 sm:grid-cols-2">
        <.method_door
          id={"#{@id_prefix}-browser-start"}
          event={@browser_event}
          icon="hero-arrow-top-right-on-square"
          label={gettext("via OAuth (browser)")}
          hint={
            if @active == :device,
              do: gettext("Switch to pasting a URL."),
              else: gettext("Approve in a tab, paste the URL back.")
          }
          active={@active == :browser}
          disabled={@disabled}
        />
        <.method_door
          id={"#{@id_prefix}-device-start"}
          event={@device_event}
          icon="hero-device-phone-mobile"
          label={gettext("via Device Code")}
          hint={
            if @active == :browser,
              do: gettext("Switch to a device code."),
              else: gettext("Approve elsewhere, nothing to paste.")
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

  @spec browser_authorization_step(map()) :: Phoenix.LiveView.Rendered.t()
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
      |> assign(:callback_demo_id, "#{assigns.id_prefix}-callback-demo")
      |> assign(:submit_id, "#{assigns.id_prefix}-submit-callback")

    ~H"""
    <section id={@root_id} data-role="oauth-browser-flow" class="grid gap-4">
      <div id={@authorization_step_id} data-role="oauth-authorization-step" class="grid min-w-0 gap-2">
        <label
          for={@authorization_url_id}
          class="text-xs font-semibold uppercase tracking-wide text-base-content/60"
        >
          {gettext("Authorization page")}
        </label>
        <div class="grid min-w-0 items-stretch gap-2 sm:grid-cols-[minmax(0,1fr)_auto]">
          <input
            id={@authorization_url_id}
            type="url"
            value={@authorization_url}
            readonly
            aria-label={gettext("OpenAI authorization URL")}
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
              <span>{gettext("Open")}</span>
            </a>
            <AdminComponents.clipboard_button
              id={@authorization_copy_id}
              copy_text={@authorization_url}
              label={gettext("Copy link")}
              aria_label={gettext("Copy OpenAI authorization URL")}
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
            {gettext("Callback URL")}
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
            {gettext("After OpenAI redirects, copy the full URL from the browser address bar and paste it here.")}
          </p>
          <.callback_paste_demo id={@callback_demo_id} />
        </div>
      </.form>
    </section>
    """
  end

  attr :id, :string, required: true

  @doc """
  The copy-then-paste move, drawn once so the step does not have to be read.

  The callback URL lands on a page that cannot load, which reads as a failure
  right when the operator has to do the one thing that finishes the link: take
  the URL out of the address bar and bring it back here. Prose says that in two
  sentences; this says it in one glance, and the dead page is drawn as part of
  the expected picture rather than left to look like the error it resembles.

  Inline SVG rather than a raster loop: it inherits the theme's own tokens in
  both themes, stays sharp at any density, and costs no request. The motion is
  instructional, not ambient — every moving part is a step of the instruction —
  and under `prefers-reduced-motion` the same drawing holds its finished frame,
  where the selection, the pasted value, and both key pills are already visible.
  """
  @spec callback_paste_demo(map()) :: Phoenix.LiveView.Rendered.t()
  def callback_paste_demo(assigns) do
    ~H"""
    <figure
      id={@id}
      data-role="oauth-callback-paste-demo"
      class="oauth-paste-demo rounded-box border border-base-300 bg-base-200/30 p-2"
    >
      <svg
        viewBox="0 0 352 126"
        role="img"
        aria-label={gettext("Select the callback URL in the browser address bar, copy it, then paste it into the callback URL field and press Complete link.")}
        focusable="false"
        class="block w-full"
      >
        <g class="opd-frame">
          <rect x="1" y="1" width="350" height="54" rx="8" class="opd-panel" />
          <circle cx="13" cy="15" r="2.2" class="opd-dot" />
          <circle cx="21" cy="15" r="2.2" class="opd-dot" />
          <circle cx="29" cy="15" r="2.2" class="opd-dot" />
          <rect x="38" y="8" width="306" height="14" rx="7" class="opd-omnibox" />
          <line x1="1" y1="29" x2="351" y2="29" class="opd-rule" />
          <text x="13" y="44" class="opd-body-text">{gettext("This page will not load — that is expected.")}</text>

          <path d="M176 58 L176 65 M172.6 62 L176 66 L179.4 62" class="opd-arrow" />

          <rect x="1" y="70" width="350" height="55" rx="8" class="opd-panel opd-panel--dialog" />
          <text x="13" y="83" class="opd-field-label">{gettext("CALLBACK URL")}</text>
          <rect x="12" y="89" width="250" height="17" rx="4" class="opd-input" />
          <rect x="270" y="89" width="70" height="17" rx="4" class="opd-submit" />
          <text x="305" y="100.5" class="opd-submit-label">{gettext("Complete link")}</text>
        </g>

        <g class="opd-play">
          <rect x="43.5" y="9" width="212" height="12" rx="2" class="opd-selection" />
          <text x="45" y="18.6" class="opd-url">localhost:1455/auth/callback?code=ac_…</text>
          <text x="19" y="100.6" class="opd-placeholder">https://…</text>
          <text x="19" y="100.6" class="opd-pasted">http://localhost:1455/auth/callback?code=ac_…</text>

          <g class="opd-chip">
            <rect x="43.5" y="9" width="212" height="12" rx="3" class="opd-chip-body" />
            <text x="45" y="18.6" class="opd-chip-text">localhost:1455/auth/callback?code=ac_…</text>
          </g>

          <g class="opd-pill opd-pill--copy">
            <rect x="0" y="0" width="47" height="14" rx="7" class="opd-pill-body" />
            <rect x="7" y="4" width="5.4" height="6.4" rx="1.4" class="opd-pill-glyph" />
            <rect x="9.6" y="3.4" width="5.4" height="6.4" rx="1.4" class="opd-pill-glyph" />
            <text x="19" y="9.9" class="opd-pill-text">{gettext("Copy")}</text>
          </g>

          <g class="opd-pill opd-pill--paste">
            <rect x="0" y="0" width="50" height="14" rx="7" class="opd-pill-body" />
            <rect x="7" y="3.4" width="5.4" height="6.4" rx="1.4" class="opd-pill-glyph" />
            <rect x="9.6" y="4" width="5.4" height="6.4" rx="1.4" class="opd-pill-glyph" />
            <text x="19" y="9.9" class="opd-pill-text">{gettext("Paste")}</text>
          </g>

          <path
            d="M0 0 L0 11.4 L2.7 8.9 L4.5 12.4 L6.3 11.5 L4.6 8.1 L8 8.1 Z"
            class="opd-cursor"
          />
        </g>
      </svg>
    </figure>
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
  @spec device_authorization_step(map()) :: Phoenix.LiveView.Rendered.t()
  def device_authorization_step(assigns) do
    ~H"""
    <section id={"#{@id_prefix}-device-code"} data-role="oauth-device-flow" class="grid gap-4">
      <div class="grid min-w-0 gap-2">
        <span class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
          {gettext("Device code")}
        </span>
        <p class="text-xs leading-4 text-base-content/55">
          {gettext("Open the verification page below and enter this code to approve the account.")}<span
            :if={@expires_at}
            id={"#{@id_prefix}-device-expires-at"}
            phx-hook="RelativeCountdown"
            data-countdown-at={DateTime.to_iso8601(@expires_at)}
            title={DateTimeDisplay.format_datetime(@expires_at, @datetime_preferences)}
            data-countdown-label={gettext("It expires in %{duration}.", duration: "%{duration}")}
            data-countdown-due-label={gettext("due")}
          >{" "}<span data-role="relative-countdown-value" class="font-semibold text-base-content/75">{gettext("It expires in %{duration}.", duration: countdown_label(@expires_at))}</span></span>
        </p>
        <div class="grid min-w-0 gap-2 rounded-box border border-base-300 bg-base-200/40 px-3 py-2">
          <div class="flex min-w-0 items-center gap-2">
            <p class="min-w-0 flex-1 break-all font-mono text-lg font-semibold tracking-wider text-base-content">
              {@user_code}
            </p>
            <AdminComponents.clipboard_button
              id={"#{@id_prefix}-device-code-copy"}
              copy_text={@user_code}
              label={gettext("Copy code")}
              aria_label={gettext("Copy device code")}
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
            <span>{device_status_label(@status, @interval_seconds)}</span>
          </p>
        </div>
      </div>

      <div :if={@verification_uri} class="grid min-w-0 gap-2 border-t border-base-300 pt-4">
        <label
          for={"#{@id_prefix}-device-verification-url"}
          class="text-xs font-semibold uppercase tracking-wide text-base-content/60"
        >
          {gettext("Verification page")}
        </label>
        <div class="grid min-w-0 items-stretch gap-2 sm:grid-cols-[minmax(0,1fr)_auto]">
          <input
            id={"#{@id_prefix}-device-verification-url"}
            type="url"
            value={@verification_uri}
            readonly
            aria-label={gettext("Device verification URL")}
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
              <span>{gettext("Open")}</span>
            </a>
            <AdminComponents.clipboard_button
              id={"#{@id_prefix}-device-verification-url-copy"}
              copy_text={@verification_uri}
              label={gettext("Copy link")}
              aria_label={gettext("Copy device verification URL")}
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
      seconds <= 0 ->
        gettext("due")

      seconds >= @day ->
        duration_parts([{div(seconds, @day), "d"}, {rem(div(seconds, @hour), 24), "h"}])

      seconds >= @hour ->
        hour_label(ceil(seconds / @minute))

      seconds >= @minute ->
        "#{ceil(seconds / @minute)}m"

      true ->
        "<1m"
    end
  end

  defp countdown_label(_expires_at), do: gettext("due")

  defp hour_label(total_minutes),
    do: duration_parts([{div(total_minutes, 60), "h"}, {rem(total_minutes, 60), "m"}])

  defp duration_parts(parts) do
    parts
    |> Enum.filter(fn {value, _unit} -> value > 0 end)
    |> Enum.map_join(" ", fn {value, unit} -> "#{value}#{unit}" end)
  end

  # How often the poll re-checks is the one thing about this wait the operator
  # cannot work out from the screen, and the flow already carries it.
  defp device_status_label(status, seconds) when is_integer(seconds) and seconds > 0,
    do: gettext("%{status}, rechecking every %{seconds}s", status: status, seconds: seconds)

  defp device_status_label(status, _seconds), do: status

  @doc """
  Id of the callback form, so a dialog footer can submit it from outside.
  """
  @spec callback_form_id(String.t()) :: String.t()
  def callback_form_id(id_prefix), do: "#{id_prefix}-callback-form"

  @spec callback_submit_id(String.t()) :: String.t()
  def callback_submit_id(id_prefix), do: "#{id_prefix}-submit-callback"
end
