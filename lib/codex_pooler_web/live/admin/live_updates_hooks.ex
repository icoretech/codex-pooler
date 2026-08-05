defmodule CodexPoolerWeb.Admin.LiveUpdatesHooks do
  @moduledoc """
  Operator-controlled pause for the admin surfaces that refresh themselves.

  Several admin pages rebuild on a debounce when Pool events arrive. That is
  right while an operator is watching traffic and wrong while they are reading:
  the list moves under them. The choice is theirs, so it lives in one topbar
  control and every self-refreshing surface asks the same question.

  The pause is a property of the reading session, not of the operator. It is
  held in `sessionStorage` by the topbar hook and pushed up on mount and on
  reconnect, so it survives navigation and rejoin while a second tab stays live.

  This gates the **source** rather than the socket. Cycling the socket would
  stop clicks, filters and navigation too, and would remount every LiveView on
  resume — a full set of mount queries per tab, which is the stampede rather
  than a way to avoid it.

  Two things a caller still owns, because no hook can know them:

    * a debounce already in flight when the operator pauses. Pages guard their
      own reload with `paused?/1` and call `hold/1`, or the list moves up to one
      debounce after the click.
    * a refresh that is not driven by a Pool event — a fallback timer, or
      another domain's events. Those pass this gate untouched.
  """

  import Phoenix.Component, only: [assign: 3]

  alias CodexPooler.Events
  alias Phoenix.LiveView.Socket

  @paused_assign :live_updates_paused?
  @held_assign :live_updates_held
  @page_held_assign :live_updates_page_held?

  @spec on_mount(:default, map(), map(), Socket.t()) :: {:cont, Socket.t()}
  def on_mount(:default, _params, _session, %Socket{} = socket) do
    socket =
      socket
      |> assign(@paused_assign, connected_paused?(socket))
      |> assign(@held_assign, %{})
      |> assign(@page_held_assign, false)
      |> Phoenix.LiveView.attach_hook(
        :admin_live_updates,
        :handle_event,
        &handle_live_updates_event/3
      )
      |> Phoenix.LiveView.attach_hook(
        :admin_live_updates_gate,
        :handle_info,
        &gate_live_update/2
      )

    {:cont, socket}
  end

  @doc """
  Whether this reading session has auto-refresh paused.
  """
  @spec paused?(Socket.t()) :: boolean()
  def paused?(%Socket{assigns: assigns}), do: assigns[@paused_assign] == true

  # The session's answer arrives with the join, so a page mounted by live
  # navigation is paused before it renders rather than a round trip later. The
  # toggle still reports on mount: this covers the gap, not the toggle.
  #
  # The disconnected render has no connect params and processes no events, so
  # its answer does not matter — but it must not be `nil`.
  defp connected_paused?(%Socket{} = socket) do
    Phoenix.LiveView.connected?(socket) and
      case Phoenix.LiveView.get_connect_params(socket) do
        %{"live_updates_paused" => paused} -> paused in [true, "true"]
        _params -> false
      end
  end

  @doc """
  Records that a refresh was skipped, so resuming runs it.

  For a page whose reload is driven by something this gate cannot see: a
  fallback timer, another domain's events, or a debounce armed before the pause.
  """
  @spec hold(Socket.t()) :: Socket.t()
  def hold(%Socket{} = socket), do: assign(socket, @page_held_assign, true)

  @doc """
  Runs a page's reload unless the session is paused, holding it if it is.

  For the refreshes this gate cannot intercept: a debounce armed before the
  click, a fallback timer, another domain's events.
  """
  @spec unless_paused(Socket.t(), (Socket.t() -> Socket.t())) :: {:noreply, Socket.t()}
  def unless_paused(%Socket{} = socket, reload) when is_function(reload, 1) do
    if paused?(socket) do
      {:noreply, hold(socket)}
    else
      {:noreply, reload.(socket)}
    end
  end

  @doc """
  Messages held during the pause, for replay on resume.
  """
  @spec held(Socket.t()) :: [term()]
  def held(%Socket{assigns: assigns}), do: assigns |> Map.get(@held_assign, %{}) |> Map.values()

  # In front of every admin LiveView, so a page is paused without knowing that
  # pausing exists — for the refreshes that Pool events drive, which is most of
  # them.
  #
  # Only Pool events are held: the alert notification centre speaks a different
  # message and keeps running, because an alert firing is not something to be
  # quiet about.
  defp gate_live_update({Events, payload} = message, %Socket{} = socket) do
    if paused?(socket) do
      {:halt, put_held(socket, routing_key(payload), message)}
    else
      {:cont, socket}
    end
  end

  defp gate_live_update(_message, socket), do: {:cont, socket}

  # Events carry a generated id and a timestamp, so no two are equal and
  # deduplicating on the whole message never matches. What decides whether a
  # page reloads is the pool and the topics; everything else is provenance.
  # Keying on that pair bounds the map at pools times topic-sets, and keeps the
  # newest message for each — so a resume cannot silently drop the one arrival
  # a page was waiting for.
  defp routing_key(payload) when is_map(payload) do
    {Map.get(payload, :pool_id), Map.get(payload, :topics)}
  end

  defp routing_key(payload), do: payload

  defp put_held(%Socket{} = socket, key, message) do
    assign(socket, @held_assign, Map.put(socket.assigns[@held_assign] || %{}, key, message))
  end

  # The toggle reports the session's state rather than asking to flip it, so a
  # mount, a reconnect and a click all say the same thing.
  defp handle_live_updates_event("set_live_updates", params, socket) do
    wanted = params_paused(params)
    changed? = paused?(socket) != wanted
    resumed? = paused?(socket) and not wanted

    socket = assign(socket, @paused_assign, wanted)
    socket = if resumed?, do: resume(socket), else: socket

    # Only an actual change is worth a toast. The toggle also reports on mount
    # and on reconnect, and those agree with what the join already established,
    # so announcing every report would put a toast on every page load.
    if changed?, do: {:halt, announce(socket, wanted)}, else: {:halt, socket}
  end

  defp handle_live_updates_event(_event, _params, socket), do: {:cont, socket}

  # The icon swapping is easy to miss on a control this small, and the
  # consequence of pausing — that lists stop moving — is not something to leave
  # the operator to infer from a list that has gone quiet.
  defp announce(socket, true) do
    Phoenix.LiveView.put_flash(
      socket,
      :info,
      "Live updates paused. Lists hold still until you resume."
    )
  end

  defp announce(socket, false) do
    Phoenix.LiveView.put_flash(socket, :info, "Live updates resumed.")
  end

  # The event name is owned here, so every shape of it is too: a payload without
  # the key must not fall through to a page that has no clause for it.
  defp params_paused(%{"paused" => paused}), do: paused in [true, "true"]
  defp params_paused(_params), do: false

  # Resuming replays what was held rather than inventing a refresh of its own,
  # so each page reacts exactly as it would have unpaused — its own scope check,
  # its own debounce, which is what collapses a paused hour into one rebuild.
  defp resume(%Socket{} = socket) do
    messages = held(socket)
    Enum.each(messages, &send(self(), &1))

    # A page that held its own reload only needs telling when nothing was
    # replayed to it: a replayed event already produces the rebuild, and sending
    # both would run two. Order is explicit rather than left to map traversal.
    if messages == [] and socket.assigns[@page_held_assign] do
      send(self(), :live_updates_resumed)
    end

    socket
    |> assign(@held_assign, %{})
    |> assign(@page_held_assign, false)
  end
end
