defmodule CodexPoolerWeb.Admin.UpstreamPageComponents.UsagePollPause do
  @moduledoc false

  use CodexPoolerWeb, :html

  attr :id_prefix, :string, required: true
  attr :pause, :map, default: nil

  @spec usage_poll_pause(map()) :: Phoenix.LiveView.Rendered.t()
  def usage_poll_pause(assigns) do
    assigns = assign(assigns, :heading, assigns.pause && gettext("Usage polling paused until %{time}", time: assigns.pause.paused_until_label))

    ~H"""
    <section
      :if={@pause}
      id={"#{@id_prefix}-usage-poll-pause"}
      data-role="upstream-usage-poll-pause"
      data-paused-until={DateTime.to_iso8601(@pause.paused_until)}
      data-status-code={@pause.status_code}
      class="grid min-w-0 gap-1 rounded-box border border-warning/40 bg-warning/5 px-3 py-2.5 text-sm"
    >
      <div class="flex min-w-0 items-center gap-2">
        <span class="size-2 shrink-0 rounded-full bg-warning ring-[3px] ring-warning/15" aria-hidden="true"></span>
        <%!-- Below `sm` the heading wraps so the whole deadline shows; from `sm` it truncates as before, and the title carries the full text. --%>
        <h3 id={"#{@id_prefix}-usage-poll-pause-title"} title={@heading} class="min-w-0 flex-1 font-semibold text-base-content sm:truncate">
          {@heading}
        </h3>
        <span id={"#{@id_prefix}-usage-poll-pause-remaining"} phx-hook="RelativeCountdown" data-countdown-at={DateTime.to_iso8601(@pause.paused_until)} data-countdown-due-label={gettext("due")} class="shrink-0 text-xs text-base-content/55">
          <span data-role="relative-countdown-value">{@pause.remaining_label}</span>
        </span>
      </div>
      <p id={"#{@id_prefix}-usage-poll-pause-origin"} class="text-xs text-base-content/70">
        {gettext("The provider answered a usage read with %{origin}. Quota and saved-reset reads for this account resume on their own at that time. The provider throttles the account, so refreshing, re-importing or reactivating its credentials does not end the pause; until then routing uses its quota evidence only while that evidence stays fresh.", origin: @pause.origin_label)}
      </p>
      <p
        :if={@pause.origin_count > 1}
        id={"#{@id_prefix}-usage-poll-pause-origin-count"}
        class="text-xs text-base-content/55"
      >
        {ngettext("Paused on %{count} usage host; the latest deadline is shown.", "Paused on %{count} usage hosts; the latest deadline is shown.", @pause.origin_count)}
      </p>
    </section>
    """
  end
end
