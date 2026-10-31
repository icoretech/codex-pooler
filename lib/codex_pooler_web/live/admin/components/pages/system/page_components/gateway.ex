defmodule CodexPoolerWeb.Admin.SystemPageComponents.Gateway do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPooler.Gateway.OwnerRenewalSchedule

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

  @spec cards(map()) :: Phoenix.LiveView.Rendered.t()
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
              eyebrow={gettext("Gateway")}
              title={gettext("Gateway controls")}
              description={gettext("Admission, timeout, continuity, routing, file, and audio guardrails for new gateway work.")}
            >
              <div id="instance-settings-gateway-debug-region" class="max-w-xl">
                <FormControls.scalar_controls
                  form={gateway_form}
                  controls={gateway_debug_controls()}
                />
                <FormControls.scalar_controls
                  form={gateway_form}
                  controls={[
                    %{
                      type: :toggle,
                      id: "instance-settings-upstream-token-refresh-proactive-enabled",
                      field: :upstream_token_refresh_proactive_enabled,
                      label: gettext("Proactive credential refresh"),
                      hint: gettext("Refresh active accounts near token expiry, including busy accounts. Disabling this leaves manual refresh, recovery, and refresh after authentication failure enabled.")
                    }
                  ]}
                />
              </div>
              <GatewaySettingsMatrix.matrix groups={gateway_setting_groups(gateway_form, files_form, transcription_form)} />
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
                  label={gettext("Model context window overrides")}
                  value={
                    param_json_value(
                      @form_params,
                      "gateway",
                      "model_context_window_overrides",
                      @settings.gateway.model_context_window_overrides
                    )
                  }
                  hint={gettext("Model-specific raw native context windows used when upstream metadata is missing or needs correction. Codex applies the advertised effective percentage once; /v1/models publishes the flattened value.")}
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
          eyebrow={gettext("Operator email")}
          title={gettext("Public operator app URL")}
          description={gettext("Public browser URL for this operator app. Operator emails append /login to this value.")}
          hint={gettext("Store the app root URL, not the login path. Email links are generated from the current saved setting at send time.")}
        >
          <div class="max-w-xl">
            <.input
              id="instance-settings-operator-login-base-url"
              field={operator_form[:login_base_url]}
              type="url"
              label={gettext("Public operator app URL")}
              placeholder="https://codex-pooler.example.com"
            />
          </div>
        </FormControls.settings_group>
        <FormControls.settings_group
          id="instance-settings-openai-status"
          eyebrow={gettext("Status feed")}
          title={gettext("OpenAI status polling")}
          description={gettext("Check status.openai.com every five minutes for provider incident updates.")}
          hint={gettext("Disable polling when outbound access is restricted. Existing incident history is retained.")}
        >
          <.input
            id="instance-settings-openai-status-polling-enabled"
            field={operator_form[:openai_status_polling_enabled]}
            type="checkbox"
            label={gettext("Enable OpenAI status polling")}
          />
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
          eyebrow={gettext("Catalog")}
          title={gettext("Pricing catalog source")}
          description={gettext("Published OpenAI pricing JSON used by the hourly pricing snapshot refresh.")}
          hint={gettext("The release migration Job and local dev seed still import the vendored JSON file; the scheduler resolves this URL when each pricing import job runs.")}
        >
          <div class="max-w-2xl">
            <.input
              id="instance-settings-openai-pricing-url"
              field={catalog_form[:openai_pricing_url]}
              type="url"
              label={gettext("OpenAI pricing URL")}
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
        label: gettext("Gateway debug logging"),
        hint: gettext("Adds sanitized request and routing details to gateway logs and attempt metadata for temporary troubleshooting. It increases log and stored-data volume; keep it disabled during normal production operation to minimize overhead.")
      }
    ]
  end

  defp gateway_setting_groups(gateway_form, files_form, transcription_form) do
    [
      %{
        id: "streaming",
        label: gettext("Streaming"),
        description: gettext("Bounds heartbeat and socket lifetime independently of route-class capacity."),
        form: gateway_form,
        settings: [
          gateway_setting(%{
            id: "instance-settings-sse-keepalive-interval-ms",
            field: :sse_keepalive_interval_ms,
            label: gettext("SSE keepalive (ms)"),
            hint: gettext("Interval for downstream SSE heartbeat events; 0 disables heartbeats."),
            minimum: 0,
            unit: "ms"
          }),
          gateway_setting(%{
            id: "instance-settings-websocket-idle-timeout-ms",
            field: :websocket_idle_timeout_ms,
            label: gettext("Websocket idle timeout (ms)"),
            hint: gettext("Bounded downstream websocket idle window for new upgrades."),
            minimum: 60_000,
            maximum: 3_600_000,
            unit: "ms"
          }),
          gateway_setting(%{
            id: "instance-settings-websocket-owner-idle-timeout-ms",
            field: :websocket_owner_idle_timeout_ms,
            label: gettext("Websocket owner post-detach retention (ms)"),
            hint: gettext("Post-detach retention for websocket owners. Running owners keep the value captured when they were created."),
            minimum: 60_000,
            maximum: 3_600_000,
            unit: "ms"
          })
        ]
      },
      %{
        id: "upstream",
        label: gettext("Upstream timing"),
        description: gettext("Controls how long requests can acquire, connect to, and wait on upstream work."),
        form: gateway_form,
        settings: [
          gateway_setting(%{
            id: "instance-settings-upstream-connect-timeout-ms",
            field: :upstream_connect_timeout_ms,
            label: gettext("Connect timeout (ms)"),
            hint: gettext("Maximum time allowed to establish a connection to an upstream account."),
            minimum: 1,
            unit: "ms"
          }),
          gateway_setting(%{
            id: "instance-settings-upstream-pool-timeout-ms",
            field: :upstream_pool_timeout_ms,
            label: gettext("Pool timeout (ms)"),
            hint: gettext("Maximum time a gateway request may wait for an available pooled connection."),
            minimum: 1,
            unit: "ms"
          }),
          gateway_setting(%{
            id: "instance-settings-upstream-receive-timeout-ms",
            field: :upstream_receive_timeout_ms,
            label: gettext("Receive timeout (ms)"),
            hint: gettext("Maximum idle receive window while waiting for upstream response data."),
            minimum: 1,
            unit: "ms"
          }),
          gateway_setting(%{
            id: "instance-settings-upstream-conn-max-idle-time-ms",
            field: :upstream_conn_max_idle_time_ms,
            label: gettext("Connection idle bound (ms)"),
            hint: gettext("Pooled upstream connections idle longer than this are replaced on their next use. Checked only when a connection is taken, so it never interrupts an in-flight or streaming request. Keep it below the idle timeout of any NAT, load balancer, or proxy on the egress path."),
            minimum: 1_000,
            maximum: 3_600_000,
            unit: "ms"
          })
        ]
      },
      %{
        id: "token_refresh",
        label: gettext("Credential refresh"),
        description: gettext("Controls how early scheduled recovery refreshes upstream credentials based on expiry, including busy accounts."),
        form: gateway_form,
        settings: [
          gateway_setting(%{
            id: "instance-settings-upstream-token-refresh-margin-seconds",
            field: :upstream_token_refresh_margin_seconds,
            label: gettext("Proactive refresh margin (s)"),
            hint: gettext("Scheduled recovery refreshes an active account once its access token is this close to expiring, so an account with no traffic cannot age into required re-authentication. Accounts already inside the margin are retried on a bounded cooldown, not on every recovery pass."),
            minimum: 3_600,
            maximum: 1_209_600,
            unit: "s"
          })
        ]
      },
      %{
        id: "continuity",
        label: gettext("Continuity"),
        description: gettext("Keeps response aliases and bridge ownership available while work moves between requests."),
        form: gateway_form,
        settings: [
          gateway_setting(%{
            id: "instance-settings-expired-alias-ttl-seconds",
            field: :expired_alias_ttl_seconds,
            label: gettext("Expired alias TTL (s)"),
            hint: gettext("How long expired response aliases stay available for continuity lookups."),
            minimum: 1,
            unit: "s"
          }),
          gateway_setting(%{
            id: "instance-settings-bridge-owner-lease-ttl-seconds",
            field: :bridge_owner_lease_ttl_seconds,
            label: gettext("Owner lease TTL (s)"),
            hint: gettext("How long a bridge owner lease remains valid without renewal. At least %{minimum} s, so a request's lease outlives its pre-dispatch work; a lower stored value is raised to it.", minimum: OwnerRenewalSchedule.minimum_lease_ttl_seconds()),
            minimum: OwnerRenewalSchedule.minimum_lease_ttl_seconds(),
            unit: "s"
          }),
          gateway_setting(%{
            id: "instance-settings-bridge-owner-lease-renewal-seconds",
            field: :bridge_owner_lease_renewal_seconds,
            label: gettext("Owner lease renewal (s)"),
            hint: gettext("How often active bridge owners renew their lease while work is running. At most a third of the owner lease TTL, so an owner renews well before its lease expires; a higher stored value is lowered to it."),
            minimum: 1,
            unit: "s"
          })
        ]
      },
      %{
        id: "circuit",
        label: gettext("Circuit recovery"),
        description: gettext("Controls when failing upstreams leave normal routing and become eligible again."),
        form: gateway_form,
        settings: [
          gateway_setting(%{
            id: "instance-settings-circuit-failure-threshold",
            field: :circuit_failure_threshold,
            label: gettext("Circuit failure threshold"),
            hint: gettext("Consecutive failed attempts needed before opening an upstream circuit."),
            minimum: 1,
            unit: gettext("failures")
          }),
          gateway_setting(%{
            id: "instance-settings-circuit-open-seconds",
            field: :circuit_open_seconds,
            label: gettext("Circuit open window (s)"),
            hint: gettext("How long an opened circuit stays closed to normal traffic before probing."),
            minimum: 1,
            unit: "s"
          }),
          gateway_setting(%{
            id: "instance-settings-circuit-half-open-probe-limit",
            field: :circuit_half_open_probe_limit,
            label: gettext("Half-open probe limit"),
            hint: gettext("Concurrent probe attempts allowed while testing a half-open circuit."),
            minimum: 1,
            unit: gettext("probes")
          }),
          gateway_setting(%{
            id: "instance-settings-circuit-success-threshold",
            field: :circuit_success_threshold,
            label: gettext("Circuit close successes"),
            hint: gettext("Successful probes required before closing a previously opened circuit."),
            minimum: 1,
            unit: gettext("successes")
          })
        ]
      },
      %{
        id: "files",
        label: gettext("File bridge"),
        description: gettext("Controls upload size and metadata lifetime. Expired uploads are checked every 15 minutes."),
        form: files_form,
        settings: [
          gateway_setting(%{
            id: "instance-settings-file-max-size-bytes",
            field: :max_size_bytes,
            label: gettext("File upload limit"),
            hint: gettext("Maximum size accepted for new upstream-backed file uploads."),
            minimum: 1,
            unit: gettext("bytes")
          }),
          gateway_setting(%{
            id: "instance-settings-upload-ttl-seconds",
            field: :upload_ttl_seconds,
            label: gettext("File metadata TTL (s)"),
            hint: gettext("How long upload metadata remains available before expiry."),
            minimum: 1,
            unit: "s"
          })
        ]
      },
      %{
        id: "transcription",
        label: gettext("Audio transcription"),
        description: gettext("Limits new audio transcription multipart uploads."),
        form: transcription_form,
        settings: [
          gateway_setting(%{
            id: "instance-settings-transcription-max-upload-bytes",
            field: :max_upload_bytes,
            label: gettext("Audio upload limit"),
            hint: gettext("Maximum size accepted for new audio transcription multipart uploads."),
            minimum: 1,
            unit: gettext("bytes")
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
      value when is_map(value) -> CodexPooler.JSON.encode!(value, pretty: true)
      _missing -> CodexPooler.JSON.encode!(fallback || %{}, pretty: true)
    end
  end

  defp bulkhead_values(form_params, fallback) do
    case get_in(form_params, ["gateway", "bulkheads"]) do
      %{} = value -> value
      _missing_or_invalid -> fallback
    end
  end
end
