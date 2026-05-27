defmodule CodexPooler.InstanceSettings.Defaults do
  @moduledoc false

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.InstanceSettings.Classification

  @transcription_max_upload_bytes 26_214_400
  @operator_login_base_url "http://localhost"
  @openai_pricing_url "https://icoretech.github.io/openai-json-pricing/pricing.json"
  @smtp_from "codex-pooler@example.com"

  @spec gateway() :: map()
  def gateway do
    settings = %OperationalSettings{}

    %{
      "gateway_debug" => settings.gateway_debug?,
      "sse_keepalive_interval_ms" => settings.sse_keepalive_interval_ms,
      "upstream_connect_timeout_ms" => settings.upstream_connect_timeout_ms,
      "upstream_pool_timeout_ms" => settings.upstream_pool_timeout_ms,
      "upstream_receive_timeout_ms" => settings.upstream_receive_timeout_ms,
      "upstream_user_agent" => settings.upstream_user_agent,
      "expired_alias_ttl_seconds" => settings.expired_alias_ttl_seconds,
      "bridge_owner_lease_ttl_seconds" => settings.bridge_owner_lease_ttl_seconds,
      "bridge_owner_lease_renewal_seconds" => settings.bridge_owner_lease_renewal_seconds,
      "circuit_failure_threshold" => settings.circuit_failure_threshold,
      "circuit_open_seconds" => settings.circuit_open_seconds,
      "circuit_half_open_probe_limit" => settings.circuit_half_open_probe_limit,
      "circuit_success_threshold" => settings.circuit_success_threshold,
      "bulkheads" => stringify_nested_map(settings.bulkheads),
      "model_context_window_overrides" => settings.model_context_window_overrides
    }
  end

  @spec ingress() :: map()
  def ingress do
    settings = %OperationalSettings{}

    %{
      "firewall_allowlist" => settings.firewall_allowlist,
      "trusted_proxies" => settings.trusted_proxies,
      "decompression_algorithms" => settings.decompression_algorithms,
      "max_compressed_body_bytes" => settings.max_compressed_body_bytes,
      "max_decompressed_body_bytes" => settings.max_decompressed_body_bytes,
      "max_decompression_ratio" => settings.max_decompression_ratio,
      "decompression_timeout_ms" => settings.decompression_timeout_ms
    }
  end

  @spec files() :: map()
  def files do
    settings = %OperationalSettings{}

    %{
      "max_size_bytes" => settings.file_max_size_bytes,
      "upload_ttl_seconds" => settings.upload_ttl_seconds,
      "abandoned_upload_cleanup_interval_seconds" =>
        settings.abandoned_upload_cleanup_interval_seconds
    }
  end

  @spec transcription() :: map()
  def transcription, do: %{"max_upload_bytes" => @transcription_max_upload_bytes}

  @spec operator() :: map()
  def operator, do: %{"login_base_url" => @operator_login_base_url}

  @spec catalog() :: map()
  def catalog, do: %{"openai_pricing_url" => @openai_pricing_url}

  @spec development() :: map()
  def development do
    %{"impeccable_live_enabled" => false, "account_reconciliation_paused" => false}
  end

  @spec mcp() :: map()
  def mcp, do: %{"enabled" => false}

  @spec metrics() :: map()
  def metrics do
    %{
      "bearer_token_hmac_digest" => nil,
      "bearer_token_fingerprint" => nil,
      "bearer_token_key_version" => nil
    }
  end

  @spec smtp() :: map()
  def smtp do
    %{
      "enabled" => false,
      "host" => nil,
      "port" => 587,
      "username" => nil,
      "from" => @smtp_from,
      "ssl" => false,
      "tls" => "if_available",
      "retries" => 2,
      "password_ciphertext" => nil,
      "password_nonce" => nil,
      "password_aad" => nil,
      "password_key_version" => nil
    }
  end

  @spec all() :: map()
  def all do
    :ok = Classification.validate_candidate_coverage()

    %{
      gateway: gateway(),
      ingress: ingress(),
      files: files(),
      transcription: transcription(),
      operator: operator(),
      catalog: catalog(),
      development: development(),
      mcp: mcp(),
      metrics: metrics(),
      smtp: smtp(),
      metadata: %{"defaults_contract" => "instance_settings_v1"}
    }
  end

  defp stringify_nested_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
