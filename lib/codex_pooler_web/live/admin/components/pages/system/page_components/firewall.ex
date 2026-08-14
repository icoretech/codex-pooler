defmodule CodexPoolerWeb.Admin.SystemPageComponents.Firewall do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.SystemPageComponents.FormControls
  alias CodexPoolerWeb.Admin.SystemSettingsForm

  attr :selected_tab, :string, required: true
  attr :forms, :map, required: true
  attr :form_params, :map, required: true
  attr :settings, :any, required: true
  attr :card_statuses, :map, required: true
  attr :current_session_ip, :string, default: nil

  def cards(assigns) do
    ~H"""
    <section
      :if={@selected_tab == "firewall"}
      id="system-runtime-firewall-card"
      data-firewall-state={firewall_state(@settings)}
      class="rounded-box border border-base-300 bg-base-100 p-4"
    >
      <div class="grid gap-4 md:grid-cols-[minmax(0,1fr)_auto] md:items-center">
        <div class="min-w-0">
          <p class="text-xs font-semibold uppercase tracking-[0.18em] text-primary">
            Runtime ingress
          </p>
          <h2 class="mt-1 text-lg font-semibold text-base-content">Firewall visibility</h2>
          <p class="mt-1 text-sm text-base-content/60">
            Current policy state and the network address recorded for this authenticated session.
          </p>
          <p id="system-runtime-firewall-scope" class="mt-2 text-xs text-base-content/60">
            Covers compatibility routes and /mcp. /metrics uses its separate bearer boundary.
          </p>
        </div>

        <dl class="grid min-w-0 gap-3 sm:grid-cols-2 md:min-w-[22rem]">
          <div class="rounded-field border border-base-300 bg-base-200/50 px-3 py-2">
            <dt class="text-[0.62rem] font-semibold uppercase tracking-[0.08em] text-base-content/50">
              Firewall
            </dt>
            <dd class="mt-1">
              <span
                id="system-runtime-firewall-status"
                data-state={firewall_state(@settings)}
                class={firewall_status_class(@settings)}
              >
                {firewall_label(@settings)}
              </span>
            </dd>
          </div>

          <div class="min-w-0 rounded-field border border-base-300 bg-base-200/50 px-3 py-2">
            <dt class="text-[0.62rem] font-semibold uppercase tracking-[0.08em] text-base-content/50">
              Current session IP
            </dt>
            <dd
              id="system-current-session-ip"
              data-state={if @current_session_ip, do: "available", else: "unavailable"}
              class="mt-1 truncate font-mono text-xs font-semibold text-base-content"
            >
              {@current_session_ip || "not recorded"}
            </dd>
          </div>
        </dl>
      </div>
    </section>

    <FormControls.settings_card
      :if={@selected_tab == "firewall"}
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
          <div class="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
            <FormControls.scalar_controls form={ingress_form} controls={ingress_scalar_controls()} />
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

  defp ingress_scalar_controls do
    [
      %{
        type: :select,
        id: "instance-settings-forwarded-client-ip-source",
        field: :forwarded_client_ip_source,
        label: "Forwarded client IP source",
        options: SystemSettingsForm.forwarded_client_ip_source_options()
      },
      %{
        type: :number,
        id: "instance-settings-forwarded-proxy-depth",
        field: :forwarded_proxy_depth,
        label: "Forwarded proxy depth",
        hint:
          "number of proxies between the internet and the pooler, including the one connected directly; 0 uses trusted-CIDR walking."
      },
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

  defp firewall_enabled?(settings), do: settings.ingress.firewall_allowlist != []

  defp firewall_state(settings),
    do: if(firewall_enabled?(settings), do: "enabled", else: "disabled")

  defp firewall_label(settings),
    do: if(firewall_enabled?(settings), do: "Enabled", else: "Disabled")

  defp firewall_status_class(settings) do
    if firewall_enabled?(settings) do
      "badge badge-success badge-sm font-semibold"
    else
      "badge badge-ghost badge-sm border-base-300 font-semibold text-base-content/70"
    end
  end
end
