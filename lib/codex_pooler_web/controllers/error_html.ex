defmodule CodexPoolerWeb.ErrorHTML do
  @moduledoc """
  HTML error renderer for browser requests.
  """
  use CodexPoolerWeb, :html

  @spec render(String.t(), map()) :: String.t()
  def render(template, _assigns) do
    template
    |> Phoenix.Controller.status_message_from_template()
    |> status_message()
  end

  defp status_message("Bad Request"), do: gettext("Bad Request")
  defp status_message("Unauthorized"), do: gettext("Unauthorized")
  defp status_message("Payment Required"), do: gettext("Payment Required")
  defp status_message("Forbidden"), do: gettext("Forbidden")
  defp status_message("Not Found"), do: gettext("Not Found")
  defp status_message("Method Not Allowed"), do: gettext("Method Not Allowed")
  defp status_message("Not Acceptable"), do: gettext("Not Acceptable")
  defp status_message("Proxy Authentication Required"), do: gettext("Proxy Authentication Required")
  defp status_message("Request Timeout"), do: gettext("Request Timeout")
  defp status_message("Conflict"), do: gettext("Conflict")
  defp status_message("Gone"), do: gettext("Gone")
  defp status_message("Length Required"), do: gettext("Length Required")
  defp status_message("Precondition Failed"), do: gettext("Precondition Failed")
  defp status_message("Request Entity Too Large"), do: gettext("Request Entity Too Large")
  defp status_message("Request-URI Too Long"), do: gettext("Request-URI Too Long")
  defp status_message("Unsupported Media Type"), do: gettext("Unsupported Media Type")
  defp status_message("Requested Range Not Satisfiable"), do: gettext("Requested Range Not Satisfiable")
  defp status_message("Expectation Failed"), do: gettext("Expectation Failed")
  defp status_message("I'm a teapot"), do: gettext("I'm a teapot")
  defp status_message("Misdirected Request"), do: gettext("Misdirected Request")
  defp status_message("Unprocessable Content"), do: gettext("Unprocessable Content")
  defp status_message("Locked"), do: gettext("Locked")
  defp status_message("Failed Dependency"), do: gettext("Failed Dependency")
  defp status_message("Too Early"), do: gettext("Too Early")
  defp status_message("Upgrade Required"), do: gettext("Upgrade Required")
  defp status_message("Precondition Required"), do: gettext("Precondition Required")
  defp status_message("Too Many Requests"), do: gettext("Too Many Requests")
  defp status_message("Request Header Fields Too Large"), do: gettext("Request Header Fields Too Large")
  defp status_message("Unavailable For Legal Reasons"), do: gettext("Unavailable For Legal Reasons")
  defp status_message("Internal Server Error"), do: gettext("Internal Server Error")
  defp status_message("Not Implemented"), do: gettext("Not Implemented")
  defp status_message("Bad Gateway"), do: gettext("Bad Gateway")
  defp status_message("Service Unavailable"), do: gettext("Service Unavailable")
  defp status_message("Gateway Timeout"), do: gettext("Gateway Timeout")
  defp status_message("HTTP Version Not Supported"), do: gettext("HTTP Version Not Supported")
  defp status_message("Variant Also Negotiates"), do: gettext("Variant Also Negotiates")
  defp status_message("Insufficient Storage"), do: gettext("Insufficient Storage")
  defp status_message("Loop Detected"), do: gettext("Loop Detected")
  defp status_message("Not Extended"), do: gettext("Not Extended")
  defp status_message("Network Authentication Required"), do: gettext("Network Authentication Required")
  defp status_message(message), do: message
end
