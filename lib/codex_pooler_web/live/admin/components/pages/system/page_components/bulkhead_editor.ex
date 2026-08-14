defmodule CodexPoolerWeb.Admin.SystemPageComponents.BulkheadEditor do
  @moduledoc false

  use CodexPoolerWeb, :html

  @presets [
    %{id: :default, label: "Solo / Small", range: "1-4 active"},
    %{id: :medium, label: "Medium", range: "5-49 active"},
    %{id: :large, label: "Large", range: "50+ active"}
  ]

  @gateway_rows [
    %{
      route_class: "proxy_http",
      label: "Buffered requests",
      description: "Does not share streaming or persistent-session capacity."
    },
    %{
      route_class: "proxy_stream",
      label: "Streaming responses",
      description: "Long streams do not occupy the buffered lane."
    },
    %{
      route_class: "proxy_websocket",
      label: "WebSocket sessions",
      description: "Persistent sockets do not occupy buffered or streaming lanes."
    },
    %{
      route_class: "proxy_compact",
      label: "Compact responses",
      description: "Compaction does not occupy ordinary response lanes."
    },
    %{
      route_class: "proxy_control",
      label: "Control plane (reserved)",
      description: "No current route selects this class."
    }
  ]

  @supporting_rows [
    %{
      route_class: "file_upload",
      label: "File operations",
      description: "Shared by every file endpoint; outside proxy traffic."
    },
    %{
      route_class: "audio_transcription",
      label: "Audio transcription",
      description: "Outside proxy traffic and file operations."
    },
    %{
      route_class: "admin_browser",
      label: "Browser pages",
      description: "Login, onboarding, and admin UI stay outside runtime traffic."
    },
    %{
      route_class: "mcp",
      label: "MCP requests",
      description: "Outside browser and runtime traffic."
    }
  ]

  attr :bulkheads, :map, required: true
  attr :active_preset, :atom, required: true

  def editor(assigns) do
    assigns =
      assigns
      |> assign(:presets, @presets)
      |> assign(:gateway_rows, project_rows(@gateway_rows, assigns.bulkheads))
      |> assign(:supporting_rows, project_rows(@supporting_rows, assigns.bulkheads))

    ~H"""
    <section
      id="instance-settings-bulkheads"
      data-role="bulkhead-editor"
      data-active-preset={@active_preset}
      class="grid min-w-0 gap-3"
    >
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="grid max-w-3xl gap-1">
          <h4 class="text-sm font-medium text-base-content">Route-class bulkheads</h4>
          <p class="text-xs leading-5 text-base-content/60">
            Each class has a separate per-node concurrency and queue budget. Saturating one class does not consume another class's capacity.
          </p>
        </div>
        <span
          :if={@active_preset == :custom}
          id="instance-settings-bulkhead-custom"
          class="badge badge-outline badge-sm text-base-content/65"
        >
          Custom values
        </span>
      </div>

      <div id="instance-settings-bulkhead-preset-region" class="grid gap-2">
        <div
          id="instance-settings-bulkhead-presets"
          class="grid gap-1 rounded-field border border-base-300 bg-base-200/60 p-1 sm:grid-cols-3"
          role="group"
          aria-label="Concurrent user presets"
        >
          <button
            :for={preset <- @presets}
            id={"instance-settings-bulkhead-preset-#{preset.id}"}
            type="button"
            phx-click="apply_bulkhead_preset"
            phx-value-preset={preset.id}
            aria-pressed={to_string(@active_preset == preset.id)}
            class={[
              "grid min-h-12 cursor-pointer gap-0.5 rounded-field border px-3 py-2 text-left transition-colors focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary",
              @active_preset == preset.id &&
                "border-primary/50 bg-primary/5 text-base-content",
              @active_preset != preset.id &&
                "border-transparent text-base-content/65 hover:border-base-300 hover:bg-base-100 hover:text-base-content"
            ]}
          >
            <span class="text-sm font-semibold leading-4">{preset.label}</span>
            <span class="text-[11px] leading-4 text-base-content/55">{preset.range}</span>
          </button>
        </div>
        <p
          id="instance-settings-bulkhead-notes"
          class="text-xs leading-5 text-base-content/55"
        >
          Route classes stay fixed. Max concurrent and timeout must be at least 1; queue limit may be 0.
        </p>
      </div>

      <p
        id="instance-settings-bulkhead-mobile-cue"
        class="text-[0.62rem] font-semibold uppercase tracking-[0.08em] text-base-content/50 sm:hidden"
      >
        Swipe table for limits &rarr;
      </p>

      <div
        id="instance-settings-bulkhead-scroll-region"
        data-role="bulkhead-scroll-region"
        class="overflow-x-auto rounded-box border border-base-300"
      >
        <table class="table table-sm min-w-xl bg-base-100">
          <thead>
            <tr class="text-[0.62rem] uppercase tracking-[0.08em] text-base-content/45">
              <th scope="col" class="w-full min-w-56">Route class</th>
              <th scope="col" class="min-w-24">Max concurrent</th>
              <th scope="col" class="min-w-24">Queue limit</th>
              <th scope="col" class="min-w-24">Timeout (ms)</th>
            </tr>
          </thead>
          <.bulkhead_group
            id="instance-settings-bulkhead-group-gateway"
            label="Gateway traffic"
            rows={@gateway_rows}
          />
          <.bulkhead_group
            id="instance-settings-bulkhead-group-supporting"
            label="Supporting lanes"
            rows={@supporting_rows}
          />
        </table>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :rows, :list, required: true

  defp bulkhead_group(assigns) do
    ~H"""
    <tbody>
      <tr id={@id} class="bg-base-200/65">
        <th
          scope="rowgroup"
          colspan="4"
          class="border-t border-base-300 py-2 text-[0.62rem] font-semibold uppercase tracking-[0.08em] text-base-content/50"
        >
          {@label}
        </th>
      </tr>
      <tr
        :for={row <- @rows}
        id={"instance-settings-bulkhead-row-#{row.dom_id}"}
        data-role="bulkhead-row"
        data-route-class={row.route_class}
        class="align-top"
      >
        <th scope="row" class="whitespace-normal py-3 font-normal">
          <span class="block text-sm font-semibold leading-5 text-base-content">{row.label}</span>
          <span class="mt-0.5 block max-w-72 text-xs leading-4 text-base-content/55">
            {row.description}
          </span>
        </th>
        <td :for={field <- row.fields} class="py-3">
          <label class="sr-only" for={field.id}>{field.accessible_label}</label>
          <input
            id={field.id}
            type="number"
            name={field.name}
            value={field.value}
            min={field.minimum}
            step="1"
            required
            inputmode="numeric"
            aria-invalid={to_string(!field.valid?)}
            aria-describedby={if field.valid?, do: nil, else: "#{field.id}-error"}
            class={[
              "input input-sm w-full min-w-20",
              !field.valid? && "input-error"
            ]}
          />
          <p
            :if={!field.valid?}
            id={"#{field.id}-error"}
            class="mt-1 text-xs leading-4 text-error"
          >
            {field.error_message}
          </p>
        </td>
      </tr>
    </tbody>
    """
  end

  defp project_rows(rows, bulkheads) do
    Enum.map(rows, fn row ->
      config = Map.get(bulkheads, row.route_class, %{})
      dom_id = String.replace(row.route_class, "_", "-")

      fields = [
        project_field(row, dom_id, config, "max_concurrency", "Max concurrent", 1),
        project_field(row, dom_id, config, "queue_limit", "Queue limit", 0),
        project_field(row, dom_id, config, "queue_timeout_ms", "Timeout", 1)
      ]

      row |> Map.put(:dom_id, dom_id) |> Map.put(:fields, fields)
    end)
  end

  defp project_field(row, dom_id, config, field, label, minimum) do
    value = config_value(config, field)
    id = "instance-settings-bulkhead-#{dom_id}-#{String.replace(field, "_", "-")}"

    %{
      id: id,
      name: "instance_settings[gateway][bulkheads][#{row.route_class}][#{field}]",
      value: value,
      minimum: minimum,
      valid?: is_integer(value) and value >= minimum,
      accessible_label: "#{label} for #{row.label}",
      error_message: "Must be #{minimum} or more"
    }
  end

  defp config_value(config, "max_concurrency"),
    do: Map.get(config, "max_concurrency", Map.get(config, :max_concurrency))

  defp config_value(config, "queue_limit"),
    do: Map.get(config, "queue_limit", Map.get(config, :queue_limit))

  defp config_value(config, "queue_timeout_ms"),
    do: Map.get(config, "queue_timeout_ms", Map.get(config, :queue_timeout_ms))
end
