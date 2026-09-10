defmodule CodexPoolerWeb.Operations.MetricsController do
  use CodexPoolerWeb, :controller

  alias CodexPooler.InstanceSettings
  alias CodexPooler.Metrics.AccountSnapshot

  def show(conn, _params) do
    case authorize_metrics(conn) do
      :ok ->
        conn
        |> put_resp_content_type("text/plain; version=0.0.4")
        |> send_resp(200, [
          TelemetryMetricsPrometheus.Core.scrape(),
          "\n",
          AccountSnapshot.scrape()
        ])

      {:error, reason} ->
        conn
        |> put_status(401)
        |> json(%{"error" => %{"code" => "metrics_unauthorized", "message" => reason}})
    end
  end

  defp authorize_metrics(conn) do
    settings = InstanceSettings.current()

    case settings.metrics.bearer_token_status do
      :intentionally_unset ->
        :ok

      :configured ->
        with {:ok, token} <- bearer_token(conn),
             true <- InstanceSettings.metrics_token_matches?(settings, token) do
          :ok
        else
          _mismatch -> {:error, "metrics bearer token is required"}
        end

      :unavailable ->
        {:error, "metrics bearer token is unavailable"}
    end
  end

  defp bearer_token(conn) do
    case List.first(get_req_header(conn, "authorization")) do
      "Bearer " <> token ->
        token = String.trim(token)

        if token == "" do
          {:error, :missing_bearer}
        else
          {:ok, token}
        end

      _value ->
        {:error, :missing_bearer}
    end
  end
end
