defmodule CodexPoolerWeb.V1.FilesController do
  use CodexPoolerWeb, :controller

  alias CodexPooler.Files
  alias CodexPooler.Gateway
  alias CodexPooler.Gateway.OpenAICompatibility.Files, as: FilesAdapter
  alias CodexPooler.Gateway.Payloads.{FileRequestMetadata, RequestOptions}
  alias CodexPooler.RouteClass
  alias CodexPoolerWeb.GatewayControllerHelpers, as: GatewayHelpers
  alias CodexPoolerWeb.PublicGatewayDispatch

  @unsupported_content %{
    status: 404,
    code: "unsupported_endpoint",
    message: "Unsupported OpenAI /v1 endpoint",
    param: nil
  }

  def index(conn, _params) do
    with_authenticated_file_admission(conn, "/v1/files", fn auth ->
      with {:ok, %{files: files}} <-
             Files.list_files(
               auth,
               conn |> request_options("/v1/files") |> file_request_metadata()
             ) do
        {:ok,
         %{
           status: 200,
           headers: [],
           body: %{"object" => "list", "data" => Enum.map(files, &Files.response_shape/1), "has_more" => false}
         }}
      end
    end)
  end

  def create(conn, params) do
    with_authenticated_file_admission(conn, "/v1/files", fn auth ->
      with {:ok, validated} <- FilesAdapter.validate_create(params),
           {:ok, result} <-
             Gateway.create_v1_file(auth, validated, request_options(conn, "/v1/files")) do
        {:ok, %{status: 200, headers: [], body: Files.response_shape(result.file)}}
      end
    end)
  end

  def show(conn, %{"file_id" => file_id}) do
    with_authenticated_file_admission(conn, "/v1/files", fn auth ->
      with {:ok, %{file: file}} <-
             Files.retrieve_file(
               auth,
               file_id,
               conn |> request_options("/v1/files") |> file_request_metadata()
             ) do
        {:ok, %{status: 200, headers: [], body: Files.response_shape(file)}}
      end
    end)
  end

  def content(conn, %{"file_id" => file_id}) do
    with_authenticated_file_admission(conn, "/v1/files/content", fn auth ->
      with {:ok, _request} <-
             Files.record_unsupported_operation(
               auth,
               file_id,
               "content",
               conn
               |> request_options("/v1/files/content")
               |> file_request_metadata()
             ) do
        {:error, @unsupported_content}
      end
    end)
  end

  def delete(conn, %{"file_id" => file_id}) do
    with_authenticated_file_admission(conn, "/v1/files/delete", fn auth ->
      with {:ok, _request} <-
             Files.record_unsupported_operation(
               auth,
               file_id,
               "delete",
               conn
               |> request_options("/v1/files/delete")
               |> file_request_metadata()
             ) do
        {:error, @unsupported_content}
      end
    end)
  end

  defp with_authenticated_file_admission(conn, endpoint, fun) when is_function(fun, 1) do
    PublicGatewayDispatch.authenticated(conn, RouteClass.file_upload(), endpoint, fun)
  end

  defp file_request_metadata(%RequestOptions{} = request_options),
    do: FileRequestMetadata.from_request_options(request_options)

  defp request_options(conn, endpoint) do
    conn
    |> GatewayHelpers.request_opts()
    |> RequestOptions.from_conn_metadata(endpoint, %{})
    |> RequestOptions.put_transport(transport: "http_multipart")
  end
end
