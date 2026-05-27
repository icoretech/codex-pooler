defmodule CodexPoolerWeb.Admin.SystemPageComponents do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias Phoenix.HTML.Form

  @settings_group_submit_labels %{
    "gateway" => "Save gateway controls",
    "ingress" => "Save runtime ingress",
    "files" => "Save file limits",
    "transcription" => "Save audio limit",
    "operator" => "Save operator URL",
    "catalog" => "Save catalog source",
    "development" => "Save development helpers",
    "mcp" => "Save MCP service",
    "metrics" => "Save metrics token",
    "smtp" => "Save SMTP delivery"
  }

  attr :tabs, :list, required: true
  attr :selected_tab, :string, required: true

  def system_tab_picker(assigns) do
    ~H"""
    <div class="flex flex-wrap items-end justify-between gap-3">
      <div>
        <p class="text-xs font-semibold uppercase tracking-[0.18em] text-base-content/45">
          Instance system
        </p>
        <h2 class="text-lg font-semibold text-base-content">Choose what to configure</h2>
      </div>
      <div id="system-tabs" class="tabs tabs-border" role="tablist">
        <.link
          :for={tab <- @tabs}
          id={"system-tab-#{tab.id}"}
          patch={~p"/admin/system?#{%{"tab" => tab.id}}"}
          role="tab"
          aria-selected={to_string(@selected_tab == tab.id)}
          class={["tab", @selected_tab == tab.id && "tab-active"]}
        >
          {tab.label}
        </.link>
      </div>
    </div>
    """
  end

  attr :forms, :map, required: true
  attr :form_params, :map, required: true
  attr :settings, :any, required: true
  attr :mcp_key_count, :integer, required: true
  attr :card_statuses, :map, required: true
  attr :selected_tab, :string, required: true
  attr :development_action_status, :map, default: nil
  attr :smtp_test_status, :map, default: nil
  attr :development_helpers_available?, :boolean, required: true

  def instance_settings_panel(assigns) do
    ~H"""
    <section id="system-settings-panel" class="grid gap-4" data-selected-tab={@selected_tab}>
      <.gateway_settings_cards
        selected_tab={@selected_tab}
        forms={@forms}
        form_params={@form_params}
        settings={@settings}
        card_statuses={@card_statuses}
      />
      <.development_settings_card
        selected_tab={@selected_tab}
        forms={@forms}
        settings={@settings}
        card_statuses={@card_statuses}
        development_action_status={@development_action_status}
        development_helpers_available?={@development_helpers_available?}
      />
      <.mcp_settings_card
        selected_tab={@selected_tab}
        forms={@forms}
        card_statuses={@card_statuses}
        mcp_key_count={@mcp_key_count}
      />
      <.metrics_settings_card
        selected_tab={@selected_tab}
        forms={@forms}
        form_params={@form_params}
        settings={@settings}
        card_statuses={@card_statuses}
      />
      <.smtp_settings_card
        selected_tab={@selected_tab}
        forms={@forms}
        form_params={@form_params}
        settings={@settings}
        card_statuses={@card_statuses}
        smtp_test_status={@smtp_test_status}
      />
    </section>
    """
  end

  attr :selected_tab, :string, required: true
  attr :forms, :map, required: true
  attr :form_params, :map, required: true
  attr :settings, :any, required: true
  attr :card_statuses, :map, required: true

  defp gateway_settings_cards(assigns) do
    ~H"""
    <.settings_card
      :if={@selected_tab == "gateway"}
      group="gateway"
      form={@forms["gateway"]}
      status={@card_statuses["gateway"]}
    >
      <.inputs_for :let={gateway_form} field={@forms["gateway"][:gateway]}>
        <.settings_group
          id="instance-settings-gateway"
          eyebrow="Gateway"
          title="Gateway controls"
          description="Admission, timeout, continuity, routing, and circuit guardrails for new gateway work."
          hint="Most values reload through the settings cache for new work; existing in-flight work keeps the runtime values it started with."
        >
          <div class="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
            <.scalar_controls form={gateway_form} controls={gateway_scalar_controls()} />
          </div>
          <div class="max-w-2xl">
            <.input
              id="instance-settings-upstream-user-agent"
              field={gateway_form[:upstream_user_agent]}
              type="text"
              label="Upstream Codex user-agent"
              placeholder="codex_cli_rs/0.0.0"
            />
            <p class="mt-1 text-xs leading-5 text-base-content/55">
              Sent to upstream Codex-compatible routes instead of forwarding downstream client user-agent strings.
            </p>
          </div>
          <div class="grid gap-4 lg:grid-cols-2">
            <.json_textarea
              id="instance-settings-bulkheads"
              name="instance_settings[gateway][bulkheads]"
              label="Route-class bulkheads"
              value={
                param_json_value(@form_params, "gateway", "bulkheads", @settings.gateway.bulkheads)
              }
              hint="Per route-class concurrency, queue length, and queue timeout policy as JSON."
            />
            <.json_textarea
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
        </.settings_group>
      </.inputs_for>
    </.settings_card>

    <.settings_card
      :if={@selected_tab == "gateway"}
      group="ingress"
      form={@forms["ingress"]}
      status={@card_statuses["ingress"]}
    >
      <.inputs_for :let={ingress_form} field={@forms["ingress"][:ingress]}>
        <.settings_group
          id="instance-settings-ingress"
          eyebrow="Ingress"
          title="Runtime ingress"
          description="Firewall, trusted proxy, and compressed-body controls for compatibility routes."
          hint="Evaluated for new requests; keep proxy lists metadata-only and CIDR based."
        >
          <div class="grid gap-4 lg:grid-cols-3">
            <.list_textarea
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
            <.list_textarea
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
            <.compressed_json_encoding_checkboxes
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
          <div class="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
            <.scalar_controls form={ingress_form} controls={ingress_scalar_controls()} />
          </div>
        </.settings_group>
      </.inputs_for>
    </.settings_card>

    <.settings_card
      :if={@selected_tab == "gateway"}
      group="files"
      form={@forms["files"]}
      status={@card_statuses["files"]}
    >
      <.inputs_for :let={files_form} field={@forms["files"][:files]}>
        <.settings_group
          id="instance-settings-files"
          eyebrow="Files"
          title="File bridge limits"
          description="Upload size, metadata TTL, and cleanup cadence for upstream-backed file payloads."
          hint="Applies to new uploads and cleanup jobs; stored file metadata remains metadata-only."
        >
          <div class="grid gap-4 md:grid-cols-3">
            <.scalar_controls form={files_form} controls={files_scalar_controls()} />
          </div>
        </.settings_group>
      </.inputs_for>
    </.settings_card>

    <.settings_card
      :if={@selected_tab == "gateway"}
      group="transcription"
      form={@forms["transcription"]}
      status={@card_statuses["transcription"]}
    >
      <.inputs_for :let={transcription_form} field={@forms["transcription"][:transcription]}>
        <.settings_group
          id="instance-settings-transcription"
          eyebrow="Transcription"
          title="Audio upload limit"
          description="Runtime limit for new audio transcription multipart uploads."
          hint="Reloads live for new requests and keeps audio bytes out of admin surfaces."
        >
          <div class="max-w-md">
            <.scalar_controls
              form={transcription_form}
              controls={transcription_scalar_controls()}
            />
          </div>
        </.settings_group>
      </.inputs_for>
    </.settings_card>

    <.settings_card
      :if={@selected_tab == "gateway"}
      group="operator"
      form={@forms["operator"]}
      status={@card_statuses["operator"]}
    >
      <.inputs_for :let={operator_form} field={@forms["operator"][:operator]}>
        <.settings_group
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
              placeholder="https://pooler.example.com"
            />
          </div>
        </.settings_group>
      </.inputs_for>
    </.settings_card>

    <.settings_card
      :if={@selected_tab == "gateway"}
      group="catalog"
      form={@forms["catalog"]}
      status={@card_statuses["catalog"]}
    >
      <.inputs_for :let={catalog_form} field={@forms["catalog"][:catalog]}>
        <.settings_group
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
        </.settings_group>
      </.inputs_for>
    </.settings_card>
    """
  end

  attr :selected_tab, :string, required: true
  attr :forms, :map, required: true
  attr :settings, :any, required: true
  attr :card_statuses, :map, required: true
  attr :development_action_status, :map, default: nil
  attr :development_helpers_available?, :boolean, required: true

  defp development_settings_card(assigns) do
    ~H"""
    <.settings_card
      :if={@selected_tab == "development" and @development_helpers_available?}
      group="development"
      form={@forms["development"]}
      status={@card_statuses["development"]}
      autosave
    >
      <.inputs_for :let={development_form} field={@forms["development"][:development]}>
        <.settings_group
          id="instance-settings-development"
          eyebrow="Development helpers"
          title="Development-only local safeguards"
          description="Controls local-only helpers and pauses fake-account jobs that would otherwise call upstream accounts."
        >
          <div class="grid gap-4 xl:grid-cols-2">
            <.toggle_input
              id="instance-settings-account-reconciliation-paused"
              field={development_form[:account_reconciliation_paused]}
              label="Pause account reconciliation jobs"
              hint="Stops scheduled and queued reconciliation jobs before they call upstream accounts in development."
            />
            <.toggle_input
              id="instance-settings-impeccable-live-enabled"
              field={development_form[:impeccable_live_enabled]}
              label="Enable Impeccable live helper"
              hint="Requires a local Impeccable server at http://localhost:8400."
            />
          </div>
          <div
            id="instance-settings-development-actions"
            class="grid gap-3 rounded-box border border-base-300 bg-base-200/40 p-3"
          >
            <div class="grid gap-1">
              <h4 class="text-sm font-semibold text-base-content">Development data imports</h4>
              <p class="text-xs leading-5 text-base-content/55">
                Import deterministic fake data for the admin UI, or refresh pricing snapshots from <a
                  id="instance-settings-development-pricing-url"
                  href={@settings.catalog.openai_pricing_url}
                  class="text-primary underline-offset-2 hover:underline"
                >
                    {@settings.catalog.openai_pricing_url}
                  </a>.
                Change the URL in <.link
                  id="instance-settings-development-catalog-link"
                  patch={~p"/admin/system?#{%{"tab" => "gateway"}}"}
                  class="font-medium text-primary underline-offset-2 hover:underline"
                >
                    Gateway settings
                  </.link>.
              </p>
            </div>
            <div class="flex flex-wrap gap-2">
              <AdminComponents.action_button
                id="instance-settings-import-sample-data"
                icon="hero-circle-stack"
                label="Import Sample Data"
                phx-click="import_sample_data"
                phx-disable-with="Importing..."
              />
              <AdminComponents.action_button
                id="instance-settings-import-pricing-catalog"
                icon="hero-arrow-path"
                label="Import Pricing"
                phx-click="import_pricing_catalog"
                phx-disable-with="Importing..."
              />
            </div>
            <.development_action_notice
              id="instance-settings-development-action-status"
              status={@development_action_status}
            />
          </div>
        </.settings_group>
      </.inputs_for>
    </.settings_card>
    """
  end

  attr :selected_tab, :string, required: true
  attr :forms, :map, required: true
  attr :card_statuses, :map, required: true
  attr :mcp_key_count, :integer, required: true

  defp mcp_settings_card(assigns) do
    ~H"""
    <.settings_card
      :if={@selected_tab == "mcp"}
      group="mcp"
      form={@forms["mcp"]}
      status={@card_statuses["mcp"]}
      autosave
    >
      <.inputs_for :let={mcp_form} field={@forms["mcp"][:mcp]}>
        <.settings_group
          id="instance-settings-mcp"
          eyebrow="MCP"
          title="MCP service"
          description="Controls whether operator MCP bearer tokens can use the metadata-only /mcp endpoint."
          hint="This setting never creates or exposes tokens."
        >
          <:hint_content>
            Manage your own MCP keys in <.link
              id="instance-settings-mcp-account-settings-link"
              navigate={~p"/admin/settings?tab=account"}
              class="font-medium text-primary underline-offset-2 hover:underline"
            >
                account settings
              </.link>. {mcp_key_count_label(@mcp_key_count)}
          </:hint_content>
          <div class="w-full">
            <.toggle_input
              id="instance-settings-mcp-enabled"
              field={mcp_form[:enabled]}
              label="Enabled"
              hint="When off, existing MCP tokens are rejected."
            />
          </div>
        </.settings_group>
      </.inputs_for>
    </.settings_card>
    """
  end

  attr :selected_tab, :string, required: true
  attr :forms, :map, required: true
  attr :form_params, :map, required: true
  attr :settings, :any, required: true
  attr :card_statuses, :map, required: true

  defp metrics_settings_card(assigns) do
    ~H"""
    <.settings_card
      :if={@selected_tab == "metrics"}
      group="metrics"
      form={@forms["metrics"]}
      status={@card_statuses["metrics"]}
    >
      <.settings_group
        id="instance-settings-metrics"
        eyebrow="Metrics"
        title="Metrics bearer token"
        description="Protect the Prometheus metrics endpoint with an HMAC-only write-once token."
        hint="Blank saves preserve the current token. Choose clear to intentionally remove it. The raw token cannot be recovered after save."
      >
        <div class="grid gap-4 lg:grid-cols-[minmax(0,1fr)_16rem]">
          <.write_only_secret_input
            id="instance-settings-metrics-token"
            name="instance_settings[metrics][bearer_token]"
            action_name="instance_settings[metrics][bearer_token_action]"
            label="Metrics bearer token"
            status_label="Stored token"
            clear_label="Clear stored token"
            action={param_secret_action(@form_params, "metrics", "bearer_token_action")}
            status={@settings.metrics.bearer_token_status}
          />
          <div class="grid content-start gap-2 rounded-box border border-base-300 bg-base-200/60 p-3 text-sm">
            <p class="text-xs font-semibold uppercase tracking-wide text-base-content/45">
              Safe metadata
            </p>
            <p
              id="instance-settings-metrics-token-fingerprint"
              class="break-all text-base-content/70"
            >
              Fingerprint: {safe_value(@settings.metrics.bearer_token_fingerprint)}
            </p>
            <p class="break-all text-base-content/70">
              Key version: {safe_value(@settings.metrics.bearer_token_key_version)}
            </p>
          </div>
        </div>
      </.settings_group>
    </.settings_card>
    """
  end

  attr :selected_tab, :string, required: true
  attr :forms, :map, required: true
  attr :form_params, :map, required: true
  attr :settings, :any, required: true
  attr :card_statuses, :map, required: true
  attr :smtp_test_status, :map, default: nil

  defp smtp_settings_card(assigns) do
    ~H"""
    <.settings_card
      :if={@selected_tab == "smtp"}
      group="smtp"
      form={@forms["smtp"]}
      status={@card_statuses["smtp"]}
    >
      <.inputs_for :let={smtp_form} field={@forms["smtp"][:smtp]}>
        <.settings_group
          id="instance-settings-smtp"
          eyebrow="SMTP"
          title="SMTP delivery"
          description="Delivery-time email settings for operator mail."
          hint="Leave the SMTP password blank to keep the stored value."
        >
          <div class="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
            <.scalar_controls form={smtp_form} controls={smtp_scalar_controls(:before_password)} />
            <.write_only_secret_input
              id="instance-settings-smtp-password"
              name="instance_settings[smtp][password]"
              action_name="instance_settings[smtp][password_action]"
              label="SMTP password"
              status_label="Stored password"
              clear_label="Clear stored password"
              action={param_secret_action(@form_params, "smtp", "password_action")}
              status={@settings.smtp.password_status}
            />
            <.scalar_controls form={smtp_form} controls={smtp_scalar_controls(:after_password)} />
          </div>
          <div class="grid gap-3 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-center">
            <p class="text-xs leading-5 text-base-content/60">
              Send a deterministic test email to the signed-in operator with the unsaved SMTP values from this form.
            </p>
            <AdminComponents.action_button
              id="instance-settings-smtp-test"
              icon="hero-paper-airplane"
              label="Send test email to me"
              phx-click="test_smtp"
              variant={:secondary}
            />
          </div>
          <div
            id="instance-settings-smtp-test-status"
            class={smtp_status_class(@smtp_test_status)}
            role="status"
          >
            {smtp_status_message(@smtp_test_status)}
          </div>
        </.settings_group>
      </.inputs_for>
    </.settings_card>
    """
  end

  attr :group, :string, required: true
  attr :form, :any, required: true
  attr :status, :map, default: nil
  attr :autosave, :boolean, default: false

  slot :inner_block, required: true

  defp settings_card(assigns) do
    ~H"""
    <.form
      id={"instance-settings-#{@group}-form"}
      for={@form}
      phx-change={if @autosave, do: "autosave_instance_settings", else: "validate_instance_settings"}
      phx-submit={unless @autosave, do: "save_instance_settings"}
      autocomplete="off"
      class="grid gap-3"
    >
      <input type="hidden" name="instance_settings[_group]" value={@group} />
      <.input
        id={"instance-settings-#{@group}-lock-version"}
        field={@form[:lock_version]}
        type="hidden"
      />

      <.form_error_summary id={"instance-settings-#{@group}-errors"} form={@form} />

      {render_slot(@inner_block)}

      <div class="flex flex-wrap items-center justify-between gap-3 border-t border-base-300 pt-3">
        <p
          id={"instance-settings-#{@group}-status"}
          class={card_status_class(@status)}
          role="status"
        >
          {card_status_message(@status, @autosave)}
        </p>
        <AdminComponents.action_button
          :if={!@autosave}
          id={"instance-settings-#{@group}-submit"}
          icon="hero-check"
          label={submit_label(@group)}
          type="submit"
          variant={:primary}
        />
      </div>
    </.form>
    """
  end

  attr :id, :string, required: true
  attr :eyebrow, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true
  attr :hint, :string, default: nil

  slot :hint_content

  slot :inner_block, required: true

  defp settings_group(assigns) do
    ~H"""
    <section id={@id} class="grid gap-4 rounded-box border border-base-300 bg-base-100 p-4 shadow-sm">
      <div class="grid gap-1 border-b border-base-300 pb-3">
        <p class="text-xs font-semibold uppercase tracking-wide text-base-content/45">{@eyebrow}</p>
        <h3 class="text-xl font-semibold text-base-content">{@title}</h3>
        <p class="text-sm leading-6 text-base-content/65">{@description}</p>
        <p :if={@hint_content != []} class="text-xs leading-5 text-base-content/55">
          {render_slot(@hint_content)}
        </p>
        <p :if={@hint_content == [] and @hint} class="text-xs leading-5 text-base-content/55">
          {@hint}
        </p>
      </div>
      <div class="grid gap-4">{render_slot(@inner_block)}</div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :status, :map, default: nil

  defp development_action_notice(assigns) do
    assigns = assign(assigns, :notice, development_action_notice_content(assigns.status))

    ~H"""
    <AdminComponents.extended_notice
      id={@id}
      icon={@notice.icon}
      tone={@notice.tone}
      title={@notice.title}
      description={@notice.message}
    />
    """
  end

  attr :form, :any, required: true
  attr :controls, :list, required: true

  defp scalar_controls(assigns) do
    ~H"""
    <.scalar_control :for={control <- @controls} form={@form} control={control} />
    """
  end

  attr :form, :any, required: true
  attr :control, :map, required: true

  defp scalar_control(%{control: %{type: :toggle}} = assigns) do
    assigns = assign(assigns, :field, assigns.form[assigns.control.field])

    ~H"""
    <.toggle_input
      id={@control.id}
      field={@field}
      label={@control.label}
      hint={Map.get(@control, :hint)}
    />
    """
  end

  defp scalar_control(%{control: %{type: :number}} = assigns) do
    assigns = assign(assigns, :field, assigns.form[assigns.control.field])

    ~H"""
    <.number_input
      id={@control.id}
      field={@field}
      label={@control.label}
      hint={Map.get(@control, :hint)}
    />
    """
  end

  defp scalar_control(%{control: %{type: :input}} = assigns) do
    assigns = assign(assigns, :field, assigns.form[assigns.control.field])

    ~H"""
    <.input
      id={@control.id}
      field={@field}
      type={@control.input_type}
      label={@control.label}
      placeholder={Map.get(@control, :placeholder)}
    />
    """
  end

  defp scalar_control(%{control: %{type: :select}} = assigns) do
    assigns = assign(assigns, :field, assigns.form[assigns.control.field])

    ~H"""
    <.input
      id={@control.id}
      field={@field}
      type="select"
      label={@control.label}
      options={@control.options}
    />
    """
  end

  attr :field, :any, required: true
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :hint, :string, default: nil

  defp toggle_input(assigns) do
    assigns =
      assigns
      |> assign(:name, assigns.field.name)
      |> assign(:checked, Form.normalize_value("checkbox", assigns.field.value))

    ~H"""
    <label
      id={"#{@id}-control"}
      class={[
        "flex min-h-12 w-full cursor-pointer items-center justify-between gap-3 rounded-box border border-base-300 bg-base-200/40 px-3 py-2 transition-colors hover:border-primary/50 hover:bg-primary/5 hover:ring-1 hover:ring-primary/20",
        @checked && "border-primary/50 bg-primary/5 ring-1 ring-primary/20"
      ]}
      for={@id}
      data-state={if @checked, do: "enabled", else: "disabled"}
    >
      <span class="grid gap-0.5">
        <span class="text-sm font-medium text-base-content">{@label}</span>
        <span :if={@hint} class="text-xs leading-5 text-base-content/55">{@hint}</span>
      </span>
      <input type="hidden" name={@name} value="false" />
      <input
        id={@id}
        type="checkbox"
        name={@name}
        value="true"
        checked={@checked}
        class="toggle toggle-primary toggle-sm shrink-0"
      />
    </label>
    """
  end

  attr :field, :any, required: true
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :hint, :string, default: nil

  defp number_input(assigns) do
    ~H"""
    <div class="grid gap-1">
      <.input id={@id} field={@field} type="number" label={@label} min="0" step="1" />
      <p :if={@hint} class="text-xs leading-5 text-base-content/55">{@hint}</p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :form, :any, required: true

  defp form_error_summary(assigns) do
    assigns = assign(assigns, :errors, form_error_messages(assigns.form))

    ~H"""
    <div
      id={@id}
      class={[
        @errors == [] && "hidden",
        @errors != [] && "rounded-box border border-error/25 bg-error/10 p-3 text-sm text-error"
      ]}
      role="alert"
    >
      <p :if={@errors != []} class="font-semibold">Review this card before saving.</p>
      <ul :if={@errors != []} class="mt-2 list-disc space-y-1 pl-5">
        <li :for={error <- @errors}>{error}</li>
      </ul>
    </div>
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

  defp smtp_scalar_controls(:before_password) do
    [
      %{
        type: :toggle,
        id: "instance-settings-smtp-enabled",
        field: :enabled,
        label: "SMTP enabled",
        hint: "Use these settings for operator email."
      },
      %{
        type: :input,
        id: "instance-settings-smtp-host",
        field: :host,
        input_type: "text",
        label: "SMTP host"
      },
      %{type: :number, id: "instance-settings-smtp-port", field: :port, label: "SMTP port"},
      %{
        type: :input,
        id: "instance-settings-smtp-from",
        field: :from,
        input_type: "email",
        label: "From address"
      },
      %{
        type: :input,
        id: "instance-settings-smtp-username",
        field: :username,
        input_type: "text",
        label: "SMTP username"
      }
    ]
  end

  defp smtp_scalar_controls(:after_password) do
    [
      %{
        type: :select,
        id: "instance-settings-smtp-tls",
        field: :tls,
        label: "TLS",
        options: [{"Always", "always"}, {"If available", "if_available"}, {"Never", "never"}]
      },
      %{
        type: :toggle,
        id: "instance-settings-smtp-ssl",
        field: :ssl,
        label: "SSL",
        hint: "Connect with SSL from the start."
      },
      %{type: :number, id: "instance-settings-smtp-retries", field: :retries, label: "Retries"}
    ]
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :placeholder, :string, default: nil

  defp list_textarea(assigns) do
    ~H"""
    <label class="fieldset mb-2" for={@id}>
      <span class="label mb-1">{@label}</span>
      <textarea id={@id} name={@name} rows="4" class="w-full textarea" placeholder={@placeholder}>{@value}</textarea>
      <span class="text-xs leading-5 text-base-content/55">
        One value per line or comma-separated.
      </span>
    </label>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :values, :list, required: true

  defp compressed_json_encoding_checkboxes(assigns) do
    assigns = assign(assigns, :options, accepted_compressed_json_encoding_options())

    ~H"""
    <fieldset id={@id} class="grid gap-2 rounded-box border border-base-300 bg-base-200/40 p-3">
      <legend class="px-1 text-sm font-semibold text-base-content">
        Accepted compressed JSON encodings
      </legend>
      <input type="hidden" name={"#{@name}[]"} value="" />
      <p id={"#{@id}-help"} class="text-xs leading-5 text-base-content/60">
        Uncompressed JSON is always accepted. Compressed JSON must declare one of these values in Content-Encoding. Body size, decompressed size, ratio, and timeout limits still apply. If no encodings are selected, compressed JSON requests return 415.
      </p>
      <div class="grid gap-2 sm:grid-cols-3">
        <label
          :for={option <- @options}
          id={"#{@id}-#{option_value(option)}-option"}
          for={"#{@id}-#{option_value(option)}"}
          class="flex min-h-12 cursor-pointer items-center gap-3 rounded-box border border-base-300 bg-base-100 px-3 py-2 transition-colors hover:border-primary/50 hover:bg-primary/5"
        >
          <input
            id={"#{@id}-#{option_value(option)}"}
            type="checkbox"
            name={"#{@name}[]"}
            value={option_value(option)}
            checked={option_value(option) in @values}
            class="checkbox checkbox-primary checkbox-sm shrink-0"
            aria-describedby={"#{@id}-help"}
          />
          <span class="text-sm font-medium text-base-content">{option_label(option)}</span>
        </label>
      </div>
    </fieldset>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :hint, :string, default: nil

  defp json_textarea(assigns) do
    ~H"""
    <label class="fieldset mb-2" for={@id}>
      <span class="label mb-1">{@label}</span>
      <textarea id={@id} name={@name} rows="7" class="w-full textarea font-mono text-xs leading-5">{@value}</textarea>
      <span class="text-xs leading-5 text-base-content/55">
        {@hint || "JSON object. Leave existing keys intact unless intentionally changing this policy."}
      </span>
    </label>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :action_name, :string, required: true
  attr :label, :string, required: true
  attr :status_label, :string, default: "Stored value"
  attr :clear_label, :string, default: "Clear stored value"
  attr :action, :string, required: true
  attr :status, :atom, default: nil

  defp write_only_secret_input(assigns) do
    ~H"""
    <div class="grid gap-2">
      <label class="fieldset mb-0" for={@id}>
        <span class="label mb-1">{@label}</span>
        <input
          id={@id}
          name={@name}
          value=""
          type="password"
          autocomplete="new-password"
          class="w-full input"
          placeholder="Leave blank to preserve"
        />
      </label>
      <div class="flex flex-wrap items-center justify-between gap-3">
        <p id={"#{@id}-status"} class="text-xs leading-5 text-base-content/60">
          {@status_label}:
          <span class={secret_status_class(@status)}>{secret_status_label(@status)}</span>
        </p>
        <input type="hidden" name={@action_name} value="preserve" />
        <label class="flex cursor-pointer items-center gap-2 text-xs font-medium text-base-content/70">
          <input
            id={"#{@id}-clear"}
            type="checkbox"
            name={@action_name}
            value="clear"
            checked={@action == "clear"}
            class="checkbox checkbox-primary checkbox-sm"
          />
          {@clear_label}
        </label>
      </div>
    </div>
    """
  end

  defp submit_label(group), do: Map.fetch!(@settings_group_submit_labels, group)

  defp mcp_key_count_label(0), do: "No MCP keys exist in this system."
  defp mcp_key_count_label(1), do: "1 MCP key exists in this system."
  defp mcp_key_count_label(count), do: "#{count} MCP keys exist in this system."

  defp card_status_message(nil, true), do: "Changes save automatically."
  defp card_status_message(nil, false), do: "No changes saved in this card yet."
  defp card_status_message(%{message: message}, _autosave), do: message

  defp card_status_class(%{tone: :success}) do
    "rounded-box border border-success/25 bg-success/10 px-3 py-2 text-sm font-medium text-success"
  end

  defp card_status_class(%{tone: :warning}) do
    "rounded-box border border-warning/25 bg-warning/10 px-3 py-2 text-sm font-medium text-warning"
  end

  defp card_status_class(%{tone: :error}) do
    "rounded-box border border-error/25 bg-error/10 px-3 py-2 text-sm font-medium text-error"
  end

  defp card_status_class(_status) do
    "rounded-box border border-base-300 bg-base-200/70 px-3 py-2 text-sm text-base-content/60"
  end

  defp development_action_notice_content(nil) do
    %{
      icon: "hero-information-circle",
      tone: :info,
      title: "Ready to import",
      message: "Run a development import when you need fresh fake data or pricing snapshots."
    }
  end

  defp development_action_notice_content(%{tone: :success, message: message}) do
    %{icon: "hero-check-circle", tone: :success, title: "Import complete", message: message}
  end

  defp development_action_notice_content(%{tone: :error, message: message}) do
    %{icon: "hero-exclamation-triangle", tone: :error, title: "Import failed", message: message}
  end

  defp development_action_notice_content(%{message: message}) do
    %{icon: "hero-information-circle", tone: :info, title: "Import status", message: message}
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

  defp accepted_compressed_json_encoding_options do
    [{"gzip", "gzip"}, {"deflate", "deflate"}, {"zstd", "zstd"}]
  end

  defp option_label({label, _value}), do: label
  defp option_value({_label, value}), do: value

  defp param_json_value(params, group, field, fallback) do
    case get_in(params, [group, field]) do
      value when is_binary(value) -> value
      value when is_map(value) -> Jason.encode!(value, pretty: true)
      _missing -> Jason.encode!(fallback || %{}, pretty: true)
    end
  end

  defp param_secret_action(params, group, field) do
    case get_in(params, [group, field]) do
      "clear" -> "clear"
      _other -> "preserve"
    end
  end

  defp safe_value(value) when is_binary(value) and value != "", do: value
  defp safe_value(_value), do: "not configured"

  defp secret_status_label(:configured), do: "configured"
  defp secret_status_label(:intentionally_unset), do: "not configured"
  defp secret_status_label(:unavailable), do: "unavailable"
  defp secret_status_label(_status), do: "not configured"

  defp secret_status_class(:configured), do: "font-semibold text-success"
  defp secret_status_class(:unavailable), do: "font-semibold text-warning"
  defp secret_status_class(_status), do: "font-semibold text-base-content/70"

  defp smtp_status_message(nil), do: "No SMTP test email has been sent in this form session."
  defp smtp_status_message(%{message: message}), do: message

  defp smtp_status_class(nil) do
    "rounded-box border border-base-300 bg-base-200/70 px-3 py-2 text-sm text-base-content/60"
  end

  defp smtp_status_class(%{tone: :success}) do
    "rounded-box border border-success/25 bg-success/10 px-3 py-2 text-sm font-medium text-success"
  end

  defp smtp_status_class(%{tone: :error}) do
    "rounded-box border border-error/25 bg-error/10 px-3 py-2 text-sm font-medium text-error"
  end

  defp form_error_messages(%Phoenix.HTML.Form{source: %Ecto.Changeset{action: nil}}), do: []

  defp form_error_messages(%Phoenix.HTML.Form{} = form) do
    form.source
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> flatten_error_map()
    |> Enum.uniq()
  end

  defp flatten_error_map(errors) when is_map(errors) do
    Enum.flat_map(errors, fn {field, value} -> flatten_error_value([field], value) end)
  end

  defp flatten_error_value(path, messages) when is_list(messages) do
    Enum.map(messages, fn message -> "#{error_path_label(path)} #{message}" end)
  end

  defp flatten_error_value(path, errors) when is_map(errors) do
    Enum.flat_map(errors, fn {field, value} -> flatten_error_value(path ++ [field], value) end)
  end

  defp error_path_label(path), do: Enum.map_join(path, " ", &Phoenix.Naming.humanize/1)
end
