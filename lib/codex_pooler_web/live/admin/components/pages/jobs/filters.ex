defmodule CodexPoolerWeb.Admin.JobsPageComponents.Filters do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.JobFilterForm
  alias Phoenix.LiveView.JS

  attr :filter_form, :any, required: true
  attr :filters, :map, required: true
  attr :filter_options, :map, required: true
  attr :filter_errors, :list, required: true

  def job_filters(assigns) do
    assigns =
      assigns
      |> assign(:target_kind_options, target_kind_options(assigns.filter_options.target_kind))
      |> assign(:show_completed_options, show_completed_options())

    ~H"""
    <AdminComponents.filter_form
      id="job-filter-form"
      for={@filter_form}
      phx-change="filter"
      phx-submit="filter"
      mobile_single_column
      single_row
      advanced_open={advanced_filters_open?(@filters)}
      autocomplete="off"
    >
      <input
        type="hidden"
        id="filters_page"
        name="filters[page]"
        value={Integer.to_string(@filters.page)}
      />
      <input
        type="hidden"
        id="filters_job_id"
        name="filters[job_id]"
        value={if @filters.job_id, do: Integer.to_string(@filters.job_id), else: ""}
      />

      <.job_filter_dropdown
        id="job-attention-filter"
        label="Attention"
        field_name="attention"
        hidden_id="filters_attention"
        role="attention-filter"
        event="select_attention_filter"
        value_attr={:attention}
        selected_value={@filters.attention || ""}
        selected={JobFilterForm.selected_attention_option(@filters.attention)}
        options={@filter_options.attention}
      />
      <.job_filter_dropdown
        id="job-state-filter"
        label="State"
        field_name="state"
        hidden_id="filters_state"
        role="state-filter"
        event="select_state_filter"
        value_attr={:state}
        selected_value={@filters.state || ""}
        selected={JobFilterForm.selected_state_option(@filters.state)}
        options={@filter_options.state}
      />
      <.job_filter_dropdown
        id="job-worker-filter"
        label="Worker"
        field_name="worker"
        hidden_id="filters_worker"
        role="worker-filter"
        event="select_worker_filter"
        value_attr={:worker}
        selected_value={@filters.worker || ""}
        selected={JobFilterForm.selected_worker_option(@filter_options.worker, @filters.worker)}
        options={@filter_options.worker}
      />
      <.job_filter_dropdown
        id="job-queue-filter"
        label="Queue"
        field_name="queue"
        hidden_id="filters_queue"
        role="queue-filter"
        event="select_queue_filter"
        value_attr={:queue}
        selected_value={@filters.queue || ""}
        selected={JobFilterForm.selected_queue_option(@filter_options.queue, @filters.queue)}
        options={@filter_options.queue}
      />
      <.job_filter_dropdown
        id="job-show-completed-filter"
        label="Completed visibility"
        field_name="show_completed"
        hidden_id="filters_show_completed"
        role="show-completed-filter"
        event="select_show_completed_filter"
        value_attr={:show_completed}
        selected_value={show_completed_value(@filters.show_completed)}
        selected={selected_show_completed_option(@filters.show_completed)}
        options={@show_completed_options}
      />

      <:advanced>
        <.job_filter_dropdown
          id="job-target-kind-filter"
          label="Target kind"
          field_name="target_kind"
          hidden_id="filters_target_kind"
          role="target-kind-filter"
          event="select_target_kind_filter"
          value_attr={:target_kind}
          selected_value={@filters.target_kind || ""}
          selected={selected_target_kind_option(@target_kind_options, @filters.target_kind)}
          options={@target_kind_options}
        />
        <.target_id_filter value={@filters.target_id || ""} />
      </:advanced>
    </AdminComponents.filter_form>

    <div
      :if={@filter_errors != []}
      id="job-filter-errors"
      class="alert alert-warning items-start"
    >
      <.icon name="hero-exclamation-triangle" class="size-5" />
      <div>
        <p class="font-semibold">Some filters were ignored</p>
        <ul class="mt-1 list-disc space-y-1 pl-5 text-sm">
          <li
            :for={error <- @filter_errors}
            data-role="job-filter-warning"
            data-field={error.field}
          >
            {error.message}
          </li>
        </ul>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :field_name, :string, required: true
  attr :hidden_id, :string, required: true
  attr :role, :string, required: true
  attr :event, :string, required: true
  attr :value_attr, :atom, required: true
  attr :selected_value, :string, required: true
  attr :selected, :map, required: true
  attr :options, :list, required: true

  defp job_filter_dropdown(assigns) do
    ~H"""
    <div class="grid gap-2">
      <input
        type="hidden"
        id={@hidden_id}
        name={"filters[#{@field_name}]"}
        value={@selected_value}
      />
      <details
        id={@id}
        class="dropdown w-full"
        phx-click-away={JS.remove_attribute("open", to: "##{@id}")}
      >
        <summary
          data-role={"#{@role}-trigger"}
          aria-label={@label}
          class="select select-bordered flex min-h-10 w-full cursor-pointer items-center gap-2 pr-8 text-left text-sm font-normal"
        >
          <.icon name={@selected.icon} class={["size-4 shrink-0", option_icon_class(@selected)]} />
          <span class="truncate">{@selected.label}</span>
        </summary>
        <ul
          data-role={"#{@role}-menu"}
          class="menu dropdown-content z-[60] mt-1 max-h-80 w-full flex-nowrap overflow-y-auto rounded-box border border-base-300 bg-base-100 p-1 !transition-none ![scale:100%] shadow-xl"
        >
          <li :for={option <- @options}>
            <button
              type="button"
              phx-click={@event}
              phx-value-attention={filter_option_value(@value_attr, :attention, option)}
              phx-value-state={filter_option_value(@value_attr, :state, option)}
              phx-value-worker={filter_option_value(@value_attr, :worker, option)}
              phx-value-queue={filter_option_value(@value_attr, :queue, option)}
              phx-value-target-kind={filter_option_value(@value_attr, :target_kind, option)}
              phx-value-show-completed={filter_option_value(@value_attr, :show_completed, option)}
              data-role={"#{@role}-option"}
              data-attention={filter_option_value(@value_attr, :attention, option)}
              data-state={filter_option_value(@value_attr, :state, option)}
              data-worker={filter_option_value(@value_attr, :worker, option)}
              data-queue={filter_option_value(@value_attr, :queue, option)}
              data-target-kind={filter_option_value(@value_attr, :target_kind, option)}
              data-show-completed={filter_option_value(@value_attr, :show_completed, option)}
              class={[
                "flex items-center gap-2 text-sm",
                option.value == @selected_value && "active"
              ]}
              aria-current={option.value == @selected_value && "true"}
            >
              <span data-role={"#{@role}-icon"} class="shrink-0">
                <.icon name={option.icon} class={["size-4", option_icon_class(option)]} />
              </span>
              <span class="truncate">{option.label}</span>
            </button>
          </li>
        </ul>
      </details>
    </div>
    """
  end

  attr :value, :string, required: true

  defp target_id_filter(assigns) do
    ~H"""
    <div id="job-target-id-filter" class="fieldset mb-2">
      <div class="input input-sm flex w-full items-center gap-2">
        <span class="label !mb-0 min-w-20 shrink-0 truncate !px-2 !normal-case !tracking-normal leading-none text-base-content/60">
          Target id
        </span>
        <input
          type="text"
          id="filters_target_id"
          name="filters[target_id]"
          value={@value}
          placeholder="UUID, date, or blank"
          aria-label="Target id"
          class="min-w-0 grow bg-transparent p-0 font-mono text-xs font-normal outline-none placeholder:font-sans placeholder:text-base-content/45"
        />
      </div>
    </div>
    """
  end

  defp target_kind_options(options) do
    [%{label: "Any target", value: "", icon: "hero-tag"} | options]
  end

  defp show_completed_options do
    [
      %{label: "Hide completed", value: "false", icon: "hero-eye-slash"},
      %{label: "Include completed", value: "true", icon: "hero-eye"}
    ]
  end

  defp selected_show_completed_option(true),
    do: %{label: "Include completed", value: "true", icon: "hero-eye"}

  defp selected_show_completed_option(_show_completed),
    do: %{label: "Hide completed", value: "false", icon: "hero-eye-slash"}

  defp selected_target_kind_option(options, target_kind) do
    Enum.find(options, &(&1.value == (target_kind || ""))) || hd(options)
  end

  defp show_completed_value(true), do: "true"
  defp show_completed_value(_show_completed), do: "false"

  defp advanced_filters_open?(filters) do
    filters.target_kind != nil or filters.target_id != nil
  end

  defp filter_option_value(current_attr, target_attr, option) when current_attr == target_attr,
    do: option.value

  defp filter_option_value(_current_attr, _target_attr, _option), do: nil

  defp option_icon_class(%{value: "active_failure"}), do: "text-error"
  defp option_icon_class(%{value: "retry_pressure"}), do: "text-warning"
  defp option_icon_class(%{value: "stuck_executing"}), do: "text-warning"
  defp option_icon_class(%{value: "backlog_pressure"}), do: "text-warning"
  defp option_icon_class(%{value: "completed"}), do: "text-success"
  defp option_icon_class(%{value: "discarded"}), do: "text-error"
  defp option_icon_class(%{value: "cancelled"}), do: "text-warning"
  defp option_icon_class(%{value: "retryable"}), do: "text-warning"
  defp option_icon_class(%{value: "executing"}), do: "text-info"
  defp option_icon_class(%{value: "available"}), do: "text-info"
  defp option_icon_class(%{value: "scheduled"}), do: "text-info"
  defp option_icon_class(%{value: "true"}), do: "text-success"
  defp option_icon_class(_option), do: "text-base-content/60"
end
