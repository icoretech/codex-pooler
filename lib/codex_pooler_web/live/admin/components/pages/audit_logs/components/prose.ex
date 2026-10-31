defmodule CodexPoolerWeb.Admin.AuditLogsComponents.Prose do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.AuditLogsComponents.Presentation
  alias CodexPoolerWeb.DateTimeDisplay

  # Sentinels split the translated plain-text sentence into semantic slots. Only
  # application-owned markers are parsed; untrusted values are rendered afterward.
  @sentence_marker ~r/\x{E000}(?:actor|operator|pool|scoped_pool|target|email|status|role|ip|failure|reason)\x{E001}/u

  defp marker(kind), do: "\uE000#{kind}\uE001"

  defp sentence_parts(event) do
    case sentence_template(event.action, event) do
      nil -> nil
      sentence -> split_sentence(sentence)
    end
  end

  defp split_sentence(sentence) do
    sentence
    |> then(&Regex.split(@sentence_marker, &1, include_captures: true, trim: true))
    |> Enum.map(&sentence_part/1)
  end

  defp sentence_part("\uE000actor\uE001"), do: :actor
  defp sentence_part("\uE000operator\uE001"), do: :operator
  defp sentence_part("\uE000pool\uE001"), do: :pool
  defp sentence_part("\uE000scoped_pool\uE001"), do: :scoped_pool
  defp sentence_part("\uE000target\uE001"), do: :target
  defp sentence_part("\uE000email\uE001"), do: :email
  defp sentence_part("\uE000status\uE001"), do: :status
  defp sentence_part("\uE000role\uE001"), do: :role
  defp sentence_part("\uE000ip\uE001"), do: :ip
  defp sentence_part("\uE000failure\uE001"), do: :failure
  defp sentence_part("\uE000reason\uE001"), do: :reason
  defp sentence_part(text), do: {:text, text}

  defp sentence_template("auth.bootstrap", _event) do
    gettext("%{actor} created the first owner account", actor: marker(:actor))
  end

  defp sentence_template("auth.login", event) do
    if ip_address(event) do
      gettext("%{actor} signed in from %{ip}", actor: marker(:actor), ip: marker(:ip))
    else
      gettext("%{actor} signed in", actor: marker(:actor))
    end
  end

  defp sentence_template("auth.logout", event) do
    if ip_address(event) do
      gettext("%{actor} signed out from %{ip}", actor: marker(:actor), ip: marker(:ip))
    else
      gettext("%{actor} signed out", actor: marker(:actor))
    end
  end

  defp sentence_template("auth.session_revoked", _event) do
    gettext("%{actor} signed out a browser session", actor: marker(:actor))
  end

  defp sentence_template("auth.sessions_revoked", _event) do
    gettext("%{actor} signed out the other browser sessions", actor: marker(:actor))
  end

  defp sentence_template("auth.recovery_code_used", event) do
    if ip_address(event) do
      gettext("%{actor} used a recovery code from %{ip}", actor: marker(:actor), ip: marker(:ip))
    else
      gettext("%{actor} used a recovery code", actor: marker(:actor))
    end
  end

  defp sentence_template("auth.password_change", _event) do
    gettext("%{actor} changed their password", actor: marker(:actor))
  end

  defp sentence_template("auth.required_password_change", _event) do
    gettext("%{actor} completed the required password change", actor: marker(:actor))
  end

  defp sentence_template("auth.totp_enrolled", _event) do
    gettext("%{actor} enrolled an authenticator app", actor: marker(:actor))
  end

  defp sentence_template("operator.create", event) do
    if changed_role(event) do
      gettext("%{actor} created the operator %{operator} — role set to %{role}", actor: marker(:actor), operator: marker(:operator), role: marker(:role))
    else
      gettext("%{actor} created the operator %{operator}", actor: marker(:actor), operator: marker(:operator))
    end
  end

  defp sentence_template("operator.update", event) do
    if changed_role(event) do
      gettext("%{actor} updated the operator %{operator} — role set to %{role}", actor: marker(:actor), operator: marker(:operator), role: marker(:role))
    else
      gettext("%{actor} updated the operator %{operator}", actor: marker(:actor), operator: marker(:operator))
    end
  end

  defp sentence_template("operator.deactivate", event) do
    if changed_role(event) do
      gettext("%{actor} deactivated the operator %{operator} — role set to %{role}", actor: marker(:actor), operator: marker(:operator), role: marker(:role))
    else
      gettext("%{actor} deactivated the operator %{operator}", actor: marker(:actor), operator: marker(:operator))
    end
  end

  defp sentence_template("operator.reactivate", event) do
    if changed_role(event) do
      gettext("%{actor} reactivated the operator %{operator} — role set to %{role}", actor: marker(:actor), operator: marker(:operator), role: marker(:role))
    else
      gettext("%{actor} reactivated the operator %{operator}", actor: marker(:actor), operator: marker(:operator))
    end
  end

  defp sentence_template("operator.password_reset", event) do
    if changed_role(event) do
      gettext("%{actor} issued a temporary password for %{operator} — role set to %{role}", actor: marker(:actor), operator: marker(:operator), role: marker(:role))
    else
      gettext("%{actor} issued a temporary password for %{operator}", actor: marker(:actor), operator: marker(:operator))
    end
  end

  defp sentence_template("operator.temporary_password_resend", event) do
    if changed_role(event) do
      gettext("%{actor} resent the temporary password to %{operator} — role set to %{role}", actor: marker(:actor), operator: marker(:operator), role: marker(:role))
    else
      gettext("%{actor} resent the temporary password to %{operator}", actor: marker(:actor), operator: marker(:operator))
    end
  end

  defp sentence_template("pool.create", _event) do
    gettext("%{actor} created the Pool %{pool}", actor: marker(:actor), pool: marker(:pool))
  end

  defp sentence_template("pool.update", _event) do
    gettext("%{actor} updated the Pool %{pool}", actor: marker(:actor), pool: marker(:pool))
  end

  defp sentence_template("pool.status_update", event) do
    if Presentation.detail_value(event, "status") do
      gettext("%{actor} changed the status of the Pool %{pool} to %{status}", actor: marker(:actor), pool: marker(:pool), status: marker(:status))
    else
      gettext("%{actor} changed the status of the Pool %{pool}", actor: marker(:actor), pool: marker(:pool))
    end
  end

  defp sentence_template("pool.routing_update", _event) do
    gettext("%{actor} updated the routing of the Pool %{pool}", actor: marker(:actor), pool: marker(:pool))
  end

  defp sentence_template("pool.model_serving_modes_update", _event) do
    gettext("%{actor} updated the model serving modes of the Pool %{pool}", actor: marker(:actor), pool: marker(:pool))
  end

  defp sentence_template("pool.delete", _event) do
    gettext("%{actor} deleted the Pool %{pool}", actor: marker(:actor), pool: marker(:pool))
  end

  defp sentence_template("pool.delete_requested", _event) do
    gettext("%{actor} requested deletion of the Pool %{pool}", actor: marker(:actor), pool: marker(:pool))
  end

  defp sentence_template("pool.assignment_add", event) do
    if pool_filterable?(event) do
      gettext("%{actor} assigned the upstream account %{target} in the Pool %{scoped_pool}", actor: marker(:actor), target: marker(:target), scoped_pool: marker(:scoped_pool))
    else
      gettext("%{actor} assigned the upstream account %{target}", actor: marker(:actor), target: marker(:target))
    end
  end

  defp sentence_template("pool.assignment_remove", event) do
    if pool_filterable?(event) do
      gettext("%{actor} unassigned the upstream account %{target} in the Pool %{scoped_pool}", actor: marker(:actor), target: marker(:target), scoped_pool: marker(:scoped_pool))
    else
      gettext("%{actor} unassigned the upstream account %{target}", actor: marker(:actor), target: marker(:target))
    end
  end

  defp sentence_template("invite.create", event) do
    if Presentation.detail_value(event, "invited_email") do
      gettext("%{actor} invited %{email} to the Pool %{pool}", actor: marker(:actor), email: marker(:email), pool: marker(:pool))
    else
      gettext("%{actor} created an invite for the Pool %{pool}", actor: marker(:actor), pool: marker(:pool))
    end
  end

  defp sentence_template("invite.revoke", event) do
    if Presentation.detail_value(event, "invited_email") do
      gettext("%{actor} revoked the invite for %{email} to the Pool %{pool}", actor: marker(:actor), email: marker(:email), pool: marker(:pool))
    else
      gettext("%{actor} revoked an invite for the Pool %{pool}", actor: marker(:actor), pool: marker(:pool))
    end
  end

  defp sentence_template("upstream_account.import", event) do
    if pool_filterable?(event) do
      gettext("%{actor} imported the upstream account %{target} in the Pool %{scoped_pool}", actor: marker(:actor), target: marker(:target), scoped_pool: marker(:scoped_pool))
    else
      gettext("%{actor} imported the upstream account %{target}", actor: marker(:actor), target: marker(:target))
    end
  end

  defp sentence_template("upstream_account.oauth_browser_link", _event) do
    gettext("%{actor} linked the upstream account %{target} through the browser OAuth flow", actor: marker(:actor), target: marker(:target))
  end

  defp sentence_template("upstream_account.oauth_device_link", _event) do
    gettext("%{actor} linked the upstream account %{target} with a device code", actor: marker(:actor), target: marker(:target))
  end

  defp sentence_template("upstream_account.rename", event) do
    if pool_filterable?(event) do
      gettext("%{actor} renamed the upstream account %{target} in the Pool %{scoped_pool}", actor: marker(:actor), target: marker(:target), scoped_pool: marker(:scoped_pool))
    else
      gettext("%{actor} renamed the upstream account %{target}", actor: marker(:actor), target: marker(:target))
    end
  end

  defp sentence_template("upstream_account.pause", event) do
    if pool_filterable?(event) do
      gettext("%{actor} paused the upstream account %{target} in the Pool %{scoped_pool}", actor: marker(:actor), target: marker(:target), scoped_pool: marker(:scoped_pool))
    else
      gettext("%{actor} paused the upstream account %{target}", actor: marker(:actor), target: marker(:target))
    end
  end

  defp sentence_template("upstream_account.reactivate", event) do
    if pool_filterable?(event) do
      gettext("%{actor} reactivated the upstream account %{target} in the Pool %{scoped_pool}", actor: marker(:actor), target: marker(:target), scoped_pool: marker(:scoped_pool))
    else
      gettext("%{actor} reactivated the upstream account %{target}", actor: marker(:actor), target: marker(:target))
    end
  end

  defp sentence_template("upstream_account.refresh_enqueue", event) do
    if pool_filterable?(event) do
      gettext("%{actor} queued a token refresh for the upstream account %{target} in the Pool %{scoped_pool}", actor: marker(:actor), target: marker(:target), scoped_pool: marker(:scoped_pool))
    else
      gettext("%{actor} queued a token refresh for the upstream account %{target}", actor: marker(:actor), target: marker(:target))
    end
  end

  defp sentence_template("upstream_account.delete", event) do
    if pool_filterable?(event) do
      gettext("%{actor} deleted the upstream account %{target} in the Pool %{scoped_pool}", actor: marker(:actor), target: marker(:target), scoped_pool: marker(:scoped_pool))
    else
      gettext("%{actor} deleted the upstream account %{target}", actor: marker(:actor), target: marker(:target))
    end
  end

  defp sentence_template("upstream_account.delete_requested", event) do
    if pool_filterable?(event) do
      gettext("%{actor} requested deletion of the upstream account %{target} in the Pool %{scoped_pool}", actor: marker(:actor), target: marker(:target), scoped_pool: marker(:scoped_pool))
    else
      gettext("%{actor} requested deletion of the upstream account %{target}", actor: marker(:actor), target: marker(:target))
    end
  end

  defp sentence_template("upstream_account.saved_reset_policy_update", event) do
    if pool_filterable?(event) do
      gettext("%{actor} updated the saved-reset policy of the upstream account %{target} in the Pool %{scoped_pool}", actor: marker(:actor), target: marker(:target), scoped_pool: marker(:scoped_pool))
    else
      gettext("%{actor} updated the saved-reset policy of the upstream account %{target}", actor: marker(:actor), target: marker(:target))
    end
  end

  defp sentence_template("upstream_account.provider_credits_policy_update", event) do
    if pool_filterable?(event) do
      gettext("%{actor} updated the provider-credit policy of the upstream account %{target} in the Pool %{scoped_pool}", actor: marker(:actor), target: marker(:target), scoped_pool: marker(:scoped_pool))
    else
      gettext("%{actor} updated the provider-credit policy of the upstream account %{target}", actor: marker(:actor), target: marker(:target))
    end
  end

  defp sentence_template("upstream_account.saved_reset_redeem_enqueue", event) do
    if pool_filterable?(event) do
      gettext("%{actor} queued a saved-reset redemption for the upstream account %{target} in the Pool %{scoped_pool}", actor: marker(:actor), target: marker(:target), scoped_pool: marker(:scoped_pool))
    else
      gettext("%{actor} queued a saved-reset redemption for the upstream account %{target}", actor: marker(:actor), target: marker(:target))
    end
  end

  defp sentence_template("api_key.create", event) do
    if pool_filterable?(event) do
      gettext("%{actor} created the API key %{target} in the Pool %{scoped_pool}", actor: marker(:actor), target: marker(:target), scoped_pool: marker(:scoped_pool))
    else
      gettext("%{actor} created the API key %{target}", actor: marker(:actor), target: marker(:target))
    end
  end

  defp sentence_template("api_key.update", event) do
    if pool_filterable?(event) do
      gettext("%{actor} updated the API key %{target} in the Pool %{scoped_pool}", actor: marker(:actor), target: marker(:target), scoped_pool: marker(:scoped_pool))
    else
      gettext("%{actor} updated the API key %{target}", actor: marker(:actor), target: marker(:target))
    end
  end

  defp sentence_template("api_key.pause", event) do
    if pool_filterable?(event) do
      gettext("%{actor} paused the API key %{target} in the Pool %{scoped_pool}", actor: marker(:actor), target: marker(:target), scoped_pool: marker(:scoped_pool))
    else
      gettext("%{actor} paused the API key %{target}", actor: marker(:actor), target: marker(:target))
    end
  end

  defp sentence_template("api_key.resume", event) do
    if pool_filterable?(event) do
      gettext("%{actor} resumed the API key %{target} in the Pool %{scoped_pool}", actor: marker(:actor), target: marker(:target), scoped_pool: marker(:scoped_pool))
    else
      gettext("%{actor} resumed the API key %{target}", actor: marker(:actor), target: marker(:target))
    end
  end

  defp sentence_template("api_key.revoke", event) do
    if pool_filterable?(event) do
      gettext("%{actor} revoked the API key %{target} in the Pool %{scoped_pool}", actor: marker(:actor), target: marker(:target), scoped_pool: marker(:scoped_pool))
    else
      gettext("%{actor} revoked the API key %{target}", actor: marker(:actor), target: marker(:target))
    end
  end

  defp sentence_template("api_key.rotate", event) do
    if pool_filterable?(event) do
      gettext("%{actor} rotated the API key %{target} in the Pool %{scoped_pool}", actor: marker(:actor), target: marker(:target), scoped_pool: marker(:scoped_pool))
    else
      gettext("%{actor} rotated the API key %{target}", actor: marker(:actor), target: marker(:target))
    end
  end

  defp sentence_template("api_key.delete", event) do
    if pool_filterable?(event) do
      gettext("%{actor} deleted the API key %{target} in the Pool %{scoped_pool}", actor: marker(:actor), target: marker(:target), scoped_pool: marker(:scoped_pool))
    else
      gettext("%{actor} deleted the API key %{target}", actor: marker(:actor), target: marker(:target))
    end
  end

  defp sentence_template("api_key.delete_requested", event) do
    if pool_filterable?(event) do
      gettext("%{actor} requested deletion of the API key %{target} in the Pool %{scoped_pool}", actor: marker(:actor), target: marker(:target), scoped_pool: marker(:scoped_pool))
    else
      gettext("%{actor} requested deletion of the API key %{target}", actor: marker(:actor), target: marker(:target))
    end
  end

  defp sentence_template("mcp.operator_enable", _event) do
    gettext("%{actor} enabled MCP access for their operator account", actor: marker(:actor))
  end

  defp sentence_template("mcp.operator_disable", _event) do
    gettext("%{actor} disabled MCP access for their operator account", actor: marker(:actor))
  end

  defp sentence_template("mcp.token_create", event) do
    if pool_filterable?(event) do
      gettext("%{actor} created the MCP token %{target} in the Pool %{scoped_pool}", actor: marker(:actor), target: marker(:target), scoped_pool: marker(:scoped_pool))
    else
      gettext("%{actor} created the MCP token %{target}", actor: marker(:actor), target: marker(:target))
    end
  end

  defp sentence_template("mcp.token_update", event) do
    if pool_filterable?(event) do
      gettext("%{actor} relabeled the MCP token %{target} in the Pool %{scoped_pool}", actor: marker(:actor), target: marker(:target), scoped_pool: marker(:scoped_pool))
    else
      gettext("%{actor} relabeled the MCP token %{target}", actor: marker(:actor), target: marker(:target))
    end
  end

  defp sentence_template("mcp.token_delete", event) do
    if pool_filterable?(event) do
      gettext("%{actor} deleted the MCP token %{target} in the Pool %{scoped_pool}", actor: marker(:actor), target: marker(:target), scoped_pool: marker(:scoped_pool))
    else
      gettext("%{actor} deleted the MCP token %{target}", actor: marker(:actor), target: marker(:target))
    end
  end

  defp sentence_template("alert_rule.create", event) do
    if pool_filterable?(event) do
      gettext("%{actor} created the alert rule %{target} in the Pool %{scoped_pool}", actor: marker(:actor), target: marker(:target), scoped_pool: marker(:scoped_pool))
    else
      gettext("%{actor} created the alert rule %{target}", actor: marker(:actor), target: marker(:target))
    end
  end

  defp sentence_template("alert_rule.update", event) do
    if pool_filterable?(event) do
      gettext("%{actor} updated the alert rule %{target} in the Pool %{scoped_pool}", actor: marker(:actor), target: marker(:target), scoped_pool: marker(:scoped_pool))
    else
      gettext("%{actor} updated the alert rule %{target}", actor: marker(:actor), target: marker(:target))
    end
  end

  defp sentence_template("alert_rule.enable", event) do
    if pool_filterable?(event) do
      gettext("%{actor} enabled the alert rule %{target} in the Pool %{scoped_pool}", actor: marker(:actor), target: marker(:target), scoped_pool: marker(:scoped_pool))
    else
      gettext("%{actor} enabled the alert rule %{target}", actor: marker(:actor), target: marker(:target))
    end
  end

  defp sentence_template("alert_rule.disable", event) do
    if pool_filterable?(event) do
      gettext("%{actor} disabled the alert rule %{target} in the Pool %{scoped_pool}", actor: marker(:actor), target: marker(:target), scoped_pool: marker(:scoped_pool))
    else
      gettext("%{actor} disabled the alert rule %{target}", actor: marker(:actor), target: marker(:target))
    end
  end

  defp sentence_template("alert_rule.delete", event) do
    if pool_filterable?(event) do
      gettext("%{actor} deleted the alert rule %{target} in the Pool %{scoped_pool}", actor: marker(:actor), target: marker(:target), scoped_pool: marker(:scoped_pool))
    else
      gettext("%{actor} deleted the alert rule %{target}", actor: marker(:actor), target: marker(:target))
    end
  end

  defp sentence_template("alert_channel.create", event) do
    if pool_filterable?(event) do
      gettext("%{actor} created the alert channel %{target} in the Pool %{scoped_pool}", actor: marker(:actor), target: marker(:target), scoped_pool: marker(:scoped_pool))
    else
      gettext("%{actor} created the alert channel %{target}", actor: marker(:actor), target: marker(:target))
    end
  end

  defp sentence_template("alert_channel.update", event) do
    if pool_filterable?(event) do
      gettext("%{actor} updated the alert channel %{target} in the Pool %{scoped_pool}", actor: marker(:actor), target: marker(:target), scoped_pool: marker(:scoped_pool))
    else
      gettext("%{actor} updated the alert channel %{target}", actor: marker(:actor), target: marker(:target))
    end
  end

  defp sentence_template("alert_channel.enable", event) do
    if pool_filterable?(event) do
      gettext("%{actor} enabled the alert channel %{target} in the Pool %{scoped_pool}", actor: marker(:actor), target: marker(:target), scoped_pool: marker(:scoped_pool))
    else
      gettext("%{actor} enabled the alert channel %{target}", actor: marker(:actor), target: marker(:target))
    end
  end

  defp sentence_template("alert_channel.disable", event) do
    if pool_filterable?(event) do
      gettext("%{actor} disabled the alert channel %{target} in the Pool %{scoped_pool}", actor: marker(:actor), target: marker(:target), scoped_pool: marker(:scoped_pool))
    else
      gettext("%{actor} disabled the alert channel %{target}", actor: marker(:actor), target: marker(:target))
    end
  end

  defp sentence_template("alert_channel.delete", event) do
    if pool_filterable?(event) do
      gettext("%{actor} deleted the alert channel %{target} in the Pool %{scoped_pool}", actor: marker(:actor), target: marker(:target), scoped_pool: marker(:scoped_pool))
    else
      gettext("%{actor} deleted the alert channel %{target}", actor: marker(:actor), target: marker(:target))
    end
  end

  defp sentence_template("alert_incident.acknowledge", event) do
    if pool_filterable?(event) do
      gettext("%{actor} acknowledged the alert incident %{target} in the Pool %{scoped_pool}", actor: marker(:actor), target: marker(:target), scoped_pool: marker(:scoped_pool))
    else
      gettext("%{actor} acknowledged the alert incident %{target}", actor: marker(:actor), target: marker(:target))
    end
  end

  defp sentence_template("alert_incident.resolve", event) do
    if pool_filterable?(event) do
      gettext("%{actor} resolved the alert incident %{target} in the Pool %{scoped_pool}", actor: marker(:actor), target: marker(:target), scoped_pool: marker(:scoped_pool))
    else
      gettext("%{actor} resolved the alert incident %{target}", actor: marker(:actor), target: marker(:target))
    end
  end

  defp sentence_template("instance_settings.update", _event) do
    gettext("%{actor} updated the instance settings", actor: marker(:actor))
  end

  defp sentence_template(_action, _event), do: nil

  attr :event, :map, required: true
  attr :pool_names, :map, required: true
  attr :datetime_preferences, :map, required: true

  @spec event_sentence(map()) :: Phoenix.LiveView.Rendered.t()
  def event_sentence(assigns) do
    assigns = assign(assigns, :sentence_parts, sentence_parts(assigns.event))

    ~H"""
    <p class="min-w-0 flex-1 text-[0.8rem] leading-relaxed text-base-content/45">
      <.event_time event={@event} datetime_preferences={@datetime_preferences} />
      <%= if @sentence_parts do %>
        <%= for part <- @sentence_parts do %>
          <%= case part do %>
            <% {:text, text} -> %>
              {text}
            <% :actor -> %>
              <.actor event={@event} />
            <% :operator -> %>
              <.target_user event={@event} />
            <% :pool -> %>
              <.pool event={@event} pool_names={@pool_names} />
            <% :scoped_pool -> %>
              <span data-role="audit-prose-in-pool"><.pool event={@event} pool_names={@pool_names} /></span>
            <% :target -> %>
              <.named_target event={@event} />
            <% :email -> %>
              <span data-role="audit-prose-invited-email" class="text-base-content">{Presentation.detail_value(@event, "invited_email")}</span>
            <% :status -> %>
              <span data-role="audit-prose-detail-tail" class="text-base-content">{Presentation.detail_value(@event, "status")}</span>
            <% :role -> %>
              <span data-role="audit-prose-role-tail" class="text-base-content">{changed_role(@event)}</span>
            <% :ip -> %>
              <span class="text-base-content/38">{ip_address(@event)}</span>
          <% end %>
        <% end %>
      <% else %>
        <span data-role="audit-prose-fallback"><.actor event={@event} />
        {Presentation.fallback_event_title(@event.action) |> String.downcase()}</span>
      <% end %>
      <.failure_tail event={@event} />
    </p>
    """
  end

  attr :event, :map, required: true
  attr :datetime_preferences, :map, required: true

  defp event_time(assigns) do
    ~H"""
    <button
      id={"audit-log-time-#{@event.id}"}
      type="button"
      class="relative -top-px mr-1.5 cursor-pointer text-[0.62rem] font-semibold tracking-[0.08em] tabular-nums text-base-content/35 underline-offset-2 transition-colors hover:text-primary hover:underline"
      aria-haspopup="dialog"
      aria-controls="audit-event-details-sidebar"
      aria-label={gettext("Inspect event details for %{event}", event: Presentation.event_title(@event))}
      phx-click="show_audit_event"
      phx-value-id={@event.id}
    >
      {event_time_label(@event, @datetime_preferences)}
    </button>
    """
  end

  attr :event, :map, required: true

  defp actor(assigns) do
    assigns = assign(assigns, :label, Presentation.format_actor(assigns.event))

    ~H"""
    <button
      :if={actor_filterable?(@event)}
      type="button"
      data-role="audit-prose-actor"
      class={filter_value_class()}
      aria-label={gettext("Filter by actor %{actor}", actor: @label)}
      phx-click="select_actor_filter"
      phx-value-actor={@label}
    >{@label}</button><span
      :if={!actor_filterable?(@event)}
      data-role="audit-prose-actor"
      class="text-base-content"
    >{@label}</span>
    """
  end

  attr :event, :map, required: true

  defp target_user(assigns) do
    assigns =
      assigns
      |> assign(:label, Presentation.target_label(assigns.event))
      |> assign(:filter_value, target_filter_value(assigns.event))

    ~H"""
    <button
      :if={@filter_value}
      type="button"
      data-role="audit-prose-target"
      class={filter_value_class()}
      aria-label={gettext("Filter by target %{target}", target: @label)}
      phx-click="select_target_filter"
      phx-value-target={@filter_value}
    >{@label}</button><span
      :if={!@filter_value}
      data-role="audit-prose-target"
      class="text-base-content"
    >{@label}</span>
    """
  end

  defp target_filter_value(event) do
    Presentation.detail_value(event, "email") ||
      case Map.get(event, :target_id) do
        target_id when is_binary(target_id) and target_id != "" -> target_id
        _missing -> nil
      end
  end

  attr :event, :map, required: true
  attr :pool_names, :map, required: true

  defp pool(assigns) do
    assigns = assign(assigns, :label, pool_label(assigns.event, assigns.pool_names))

    ~H"""
    <button
      :if={pool_filterable?(@event)}
      type="button"
      data-role="audit-prose-pool"
      class={filter_value_class()}
      aria-label={gettext("Filter by Pool: %{pool}", pool: @label)}
      phx-click="select_pool_filter"
      phx-value-pool-id={@event.pool_id}
    >{@label}</button><span
      :if={!pool_filterable?(@event)}
      data-role="audit-prose-pool"
      class="text-base-content"
    >{@label}</span>
    """
  end

  attr :event, :map, required: true

  defp named_target(assigns) do
    assigns = assign(assigns, :label, named_target_label(assigns.event))

    ~H"""
    <span data-role="audit-prose-named-target" class="text-base-content">
      {@label}
    </span>
    """
  end

  attr :event, :map, required: true

  defp failure_tail(assigns) do
    assigns = assign(assigns, :parts, failure_parts(assigns.event))

    ~H"""
    <span :if={@event.outcome == "failure"}>
      <%= for part <- @parts do %>
        <%= case part do %>
          <% {:text, text} -> %>
            {text}
          <% :reason -> %>
            {failure_reason(@event)}
          <% :failure -> %>
            <button
              type="button"
              data-role="audit-prose-failure"
              class="cursor-pointer text-error underline-offset-2 transition-colors hover:underline"
              aria-label={gettext("Filter by failed events")}
              phx-click="select_outcome_filter"
              phx-value-outcome="failure"
            >{gettext("failed")}</button>
        <% end %>
      <% end %>
    </span>
    """
  end

  defp failure_parts(event) do
    sentence =
      if failure_reason(event) do
        gettext("— it %{failure}: %{reason}", failure: marker(:failure), reason: marker(:reason))
      else
        gettext("— it %{failure}", failure: marker(:failure))
      end

    split_sentence(sentence)
  end

  defp filter_value_class do
    "cursor-pointer text-base-content underline-offset-2 transition-colors hover:text-primary hover:underline"
  end

  defp actor_filterable?(%{actor_type: "user"} = event) do
    is_binary(Map.get(event, :actor_user_email)) and Map.get(event, :actor_user_email) != ""
  end

  defp actor_filterable?(_event), do: false

  defp pool_filterable?(%{pool_id: pool_id}), do: is_binary(pool_id)
  defp pool_filterable?(_event), do: false

  defp pool_label(event, pool_names) do
    Map.get(pool_names, event.pool_id) ||
      Presentation.detail_value(event, "pool_name") ||
      Presentation.detail_value(event, "name") ||
      gettext("a Pool no longer listed")
  end

  defp named_target_label(event) do
    Presentation.detail_value(event, "label") ||
      Presentation.detail_value(event, "name") ||
      Presentation.detail_value(event, "account_label") ||
      Presentation.target_label(event)
  end

  defp changed_role(event) do
    role = Presentation.detail_value(event, "role")
    previous_role = Presentation.detail_value(event, "previous_role")

    if is_binary(role) and is_binary(previous_role) and role != previous_role do
      role_label(role)
    end
  end

  # Same vocabulary as the Operators page role badge.
  defp role_label("instance_owner"), do: gettext("Instance owner")
  defp role_label("instance_admin"), do: gettext("Instance admin")
  defp role_label(role), do: String.replace(role, "_", " ")

  defp failure_reason(event) do
    Presentation.detail_value(event, "reason") ||
      Presentation.detail_value(event, "error") ||
      Presentation.detail_value(event, "message")
  end

  defp ip_address(event) do
    case Map.get(event, :ip_address) do
      value when is_binary(value) and value != "" -> value
      %{} = inet -> to_string(inet)
      _missing -> nil
    end
  end

  defp event_time_label(event, preferences) do
    case DateTimeDisplay.format_datetime_parts(event.occurred_at, preferences) do
      %{time: time} -> time
      nil -> gettext("not recorded")
    end
  end
end
