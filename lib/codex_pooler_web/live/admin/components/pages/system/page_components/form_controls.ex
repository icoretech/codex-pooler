defmodule CodexPoolerWeb.Admin.SystemPageComponents.FormControls do
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

  attr :group, :string, required: true
  attr :form, :any, required: true
  attr :status, :map, default: nil
  attr :autosave, :boolean, default: false

  slot :inner_block, required: true

  def settings_card(assigns) do
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

  def settings_group(assigns) do
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

  attr :form, :any, required: true
  attr :controls, :list, required: true

  def scalar_controls(assigns) do
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

  def toggle_input(assigns) do
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

  def number_input(assigns) do
    ~H"""
    <div class="grid gap-1">
      <.input id={@id} field={@field} type="number" label={@label} min="0" step="1" />
      <p :if={@hint} class="text-xs leading-5 text-base-content/55">{@hint}</p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :form, :any, required: true

  def form_error_summary(assigns) do
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

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :placeholder, :string, default: nil

  def list_textarea(assigns) do
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

  def compressed_json_encoding_checkboxes(assigns) do
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

  def json_textarea(assigns) do
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

  def write_only_secret_input(assigns) do
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

  defp accepted_compressed_json_encoding_options do
    [{"gzip", "gzip"}, {"deflate", "deflate"}, {"zstd", "zstd"}]
  end

  defp option_label({label, _value}), do: label
  defp option_value({_label, value}), do: value

  defp secret_status_label(:configured), do: "configured"
  defp secret_status_label(:intentionally_unset), do: "not configured"
  defp secret_status_label(:unavailable), do: "unavailable"
  defp secret_status_label(_status), do: "not configured"

  defp secret_status_class(:configured), do: "font-semibold text-success"
  defp secret_status_class(:unavailable), do: "font-semibold text-warning"
  defp secret_status_class(_status), do: "font-semibold text-base-content/70"

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
