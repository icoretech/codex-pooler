defmodule CodexPoolerWeb.Admin.SystemPageComponents.Gateway do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.SystemPageComponents.{
    BulkheadEditor,
    FormControls,
    GatewaySettingsMatrix
  }

  alias CodexPoolerWeb.Admin.SystemSettingsForm

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
        <.inputs_for :let={files_form} field={@forms["gateway"][:files]}>
          <.inputs_for :let={transcription_form} field={@forms["gateway"][:transcription]}>
            <FormControls.settings_group
              id="instance-settings-gateway"
              eyebrow="Gateway"
              title="Gateway controls"
              description="Admission, timeout, continuity, routing, file, and audio guardrails for new gateway work."
            >
              <div id="instance-settings-gateway-debug-region" class="max-w-xl">
                <FormControls.scalar_controls
                  form={gateway_form}
                  controls={gateway_debug_controls()}
                />
              </div>
              <GatewaySettingsMatrix.matrix groups={
                gateway_setting_groups(gateway_form, files_form, transcription_form)
              } />
              <div class="grid gap-4">
                <BulkheadEditor.editor
                  bulkheads={bulkhead_values(@form_params, @settings.gateway.bulkheads)}
                  active_preset={
                    @form_params
                    |> bulkhead_values(@settings.gateway.bulkheads)
                    |> SystemSettingsForm.bulkhead_preset()
                  }
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
        </.inputs_for>
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

  defp gateway_debug_controls do
    [
      %{
        type: :toggle,
        id: "instance-settings-gateway-debug",
        field: :gateway_debug,
        label: "Gateway debug logging",
        hint:
          "Adds sanitized request and routing details to gateway logs and attempt metadata for temporary troubleshooting. It increases log and stored-data volume; keep it disabled during normal production operation to minimize overhead."
      }
    ]
  end

  defp gateway_setting_groups(gateway_form, files_form, transcription_form) do
    [
      %{
        id: "streaming",
        label: "Streaming",
        description:
          "Bounds heartbeat and socket lifetime independently of route-class capacity.",
        form: gateway_form,
        settings: [
          gateway_setting(%{
            id: "instance-settings-sse-keepalive-interval-ms",
            field: :sse_keepalive_interval_ms,
            label: "SSE keepalive (ms)",
            hint: "Interval for downstream SSE heartbeat events; 0 disables heartbeats.",
            minimum: 0,
            unit: "ms"
          }),
          gateway_setting(%{
            id: "instance-settings-websocket-idle-timeout-ms",
            field: :websocket_idle_timeout_ms,
            label: "Websocket idle timeout (ms)",
            hint: "Bounded downstream websocket idle window for new upgrades.",
            minimum: 60_000,
            maximum: 3_600_000,
            unit: "ms"
          }),
          gateway_setting(%{
            id: "instance-settings-websocket-owner-idle-timeout-ms",
            field: :websocket_owner_idle_timeout_ms,
            label: "Websocket owner post-detach retention (ms)",
            hint:
              "Post-detach retention for websocket owners. Running owners keep the value captured when they were created.",
            minimum: 60_000,
            maximum: 3_600_000,
            unit: "ms"
          })
        ]
      },
      %{
        id: "upstream",
        label: "Upstream timing",
        description:
          "Controls how long requests can acquire, connect to, and wait on upstream work.",
        form: gateway_form,
        settings: [
          gateway_setting(%{
            id: "instance-settings-upstream-connect-timeout-ms",
            field: :upstream_connect_timeout_ms,
            label: "Connect timeout (ms)",
            hint: "Maximum time allowed to establish a connection to an upstream account.",
            minimum: 1,
            unit: "ms"
          }),
          gateway_setting(%{
            id: "instance-settings-upstream-pool-timeout-ms",
            field: :upstream_pool_timeout_ms,
            label: "Pool timeout (ms)",
            hint: "Maximum time a gateway request may wait for an available pooled connection.",
            minimum: 1,
            unit: "ms"
          }),
          gateway_setting(%{
            id: "instance-settings-upstream-receive-timeout-ms",
            field: :upstream_receive_timeout_ms,
            label: "Receive timeout (ms)",
            hint: "Maximum idle receive window while waiting for upstream response data.",
            minimum: 1,
            unit: "ms"
          })
        ]
      },
      %{
        id: "continuity",
        label: "Continuity",
        description:
          "Keeps response aliases and bridge ownership available while work moves between requests.",
        form: gateway_form,
        settings: [
          gateway_setting(%{
            id: "instance-settings-expired-alias-ttl-seconds",
            field: :expired_alias_ttl_seconds,
            label: "Expired alias TTL (s)",
            hint: "How long expired response aliases stay available for continuity lookups.",
            minimum: 1,
            unit: "s"
          }),
          gateway_setting(%{
            id: "instance-settings-bridge-owner-lease-ttl-seconds",
            field: :bridge_owner_lease_ttl_seconds,
            label: "Owner lease TTL (s)",
            hint: "How long a bridge owner lease remains valid without renewal.",
            minimum: 1,
            unit: "s"
          }),
          gateway_setting(%{
            id: "instance-settings-bridge-owner-lease-renewal-seconds",
            field: :bridge_owner_lease_renewal_seconds,
            label: "Owner lease renewal (s)",
            hint: "How often active bridge owners renew their lease while work is running.",
            minimum: 1,
            unit: "s"
          })
        ]
      },
      %{
        id: "circuit",
        label: "Circuit recovery",
        description:
          "Controls when failing upstreams leave normal routing and become eligible again.",
        form: gateway_form,
        settings: [
          gateway_setting(%{
            id: "instance-settings-circuit-failure-threshold",
            field: :circuit_failure_threshold,
            label: "Circuit failure threshold",
            hint: "Consecutive failed attempts needed before opening an upstream circuit.",
            minimum: 1,
            unit: "failures"
          }),
          gateway_setting(%{
            id: "instance-settings-circuit-open-seconds",
            field: :circuit_open_seconds,
            label: "Circuit open window (s)",
            hint: "How long an opened circuit stays closed to normal traffic before probing.",
            minimum: 1,
            unit: "s"
          }),
          gateway_setting(%{
            id: "instance-settings-circuit-half-open-probe-limit",
            field: :circuit_half_open_probe_limit,
            label: "Half-open probe limit",
            hint: "Concurrent probe attempts allowed while testing a half-open circuit.",
            minimum: 1,
            unit: "probes"
          }),
          gateway_setting(%{
            id: "instance-settings-circuit-success-threshold",
            field: :circuit_success_threshold,
            label: "Circuit close successes",
            hint: "Successful probes required before closing a previously opened circuit.",
            minimum: 1,
            unit: "successes"
          })
        ]
      },
      %{
        id: "files",
        label: "File bridge",
        description: "Controls upload size, metadata lifetime, and abandoned-upload cleanup.",
        form: files_form,
        settings: [
          gateway_setting(%{
            id: "instance-settings-file-max-size-bytes",
            field: :max_size_bytes,
            label: "File upload limit",
            hint: "Maximum size accepted for new upstream-backed file uploads.",
            minimum: 1,
            unit: "bytes"
          }),
          gateway_setting(%{
            id: "instance-settings-upload-ttl-seconds",
            field: :upload_ttl_seconds,
            label: "File metadata TTL (s)",
            hint: "How long upload metadata remains available before expiry.",
            minimum: 1,
            unit: "s"
          }),
          gateway_setting(%{
            id: "instance-settings-abandoned-upload-cleanup-interval-seconds",
            field: :abandoned_upload_cleanup_interval_seconds,
            label: "Abandoned upload cleanup interval (s)",
            hint: "How often cleanup scans run for abandoned file uploads.",
            minimum: 1,
            unit: "s"
          })
        ]
      },
      %{
        id: "transcription",
        label: "Audio transcription",
        description: "Limits new audio transcription multipart uploads.",
        form: transcription_form,
        settings: [
          gateway_setting(%{
            id: "instance-settings-transcription-max-upload-bytes",
            field: :max_upload_bytes,
            label: "Audio upload limit",
            hint: "Maximum size accepted for new audio transcription multipart uploads.",
            minimum: 1,
            unit: "bytes"
          })
        ]
      }
    ]
  end

  defp gateway_setting(setting) do
    setting
    |> Map.put_new(:maximum, nil)
    |> Map.put(:dom_id, setting.id |> String.replace_prefix("instance-settings-", ""))
  end

  defp param_json_value(params, group, field, fallback) do
    case get_in(params, [group, field]) do
      value when is_binary(value) -> value
      value when is_map(value) -> Jason.encode!(value, pretty: true)
      _missing -> Jason.encode!(fallback || %{}, pretty: true)
    end
  end

  defp bulkhead_values(form_params, fallback) do
    case get_in(form_params, ["gateway", "bulkheads"]) do
      %{} = value -> value
      _missing_or_invalid -> fallback
    end
  end
end
