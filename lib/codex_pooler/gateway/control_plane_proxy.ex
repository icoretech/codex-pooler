defmodule CodexPooler.Gateway.ControlPlaneProxy do
  @moduledoc false

  alias CodexPooler.Access
  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.ControlPlaneProxy.{Dispatch, Metadata, RouteLifecycle}
  alias CodexPooler.Gateway.Payloads.RequestOptions

  @response_header_allowlist ~w(cache-control content-type etag last-modified location openai-processing-ms request-id x-request-id)

  @type auth :: Access.auth_context()
  @type gateway_error :: Contracts.gateway_error()

  defmodule Request do
    @moduledoc false

    defstruct [
      :local_endpoint,
      :upstream_endpoint,
      :method,
      :query_string,
      :body,
      :body_mode,
      :request_headers,
      :request_opts
    ]

    @type body_mode :: :no_body | :sdp | {:json, atom()}
    @type t :: %__MODULE__{
            local_endpoint: String.t(),
            upstream_endpoint: String.t(),
            method: String.t(),
            query_string: String.t(),
            body: binary(),
            body_mode: body_mode(),
            request_headers: [{String.t(), String.t()}],
            request_opts: map()
          }

    @spec new(map() | keyword()) :: t()
    def new(attrs) do
      attrs = Map.new(attrs)

      %__MODULE__{
        local_endpoint: Map.fetch!(attrs, :local_endpoint),
        upstream_endpoint: Map.fetch!(attrs, :upstream_endpoint),
        method: Map.fetch!(attrs, :method),
        query_string: Map.get(attrs, :query_string, ""),
        body: Map.get(attrs, :body, ""),
        body_mode: Map.get(attrs, :body_mode, :no_body),
        request_headers: Map.get(attrs, :request_headers, []),
        request_opts: attrs |> Map.get(:request_opts, %{}) |> Map.new()
      }
    end
  end

  alias __MODULE__.Request, as: ProxyRequest

  @spec build_request!(map() | keyword()) :: ProxyRequest.t()
  def build_request!(attrs), do: ProxyRequest.new(attrs)

  @spec execute(auth(), ProxyRequest.t()) :: {:ok, map()} | {:error, gateway_error()}
  @spec execute(auth(), ProxyRequest.t(), keyword()) :: {:ok, map()} | {:error, gateway_error()}
  def execute(auth, request, opts \\ [])

  def execute(auth, %ProxyRequest{} = request, opts) when is_list(opts) do
    body = request.body

    request_options =
      request.request_opts
      |> Map.merge(%{
        request_bytes: byte_size(body),
        upstream_endpoint: request.upstream_endpoint,
        transport: "http_json"
      })
      |> RequestOptions.build(request.local_endpoint, %{})

    with {:ok, model, selection, request_options} <-
           RouteLifecycle.select_and_begin_route(
             auth,
             request.local_endpoint,
             request_options,
             Keyword.get(opts, :routing_settings)
           ),
         {:ok, response, retry_count, refresh_metadata} <-
           Dispatch.run(auth, request, model, selection, request_options) do
      with :ok <-
             Metadata.record_request(
               auth,
               request,
               model,
               selection,
               request_options,
               response,
               retry_count,
               refresh_metadata
             ) do
        {:ok,
         %{
           status: response.status,
           headers: allowlisted_response_headers(response),
           raw_body: response_body(response)
         }}
      end
    end
  end

  @spec record_disabled_analytics(auth(), ProxyRequest.t()) ::
          {:ok, map()} | {:error, gateway_error()}
  def record_disabled_analytics(auth, %ProxyRequest{} = request) do
    Metadata.record_disabled_analytics(auth, request)
  end

  defp allowlisted_response_headers(%Req.Response{headers: headers}) do
    headers
    |> Enum.flat_map(&allowlisted_response_header/1)
  end

  defp allowlisted_response_header({name, values}) do
    name = String.downcase(to_string(name))

    if name in @response_header_allowlist do
      values
      |> List.wrap()
      |> Enum.map(&{name, to_string(&1)})
    else
      []
    end
  end

  defp response_body(%Req.Response{body: body}) when is_binary(body), do: body
  defp response_body(_response), do: ""
end
