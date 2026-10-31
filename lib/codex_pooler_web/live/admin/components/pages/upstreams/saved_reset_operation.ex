defmodule CodexPoolerWeb.Admin.UpstreamPageComponents.SavedResetOperation do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.Components
  alias Phoenix.LiveView.JS

  @surfaces [:list, :bank, :cockpit]
  @outcomes [:applied, :not_applied, :unknown, :not_recorded]
  @verifications [:not_started, :pending, :candidate, :quota_confirmed, :request_verified, :reblocked, :expired, :unknown]
  defp timestamps do
    [started_at: gettext("Started"), consumed_at: gettext("Consumed"), finished_at: gettext("Finished"), deadline_at: gettext("Deadline"), last_checked_at: gettext("Checked"), pause_until: gettext("Checks paused until")]
  end

  attr :identity_id, :string, required: true
  attr :surface, :atom, required: true, values: @surfaces
  attr :operation, :map, required: true
  attr :refreshing, :boolean, default: false
  attr :status_view_disabled, :boolean, default: false

  @spec saved_reset_operation(map()) :: Phoenix.LiveView.Rendered.t()
  def saved_reset_operation(assigns) do
    validate_surface!(assigns.surface)
    operation = assigns.operation
    prefix = "saved-reset-operation-#{assigns.surface}-#{assigns.identity_id}"

    assigns =
      assigns
      |> assign(:id, prefix)
      |> assign(:heading_id, "saved-reset-operation-heading-#{assigns.surface}-#{assigns.identity_id}")
      |> assign(:refresh_id, "saved-reset-status-refresh-#{assigns.surface}-#{assigns.identity_id}")
      |> assign(:visible?, if(assigns.surface == :list, do: list_visible?(operation), else: operation.refreshable? || operation.show_latest_receipt?))
      |> assign(:detail_open?, list_visible?(operation))
      |> assign(:compact_headline, operation.compact_headline)
      |> assign(:provider_outcome, bounded_state(operation.provider_outcome, @outcomes, :unknown))
      |> assign(:verification, bounded_state(operation.verification, @verifications, :unknown))
      |> assign(:timestamps, timestamp_facts(operation, timestamps()))
      |> assign(:request_times, timestamp_facts(operation.request, requested_at: gettext("Requested"), scheduled_at: gettext("Scheduled")))
      |> assign(:announcement, announcement(operation))
      |> assign(:two_facts?, operation.show_request? and operation.show_latest_receipt?)

    ~H"""
    <section
      :if={@visible? && @surface == :list}
      id={@id}
      aria-labelledby={@heading_id}
      aria-describedby={"#{@id}-summary"}
      data-role="saved-reset-operation"
      data-presentation="compact"
      data-provider-outcome={@provider_outcome}
      data-verification-state={@verification}
      class="flex min-w-0 flex-wrap items-center justify-between gap-2 py-1 text-xs leading-5 text-base-content/70"
    >
      <h3 id={@heading_id} class="sr-only">{gettext("Saved reset status")}</h3>
      <p id={"#{@id}-summary"} data-role="saved-reset-headline" role="status" aria-live="polite" aria-atomic="true" class="min-w-0 break-words font-medium">
        <span data-role={if @operation.request.state in [:queued, :processing], do: "saved-reset-request"}>{@compact_headline}</span>
      </p>
      <button
        id={"saved-reset-view-status-list-#{@identity_id}"}
        type="button"
        data-role="saved-reset-view-status"
        data-saved-reset-action="view-status"
        data-server-disabled={to_string(@status_view_disabled)}
        class="btn btn-ghost btn-sm shrink-0 text-base-content/60 hover:text-base-content"
        phx-click={JS.push_focus() |> JS.push("open_saved_reset_policy")}
        phx-value-id={@identity_id}
        aria-controls="saved-reset-policy-dialog"
        aria-haspopup="dialog"
        disabled={@status_view_disabled}
      >{gettext("View status")}</button>
    </section>
    <details :if={@visible? && @surface != :list} id={"#{@id}-details"} data-preserve-open open={@detail_open?} class="min-w-0 text-xs leading-5 text-base-content/70">
      <summary id={@heading_id} class="cursor-pointer font-medium text-base-content">{gettext("Saved reset · %{headline}", headline: @compact_headline)}</summary>
      <section
        id={@id}
        aria-labelledby={@heading_id}
        aria-describedby={"#{@id}-summary"}
        data-role="saved-reset-operation"
        data-provider-outcome={@provider_outcome}
        data-verification-state={@verification}
        class="mt-2 grid min-w-0 gap-2 rounded-box border border-base-300 bg-base-200/45 px-3 py-2 text-xs leading-5 text-base-content/70"
      >
        <span id={"#{@id}-announcement"} role="status" aria-live="polite" aria-atomic="true" class="sr-only">{@announcement}</span>
        <div class="flex min-w-0 items-start justify-between gap-2">
          <div class="grid min-w-0 gap-2">
            <div :if={@operation.show_request?} data-role="saved-reset-request" class="grid min-w-0 gap-0.5">
              <p :if={@two_facts?} class="font-semibold text-base-content">{gettext("Request")}</p>
              <p :if={@two_facts?} class="font-medium">{@operation.request.headline}</p>
              <p :if={@operation.request.summary}>{@operation.request.summary}</p>
              <.timestamp_facts :if={@request_times != []} facts={@request_times} />
            </div>
            <div :if={@operation.show_latest_receipt?} data-role="saved-reset-latest" class="grid min-w-0 gap-0.5">
              <p :if={@two_facts?} class="font-semibold text-base-content">{gettext("Latest reset")}</p>
              <p :if={@two_facts? || @operation.headline != @compact_headline} data-role="saved-reset-headline" class="font-medium">{@operation.headline}</p>
              <p :if={@operation.summary}>{@operation.summary}</p>
              <p :if={@operation.detail} data-role="saved-reset-provider-outcome">{@operation.detail}</p>
            </div>
            <div :if={!@operation.show_latest_receipt? && @operation.headline != @operation.request.headline} data-role="saved-reset-observation" class="grid min-w-0 gap-0.5">
              <p :if={@operation.headline != @compact_headline} class="font-medium">{@operation.headline}</p>
              <p :if={@operation.summary}>{@operation.summary}</p>
            </div>
          </div>
          <button
            :if={@operation.refreshable?}
            id={@refresh_id}
            type="button"
            class="btn btn-ghost btn-xs shrink-0 gap-1 text-base-content/60 hover:text-base-content"
            phx-click="refresh_saved_reset_status"
            phx-value-id={@identity_id}
            disabled={@refreshing}
            title={gettext("Reads the recorded status. It does not contact the provider or start another redemption.")}
            data-saved-reset-action="status-refresh"
            data-server-disabled={to_string(@refreshing)}
            aria-describedby={"#{@id}-refresh-description"}
          >
            <.icon name="hero-arrow-path" class="size-3.5" />
            <span>{gettext("Refresh")}</span>
          </button>
        </div>
        <p id={"#{@id}-summary"} class="sr-only">{gettext("Request status and the latest account reset are separate recorded facts.")}</p>
        <.timestamp_facts :if={@timestamps != []} facts={@timestamps} />
        <%!-- The reason is visible while the account cannot route, when the
        operator needs it; a routing account keeps it for assistive tech. --%>
        <p :if={@operation.serving_readiness && @surface != :cockpit} data-role="saved-reset-serving-readiness" title={@operation.serving_readiness.reason} class="text-[11px] text-base-content/60">
          <span class="font-medium text-base-content/75">{gettext("Routing: %{status}", status: @operation.serving_readiness.label)}</span>
          <span class={if(@operation.serving_readiness.routing_ready_now?, do: "sr-only", else: "block")} data-role="saved-reset-serving-reason">{@operation.serving_readiness.reason}</span>
        </p>
        <p :if={@operation.refreshable?} id={"#{@id}-refresh-description"} class="sr-only">{gettext("Refresh reads the recorded status. It does not contact the provider or start another redemption.")}</p>
      </section>
    </details>
    """
  end

  @spec list_visible?(map()) :: boolean()
  def list_visible?(operation) do
    ready? = match?(%{routing_ready_now?: true}, operation.serving_readiness)
    accepted? = operation.verification in [:quota_confirmed, :request_verified]

    cond do
      operation.request.state in [:queued, :processing] -> true
      accepted? and ready? -> false
      operation.active? -> true
      operation.unresolved? and not accepted? -> true
      operation.verification in [:reblocked, :expired] -> not ready?
      true -> false
    end
  end

  attr :id, :string, required: true
  attr :in_flight, :boolean, default: false
  attr :class, :any, default: nil

  # Shown by the SavedResetConnection hook while the socket is down. It repeats the receipt's disconnected copy, and
  # says the reset continues only when the page shows an operation that is still open (`open?`). A surface whose
  # container has no padding of its own (the bank dialog's panel) passes the gutter it needs in `class`.
  @spec saved_reset_connection_notice(map()) :: Phoenix.LiveView.Rendered.t()
  def saved_reset_connection_notice(assigns) do
    assigns = assign(assigns, :text, if(assigns.in_flight, do: gettext("Live updates disconnected. The reset continues. Reconnect to see the latest status before acting."), else: gettext("Live updates disconnected. Reconnect to see the latest status before acting.")))

    ~H"""
    <p id={@id} data-saved-reset-connection-notice hidden role="status" aria-live="polite" class={["text-xs leading-5 text-base-content/70", @class]}>{@text}</p>
    """
  end

  attr :identity_id, :string, required: true
  attr :surface, :atom, required: true, values: @surfaces
  attr :id, :string, default: nil
  attr :confirm_id, :string, default: nil
  attr :cancel_id, :string, default: nil
  attr :confirm_event, :any, default: "redeem_saved_reset"
  attr :cancel_event, :any, default: "cancel_saved_reset_redemption"
  attr :disabled, :boolean, default: false

  @spec saved_reset_confirmation(map()) :: Phoenix.LiveView.Rendered.t()
  def saved_reset_confirmation(assigns) do
    validate_surface!(assigns.surface)
    id = assigns.id || "saved-reset-redemption-confirmation-#{assigns.surface}-#{assigns.identity_id}"

    assigns =
      assigns
      |> assign(:id, id)
      |> assign(:confirm_id, assigns.confirm_id || "#{id}-confirm")
      |> assign(:cancel_id, assigns.cancel_id || "#{id}-cancel")
      |> assign(:copy, gettext("Redeem one saved reset for this account? The provider may apply it before quota checks finish. Verification can take a few minutes. You can leave this view and return to check the status."))

    ~H"""
    <div id={@id} data-role="saved-reset-redemption-confirmation" class="grid min-w-0 gap-2 rounded-box border border-base-300 bg-base-200/45 px-3 py-2">
      <p id={"#{@id}-description"} class="text-xs leading-5 text-base-content/75">{@copy}</p>
      <div class="flex flex-wrap items-center gap-2">
        <Components.action_button id={@confirm_id} label={gettext("Redeem one reset")} icon="hero-check" variant={:primary} phx-click={@confirm_event} phx-value-id={@identity_id} phx-disable-with={gettext("Requesting...")} disabled={@disabled} data-saved-reset-action="confirm-redemption" data-server-disabled={to_string(@disabled)} aria-describedby={"#{@id}-description"} />
        <Components.action_button id={@cancel_id} label={gettext("Keep resets in bank")} variant={:ghost} phx-click={@cancel_event} />
      </div>
    </div>
    """
  end

  attr :facts, :list, required: true

  defp timestamp_facts(assigns) do
    ~H"""
    <dl class="flex min-w-0 flex-wrap gap-x-4 gap-y-0.5 text-[11px] text-base-content/60">
      <div :for={fact <- @facts} class="flex min-w-0 gap-1">
        <dt>{fact.label}</dt>
        <dd data-role={fact.role} class="break-words tabular-nums text-base-content/75">{fact.value}</dd>
      </div>
    </dl>
    """
  end

  defp timestamp_facts(operation, fields) do
    Enum.flat_map(fields, fn {key, label} ->
      case Map.get(operation, key) do
        value when is_binary(value) and value != "" -> [%{label: label, value: value, role: "saved-reset-#{key |> Atom.to_string() |> String.replace("_", "-")}"}]
        _absent -> []
      end
    end)
  end

  defp announcement(operation) do
    case Enum.uniq(Enum.filter([if(operation.show_request?, do: operation.request.headline), operation.headline], &is_binary/1)) do
      [request, reset] -> gettext("%{request}. %{reset}", request: request, reset: reset)
      [headline] -> headline
      [] -> ""
    end
  end

  defp bounded_state(state, allowed, fallback), do: if(state in allowed, do: state, else: fallback)

  defp validate_surface!(surface) when surface in @surfaces, do: :ok
  defp validate_surface!(_surface), do: raise(ArgumentError, "saved reset surface must be list, bank or cockpit")
end
