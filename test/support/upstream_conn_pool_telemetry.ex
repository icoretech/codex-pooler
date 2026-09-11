defmodule CodexPooler.UpstreamConnPoolTelemetry do
  @moduledoc """
  Observes which Finch pool served requests to one local fake upstream origin.

  Tests set the upstream connection idle bound through the operational
  settings snapshot and then count Finch checkout events for the fake's port.
  With a zero bound, every checkout of a connection that an earlier request
  checked in emits `conn_max_idle_time_exceeded` and never `reused_connection`,
  so N sequential requests to one origin that all carry the bound produce
  exactly N - 1 exceeded events. A request that falls back to the global
  unbounded `Req.Finch` lands in a different pool and breaks that count. Finch
  emits both events before the request returns, so draining the mailbox needs
  no wait.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias CodexPooler.Gateway.OperationalSettings

  @events [[:finch, :reused_connection], [:finch, :conn_max_idle_time_exceeded]]

  @doc """
  Sets `upstream_conn_max_idle_time_ms` in the operational settings test
  override for the rest of the test and restores the previous override on exit.
  A zero bound is below the Instance Setting minimum on purpose: it makes every
  checked-in connection stale at its next checkout without waiting.
  """
  @spec put_idle_bound!(non_neg_integer()) :: :ok
  def put_idle_bound!(idle_ms) when is_integer(idle_ms) and idle_ms >= 0 do
    previous = Application.get_env(:codex_pooler, OperationalSettings)
    settings = Keyword.get(previous || [], :settings, %OperationalSettings{})

    Application.put_env(:codex_pooler, OperationalSettings,
      settings: %{settings | upstream_conn_max_idle_time_ms: idle_ms}
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:codex_pooler, OperationalSettings, previous)
      else
        Application.delete_env(:codex_pooler, OperationalSettings)
      end
    end)
  end

  @doc "Forwards Finch checkout events for the origin at `base_url` to the test process."
  @spec attach!(String.t()) :: :ok
  def attach!(base_url) when is_binary(base_url) do
    %URI{host: host, port: port} = URI.parse(base_url)
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(handler_id, @events, &__MODULE__.handle_event/4, %{
        parent: self(),
        host: host,
        port: port
      })

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  @doc "Returns the checkout event names received so far, in order."
  @spec drain_events() :: [:reused_connection | :conn_max_idle_time_exceeded]
  def drain_events, do: drain_events([])

  defp drain_events(acc) do
    receive do
      {__MODULE__, event} -> drain_events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc false
  def handle_event([:finch, event], _measurements, %{host: host, port: port}, %{
        parent: parent,
        host: host,
        port: port
      }) do
    send(parent, {__MODULE__, event})
  end

  def handle_event(_event, _measurements, _meta, _config), do: :ok
end
