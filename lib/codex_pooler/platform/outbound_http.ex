defmodule CodexPooler.Platform.OutboundHTTP do
  @moduledoc """
  Finch pool options for every outbound Req request Codex Pooler sends.

  Req runs a request that carries Finch pool options on a dedicated Finch
  instance keyed by those options, with one HTTP/1 pool per origin, instead of
  the global unbounded `Req.Finch`. `pool_options/0` adds
  `conn_max_idle_time`, the longest a pooled connection may sit idle before it
  is closed at its next checkout instead of being reused. The value is the
  Instance Setting `gateway.upstream_conn_max_idle_time_ms`, read from the
  settings cache on each request, so a saved change applies without a restart.

  Every outbound caller needs the bound, not only gateway traffic: the gateway
  (through `TransportEnvelope.req_timeout_options/1`), provider usage probes,
  token refresh, saved-reset redemption, model catalog discovery, the pricing
  feed import, the OpenAI status feed, alert webhooks, and the file upload PUT
  to presigned storage. The less often a caller runs, the longer its pooled
  connection sits idle and the more likely an egress device has forgotten it.

  Finch checks the bound only at checkout, so it never interrupts an in-flight
  or streaming request. NimblePool hands idle connections out oldest first, so
  with no bound the stalest connection is the first one reused. A NAT, load
  balancer, or proxy that has already dropped that flow resets the next write,
  and the request fails `closed` in milliseconds after its bytes may have left
  the host. Req and Finch report send-phase and receive-phase closes as the
  same error, so that failure is not safe to retry for a POST or PUT; the bound
  removes the stale socket instead. A longer bound means fewer reconnects but
  more exposure to silently dropped connections.

  The 45 s default sits below the shortest idle timeouts common on egress
  paths, taken as common defaults rather than measurements: HAProxy `timeout
  client`/`timeout server` 50 s in the packaged Debian and Ubuntu config, AWS
  Application Load Balancer 60 s, nginx `keepalive_timeout` 75 s, Squid
  `client_idle_pconn_timeout` 2 min, Azure load balancer and NAT gateway 4 min,
  AWS NAT gateway and Network Load Balancer 350 s, and GCP Cloud NAT
  established TCP 20 min. Linux conntrack and common firewall session timeouts
  are hours or days and do not constrain it. An installation whose egress drops
  idle flows sooner lowers the setting; the 1 h maximum stands in for "no
  bound", because a connection idle that long costs one reconnect. Values
  outside the bounds, which only a stale cache or a hand-edited row can carry,
  are clamped so a bad value cannot make Finch reject every outbound request.

  Callers add `finch: pool_options()` and keep their own receive, retry, and
  redirect options. Req starts one Finch instance per distinct `finch:` pool
  option tuple; `pool_timeout` and `receive_timeout` are per-request options
  outside that key. Every caller that needs no connect timeout of its own
  passes exactly these options, so they share one instance per saved value; a
  caller that sets a connect timeout adds `conn_opts` and gets its own instance
  per idle bound and connect timeout pair. `pool_max_idle_time` stays unset, so
  no instance is ever stopped: stopping an idle per-origin pool can race a
  request that has just looked it up, and stale connections are already
  dropped at checkout. Each distinct combination of this setting and the
  gateway connect timeout saved since boot therefore keeps its pools until
  restart, so both settings are low-churn and must not be driven from
  automation. Req refuses `finch:` together with `connect_options:`, so a
  connect timeout travels as `conn_opts: [transport_opts: [timeout: ms]]`
  inside `finch:`.
  """

  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.Settings

  @conn_max_idle_time_default_ms 45_000
  @conn_max_idle_time_min_ms 1_000
  @conn_max_idle_time_max_ms 3_600_000

  @type pool_options :: [conn_max_idle_time: non_neg_integer()]

  @doc """
  Finch pool options carrying the current outbound connection idle bound.
  """
  @spec pool_options() :: pool_options()
  def pool_options, do: pool_options(current_conn_max_idle_time_ms())

  @doc """
  Finch pool options for an idle bound the caller already read from a settings
  snapshot, such as the gateway operational settings.
  """
  @spec pool_options(non_neg_integer()) :: pool_options()
  def pool_options(conn_max_idle_time_ms)
      when is_integer(conn_max_idle_time_ms) and conn_max_idle_time_ms >= 0,
      do: [conn_max_idle_time: conn_max_idle_time_ms]

  @doc """
  The clamped outbound connection idle bound carried by `settings`.
  """
  @spec conn_max_idle_time_ms(Settings.t()) :: pos_integer()
  def conn_max_idle_time_ms(%Settings{gateway: gateway}) do
    gateway
    |> Map.get(:upstream_conn_max_idle_time_ms)
    |> clamp_conn_max_idle_time()
  end

  @spec default_conn_max_idle_time_ms() :: pos_integer()
  def default_conn_max_idle_time_ms, do: @conn_max_idle_time_default_ms

  if Mix.env() == :test do
    # Tests read the code default unless they opt into the settings cache, so
    # async tests without a sandbox never reach the database; an explicit
    # override may go below the Instance Setting minimum on purpose.
    defp current_conn_max_idle_time_ms do
      config = Application.get_env(:codex_pooler, __MODULE__, [])

      case Keyword.fetch(config, :conn_max_idle_time_ms) do
        {:ok, value} ->
          value

        :error ->
          if Keyword.get(config, :use_instance_settings?, false),
            do: conn_max_idle_time_ms(InstanceSettings.current()),
            else: @conn_max_idle_time_default_ms
      end
    end
  else
    defp current_conn_max_idle_time_ms, do: conn_max_idle_time_ms(InstanceSettings.current())
  end

  defp clamp_conn_max_idle_time(value) when is_integer(value) do
    value
    |> max(@conn_max_idle_time_min_ms)
    |> min(@conn_max_idle_time_max_ms)
  end

  defp clamp_conn_max_idle_time(_value), do: @conn_max_idle_time_default_ms
end
