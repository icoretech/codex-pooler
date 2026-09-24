defmodule CodexPoolerWeb.Admin.NotificationCenterHooks do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  use Phoenix.VerifiedRoutes,
    endpoint: CodexPoolerWeb.Endpoint,
    router: CodexPoolerWeb.Router,
    statics: CodexPoolerWeb.static_paths()

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Accounts.User
  alias CodexPooler.Alerts
  alias CodexPooler.Alerts.Incidents.NotificationEvents
  alias CodexPooler.Pools
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

  # The Pools whose notification topics this page subscribed to: the Pools its
  # viewer can see, re-read on every invalidation it reloads for, because a Pool
  # status change changes them (findings#206 row 206-308).
  @subscribed_pools_key :alert_notification_subscribed_pools

  # Set only on a page that follows its viewer's visibility: whether the viewer
  # is an owner and the Pools it can see, as of the last invalidation this page
  # reloaded for (findings#206 row 206-325).
  @viewer_visibility_key :alert_notification_viewer_visibility

  @spec on_mount(:default, map(), map(), Socket.t()) :: {:cont, Socket.t()}
  def on_mount(:default, _params, _session, %Socket{} = socket) do
    socket =
      socket
      |> assign_notification_center()
      |> Phoenix.LiveView.put_private(@recent_invalidations_key, [])
      |> Phoenix.LiveView.put_private(@subscribed_pools_key, [])
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

  @doc """
  Makes a connected page follow its viewer's role and visible Pools. A role
  change, a Pool assignment granted or revoked and a Pool status change each
  send an invalidation this hook already reloads for; when that reload finds
  the viewer's role or visible Pools changed, the page receives
  `{#{inspect(__MODULE__)}, :viewer_visibility_changed}` in its
  `handle_info/2` and re-reads what it shows with its own scope, which the
  hook has re-read first. An incident invalidation that changes neither sends
  nothing (findings#206 rows 206-325 and 206-410).
  """
  @spec follow_viewer_visibility(Socket.t()) :: Socket.t()
  def follow_viewer_visibility(%Socket{} = socket) do
    if Phoenix.LiveView.connected?(socket) do
      Phoenix.LiveView.put_private(socket, @viewer_visibility_key, viewer_visibility(socket))
    else
      socket
    end
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
       |> reload_notification_center()}
    end
  end

  # A clustered peer still running a release without invalidation ids sends the
  # bare message during a rolling update; the page reloads rather than handing
  # it to a `handle_info/2` that would crash on it.
  defp handle_notification_event({NotificationEvents, :invalidated}, socket) do
    {:halt, reload_notification_center(socket)}
  end

  # Any other message under the same tag is a shape a newer release sends
  # during a rolling update. Every admin page mounts this hook and most have no
  # catch-all `handle_info/2`, so the hook takes it and reloads instead of
  # handing it on to crash the page (findings#206 row 206-302). The tag is the
  # rolling-update contract: a new shape keeps it.
  defp handle_notification_event(message, socket)
       when is_tuple(message) and tuple_size(message) > 0 and elem(message, 0) == NotificationEvents do
    {:halt, reload_notification_center(socket)}
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

  # An invalidation can follow a change of the viewer's visible Pools, so the
  # page re-reads them first: it then subscribes before it reads, and an
  # invalidation of a Pool it just subscribed to reloads it again, never less.
  defp reload_notification_center(%Socket{} = socket) do
    socket
    |> sync_pool_subscriptions()
    |> notify_viewer_visibility_change()
    |> assign_notification_center()
  end

  # The operator topic was subscribed before the page read its baseline, so a
  # change committed after that read reaches this comparison; one committed
  # before it is already in what the page read at mount.
  defp notify_viewer_visibility_change(%Socket{private: private} = socket) do
    case Map.fetch(private, @viewer_visibility_key) do
      {:ok, previous} ->
        current = viewer_visibility(socket)
        socket = if current != previous, do: follow_viewer_change(socket), else: socket
        Phoenix.LiveView.put_private(socket, @viewer_visibility_key, current)

      :error ->
        socket
    end
  end

  # The scope the page mounted with carries the viewer's roles and assigned
  # Pools as they were then. Re-reading it makes every component that takes
  # the scope render again, the admin shell's owner-only navigation included,
  # even on a page whose own content did not change (findings#206 row
  # 206-410). The page then re-reads what it shows with the fresh scope.
  defp follow_viewer_change(%Socket{} = socket) do
    send(self(), {__MODULE__, :viewer_visibility_changed})

    case socket.assigns[:current_scope] do
      %Scope{user: %User{} = user} -> assign(socket, :current_scope, Scope.for_user(user))
      _scope -> socket
    end
  end

  # The visible Pools are the ones `sync_pool_subscriptions/1` just read.
  defp viewer_visibility(%Socket{} = socket) do
    {Pools.owner?(socket.assigns[:current_scope]), Map.get(socket.private, @subscribed_pools_key, [])}
  end

  defp subscribe_to_scoped_topics(%Socket{} = socket) do
    if Phoenix.LiveView.connected?(socket) do
      subscribe_to_operator(socket.assigns[:current_scope])
      sync_pool_subscriptions(socket)
    else
      socket
    end
  end

  defp subscribe_to_operator(%Scope{user: %{id: operator_id}}) when is_binary(operator_id) do
    :ok = NotificationEvents.subscribe_operator(operator_id)
  end

  defp subscribe_to_operator(_scope), do: :ok

  # Subscribes to the Pools the viewer can see now and unsubscribes from the
  # ones it no longer can, so a page never listens to a Pool its viewer cannot
  # see and picks up one that became visible (an owner's reactivated Pool).
  defp sync_pool_subscriptions(%Socket{} = socket) do
    subscribed = Map.get(socket.private, @subscribed_pools_key, [])
    visible = visible_pool_ids(socket.assigns[:current_scope])

    Enum.each(visible -- subscribed, &(:ok = NotificationEvents.subscribe_pool(&1)))
    Enum.each(subscribed -- visible, &(:ok = NotificationEvents.unsubscribe_pool(&1)))

    Phoenix.LiveView.put_private(socket, @subscribed_pools_key, visible)
  end

  # A sorted, unique id list rather than a MapSet: the visibility comparison
  # stays a plain equality, and dialyzer does not track MapSet opaqueness
  # through the socket's private map.
  defp visible_pool_ids(%Scope{user: %{id: operator_id}} = scope) when is_binary(operator_id) do
    case Alerts.list_manageable_pools(scope) do
      {:ok, pools} -> pools |> Enum.map(& &1.id) |> Enum.uniq() |> Enum.sort()
      {:error, _reason} -> []
    end
  end

  defp visible_pool_ids(_scope), do: []

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
