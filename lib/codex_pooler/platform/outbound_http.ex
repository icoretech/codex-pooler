defmodule CodexPooler.Platform.OutboundHTTP do
  @moduledoc """
  Finch pool options for every outbound Req request Codex Pooler sends, plus
  the standard boot-time proxy environment shared by Req and upstream
  WebSockets.

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

  Callers add `finch: pool_options_for_url(url)` and keep their own receive,
  retry, and redirect options. Req starts one Finch instance per distinct `finch:` pool
  option tuple; `pool_timeout` and `receive_timeout` are per-request options
  outside that key. Every caller that needs no connect timeout of its own
  passes exactly these options, so they share one instance per saved value; a
  caller that sets a connect timeout passes it to `pool_options_for_url/2` and
  gets its own instance per idle bound and connect timeout pair. The optional
  selected boot-time proxy is also part of the pool tuple. `pool_max_idle_time` stays
  unset, so no instance is ever stopped: stopping an idle per-origin pool can
  race a request that has just looked it up, and stale connections are already
  dropped at checkout. Each distinct combination of this setting, proxy, and
  gateway connect timeout therefore keeps its pools until restart, so the live
  settings are low-churn and must not be driven from automation. Req refuses
  `finch:` together with `connect_options:`, so a connect timeout travels as
  `conn_opts: [transport_opts: [timeout: ms]]` inside `finch:`.
  """

  alias CodexPooler.InstanceSettings
  alias CodexPooler.InstanceSettings.Settings

  @conn_max_idle_time_default_ms 45_000
  @conn_max_idle_time_min_ms 1_000
  @conn_max_idle_time_max_ms 3_600_000
  @invalid_proxy_message "proxy environment variables must be http:// URLs containing only authority and optional basic credentials"

  @type pool_options :: keyword()

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
      do: pool_options_with_conn_opts(conn_max_idle_time_ms, [])

  @doc """
  Builds Finch pool options with caller-specific Mint connection options when
  no target URL is available. Production outbound calls use
  `pool_options_for_url/2` so scheme selection and `no_proxy` can be applied.
  """
  @spec pool_options_with_conn_opts(keyword()) :: pool_options()
  def pool_options_with_conn_opts(conn_opts) when is_list(conn_opts),
    do: pool_options_with_conn_opts(current_conn_max_idle_time_ms(), conn_opts)

  @spec pool_options_with_conn_opts(non_neg_integer(), keyword()) :: pool_options()
  def pool_options_with_conn_opts(conn_max_idle_time_ms, conn_opts)
      when is_integer(conn_max_idle_time_ms) and conn_max_idle_time_ms >= 0 and
             is_list(conn_opts) do
    pool_options = [conn_max_idle_time: conn_max_idle_time_ms]

    if conn_opts == [], do: pool_options, else: [conn_opts: conn_opts] ++ pool_options
  end

  @doc """
  Builds pool options for `url`, selecting `http_proxy` or `https_proxy` and
  honoring `no_proxy`.
  """
  @spec pool_options_for_url(String.t() | URI.t(), keyword()) :: pool_options()
  def pool_options_for_url(url, conn_opts \\ []) do
    pool_options_for_url(url, current_conn_max_idle_time_ms(), conn_opts)
  end

  @spec pool_options_for_url(String.t() | URI.t(), non_neg_integer(), keyword()) :: pool_options()
  def pool_options_for_url(url, conn_max_idle_time_ms, conn_opts)
      when is_integer(conn_max_idle_time_ms) and conn_max_idle_time_ms >= 0 and
             is_list(conn_opts) do
    conn_opts = Keyword.merge(proxy_options_for_url(url, conn_opts), conn_opts)
    pool_options = [conn_max_idle_time: conn_max_idle_time_ms]

    if conn_opts == [], do: pool_options, else: [conn_opts: conn_opts] ++ pool_options
  end

  @doc "Returns Mint connection options selected for the target URL."
  @spec proxy_options_for_url(String.t() | URI.t(), keyword()) :: keyword()
  def proxy_options_for_url(url, connect_opts \\ []) when is_list(connect_opts) do
    uri = if is_struct(url, URI), do: url, else: URI.parse(url)
    config = proxy_config()

    if no_proxy?(uri, config.no_proxy) do
      []
    else
      uri.scheme
      |> proxy_for_scheme(config)
      |> proxy_with_connect_timeout(connect_opts)
    end
  end

  defp proxy_with_connect_timeout([], _connect_opts), do: []

  defp proxy_with_connect_timeout(proxy_options, connect_opts) do
    proxy_connect_opts =
      case get_in(connect_opts, [:transport_opts, :timeout]) do
        timeout when is_integer(timeout) -> [transport_opts: [timeout: timeout]]
        _other -> []
      end

    Enum.map(proxy_options, fn
      {:proxy, {scheme, host, port, _opts}} ->
        {:proxy, {scheme, host, port, proxy_connect_opts}}

      option ->
        option
    end)
  end

  @doc "Reads lowercase proxy variables, with uppercase variants as fallbacks."
  @spec proxy_config_from_env!() :: map()
  def proxy_config_from_env! do
    %{
      http: parse_proxy_url!(proxy_env("http_proxy", "HTTP_PROXY")),
      https: parse_proxy_url!(proxy_env("https_proxy", "HTTPS_PROXY")),
      no_proxy: parse_no_proxy(proxy_env("no_proxy", "NO_PROXY"))
    }
  end

  @doc """
  Parses one standard proxy environment variable into Mint connection options.

  Only an `http://` proxy is accepted because Mint cannot tunnel an HTTPS
  destination through an HTTPS proxy.
  """
  @spec parse_proxy_url!(String.t() | nil) :: keyword()
  def parse_proxy_url!(value) when value in [nil, ""], do: []

  def parse_proxy_url!(value) when is_binary(value) do
    try do
      uri = URI.parse(value)
      port = uri.port || 80

      if uri.scheme != "http" or not is_binary(uri.host) or uri.host == "" or
           not is_integer(port) or port not in 1..65_535 or uri.path not in [nil, "", "/"] or
           not is_nil(uri.query) or not is_nil(uri.fragment) do
        raise ArgumentError, @invalid_proxy_message
      end

      proxy = {:http, uri.host, port, []}

      case proxy_authorization(uri.userinfo) do
        nil -> [proxy: proxy]
        authorization -> [proxy: proxy, proxy_headers: [{"proxy-authorization", authorization}]]
      end
    rescue
      _invalid in [ArgumentError, URI.Error] -> raise ArgumentError, @invalid_proxy_message
    end
  end

  defp proxy_authorization(nil), do: nil

  defp proxy_authorization(userinfo) do
    "Basic " <> Base.encode64(URI.decode(userinfo))
  end

  defp proxy_config do
    Application.get_env(:codex_pooler, __MODULE__, [])
    |> Keyword.get(:proxy_config, %{http: [], https: [], no_proxy: []})
  end

  defp proxy_env(lowercase, uppercase) do
    case System.fetch_env(lowercase) do
      {:ok, value} -> value
      :error -> System.get_env(uppercase)
    end
  end

  defp parse_no_proxy(value) when value in [nil, ""], do: []

  defp parse_no_proxy(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp proxy_for_scheme("http", config), do: config.http
  defp proxy_for_scheme("https", config), do: config.https
  defp proxy_for_scheme(_scheme, _config), do: []

  defp no_proxy?(%URI{host: host, port: port}, entries) when is_binary(host) do
    host = normalize_host(host)
    Enum.any?(entries, &no_proxy_entry?(&1, host, port))
  end

  defp no_proxy?(_uri, _entries), do: false

  defp no_proxy_entry?("*", _host, _port), do: true

  defp no_proxy_entry?(entry, host, port) do
    {entry_host, entry_port} = split_no_proxy_entry(entry)
    entry_host = normalize_host(entry_host)
    port_matches? = is_nil(entry_port) or entry_port == port

    port_matches? and (cidr_match?(host, entry_host) or host_matches?(host, entry_host))
  end

  defp host_matches?(host, entry_host) do
    host == entry_host or
      (not ip_address?(host) and String.ends_with?(host, "." <> entry_host))
  end

  defp cidr_match?(host, entry) do
    with [network, prefix] <- String.split(entry, "/", parts: 2),
         {:ok, address} <- :inet.parse_address(String.to_charlist(host)),
         {:ok, network_address} <- :inet.parse_address(String.to_charlist(network)),
         true <- tuple_size(address) == tuple_size(network_address),
         {prefix, ""} <- Integer.parse(prefix),
         segment_bits = address_segment_bits(address),
         bits = tuple_size(address) * segment_bits,
         true <- prefix in 0..bits do
      shift = bits - prefix
      divisor = Integer.pow(2, shift)

      div(address_integer(address, segment_bits), divisor) ==
        div(address_integer(network_address, segment_bits), divisor)
    else
      _no_match -> false
    end
  end

  defp address_integer(address, segment_bits) do
    address
    |> Tuple.to_list()
    |> Enum.reduce(0, fn segment, value -> value * Integer.pow(2, segment_bits) + segment end)
  end

  defp address_segment_bits(address) when tuple_size(address) == 4, do: 8
  defp address_segment_bits(_address), do: 16

  defp split_no_proxy_entry("[" <> rest = entry) do
    case String.split(rest, "]", parts: 2) do
      [host, ":" <> port] -> {host, parse_no_proxy_port(port)}
      [host, ""] -> {host, nil}
      _invalid -> {entry, nil}
    end
  end

  defp split_no_proxy_entry(entry) do
    case String.split(entry, ":") do
      [host, port] -> {host, parse_no_proxy_port(port)}
      _host_or_ipv6 -> {entry, nil}
    end
  end

  defp parse_no_proxy_port(port) do
    case Integer.parse(port) do
      {value, ""} when value in 1..65_535 -> value
      _invalid -> :invalid
    end
  end

  defp normalize_host(host) do
    host
    |> String.downcase()
    |> String.trim_trailing(".")
    |> String.trim_leading("*.")
    |> String.trim_leading(".")
  end

  defp ip_address?(host), do: match?({:ok, _address}, :inet.parse_address(String.to_charlist(host)))

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
