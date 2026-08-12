defmodule CodexPoolerWeb.Ollama.ModelManagementController do
  use CodexPoolerWeb, :controller

  alias CodexPooler.Gateway.Facade
  alias CodexPooler.RouteClass
  alias CodexPoolerWeb.PublicGatewayDispatch

  @fixed_error %{
    status: 400,
    code: "invalid_request",
    message: "gemma3 is a fixed virtual model",
    param: "model"
  }

  @embedding_error %{
    status: 400,
    code: "invalid_request",
    message: "embeddings are not supported by virtual gemma3",
    param: "model"
  }

  def pull(conn, params) do
    authenticated(conn, "/api/pull", fn _auth -> pull_result(params) end)
  end

  def immutable(conn, _params) do
    authenticated(conn, conn.request_path, fn _auth -> {:error, @fixed_error} end)
  end

  def embeddings(conn, _params) do
    authenticated(conn, conn.request_path, fn _auth -> {:error, @embedding_error} end)
  end

  defp pull_result(params) do
    with :ok <- validate_stream(params),
         true <- public_model?(model_name(params)) do
      if Map.get(params, "stream", true) do
        {:ok,
         %{
           status: 200,
           headers: [{"content-type", "application/x-ndjson"}],
           raw_body: Jason.encode!(%{"status" => "success"}) <> "\n"
         }}
      else
        {:ok,
         %{
           status: 200,
           headers: [{"content-type", "application/json"}],
           body: %{"status" => "success"}
         }}
      end
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, @fixed_error}
    end
  end

  defp validate_stream(%{"stream" => value}) when is_boolean(value), do: :ok

  defp validate_stream(%{"stream" => _value}) do
    {:error,
     %{
       status: 400,
       code: "invalid_request",
       message: "stream must be a boolean",
       param: "stream"
     }}
  end

  defp validate_stream(_params), do: :ok

  defp model_name(params), do: Map.get(params, "name") || Map.get(params, "model")

  defp public_model?(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.downcase()
    |> String.replace_suffix(":latest", "")
    |> Kernel.==(Facade.public_model())
  end

  defp public_model?(_name), do: false

  defp authenticated(conn, endpoint, fun) do
    PublicGatewayDispatch.authenticated(
      conn,
      RouteClass.proxy_control(),
      endpoint,
      fun
    )
  end
end
