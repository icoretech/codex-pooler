defmodule CodexPoolerWeb.Admin.NotificationCenterHooks do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  use Phoenix.VerifiedRoutes,
    endpoint: CodexPoolerWeb.Endpoint,
    router: CodexPoolerWeb.Router,
    statics: CodexPoolerWeb.static_paths()

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Alerts
  alias CodexPooler.Alerts.Incidents.NotificationEvents
  alias CodexPoolerWeb.Admin.AlertNotificationsReadModel
  alias Phoenix.LiveView.Socket

  @type notification_center :: %{
          required(:badge_count) => non_neg_integer(),
          required(:badge_label) => String.t(),
          required(:rows) => [AlertNotificationsReadModel.row()],
          required(:has_rows?) => boolean(),
          required(:empty?) => boolean()
        }

  # The invalidations this page already reloaded for. The copies of one
  # invalidation arrive together, one per subscribed topic it names, so a short
  # memory is enough; one that fell out of it reloads again, never less.
  @recent_invalidations_key :alert_notification_recent_invalidations
  @recent_invalidation_limit 32

  @spec on_mount(:default, map(), map(), Socket.t()) :: {:cont, Socket.t()}
  def on_mount(:default, _params, _session, %Socket{} = socket) do
    socket =
      socket
      |> assign_notification_center()
      |> Phoenix.LiveView.put_private(@recent_invalidations_key, [])
      |> subscribe_to_scoped_topics()
      |> Phoenix.LiveView.attach_hook(
        :alert_notification_center,
        :handle_info,
        &handle_notification_event/2
      )
      |> Phoenix.LiveView.attach_hook(
        :alert_notification_center_actions,
        :handle_event,
        &handle_notification_action/3
      )

    {:cont, socket}
  end

  @spec assign_notification_center(Socket.t()) :: Socket.t()
  def assign_notification_center(%Socket{} = socket) do
    assign(
      socket,
      :alert_notification_center,
      notification_center(socket.assigns[:current_scope])
    )
  end

  # One incident invalidates every Pool it targets, and this page subscribes to
  # each Pool it can see, so it gets one copy per shared Pool; it reloads for
  # the first (findings#206 row 206-270).
  defp handle_notification_event({NotificationEvents, :invalidated, invalidation_id}, socket) do
    recent = Map.get(socket.private, @recent_invalidations_key, [])

    if invalidation_id in recent do
      {:halt, socket}
    else
      recent = Enum.take([invalidation_id | recent], @recent_invalidation_limit)

      {:halt,
       socket
       |> Phoenix.LiveView.put_private(@recent_invalidations_key, recent)
       |> assign_notification_center()}
    end
  end

  # A clustered peer still running a release without invalidation ids sends the
  # bare message during a rolling update; the page reloads rather than handing
  # it to a `handle_info/2` that would crash on it.
  defp handle_notification_event({NotificationEvents, :invalidated}, socket) do
    {:halt, assign_notification_center(socket)}
  end

  # Any other message under the same tag is a shape a newer release sends
  # during a rolling update. Every admin page mounts this hook and most have no
  # catch-all `handle_info/2`, so the hook takes it and reloads instead of
  # handing it on to crash the page (findings#206 row 206-302). The tag is the
  # rolling-update contract: a new shape keeps it.
  defp handle_notification_event(message, socket)
       when is_tuple(message) and tuple_size(message) > 0 and elem(message, 0) == NotificationEvents do
    {:halt, assign_notification_center(socket)}
  end

  defp handle_notification_event(_message, socket), do: {:cont, socket}

  defp handle_notification_action(
         "open_alert_notification_incident",
         %{"id" => incident_id},
         socket
       ) do
    case Alerts.mark_incident_notification_read(socket.assigns[:current_scope], incident_id) do
      {:ok, receipt} ->
        {:halt,
         socket
         |> assign_notification_center()
         |> Phoenix.LiveView.push_navigate(to: alert_incident_path(receipt.incident_id))}

      {:error, _reason} ->
        {:halt, notification_action_error(socket)}
    end
  end

  defp handle_notification_action("mark_alert_notification_read", %{"id" => incident_id}, socket) do
    case Alerts.mark_incident_notification_read(socket.assigns[:current_scope], incident_id) do
      {:ok, _receipt} -> {:halt, assign_notification_center(socket)}
      {:error, _reason} -> {:halt, notification_action_error(socket)}
    end
  end

  defp handle_notification_action("dismiss_alert_notification", %{"id" => incident_id}, socket) do
    case Alerts.dismiss_incident_notification(socket.assigns[:current_scope], incident_id) do
      {:ok, _receipt} -> {:halt, assign_notification_center(socket)}
      {:error, _reason} -> {:halt, notification_action_error(socket)}
    end
  end

  defp handle_notification_action("dismiss_all_alert_notifications", _params, socket) do
    case Alerts.dismiss_all_visible_incident_notifications(socket.assigns[:current_scope]) do
      {:ok, _count} -> {:halt, assign_notification_center(socket)}
      {:error, _reason} -> {:halt, notification_action_error(socket)}
    end
  end

  defp handle_notification_action(_event, _params, socket), do: {:cont, socket}

  defp notification_action_error(socket) do
    socket
    |> assign_notification_center()
    |> Phoenix.LiveView.put_flash(:error, "Notification could not be updated")
  end

  defp alert_incident_path(incident_id) do
    ~p"/admin/alerts?#{%{"tab" => "incidents"}}" <> "#alert-incident-#{incident_id}"
  end

  defp notification_center(%Scope{} = scope) do
    page = AlertNotificationsReadModel.load(scope)

    %{
      badge_count: page.badge_count,
      badge_label: badge_label(page.badge_count),
      rows: page.rows,
      has_rows?: page.has_rows?,
      empty?: page.empty?
    }
  end

  defp notification_center(_scope), do: empty_notification_center()

  defp subscribe_to_scoped_topics(%Socket{} = socket) do
    if Phoenix.LiveView.connected?(socket) do
      subscribe_to_scope(socket.assigns[:current_scope])
    end

    socket
  end

  defp subscribe_to_scope(%Scope{user: %{id: operator_id}} = scope) when is_binary(operator_id) do
    :ok = NotificationEvents.subscribe_operator(operator_id)

    case Alerts.list_manageable_pools(scope) do
      {:ok, pools} -> Enum.each(pools, &subscribe_pool!/1)
      {:error, _reason} -> :ok
    end
  end

  defp subscribe_to_scope(_scope), do: :ok

  defp subscribe_pool!(%{id: pool_id}) when is_binary(pool_id) do
    :ok = NotificationEvents.subscribe_pool(pool_id)
  end

  defp badge_label(count) when is_integer(count) and count > 99, do: "99+"
  defp badge_label(count) when is_integer(count) and count >= 0, do: Integer.to_string(count)
  defp badge_label(_count), do: "0"

  defp empty_notification_center do
    %{
      badge_count: 0,
      badge_label: "0",
      rows: [],
      has_rows?: false,
      empty?: true
    }
  end
end
