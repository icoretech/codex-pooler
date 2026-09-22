defmodule CodexPoolerWeb.Admin.UpstreamPageComponents.UsagePollPause do
  @moduledoc false

  use CodexPoolerWeb, :html

  attr :id_prefix, :string, required: true
  attr :pause, :map, default: nil

  def usage_poll_pause(assigns) do
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
        <h3 id={"#{@id_prefix}-usage-poll-pause-title"} class="min-w-0 flex-1 truncate font-semibold text-base-content">
          Usage polling paused until {@pause.paused_until_label}
        </h3>
        <span id={"#{@id_prefix}-usage-poll-pause-remaining"} class="shrink-0 text-xs text-base-content/55">
          {@pause.remaining_label}
        </span>
      </div>
      <p id={"#{@id_prefix}-usage-poll-pause-origin"} class="text-xs text-base-content/70">
        The provider answered a usage read with {@pause.origin_label}.
        Quota and saved-reset reads for this account resume on their own at that time.
        The provider throttles the account, so refreshing, re-importing or reactivating
        its credentials does not end the pause; until then routing uses its quota
        evidence only while that evidence stays fresh.
      </p>
      <p
        :if={@pause.origin_count > 1}
        id={"#{@id_prefix}-usage-poll-pause-origin-count"}
        class="text-xs text-base-content/55"
      >
        Paused on {@pause.origin_count} usage hosts; the latest deadline is shown.
      </p>
    </section>
    """
  end
end
