defmodule CodexPooler.Gateway.OperationalSettings do
  @moduledoc """
  Runtime-configurable gateway hardening and Codex settings.
  """

  alias CodexPooler.{InstanceSettings, RouteClass}

  @default_decompression_algorithms ["gzip", "deflate", "zstd"]
  @default_upstream_user_agent "codex_cli_rs/0.0.0"
  @default_bulkheads RouteClass.default_bulkheads()
  @websocket_owner_forwarding_env "CODEX_POOLER_WEBSOCKET_OWNER_FORWARDING"
  @websocket_owner_forwarding_allowed_values "true,false,1,0,yes,no,on,off"
  @websocket_owner_forwarding_truthy ~w(true 1 yes on)
  @websocket_owner_forwarding_falsey ~w(false 0 no off)

  @type bulkhead_settings :: %{
          max_concurrency: pos_integer(),
          queue_limit: non_neg_integer(),
          queue_timeout_ms: pos_integer()
        }

  @type t :: %__MODULE__{
          file_max_size_bytes: pos_integer(),
          upload_ttl_seconds: pos_integer(),
          abandoned_upload_cleanup_interval_seconds: pos_integer(),
          bridge_owner_lease_ttl_seconds: pos_integer(),
          bridge_owner_lease_renewal_seconds: pos_integer(),
          expired_alias_ttl_seconds: pos_integer(),
          firewall_allowlist: [String.t()],
          trusted_proxies: [String.t()],
          decompression_algorithms: [String.t()],
          zstd_supported?: boolean(),
          max_compressed_body_bytes: pos_integer(),
          max_decompressed_body_bytes: pos_integer(),
          max_decompression_ratio: pos_integer(),
          decompression_timeout_ms: pos_integer(),
          gateway_debug?: boolean(),
          sse_keepalive_interval_ms: non_neg_integer(),
          bulkheads: %{String.t() => bulkhead_settings()},
          circuit_failure_threshold: pos_integer(),
          circuit_open_seconds: pos_integer(),
          circuit_half_open_probe_limit: pos_integer(),
          circuit_success_threshold: pos_integer(),
          upstream_connect_timeout_ms: pos_integer(),
          upstream_pool_timeout_ms: pos_integer(),
          upstream_receive_timeout_ms: pos_integer(),
          upstream_user_agent: String.t(),
          model_context_window_overrides: %{String.t() => pos_integer()}
        }

  defstruct file_max_size_bytes: 25 * 1024 * 1024,
            upload_ttl_seconds: 24 * 60 * 60,
            abandoned_upload_cleanup_interval_seconds: 15 * 60,
            bridge_owner_lease_ttl_seconds: 45,
            bridge_owner_lease_renewal_seconds: 15,
            expired_alias_ttl_seconds: 24 * 60 * 60,
            firewall_allowlist: [],
            trusted_proxies: [],
            decompression_algorithms: @default_decompression_algorithms,
            zstd_supported?: true,
            max_compressed_body_bytes: 32 * 1024 * 1024,
            max_decompressed_body_bytes: 64 * 1024 * 1024,
            max_decompression_ratio: 200,
            decompression_timeout_ms: 10_000,
            gateway_debug?: false,
            sse_keepalive_interval_ms: 10_000,
            bulkheads: @default_bulkheads,
            circuit_failure_threshold: 3,
            circuit_open_seconds: 60,
            circuit_half_open_probe_limit: 1,
            circuit_success_threshold: 1,
            upstream_connect_timeout_ms: :timer.seconds(15),
            upstream_pool_timeout_ms: :timer.seconds(15),
            upstream_receive_timeout_ms: :timer.minutes(5),
            upstream_user_agent: @default_upstream_user_agent,
            model_context_window_overrides: %{}

  @spec current() :: t()
  def current do
    case test_settings_override() do
      %__MODULE__{} = settings -> settings
      nil -> InstanceSettings.current() |> from_instance_settings()
    end
  end

  @spec from_instance_settings(InstanceSettings.Settings.t()) :: t()
  def from_instance_settings(%InstanceSettings.Settings{} = settings) do
    %__MODULE__{
      file_max_size_bytes: settings.files.max_size_bytes,
      upload_ttl_seconds: settings.files.upload_ttl_seconds,
      abandoned_upload_cleanup_interval_seconds:
        settings.files.abandoned_upload_cleanup_interval_seconds,
      bridge_owner_lease_ttl_seconds: settings.gateway.bridge_owner_lease_ttl_seconds,
      bridge_owner_lease_renewal_seconds: settings.gateway.bridge_owner_lease_renewal_seconds,
      expired_alias_ttl_seconds: settings.gateway.expired_alias_ttl_seconds,
      firewall_allowlist: settings.ingress.firewall_allowlist,
      trusted_proxies: settings.ingress.trusted_proxies,
      decompression_algorithms: settings.ingress.decompression_algorithms,
      zstd_supported?: true,
      max_compressed_body_bytes: settings.ingress.max_compressed_body_bytes,
      max_decompressed_body_bytes: settings.ingress.max_decompressed_body_bytes,
      max_decompression_ratio: settings.ingress.max_decompression_ratio,
      decompression_timeout_ms: settings.ingress.decompression_timeout_ms,
      gateway_debug?: settings.gateway.gateway_debug,
      sse_keepalive_interval_ms: settings.gateway.sse_keepalive_interval_ms,
      bulkheads: normalize_bulkheads(settings.gateway.bulkheads),
      circuit_failure_threshold: settings.gateway.circuit_failure_threshold,
      circuit_open_seconds: settings.gateway.circuit_open_seconds,
      circuit_half_open_probe_limit: settings.gateway.circuit_half_open_probe_limit,
      circuit_success_threshold: settings.gateway.circuit_success_threshold,
      upstream_connect_timeout_ms: settings.gateway.upstream_connect_timeout_ms,
      upstream_pool_timeout_ms: settings.gateway.upstream_pool_timeout_ms,
      upstream_receive_timeout_ms: settings.gateway.upstream_receive_timeout_ms,
      upstream_user_agent: settings.gateway.upstream_user_agent,
      model_context_window_overrides: settings.gateway.model_context_window_overrides
    }
  end

  @spec default_upstream_user_agent() :: String.t()
  def default_upstream_user_agent, do: @default_upstream_user_agent

  @spec firewall_enabled?(t()) :: boolean()
  def firewall_enabled?(%__MODULE__{firewall_allowlist: allowlist}), do: allowlist != []

  @spec websocket_owner_forwarding_env_name() :: String.t()
  def websocket_owner_forwarding_env_name, do: @websocket_owner_forwarding_env

  @spec websocket_owner_forwarding_enabled?() :: boolean()
  def websocket_owner_forwarding_enabled? do
    Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled, false)
  end

  @spec parse_websocket_owner_forwarding_env!() :: boolean()
  def parse_websocket_owner_forwarding_env! do
    @websocket_owner_forwarding_env
    |> System.get_env()
    |> parse_websocket_owner_forwarding!()
  end

  @spec parse_websocket_owner_forwarding!(String.t() | nil) :: boolean()
  def parse_websocket_owner_forwarding!(nil), do: false

  def parse_websocket_owner_forwarding!(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    cond do
      normalized in @websocket_owner_forwarding_truthy ->
        true

      normalized in @websocket_owner_forwarding_falsey ->
        false

      true ->
        raise ArgumentError,
              "#{@websocket_owner_forwarding_env} must be one of #{@websocket_owner_forwarding_allowed_values}"
    end
  end

  defp test_settings_override do
    if Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) and Mix.env() == :test do
      config = Application.get_env(:codex_pooler, __MODULE__, [])

      unless Keyword.get(config, :use_instance_settings?, false) do
        Keyword.get(config, :settings, %__MODULE__{})
      end
    end
  end

  defp normalize_bulkheads(bulkheads) when is_map(bulkheads) do
    configured =
      Map.new(bulkheads, fn {route_class, config} ->
        {to_string(route_class), normalize_bulkhead_config(config)}
      end)

    Map.merge(@default_bulkheads, configured)
  end

  defp normalize_bulkhead_config(config) do
    %{
      max_concurrency: map_value(config, :max_concurrency),
      queue_limit: map_value(config, :queue_limit),
      queue_timeout_ms: map_value(config, :queue_timeout_ms)
    }
  end

  defp map_value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.fetch!(map, Atom.to_string(key))
    end
  end
end
