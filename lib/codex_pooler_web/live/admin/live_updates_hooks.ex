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

  @spec on_mount(:default, map(), map(), Socket.t()) :: {:cont, Socket.t()}
  def on_mount(:default, _params, _session, %Socket{} = socket) do
    socket =
      socket
      |> assign(@paused_assign, false)
      |> assign(@held_assign, %{})
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

  @doc """
  Records that a refresh was skipped, so resuming runs it.

  For a page whose reload is driven by something this gate cannot see: a
  fallback timer, another domain's events, or a debounce armed before the pause.
  """
  @spec hold(Socket.t()) :: Socket.t()
  def hold(%Socket{} = socket), do: put_held(socket, :page, :resume)

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
    wanted = params |> params_paused() |> Kernel.==(true)
    resumed? = paused?(socket) and not wanted

    socket = assign(socket, @paused_assign, wanted)

    if resumed?, do: {:halt, resume(socket)}, else: {:halt, socket}
  end

  defp handle_live_updates_event(_event, _params, socket), do: {:cont, socket}

  # The event name is owned here, so every shape of it is too: a payload without
  # the key must not fall through to a page that has no clause for it.
  defp params_paused(%{"paused" => paused}), do: paused in [true, "true"]
  defp params_paused(_params), do: false

  # Resuming replays what was held rather than inventing a refresh of its own,
  # so each page reacts exactly as it would have unpaused — its own scope check,
  # its own debounce, which is what collapses a paused hour into one rebuild.
  defp resume(%Socket{} = socket) do
    socket
    |> held()
    |> Enum.each(fn
      :resume -> send(self(), :live_updates_resumed)
      message -> send(self(), message)
    end)

    assign(socket, @held_assign, %{})
  end
end
