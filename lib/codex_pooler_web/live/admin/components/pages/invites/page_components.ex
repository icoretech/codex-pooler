defmodule CodexPoolerWeb.Admin.InvitesPageComponents do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.BadgeComponents, as: AdminBadges
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.DateTimeDisplay
  alias Phoenix.LiveView.JS

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :field_name, :string, required: true
  attr :hidden_id, :string, required: true
  attr :role, :string, required: true
  attr :event, :string, required: true
  attr :value_attr, :atom, required: true
  attr :selected_value, :string, required: true
  attr :options, :list, required: true

  def invite_filter_dropdown(assigns) do
    assigns =
      assign(assigns,
        selected: selected_filter_option(assigns.options, assigns.selected_value)
      )

    ~H"""
    <div class="grid gap-2">
      <input
        type="hidden"
        id={@hidden_id}
        name={"filters[#{@field_name}]"}
        value={@selected_value}
      />
      <details
        id={@id}
        class="dropdown w-full"
        phx-click-away={JS.remove_attribute("open", to: "##{@id}")}
      >
        <summary
          data-role={"#{@role}-trigger"}
          aria-label={@label}
          class="select select-bordered flex min-h-10 w-full cursor-pointer items-center gap-2 pr-8 text-left text-sm font-normal"
        >
          <.icon name={@selected.icon} class={["size-4 shrink-0", option_icon_class(@selected)]} />
          <span class="truncate">{@selected.label}</span>
        </summary>
        <ul
          data-role={"#{@role}-menu"}
          class="menu dropdown-content z-[60] mt-1 max-h-80 w-full flex-nowrap overflow-y-auto rounded-box border border-base-300 bg-base-100 p-1 !transition-none ![scale:100%] shadow-xl"
        >
          <li :for={option <- @options}>
            <button
              type="button"
              phx-click={@event}
              phx-value-pool-id={filter_option_value(@value_attr, :pool_id, option)}
              phx-value-status={filter_option_value(@value_attr, :status, option)}
              data-role={"#{@role}-option"}
              data-pool-id={filter_option_value(@value_attr, :pool_id, option)}
              data-status={filter_option_value(@value_attr, :status, option)}
              class={[
                "flex items-center gap-2 text-sm",
                option.value == @selected_value && "active"
              ]}
              aria-current={option.value == @selected_value && "true"}
            >
              <.icon name={option.icon} class={["size-4 shrink-0", option_icon_class(option)]} />
              <span class="truncate">{option.label}</span>
            </button>
          </li>
        </ul>
      </details>
    </div>
    """
  end

  attr :invites, :map, required: true
  attr :mailer_configured?, :boolean, required: true
  attr :datetime_preferences, :map, required: true

  def invites_table(assigns) do
    ~H"""
    <AdminComponents.empty_state
      :if={@invites.items == []}
      id="invite-empty-state"
      icon="hero-envelope"
      title="No Pool invites"
      description="No invites match the current filters."
    />

    <div
      :if={@invites.items != []}
      id="invite-table-surface"
      class="min-w-0 overflow-visible rounded-box border border-base-300 bg-base-100 shadow-sm"
    >
      <div
        id="invite-table-scroll-region"
        class="overflow-x-auto"
      >
        <table id="invite-table" class="table w-full min-w-[74rem] table-fixed">
          <colgroup>
            <col class="w-32" />
            <col class="w-24" />
            <col class="w-32" />
            <col class="w-48" />
            <col class="w-44" />
            <col class="w-16" />
            <col class="w-56" />
            <col class="w-24" />
            <col class="w-20" />
          </colgroup>
          <thead>
            <tr>
              <th>Created</th>
              <th class="w-24 text-center">Status</th>
              <th>Pool</th>
              <th>Codex account email</th>
              <th>Invited by</th>
              <th class="text-center">Email</th>
              <th>Result</th>
              <th class="text-center">Expires</th>
              <th class="text-right">Actions</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={invite <- @invites.items}
              id={"invite-row-#{invite.id}"}
              class="text-sm transition-colors hover:bg-base-200/80"
            >
              <td class="truncate whitespace-nowrap text-xs text-base-content/70">
                {datetime_label(invite.created_at, @datetime_preferences)}
              </td>
              <td class="w-24 text-center">
                <span id={"invite-status-#{invite.id}"} class={status_badge_class(invite.status)}>
                  {status_label(invite.status)}
                </span>
              </td>
              <td class="min-w-44">
                <div class="grid min-w-0 gap-0.5">
                  <span class="truncate font-semibold text-base-content">{invite.pool_name}</span>
                </div>
              </td>
              <td class="truncate font-semibold text-primary">{invite.invited_email}</td>
              <td class="truncate text-base-content/70">{invite.inviter_email}</td>
              <td class="text-center">
                <span
                  id={"invite-email-sent-#{invite.id}"}
                  class={email_sent_class(invite.email_sent_at)}
                  title={email_sent_label(invite.email_sent_at)}
                  aria-label={email_sent_label(invite.email_sent_at)}
                >
                  <.icon name={email_sent_icon(invite.email_sent_at)} class="size-4" />
                  <span class="sr-only">{email_sent_label(invite.email_sent_at)}</span>
                </span>
              </td>
              <td>
                <div class="grid min-w-0 gap-0.5 text-xs text-base-content/65">
                  <span class="truncate">{result_label(invite, @datetime_preferences)}</span>
                  <span
                    :if={invite.accepted_by_email}
                    class="truncate font-semibold text-base-content"
                  >
                    {invite.accepted_by_email}
                  </span>
                </div>
              </td>
              <td
                id={"invite-expires-#{invite.id}"}
                class="whitespace-nowrap text-center text-xs text-base-content/70"
                title={datetime_label(invite.expires_at, @datetime_preferences)}
              >
                {expiry_label(invite.expires_at)}
              </td>
              <td class="text-right">
                <.invite_actions_menu
                  :if={invite.status == "active"}
                  invite={invite}
                  mailer_configured?={@mailer_configured?}
                />
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  attr :invite, :map, required: true
  attr :mailer_configured?, :boolean, required: true

  def invite_actions_menu(assigns) do
    ~H"""
    <div class="dropdown dropdown-end inline-block">
      <button
        id={"invite-actions-menu-#{@invite.id}"}
        type="button"
        class="btn btn-ghost btn-sm btn-square"
        tabindex="0"
        aria-label={"Actions for invite to #{@invite.invited_email}"}
      >
        <.icon name="hero-ellipsis-vertical" class="size-5" />
      </button>
      <ul
        tabindex="0"
        class="menu dropdown-content z-20 mt-2 w-56 rounded-box border border-base-300 bg-base-100 p-2 shadow-xl"
      >
        <li>
          <AdminComponents.dropdown_action_item
            id={"invite-reissue-#{@invite.id}"}
            icon="hero-paper-airplane"
            label="Reissue"
            variant={:positive}
            phx-click="reissue_invite"
            phx-value-id={@invite.id}
            disabled={@invite.status != "active" || !@mailer_configured?}
            title={reissue_title(@invite, @mailer_configured?)}
          />
        </li>
        <li>
          <AdminComponents.dropdown_action_item
            id={"invite-revoke-open-#{@invite.id}"}
            icon="hero-no-symbol"
            label="Revoke"
            variant={:danger}
            phx-click="open_revoke_invite"
            phx-value-id={@invite.id}
            disabled={@invite.status != "active"}
          />
        </li>
      </ul>
    </div>
    """
  end

  attr :invite, :map, default: nil

  def invite_revoke_dialog(assigns) do
    ~H"""
    <dialog :if={@invite} id="invite-revoke-dialog" class="modal" open>
      <div class="modal-box max-w-xl rounded-box border border-base-300 bg-base-100 p-0 shadow-2xl">
        <div class="grid gap-2 px-5 py-4">
          <p class="text-xs font-semibold uppercase tracking-wide text-primary">Pool onboarding</p>
          <h2 class="text-xl font-semibold text-base-content">Revoke Pool invite</h2>
          <p class="text-sm text-base-content/70">
            Revoke the active invite for <span class="font-semibold text-base-content">
              {@invite.invited_email}
            </span>.
          </p>
        </div>

        <div class="border-t border-base-300 px-5 py-4">
          <div class="alert border-error/20 bg-error/10 text-error">
            <.icon name="hero-no-symbol" class="size-5" />
            <span>
              The existing invite URL will stop working immediately. Existing upstream accounts are not affected.
            </span>
          </div>
        </div>

        <AdminComponents.dialog_footer
          id="invite-revoke-dialog-footer"
          class="modal-action mt-0 w-full border-t border-base-300 bg-base-200/80 px-5 py-4"
        >
          <:actions>
            <button
              id="invite-revoke-cancel"
              type="button"
              class="btn btn-secondary btn-sm gap-2"
              phx-click="cancel_revoke_invite"
            >
              <.icon name="hero-x-mark" class="size-4" />
              <span>Cancel</span>
            </button>
            <button
              id="invite-revoke-confirm"
              type="button"
              class="btn btn-error btn-sm gap-2"
              phx-click="confirm_revoke_invite"
              phx-value-id={@invite.id}
            >
              <.icon name="hero-no-symbol" class="size-4" />
              <span>Revoke invite</span>
            </button>
          </:actions>
        </AdminComponents.dialog_footer>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button type="button" phx-click="cancel_revoke_invite">close</button>
      </form>
    </dialog>
    """
  end

  defp selected_filter_option(options, value),
    do: Enum.find(options, &(&1.value == (value || ""))) || List.first(options)

  defp filter_option_value(current_attr, target_attr, option) when current_attr == target_attr,
    do: option.value

  defp filter_option_value(_current_attr, _target_attr, _option), do: nil

  defp option_icon_class(%{tone: :primary}), do: "text-primary"
  defp option_icon_class(%{tone: :success}), do: "text-success"
  defp option_icon_class(%{tone: :warning}), do: "text-warning"
  defp option_icon_class(%{tone: :error}), do: "text-error"
  defp option_icon_class(_option), do: "text-base-content/60"

  defp reissue_title(%{status: status}, _mailer_configured?) when status != "active",
    do: "Only active invites can be reissued"

  defp reissue_title(_invite, false), do: "SMTP is not configured"
  defp reissue_title(_invite, true), do: "Reissue invite email"

  defp status_badge_class(status), do: AdminBadges.status_chip_class(status)

  defp status_label("active"), do: "active"
  defp status_label("accepted"), do: "accepted"
  defp status_label("expired"), do: "expired"
  defp status_label("revoked"), do: "revoked"
  defp status_label(status), do: status

  defp result_label(%{status: "accepted", accepted_at: accepted_at}, datetime_preferences),
    do: "Accepted #{datetime_label(accepted_at, datetime_preferences)}"

  defp result_label(%{status: "revoked", revoked_at: revoked_at}, datetime_preferences),
    do: "Revoked #{datetime_label(revoked_at, datetime_preferences)}"

  defp result_label(%{status: "expired"}, _datetime_preferences), do: "Expired"

  defp result_label(_invite, _datetime_preferences), do: "Awaiting acceptance"

  defp email_sent_icon(%DateTime{}), do: "hero-check-circle"
  defp email_sent_icon(_email_sent_at), do: "hero-minus-circle"

  defp email_sent_class(%DateTime{}), do: "inline-flex justify-center text-success"
  defp email_sent_class(_email_sent_at), do: "inline-flex justify-center text-base-content/35"

  defp email_sent_label(%DateTime{}), do: "Invite email sent"
  defp email_sent_label(_email_sent_at), do: "Invite email not sent"

  defp datetime_label(nil, _datetime_preferences), do: "-"

  defp datetime_label(%DateTime{} = datetime, datetime_preferences) do
    DateTimeDisplay.format_datetime(datetime, datetime_preferences)
  end

  defp expiry_label(nil), do: "No expiry"

  defp expiry_label(%DateTime{} = datetime) do
    diff_seconds = DateTime.diff(datetime, DateTime.utc_now(), :second)

    cond do
      diff_seconds <= 0 ->
        "Expired"

      diff_seconds < 60 ->
        "in <1 minute"

      diff_seconds < 3_600 ->
        relative_minutes(diff_seconds)

      diff_seconds < 86_400 ->
        pluralized_relative_time("hour", ceil(diff_seconds / 3_600))

      true ->
        pluralized_relative_time("day", ceil(diff_seconds / 86_400))
    end
  end

  defp pluralized_relative_time(unit, count) do
    suffix = if count == 1, do: unit, else: unit <> "s"
    "in #{count} #{suffix}"
  end

  defp relative_minutes(diff_seconds) do
    minutes = ceil(diff_seconds / 60)

    if minutes == 60 do
      pluralized_relative_time("hour", 1)
    else
      pluralized_relative_time("minute", minutes)
    end
  end
end
