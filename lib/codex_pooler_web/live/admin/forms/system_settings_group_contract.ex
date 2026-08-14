defmodule CodexPoolerWeb.Admin.SystemSettingsGroupContract do
  @moduledoc false

  alias CodexPooler.InstanceSettings.Defaults

  @groups ~w(gateway ingress files transcription operator catalog development mcp metrics smtp)
  @forwarded_client_ip_source_options [
    {"Peer connection", "peer"},
    {"X-Forwarded-For", "x_forwarded_for"},
    {"X-Real-IP", "x_real_ip"}
  ]
  @group_members %{
    "gateway" => ~w(gateway files transcription)
  }
  @runtime_groups %{
    "streaming" =>
      {"gateway",
       ~w(sse_keepalive_interval_ms websocket_idle_timeout_ms websocket_owner_idle_timeout_ms)},
    "upstream" =>
      {"gateway",
       ~w(upstream_connect_timeout_ms upstream_pool_timeout_ms upstream_receive_timeout_ms)},
    "continuity" =>
      {"gateway",
       ~w(expired_alias_ttl_seconds bridge_owner_lease_ttl_seconds bridge_owner_lease_renewal_seconds)},
    "circuit" =>
      {"gateway",
       ~w(circuit_failure_threshold circuit_open_seconds circuit_half_open_probe_limit circuit_success_threshold)},
    "files" =>
      {"files", ~w(max_size_bytes upload_ttl_seconds abandoned_upload_cleanup_interval_seconds)},
    "transcription" => {"transcription", ~w(max_upload_bytes)}
  }

  @spec groups() :: [String.t()]
  def groups, do: @groups

  @spec known?(String.t()) :: boolean()
  def known?(group), do: group in @groups

  @spec forwarded_client_ip_source_options() :: [{String.t(), String.t()}]
  def forwarded_client_ip_source_options, do: @forwarded_client_ip_source_options

  @spec members(String.t()) :: [String.t()]
  def members(group) when group in @groups, do: Map.get(@group_members, group, [group])

  @spec runtime_reset(String.t()) :: {:ok, {String.t(), [String.t()], map()}} | :error
  def runtime_reset(group) do
    with {:ok, {settings_group, fields}} <- Map.fetch(@runtime_groups, group),
         defaults when is_map(defaults) <- defaults_for_group(settings_group) do
      {:ok, {settings_group, fields, defaults}}
    else
      _invalid -> :error
    end
  end

  defp defaults_for_group("gateway"), do: Defaults.gateway()
  defp defaults_for_group("files"), do: Defaults.files()
  defp defaults_for_group("transcription"), do: Defaults.transcription()
end
