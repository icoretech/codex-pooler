defmodule CodexPoolerWeb.Admin.RequestLogDetailDrawer.Format do
  @moduledoc false

  use Gettext, backend: CodexPoolerWeb.Gettext

  import CodexPoolerWeb.Admin.RequestLogsDisplay,
    only: [
      format_record_id: 1,
      status_label: 1
    ]

  @spec request_log_title(map() | nil) :: String.t()
  def request_log_title(%{id: id}), do: gettext("Request %{id}", id: format_record_id(id) || id)
  def request_log_title(_log), do: gettext("Request details")

  @spec request_log_subtitle(map() | nil) :: String.t() | nil
  def request_log_subtitle(%{correlation_id: id}) when is_binary(id) and id != "", do: id
  def request_log_subtitle(_log), do: nil

  # A request log carries the status it shows (`display_status`: a client
  # cancellation is recorded `failed`); an attempt shows its own status.
  @spec request_log_status(map() | nil) :: String.t() | nil
  def request_log_status(%{status: status} = log), do: status_label(Map.get(log, :display_status) || status || "unknown")
  def request_log_status(_log), do: nil

  @spec request_log_status_class(map() | nil) :: String.t() | nil
  def request_log_status_class(%{status: status} = log), do: status_chip_class(Map.get(log, :display_status) || status)
  def request_log_status_class(_log), do: nil

  @spec status_chip_class(String.t() | nil) :: String.t()
  def status_chip_class("succeeded"),
    do: "inline-flex items-center rounded-full border border-success/20 bg-success/10 px-2.5 py-1 text-xs font-medium leading-none text-success"

  def status_chip_class("failed"),
    do: "inline-flex items-center rounded-full border border-error/20 bg-error/10 px-2.5 py-1 text-xs font-medium leading-none text-error"

  def status_chip_class("rejected"),
    do: "inline-flex items-center rounded-full border border-error/20 bg-error/10 px-2.5 py-1 text-xs font-medium leading-none text-error"

  def status_chip_class("client_cancelled"),
    do: "inline-flex items-center rounded-full border border-warning/20 bg-warning/10 px-2.5 py-1 text-xs font-medium leading-none text-warning"

  def status_chip_class(status) when status in ["accepted", "in_progress"],
    do: "inline-flex items-center rounded-full border border-info/20 bg-info/10 px-2.5 py-1 text-xs font-medium leading-none text-info"

  def status_chip_class(_status),
    do: "inline-flex items-center rounded-full border border-base-300 bg-base-200 px-2.5 py-1 text-xs font-medium leading-none text-base-content/70"

  @spec safe_text(term()) :: String.t()
  @spec safe_text(term(), String.t()) :: String.t()
  def safe_text(value, fallback \\ "-")
  def safe_text(nil, fallback), do: fallback
  def safe_text("", fallback), do: fallback
  def safe_text(value, _fallback) when is_binary(value), do: value
  def safe_text(value, _fallback) when is_integer(value), do: Integer.to_string(value)

  def safe_text(value, _fallback) when is_float(value),
    do: :erlang.float_to_binary(value, decimals: 2)

  def safe_text(value, _fallback) when is_boolean(value), do: if(value, do: gettext("yes"), else: gettext("no"))
  def safe_text(value, _fallback) when is_atom(value), do: Atom.to_string(value)
  def safe_text(_value, fallback), do: fallback
end
