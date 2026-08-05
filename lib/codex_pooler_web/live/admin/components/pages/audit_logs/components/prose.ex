defmodule CodexPoolerWeb.Admin.AuditLogsComponents.Prose do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.AuditLogsComponents.Presentation
  alias CodexPoolerWeb.DateTimeDisplay

  # Every supported audit action maps to a sentence form and a verb phrase.
  # The coverage test walks Audit.action_options/0 against this map, so a new
  # action cannot ship without deciding how it reads — an unknown action still
  # renders through the generic fallback (marked data-role, never asserted).
  #
  # Forms:
  #   :actor_only  — "{actor} {verb}"                             (auth.*)
  #   :target_user — "{actor} {verb} {operator email}{role tail}" (operator.*)
  #   :pool        — "{actor} {verb} {pool name}{detail tail}"    (pool.*)
  #   :invite      — "{actor} {verb} {invited email} to {pool}"   (invite.*)
  #   :named       — "{actor} {verb} {target name}{in the pool}"  (everything owning a labeled record)
  #   :plain       — "{actor} {verb}"                             (no interactive object)
  @sentence_forms %{
    "auth.bootstrap" => {:plain, "created the first owner account"},
    "auth.login" => {:actor_only, "signed in"},
    "auth.logout" => {:actor_only, "signed out"},
    "auth.session_revoked" => {:plain, "signed out a browser session"},
    "auth.sessions_revoked" => {:plain, "signed out the other browser sessions"},
    "auth.recovery_code_used" => {:actor_only, "used a recovery code"},
    "auth.password_change" => {:plain, "changed their password"},
    "auth.required_password_change" => {:plain, "completed the required password change"},
    "auth.totp_enrolled" => {:plain, "enrolled an authenticator app"},
    "operator.create" => {:target_user, "created the operator"},
    "operator.update" => {:target_user, "updated the operator"},
    "operator.deactivate" => {:target_user, "deactivated the operator"},
    "operator.reactivate" => {:target_user, "reactivated the operator"},
    "operator.password_reset" => {:target_user, "issued a temporary password for"},
    "operator.temporary_password_resend" => {:target_user, "resent the temporary password to"},
    "pool.create" => {:pool, "created the Pool", nil},
    "pool.update" => {:pool, "updated the Pool", nil},
    "pool.status_update" => {:pool, "changed the status of the Pool", "status"},
    "pool.routing_update" => {:pool, "updated the routing of the Pool", nil},
    "pool.model_serving_modes_update" =>
      {:pool, "updated the model serving modes of the Pool", nil},
    "pool.delete" => {:pool, "deleted the Pool", nil},
    "invite.create" => {:invite, "invited", "created an invite for the Pool"},
    "invite.revoke" => {:invite, "revoked the invite for", "revoked an invite for the Pool"},
    "upstream_account.import" => {:named, "imported the upstream account"},
    "upstream_account.oauth_browser_link" =>
      {:named_suffix, "linked the upstream account", "through the browser OAuth flow"},
    "upstream_account.oauth_device_link" =>
      {:named_suffix, "linked the upstream account", "with a device code"},
    "upstream_account.pause" => {:named, "paused the upstream account"},
    "upstream_account.reactivate" => {:named, "reactivated the upstream account"},
    "upstream_account.refresh_enqueue" =>
      {:named, "queued a token refresh for the upstream account"},
    "upstream_account.delete" => {:named, "deleted the upstream account"},
    "upstream_account.saved_reset_policy_update" =>
      {:named, "updated the saved-reset policy of the upstream account"},
    "upstream_account.saved_reset_redeem_enqueue" =>
      {:named, "queued a saved-reset redemption for the upstream account"},
    "api_key.create" => {:named, "created the API key"},
    "api_key.update" => {:named, "updated the API key"},
    "api_key.pause" => {:named, "paused the API key"},
    "api_key.resume" => {:named, "resumed the API key"},
    "api_key.revoke" => {:named, "revoked the API key"},
    "api_key.rotate" => {:named, "rotated the API key"},
    "api_key.delete" => {:named, "deleted the API key"},
    "mcp.operator_enable" => {:plain, "enabled MCP access for their operator account"},
    "mcp.operator_disable" => {:plain, "disabled MCP access for their operator account"},
    "mcp.token_create" => {:named, "created the MCP token"},
    "mcp.token_update" => {:named, "relabeled the MCP token"},
    "mcp.token_delete" => {:named, "deleted the MCP token"},
    "alert_rule.create" => {:named, "created the alert rule"},
    "alert_rule.update" => {:named, "updated the alert rule"},
    "alert_rule.enable" => {:named, "enabled the alert rule"},
    "alert_rule.disable" => {:named, "disabled the alert rule"},
    "alert_rule.delete" => {:named, "deleted the alert rule"},
    "alert_channel.create" => {:named, "created the alert channel"},
    "alert_channel.update" => {:named, "updated the alert channel"},
    "alert_channel.enable" => {:named, "enabled the alert channel"},
    "alert_channel.disable" => {:named, "disabled the alert channel"},
    "alert_channel.delete" => {:named, "deleted the alert channel"},
    "alert_incident.acknowledge" => {:named, "acknowledged the alert incident"},
    "alert_incident.resolve" => {:named, "resolved the alert incident"},
    "instance_settings.update" => {:plain, "updated the instance settings"}
  }

  @spec covered_actions() :: [String.t()]
  def covered_actions, do: Map.keys(@sentence_forms)

  attr :event, :map, required: true
  attr :pool_names, :map, required: true
  attr :datetime_preferences, :map, required: true

  def event_sentence(assigns) do
    assigns = assign(assigns, :form, Map.get(@sentence_forms, assigns.event.action))

    ~H"""
    <p class="min-w-0 flex-1 text-[0.8rem] leading-relaxed text-base-content/45">
      <.event_time event={@event} datetime_preferences={@datetime_preferences} />
      <%= case @form do %>
        <% {:actor_only, verb} -> %>
          <.actor event={@event} /> {verb}
          <span :if={ip = ip_address(@event)} class="text-base-content/38">from {ip}</span>
        <% {:plain, verb} -> %>
          <.actor event={@event} /> {verb}
        <% {:target_user, verb} -> %>
          <.actor event={@event} /> {verb} <.target_user event={@event} />
          <.role_tail event={@event} />
        <% {:pool, verb, detail_key} -> %>
          <.actor event={@event} /> {verb} <.pool event={@event} pool_names={@pool_names} />
          <.detail_tail :if={detail_key} event={@event} detail_key={detail_key} />
        <% {:invite, verb, fallback_verb} -> %>
          <.actor event={@event} />
          <.invite_clause
            event={@event}
            pool_names={@pool_names}
            verb={verb}
            fallback_verb={fallback_verb}
          />
        <% {:named, verb} -> %>
          <.actor event={@event} /> {verb} <.named_target event={@event} />
          <.in_pool event={@event} pool_names={@pool_names} />
        <% {:named_suffix, verb, suffix} -> %>
          <.actor event={@event} /> {verb} <.named_target event={@event} /> {suffix}
        <% nil -> %>
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
      aria-label={"Inspect event details for #{Presentation.event_title(@event)}"}
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
      aria-label={"Filter by actor #{@label}"}
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
      aria-label={"Filter by target #{@label}"}
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
      aria-label={"Filter by Pool: #{@label}"}
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

  # "— role set to admin", only when the update actually moved the role.
  attr :event, :map, required: true

  defp role_tail(assigns) do
    assigns = assign(assigns, :role, changed_role(assigns.event))

    ~H"""
    <span :if={@role} data-role="audit-prose-role-tail">
      — role set to <span class="text-base-content">{@role}</span>
    </span>
    """
  end

  # Appends a recorded detail as the destination of the verb, e.g.
  # "changed the status of the Pool X to paused".
  attr :event, :map, required: true
  attr :detail_key, :string, required: true

  defp detail_tail(assigns) do
    assigns =
      assign(assigns, :value, Presentation.detail_value(assigns.event, assigns.detail_key))

    ~H"""
    <span :if={@value} data-role="audit-prose-detail-tail">
      to <span class="text-base-content">{@value}</span>
    </span>
    """
  end

  # Invites record the invited email; when present the sentence names the
  # person, otherwise it falls back to the older Pool-only phrasing.
  attr :event, :map, required: true
  attr :pool_names, :map, required: true
  attr :verb, :string, required: true
  attr :fallback_verb, :string, required: true

  defp invite_clause(assigns) do
    assigns = assign(assigns, :email, Presentation.detail_value(assigns.event, "invited_email"))

    ~H"""
    <span :if={@email}>
      {@verb}
      <span data-role="audit-prose-invited-email" class="text-base-content">
        {@email}
      </span>
      to the Pool <.pool event={@event} pool_names={@pool_names} />
    </span>
    <span :if={!@email}>
      {@fallback_verb} <.pool event={@event} pool_names={@pool_names} />
    </span>
    """
  end

  # Labeled records that belong to a Pool say so, with the Pool acting on the
  # page filter like every other entity.
  attr :event, :map, required: true
  attr :pool_names, :map, required: true

  defp in_pool(assigns) do
    ~H"""
    <span :if={pool_filterable?(@event)} data-role="audit-prose-in-pool">
      in the Pool <.pool event={@event} pool_names={@pool_names} />
    </span>
    """
  end

  attr :event, :map, required: true

  defp failure_tail(assigns) do
    ~H"""
    <span :if={@event.outcome == "failure"}>
      —
      it
      <button
        type="button"
        data-role="audit-prose-failure"
        class="cursor-pointer text-error underline-offset-2 transition-colors hover:underline"
        aria-label="Filter by failed events"
        phx-click="select_outcome_filter"
        phx-value-outcome="failure"
      >failed</button><span :if={reason = failure_reason(@event)}>: {reason}</span>
    </span>
    """
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
      "a Pool no longer listed"
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
  defp role_label("instance_owner"), do: "Instance owner"
  defp role_label("instance_admin"), do: "Instance admin"
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
      nil -> "not recorded"
    end
  end
end
