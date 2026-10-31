defmodule CodexPoolerWeb.Admin.RequestLogsPresentation.Issues do
  @moduledoc false

  use CodexPoolerWeb, :html

  import CodexPoolerWeb.Admin.RequestLogsDisplay, only: [format_errors: 2, format_served_model_detail: 1]

  @spec has_issues?(map(), map()) :: boolean()
  def has_issues?(request_log, datetime_preferences),
    do: issue_details(request_log, datetime_preferences).has_issues?

  attr :request_log, :map, required: true
  attr :datetime_preferences, :map, required: true
  attr :prefix, :string, required: true

  @spec request_log_issues_cell(map()) :: Phoenix.LiveView.Rendered.t()
  def request_log_issues_cell(assigns) do
    assigns = assign(assigns, issue_details(assigns.request_log, assigns.datetime_preferences))

    ~H"""
    <td data-role="request-issues-cell" class={["min-w-0 align-middle max-lg:col-span-2 max-lg:col-start-1 max-lg:row-start-5 max-lg:sm:col-span-3 max-lg:sm:row-start-3", !@has_issues? && "max-lg:hidden"]}>
      <div :if={@has_issues?} id={"#{@prefix}-#{@request_log.id}-issues"} data-role="request-issues" class="grid min-w-0 gap-1 text-[11px] leading-4">
        <span class="text-[10px] uppercase tracking-wide text-base-content/50 lg:hidden">{gettext("Errors · Warnings")}</span>
        <ul :if={@errors != []} id={"#{@prefix}-#{@request_log.id}-errors"} data-role="errors" class={["grid min-w-0 gap-1", error_text_class(@display_status)]}>
          <li :for={error <- @errors} data-role="error-line" class="flex min-w-0 items-start gap-1">
            <span aria-hidden="true" class="inline-flex h-4 shrink-0 items-center"><.icon name="hero-exclamation-triangle" class={["size-3.5", error_icon_class(@display_status)]} /></span>
            <span class="min-w-0 whitespace-normal break-words">{error}</span>
          </li>
        </ul>
        <span
          :if={@model_mismatch?}
          id={"#{@prefix}-#{@request_log.id}-served-model"}
          data-role="served-model"
          class="flex min-w-0 items-start gap-1 text-warning"
          title={gettext("Upstream declared model: %{model}; differs from the model sent upstream", model: @request_log.served_model)}
          aria-label={gettext("Upstream declared model: %{model}; differs from the model sent upstream", model: @request_log.served_model)}
        >
          <span aria-hidden="true" class="inline-flex h-4 shrink-0 items-center"><.icon name="hero-exclamation-triangle" class="size-3.5" /></span>
          <span class="min-w-0 whitespace-normal break-words">{gettext("Model mismatch: %{model}", model: @request_log.served_model)}</span>
        </span>
        <span :if={@conflict_attempts != []} data-role="model-declaration-conflict" class="flex min-w-0 items-start gap-1 text-warning" title={ngettext("The provider reported different model names during the same response on attempt %{attempts}", "The provider reported different model names during the same response on attempts %{attempts}", length(@conflict_attempts), attempts: Enum.join(@conflict_attempts, ", "))}>
          <span aria-hidden="true" class="inline-flex h-4 shrink-0 items-center"><.icon name="hero-exclamation-triangle" class="size-3.5" /></span>
          <span class="min-w-0 whitespace-normal break-words">{ngettext("model name changed · attempt %{attempts}", "model name changed · attempts %{attempts}", length(@conflict_attempts), attempts: Enum.join(@conflict_attempts, ", "))}</span>
        </span>
      </div>
      <span :if={!@has_issues?} data-role="no-request-issues" class="text-base-content/45">—</span>
    </td>
    """
  end

  defp issue_details(request_log, datetime_preferences) do
    errors = request_log |> format_errors(datetime_preferences) |> Enum.reject(&(&1 == "—"))
    model_mismatch? = not is_nil(format_served_model_detail(request_log))
    conflict_attempts = Map.get(request_log, :model_conflict_attempts, [])

    %{
      display_status: Map.get(request_log, :display_status) || request_log.status,
      errors: errors,
      model_mismatch?: model_mismatch?,
      conflict_attempts: conflict_attempts,
      has_issues?: errors != [] or model_mismatch? or conflict_attempts != []
    }
  end

  defp error_text_class(status) when status in ["failed", "rejected"], do: "text-error"
  defp error_text_class("client_cancelled"), do: "text-warning"
  defp error_text_class(_status), do: "text-base-content/65"

  # A client cancellation's code is not a failure: its marker takes the row's
  # warning tone. Every other row keeps the red marker on each error line.
  defp error_icon_class("client_cancelled"), do: "text-warning"
  defp error_icon_class(_status), do: "text-error"
end
