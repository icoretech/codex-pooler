defmodule CodexPooler.Application do
  @moduledoc false

  use Application

  alias CodexPooler.Gateway.Transports.Websocket.RolloutDrain

  @impl true
  def start(_type, _args) do
    children = [
      CodexPoolerWeb.Telemetry,
      CodexPooler.Repo,
      CodexPooler.Access.APIKeys.TouchDebounce,
      CodexPooler.Gateway.Transports.Admission,
      {Registry,
       keys: :unique,
       name: CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession.Registry},
      {Task.Supervisor,
       name: CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession.TaskSupervisor},
      CodexPooler.Gateway.Transports.Websocket.RolloutDrain,
      {Task.Supervisor, name: CodexPooler.RateLimitEventSupervisor, max_children: 4},
      {Phoenix.PubSub, name: CodexPooler.PubSub},
      {Postgrex.Notifications, postgres_notifications_config()},
      CodexPooler.Events.PostgresBridge,
      CodexPooler.InstanceSettings.Cache,
      {Oban, Application.fetch_env!(:codex_pooler, Oban)},
      {DNSCluster,
       query: Application.get_env(:codex_pooler, :dns_cluster_query) || :ignore,
       resolver: CodexPooler.Platform.DNSClusterResolver},
      CodexPoolerWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: CodexPooler.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def prep_stop(state) do
    _summary = RolloutDrain.drain_for_shutdown()
    state
  end

  @impl true
  def config_change(changed, _new, removed) do
    CodexPoolerWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp postgres_notifications_config do
    CodexPooler.Repo.config()
    |> Keyword.take([
      :after_connect,
      :connect_timeout,
      :database,
      :hostname,
      :password,
      :parameters,
      :port,
      :socket_dir,
      :socket_options,
      :ssl,
      :ssl_opts,
      :timeout,
      :types,
      :url,
      :username
    ])
    |> Keyword.merge(name: CodexPooler.Events.PostgresNotifications, auto_reconnect: true)
  end
end
