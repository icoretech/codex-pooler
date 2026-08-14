defmodule CodexPoolerWeb.Admin.SystemPageComponents.GatewaySettingsMatrix do
  @moduledoc false

  use CodexPoolerWeb, :html

  attr :groups, :list, required: true

  def matrix(assigns) do
    ~H"""
    <section
      id="instance-settings-gateway-scalar-matrix"
      data-role="gateway-settings-matrix"
      class="grid min-w-0 gap-3"
    >
      <div class="grid max-w-3xl gap-1">
        <h4 class="text-sm font-medium text-base-content">Runtime limits</h4>
        <p class="text-xs leading-5 text-base-content/60">
          Edit each limit or reset a group to its canonical runtime defaults.
        </p>
      </div>

      <p
        id="instance-settings-gateway-scalar-mobile-cue"
        class="text-[0.62rem] font-semibold uppercase tracking-[0.08em] text-base-content/50 sm:hidden"
      >
        Swipe table for values &rarr;
      </p>

      <div
        id="instance-settings-gateway-scalar-scroll-region"
        data-role="gateway-settings-scroll-region"
        class="overflow-x-auto rounded-box border border-base-300"
      >
        <table class="table table-sm min-w-xl bg-base-100">
          <thead>
            <tr class="text-[0.62rem] uppercase tracking-[0.08em] text-base-content/45">
              <th scope="col" class="w-full min-w-64 border-b-0">Setting</th>
              <th scope="col" class="min-w-64 border-b-0">Current value</th>
            </tr>
          </thead>
          <.settings_group :for={group <- @groups} group={group} />
        </table>
      </div>

      <p class="text-xs leading-5 text-base-content/55">
        Group resets load defaults into the form. They are not persisted until this card is saved.
      </p>
    </section>
    """
  end

  attr :group, :map, required: true

  defp settings_group(assigns) do
    ~H"""
    <tbody data-runtime-limit-group={@group.id}>
      <tr
        id={"instance-settings-gateway-scalar-group-#{@group.id}"}
        class="bg-base-200/65"
      >
        <th
          scope="rowgroup"
          colspan="2"
          class="border-t border-t-base-300 py-2"
        >
          <div class="flex items-center justify-between gap-4">
            <span class="min-w-0">
              <span class="block text-xs font-semibold text-base-content/70">{@group.label}</span>
              <span class="mt-0.5 block text-xs font-normal leading-4 text-base-content/50">
                {@group.description}
              </span>
            </span>
            <button
              id={"instance-settings-gateway-reset-#{@group.id}"}
              type="button"
              phx-click="restore_gateway_group_defaults"
              phx-value-group={@group.id}
              class="btn btn-ghost btn-square btn-xs shrink-0 text-base-content/60 hover:text-base-content"
              aria-label={"Reset #{@group.label} settings to their defaults"}
              title={"Reset #{@group.label} settings to their defaults"}
            >
              <.icon name="hero-arrow-path" class="size-3.5" />
            </button>
          </div>
        </th>
      </tr>
      <.setting_row :for={setting <- @group.settings} form={@group.form} setting={setting} />
    </tbody>
    """
  end

  attr :form, :any, required: true
  attr :setting, :map, required: true

  defp setting_row(assigns) do
    field = assigns.form[assigns.setting.field]

    errors =
      if Phoenix.Component.used_input?(field),
        do: Enum.map(field.errors, &translate_error/1),
        else: []

    assigns =
      assigns
      |> assign(:field, field)
      |> assign(:error, List.first(errors))

    ~H"""
    <tr
      id={"instance-settings-gateway-setting-#{@setting.dom_id}"}
      data-role="gateway-setting-row"
      class="align-top"
    >
      <th scope="row" class="whitespace-normal py-3 font-normal">
        <span
          id={"instance-settings-gateway-label-line-#{@setting.dom_id}"}
          class="flex flex-wrap items-baseline gap-x-2"
        >
          <span class="text-sm font-semibold leading-5 text-base-content">{@setting.label}</span>
          <span
            :if={@error}
            id={"#{@setting.id}-error"}
            class="text-xs font-normal leading-4 text-error"
          >
            {@error}
          </span>
        </span>
        <span
          id={"instance-settings-gateway-hint-#{@setting.dom_id}"}
          class="mt-0.5 block w-full max-w-none text-xs leading-4 text-base-content/55"
        >
          {@setting.hint}
        </span>
      </th>
      <td class="py-3">
        <label class="sr-only" for={@setting.id}>{@setting.label}</label>
        <div
          id={"instance-settings-gateway-control-#{@setting.dom_id}"}
          class={[
            "input flex w-full min-w-44 items-center gap-0 overflow-hidden p-0 pl-3",
            @error && "input-error"
          ]}
        >
          <input
            id={@setting.id}
            name={@field.name}
            type="number"
            value={Phoenix.HTML.Form.normalize_value("number", @field.value)}
            min={@setting.minimum}
            max={@setting.maximum}
            step="1"
            inputmode="numeric"
            aria-label={"Current value for #{@setting.label}"}
            aria-invalid={to_string(not is_nil(@error))}
            aria-describedby={@error && "#{@setting.id}-error"}
            class="min-w-0 grow bg-transparent outline-none"
          />
          <span
            id={"instance-settings-gateway-unit-#{@setting.dom_id}"}
            class="flex h-full min-w-9 shrink-0 items-center justify-center border-l border-base-300 px-2 text-xs font-medium text-base-content/50"
          >
            {@setting.unit}
          </span>
        </div>
      </td>
    </tr>
    """
  end
end
