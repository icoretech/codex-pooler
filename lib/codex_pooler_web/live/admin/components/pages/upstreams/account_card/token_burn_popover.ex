defmodule CodexPoolerWeb.Admin.UpstreamPageComponents.AccountCard.TokenBurnPopover do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.Format

  attr :id, :string, required: true
  attr :content_id, :string, required: true
  attr :token_burn, :map, required: true

  def token_burn_popover(assigns) do
    ~H"""
    <span
      id={"#{@id}-popover"}
      data-role="upstream-token-burn-popover"
      data-usage-state={usage_state(@token_burn)}
      class="dropdown dropdown-end dropdown-bottom inline-flex justify-end"
    >
      <button
        id={@id}
        type="button"
        data-role="upstream-token-burn-trigger"
        data-usage-state={usage_state(@token_burn)}
        class="inline-flex cursor-pointer items-center justify-end gap-1 rounded px-1 text-xs font-medium text-base-content/70 transition-colors hover:bg-base-300/60 hover:text-base-content focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
        tabindex="0"
        aria-label={"Token burn calculation: #{@token_burn.title}"}
        aria-haspopup="true"
        aria-describedby={@content_id}
        title={@token_burn.title}
      >
        <.icon name={token_burn_icon_name(@token_burn)} class={token_burn_icon_class(@token_burn)} />
        <span>{@token_burn.label}</span>
      </button>
      <span
        id={@content_id}
        role="tooltip"
        tabindex="0"
        class="dropdown-content z-50 mt-2 w-72 overflow-hidden rounded-box border border-base-300 bg-base-100 text-left font-normal shadow-2xl"
      >
        <span class="grid gap-2 px-4 pb-3 pt-3.5">
          <span class="block font-mono text-[0.62rem] font-semibold uppercase tracking-[0.18em] text-primary">
            Token burn
          </span>
          <span class="block text-xs leading-5 text-base-content/60">
            Settled tokens from the last 5 minutes against the previous 1 hour baseline.
          </span>
          <span class="grid grid-cols-[auto_minmax(0,1fr)] gap-x-3 gap-y-1 text-xs leading-5">
            <span class="font-medium text-base-content/55">Last 5 minutes</span>
            <span class="text-right tabular-nums text-base-content">
              {token_burn_recent_token_label(@token_burn)}<span
                :if={recent_rate_label(@token_burn)}
                class="ml-1 text-[10.5px] text-base-content/50"
              >{recent_rate_label(@token_burn)}</span>
            </span>
            <span class="font-medium text-base-content/55">Previous 1 hour</span>
            <span class="text-right tabular-nums text-base-content">
              {token_burn_baseline_token_label(@token_burn)}<span
                :if={baseline_rate_label(@token_burn)}
                class="ml-1 text-[10.5px] text-base-content/50"
              >{baseline_rate_label(@token_burn)}</span>
            </span>
          </span>
        </span>
        <span class="flex min-h-9 items-center justify-between gap-3 border-t border-base-300 bg-base-200/60 px-4 py-1.5 text-[11px] leading-4 text-base-content/55">
          <span
            data-role="upstream-token-burn-state"
            data-usage-state={usage_state(@token_burn)}
          >
            {usage_state_label(@token_burn)}
          </span>
          <span
            :if={usage_state(@token_burn) in [:partial, :unknown]}
            data-role={missing_usage_role(@token_burn)}
            class="text-right font-semibold text-warning"
          >
            {missing_usage_label(@token_burn)}
          </span>
        </span>
      </span>
    </span>
    """
  end

  defp token_burn_recent_token_label(%{usage_state: :unknown}), do: "Usage unavailable"

  defp token_burn_recent_token_label(%{usage_state: :partial, recent_tokens: tokens})
       when is_integer(tokens) and tokens >= 0 do
    "#{Format.token_count(tokens)} confirmed tokens"
  end

  defp token_burn_recent_token_label(%{recent_tokens: tokens})
       when is_integer(tokens) and tokens >= 0 do
    "#{Format.token_count(tokens)} tokens"
  end

  defp token_burn_recent_token_label(_token_burn), do: "0 tokens"

  defp token_burn_baseline_token_label(%{baseline_tokens: tokens})
       when is_integer(tokens) and tokens >= 0 do
    "#{Format.token_count(tokens)} tokens"
  end

  defp token_burn_baseline_token_label(_token_burn), do: "0 tokens"

  defp usage_state(%{usage_state: usage_state})
       when usage_state in [:idle, :complete, :partial, :unknown],
       do: usage_state

  defp usage_state(_token_burn), do: :idle

  defp usage_state_label(%{usage_state: :idle}), do: "No recent usage"
  defp usage_state_label(%{usage_state: :complete}), do: "Usage complete"
  defp usage_state_label(%{usage_state: :partial}), do: "Usage partially reported"
  defp usage_state_label(%{usage_state: :unknown}), do: "Usage unavailable"
  defp usage_state_label(_token_burn), do: "No recent usage"

  defp missing_usage_label(%{unknown_request_count: 1}), do: "1 usage record missing"

  defp missing_usage_label(%{unknown_request_count: count}) when is_integer(count) and count > 1,
    do: "#{count} usage records missing"

  defp missing_usage_label(_token_burn), do: "Usage records missing"

  defp missing_usage_role(%{usage_state: :unknown}), do: "upstream-token-burn-usage-unavailable"
  defp missing_usage_role(_token_burn), do: "upstream-token-burn-missing-usage"

  defp recent_rate_label(%{usage_state: :unknown}), do: nil

  defp recent_rate_label(%{recent_tokens: tokens}) when is_integer(tokens) and tokens > 0,
    do: "#{Format.token_count(tokens / 5)}/min"

  defp recent_rate_label(_token_burn), do: nil

  defp baseline_rate_label(%{baseline_tokens: tokens}) when is_integer(tokens) and tokens > 0,
    do: "#{Format.token_count(tokens / 60)}/min"

  defp baseline_rate_label(_token_burn), do: nil

  defp token_burn_icon_name(%{usage_state: :unknown}), do: "hero-question-mark-circle"
  defp token_burn_icon_name(_token_burn), do: "hero-fire"

  defp token_burn_icon_class(%{level: 0}), do: "size-3.5 text-base-content/35"
  defp token_burn_icon_class(%{level: level}) when level in 1..2, do: "size-3.5 text-warning/70"
  defp token_burn_icon_class(%{level: level}) when level in 3..4, do: "size-3.5 text-warning"
  defp token_burn_icon_class(%{level: 5}), do: "size-3.5 text-error"
  defp token_burn_icon_class(%{usage_state: :unknown}), do: "size-3.5 text-warning/70"
  defp token_burn_icon_class(_token_burn), do: "size-3.5 text-base-content/35"
end
