defmodule CodexPoolerWeb.Admin.RequestLogsDisplay.Status do
  @moduledoc false

  use Gettext, backend: CodexPoolerWeb.Gettext

  @status_options ~w(accepted in_progress succeeded failed client_cancelled rejected)
  # `failed` lists failures without the client cancellations, which have their
  # own option (`RequestOutcome`); the menu says so where the choice is made.
  @default_request_status_presentation %{
    icon: "hero-question-mark-circle",
    icon_class: "mx-auto size-5 text-base-content/60",
    filter_icon_color: "text-base-content/60"
  }
  @request_status_presentations %{
    "accepted" => %{
      icon: "hero-clock",
      icon_class: "mx-auto size-5 text-info",
      filter_icon_color: "text-info"
    },
    "succeeded" => %{
      icon: "hero-check-circle",
      icon_class: "mx-auto size-5 text-success",
      filter_icon_color: "text-success"
    },
    "failed" => %{
      icon: "hero-x-circle",
      icon_class: "mx-auto size-5 text-error",
      filter_icon_color: "text-error"
    },
    "rejected" => %{
      icon: "hero-shield-exclamation",
      icon_class: "mx-auto size-5 text-error",
      filter_icon_color: "text-error"
    },
    "client_cancelled" => %{
      icon: "hero-stop-circle",
      icon_class: "mx-auto size-5 text-warning",
      filter_icon_color: "text-warning"
    },
    "in_progress" => %{
      icon: "hero-clock",
      icon_class: "mx-auto size-5 text-info",
      filter_icon_color: "text-info"
    }
  }

  @spec selected_status_filter_option(String.t() | nil) :: map()
  def selected_status_filter_option(status) do
    status_filter_options()
    |> Enum.find(&(&1.value == status))
    |> Kernel.||(%{
      label: status_filter_label(status),
      value: status || "",
      icon: request_status_icon(status),
      icon_class: request_status_filter_icon_color(status)
    })
  end

  @spec status_filter_options() :: [map()]
  def status_filter_options do
    [
      %{
        label: gettext("Any status"),
        value: "",
        icon: "hero-question-mark-circle",
        icon_class: "text-base-content/60"
      }
      | Enum.map(@status_options, fn status ->
          Map.merge(
            %{
              label: status_label(status),
              value: status,
              icon: request_status_icon(status),
              icon_class: request_status_filter_icon_color(status)
            },
            status_option_details(status)
          )
        end)
    ]
  end

  @spec selected_model_filter_option(String.t() | nil) :: map()
  def selected_model_filter_option(model) do
    %{label: model_filter_label(model), value: model || "", icon: "hero-cpu-chip"}
  end

  @spec status_description(String.t() | nil) :: String.t() | nil
  def status_description("accepted"), do: gettext("Accepted; execution reservation is pending.")
  def status_description("client_cancelled"), do: gettext("An automatic client interruption or connection loss can produce this outcome. It does not imply zero usage. Excluded from failure totals.")
  def status_description(_status), do: nil

  @spec status_label(String.t()) :: String.t()
  def status_label("accepted"), do: gettext("Accepted")
  def status_label("in_progress"), do: gettext("In progress")
  def status_label("succeeded"), do: gettext("Succeeded")
  def status_label("failed"), do: gettext("Failed")
  def status_label("rejected"), do: gettext("Rejected")
  def status_label("client_cancelled"), do: gettext("Client cancelled")
  def status_label("unknown"), do: gettext("Unknown")
  def status_label(status), do: status |> String.replace("_", " ") |> String.capitalize()

  defp status_option_details("accepted"), do: %{detail: gettext("reservation pending"), title: status_description("accepted")}
  defp status_option_details("failed"), do: %{detail: gettext("excl. client cancelled"), title: gettext("Failed requests, not counting requests the client cancelled")}
  defp status_option_details("client_cancelled"), do: %{detail: gettext("excl. failure totals"), title: status_description("client_cancelled")}
  defp status_option_details(_status), do: %{}

  def request_status_icon(status), do: request_status_presentation(status).icon

  def request_status_icon_class(status), do: request_status_presentation(status).icon_class

  def request_status_filter_icon_color(status),
    do: request_status_presentation(status).filter_icon_color

  defp request_status_presentation(status),
    do:
      Map.get(
        @request_status_presentations,
        status,
        @default_request_status_presentation
      )

  defp status_filter_label(status) do
    status
    |> blank_to_nil()
    |> case do
      nil -> gettext("Any status")
      status -> status_label(status)
    end
  end

  defp model_filter_label(model) do
    model
    |> blank_to_nil()
    |> case do
      nil -> gettext("Any model")
      model -> model
    end
  end

  defp blank_to_nil(value), do: if(blank?(value), do: nil, else: String.trim(to_string(value)))
  defp blank?(nil), do: true
  defp blank?(value), do: String.trim(to_string(value)) == ""
end
