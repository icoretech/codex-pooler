defmodule CodexPoolerWeb.Admin.SystemPageComponents.Gateway do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.SystemPageComponents.FormControls

  attr :selected_tab, :string, required: true
  attr :forms, :map, required: true
  attr :form_params, :map, required: true
  attr :settings, :any, required: true
  attr :card_statuses, :map, required: true

  def cards(assigns) do
    ~H"""
    <FormControls.settings_card
      :if={@selected_tab == "gateway"}
      group="gateway"
      form={@forms["gateway"]}
      status={@card_statuses["gateway"]}
    >
      <.inputs_for :let={gateway_form} field={@forms["gateway"][:gateway]}>
        <FormControls.settings_group
          id="instance-settings-gateway"
          eyebrow="Gateway"
          title="Gateway controls"
          description="Admission, timeout, continuity, routing, and circuit guardrails for new gateway work."
          hint="Most values reload through the settings cache for new work; existing in-flight work keeps the runtime values it started with."
        >
          <div class="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
            <FormControls.scalar_controls form={gateway_form} controls={gateway_scalar_controls()} />
          </div>
          <div class="grid gap-4 lg:grid-cols-2">
            <FormControls.json_textarea
              id="instance-settings-bulkheads"
              name="instance_settings[gateway][bulkheads]"
              label="Route-class bulkheads"
              value={
                param_json_value(@form_params, "gateway", "bulkheads", @settings.gateway.bulkheads)
              }
              hint="Per route-class concurrency, queue length, and queue timeout policy as JSON."
            />
            <FormControls.json_textarea
              id="instance-settings-model-context-window-overrides"
              name="instance_settings[gateway][model_context_window_overrides]"
              label="Model context window overrides"
              value={
                param_json_value(
                  @form_params,
                  "gateway",
                  "model_context_window_overrides",
                  @settings.gateway.model_context_window_overrides
                )
              }
              hint="Model-specific context window sizes used when upstream metadata is missing or needs correction."
            />
          </div>
        </FormControls.settings_group>
      </.inputs_for>
    </FormControls.settings_card>

    <FormControls.settings_card
      :if={@selected_tab == "gateway"}
      group="ingress"
      form={@forms["ingress"]}
      status={@card_statuses["ingress"]}
    >
      <.inputs_for :let={ingress_form} field={@forms["ingress"][:ingress]}>
        <FormControls.settings_group
          id="instance-settings-ingress"
          eyebrow="Ingress"
          title="Runtime ingress"
          description="Firewall, trusted proxy, and compressed-body controls for compatibility routes."
          hint="Evaluated for new requests; keep proxy lists metadata-only and CIDR based."
        >
          <div class="grid gap-4 lg:grid-cols-2">
            <FormControls.list_textarea
              id="instance-settings-firewall-allowlist"
              name="instance_settings[ingress][firewall_allowlist]"
              label="Firewall allowlist"
              placeholder={firewall_allowlist_placeholder()}
              value={
                param_list_value(
                  @form_params,
                  "ingress",
                  "firewall_allowlist",
                  @settings.ingress.firewall_allowlist
                )
              }
            />
            <FormControls.list_textarea
              id="instance-settings-trusted-proxies"
              name="instance_settings[ingress][trusted_proxies]"
              label="Trusted proxies"
              placeholder={trusted_proxies_placeholder()}
              value={
                param_list_value(
                  @form_params,
                  "ingress",
                  "trusted_proxies",
                  @settings.ingress.trusted_proxies
                )
              }
            />
            <div class="lg:col-span-2">
              <FormControls.compressed_json_encoding_checkboxes
                id="instance-settings-decompression-algorithms"
                name="instance_settings[ingress][decompression_algorithms]"
                values={
                  param_array_value(
                    @form_params,
                    "ingress",
                    "decompression_algorithms",
                    @settings.ingress.decompression_algorithms
                  )
                }
              />
            </div>
          </div>
          <div class="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
            <FormControls.scalar_controls form={ingress_form} controls={ingress_scalar_controls()} />
          </div>
        </FormControls.settings_group>
      </.inputs_for>
    </FormControls.settings_card>

    <FormControls.settings_card
      :if={@selected_tab == "gateway"}
      group="files"
      form={@forms["files"]}
      status={@card_statuses["files"]}
    >
      <.inputs_for :let={files_form} field={@forms["files"][:files]}>
        <FormControls.settings_group
          id="instance-settings-files"
          eyebrow="Files"
          title="File bridge limits"
          description="Upload size, metadata TTL, and cleanup cadence for upstream-backed file payloads."
          hint="Applies to new uploads and cleanup jobs; stored file metadata remains metadata-only."
        >
          <div class="grid gap-4 md:grid-cols-3">
            <FormControls.scalar_controls form={files_form} controls={files_scalar_controls()} />
          </div>
        </FormControls.settings_group>
      </.inputs_for>
    </FormControls.settings_card>

    <FormControls.settings_card
      :if={@selected_tab == "gateway"}
      group="transcription"
      form={@forms["transcription"]}
      status={@card_statuses["transcription"]}
    >
      <.inputs_for :let={transcription_form} field={@forms["transcription"][:transcription]}>
        <FormControls.settings_group
          id="instance-settings-transcription"
          eyebrow="Transcription"
          title="Audio upload limit"
          description="Runtime limit for new audio transcription multipart uploads."
          hint="Reloads live for new requests and keeps audio bytes out of admin surfaces."
        >
          <div class="max-w-md">
            <FormControls.scalar_controls
              form={transcription_form}
              controls={transcription_scalar_controls()}
            />
          </div>
        </FormControls.settings_group>
      </.inputs_for>
    </FormControls.settings_card>

    <FormControls.settings_card
      :if={@selected_tab == "gateway"}
      group="operator"
      form={@forms["operator"]}
      status={@card_statuses["operator"]}
    >
      <.inputs_for :let={operator_form} field={@forms["operator"][:operator]}>
        <FormControls.settings_group
          id="instance-settings-operator"
          eyebrow="Operator email"
          title="Public operator app URL"
          description="Public browser URL for this operator app. Operator emails append /login to this value."
          hint="Store the app root URL, not the login path. Email links are generated from the current saved setting at send time."
        >
          <div class="max-w-xl">
            <.input
              id="instance-settings-operator-login-base-url"
              field={operator_form[:login_base_url]}
              type="url"
              label="Public operator app URL"
              placeholder="https://codex-pooler.example.com"
            />
          </div>
        </FormControls.settings_group>
      </.inputs_for>
    </FormControls.settings_card>

    <FormControls.settings_card
      :if={@selected_tab == "gateway"}
      group="catalog"
      form={@forms["catalog"]}
      status={@card_statuses["catalog"]}
    >
      <.inputs_for :let={catalog_form} field={@forms["catalog"][:catalog]}>
        <FormControls.settings_group
          id="instance-settings-catalog"
          eyebrow="Catalog"
          title="Pricing catalog source"
          description="Published OpenAI pricing JSON used by the hourly pricing snapshot refresh."
          hint="The migration hook and local dev seed still import the vendored JSON file; the scheduler resolves this URL when each pricing import job runs."
        >
          <div class="max-w-2xl">
            <.input
              id="instance-settings-openai-pricing-url"
              field={catalog_form[:openai_pricing_url]}
              type="url"
              label="OpenAI pricing URL"
              placeholder="https://icoretech.github.io/openai-json-pricing/pricing.json"
            />
          </div>
        </FormControls.settings_group>
      </.inputs_for>
    </FormControls.settings_card>
    """
  end

  defp firewall_allowlist_placeholder do
    Enum.join(["198.51.100.10/32", "203.0.113.0/24", "2001:db8::/32"], "\n")
  end

  defp trusted_proxies_placeholder do
    Enum.join(["10.0.0.0/8", "172.16.0.0/12", "2001:db8:10::/48"], "\n")
  end

  defp gateway_scalar_controls do
    [
      %{
        type: :toggle,
        id: "instance-settings-gateway-debug",
        field: :gateway_debug,
        label: "Gateway debug metadata",
        hint: "Records sanitized request/attempt routing metadata for new gateway requests."
      },
      %{
        type: :number,
        id: "instance-settings-sse-keepalive-interval-ms",
        field: :sse_keepalive_interval_ms,
        label: "SSE keepalive (ms)",
        hint: "Interval for downstream SSE heartbeat events; 0 disables heartbeats."
      },
      %{
        type: :number,
        id: "instance-settings-websocket-idle-timeout-ms",
        field: :websocket_idle_timeout_ms,
        label: "Websocket idle timeout (ms)",
        hint: "Bounded downstream websocket idle window for new upgrades."
      },
      %{
        type: :number,
        id: "instance-settings-upstream-connect-timeout-ms",
        field: :upstream_connect_timeout_ms,
        label: "Connect timeout (ms)",
        hint: "Maximum time allowed to establish a connection to an upstream account."
      },
      %{
        type: :number,
        id: "instance-settings-upstream-pool-timeout-ms",
        field: :upstream_pool_timeout_ms,
        label: "Pool timeout (ms)",
        hint: "Maximum time a gateway request may wait for an available pooled connection."
      },
      %{
        type: :number,
        id: "instance-settings-upstream-receive-timeout-ms",
        field: :upstream_receive_timeout_ms,
        label: "Receive timeout (ms)",
        hint: "Maximum idle receive window while waiting for upstream response data."
      },
      %{
        type: :number,
        id: "instance-settings-expired-alias-ttl-seconds",
        field: :expired_alias_ttl_seconds,
        label: "Expired alias TTL (s)",
        hint: "How long expired response aliases stay available for continuity lookups."
      },
      %{
        type: :number,
        id: "instance-settings-bridge-owner-lease-ttl-seconds",
        field: :bridge_owner_lease_ttl_seconds,
        label: "Owner lease TTL (s)",
        hint: "How long a bridge owner lease remains valid without renewal."
      },
      %{
        type: :number,
        id: "instance-settings-bridge-owner-lease-renewal-seconds",
        field: :bridge_owner_lease_renewal_seconds,
        label: "Owner lease renewal (s)",
        hint: "How often active bridge owners renew their lease while work is running."
      },
      %{
        type: :number,
        id: "instance-settings-circuit-failure-threshold",
        field: :circuit_failure_threshold,
        label: "Circuit failure threshold",
        hint: "Consecutive failed attempts needed before opening an upstream circuit."
      },
      %{
        type: :number,
        id: "instance-settings-circuit-open-seconds",
        field: :circuit_open_seconds,
        label: "Circuit open window (s)",
        hint: "How long an opened circuit stays closed to normal traffic before probing."
      },
      %{
        type: :number,
        id: "instance-settings-circuit-half-open-probe-limit",
        field: :circuit_half_open_probe_limit,
        label: "Half-open probe limit",
        hint: "Concurrent probe attempts allowed while testing a half-open circuit."
      },
      %{
        type: :number,
        id: "instance-settings-circuit-success-threshold",
        field: :circuit_success_threshold,
        label: "Circuit close successes",
        hint: "Successful probes required before closing a previously opened circuit."
      }
    ]
  end

  defp ingress_scalar_controls do
    [
      %{
        type: :number,
        id: "instance-settings-max-compressed-body-bytes",
        field: :max_compressed_body_bytes,
        label: "Max compressed bytes"
      },
      %{
        type: :number,
        id: "instance-settings-max-decompressed-body-bytes",
        field: :max_decompressed_body_bytes,
        label: "Max decompressed bytes"
      },
      %{
        type: :number,
        id: "instance-settings-max-decompression-ratio",
        field: :max_decompression_ratio,
        label: "Max ratio"
      },
      %{
        type: :number,
        id: "instance-settings-decompression-timeout-ms",
        field: :decompression_timeout_ms,
        label: "Timeout (ms)"
      }
    ]
  end

  defp files_scalar_controls do
    [
      %{
        type: :number,
        id: "instance-settings-file-max-size-bytes",
        field: :max_size_bytes,
        label: "Max size bytes"
      },
      %{
        type: :number,
        id: "instance-settings-upload-ttl-seconds",
        field: :upload_ttl_seconds,
        label: "Upload TTL seconds"
      },
      %{
        type: :number,
        id: "instance-settings-abandoned-upload-cleanup-interval-seconds",
        field: :abandoned_upload_cleanup_interval_seconds,
        label: "Cleanup interval seconds"
      }
    ]
  end

  defp transcription_scalar_controls do
    [
      %{
        type: :number,
        id: "instance-settings-transcription-max-upload-bytes",
        field: :max_upload_bytes,
        label: "Max upload bytes"
      }
    ]
  end

  defp split_list(value) do
    value
    |> String.split(["\n", ","], trim: true)
    |> normalize_list_values()
  end

  defp normalize_list_values(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp param_list_value(params, group, field, fallback) do
    case get_in(params, [group, field]) do
      value when is_binary(value) -> value
      value when is_list(value) -> Enum.join(value, "\n")
      _missing -> Enum.join(fallback || [], "\n")
    end
  end

  defp param_array_value(params, group, field, fallback) do
    case get_in(params, [group, field]) do
      value when is_binary(value) -> split_list(value)
      value when is_list(value) -> normalize_list_values(value)
      _missing -> fallback || []
    end
  end

  defp param_json_value(params, group, field, fallback) do
    case get_in(params, [group, field]) do
      value when is_binary(value) -> value
      value when is_map(value) -> Jason.encode!(value, pretty: true)
      _missing -> Jason.encode!(fallback || %{}, pretty: true)
    end
  end
end
