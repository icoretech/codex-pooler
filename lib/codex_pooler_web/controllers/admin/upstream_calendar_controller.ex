defmodule CodexPoolerWeb.Admin.UpstreamCalendarController do
  use CodexPoolerWeb, :controller

  alias CodexPooler.Upstreams
  alias CodexPoolerWeb.Admin.SavedResetCalendar

  @spec download(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def download(conn, %{"id" => identity_id}) do
    conn = put_resp_header(conn, "cache-control", "private, no-store")

    case Upstreams.get_visible_upstream_identity(conn.assigns.current_scope, identity_id) do
      nil ->
        conn |> put_status(:not_found) |> text("Not found")

      identity ->
        upstream_url = url(~p"/admin/upstreams/#{identity.id}")

        case SavedResetCalendar.build(identity, upstream_url) do
          {:ok, calendar} ->
            send_download(conn, {:binary, calendar},
              filename: "banked-reset-expirations-#{String.slice(identity.id, 0, 8)}.ics",
              content_type: "text/calendar",
              charset: "utf-8"
            )

          {:error, :no_upcoming_expirations} ->
            conn |> put_status(:not_found) |> text("No upcoming banked reset expirations are available for this upstream.")
        end
    end
  end
end
