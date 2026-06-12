defmodule CodexPooler.Gateway.Transports.FileBridge do
  @moduledoc false

  require Logger

  alias CodexPooler.Gateway.OpenAICompatibility.Error
  alias CodexPooler.Gateway.Payloads.{RequestOptions, TransportEnvelope}
  alias CodexPooler.Gateway.Routing.RoutingSelection
  alias CodexPooler.Gateway.Transports.TransportFailureReason
  alias CodexPooler.Upstreams.EndpointMetadata
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}
  alias CodexPooler.Upstreams.Secrets

  @secret_kind "access_token"
  @timeout_defaults %{
    connect_timeout_ms: :timer.seconds(15),
    pool_timeout_ms: :timer.seconds(15),
    receive_timeout_ms: :timer.seconds(30)
  }
  @finalize_retry_timeout_ms :timer.seconds(30)
  @finalize_retry_interval_ms 250
  @upload_req_option_allowlist [:adapter, :plug]
  @upload_request_step_denylist [:put_user_agent]

  @type auth :: CodexPooler.Access.auth_context()
  @type payload :: map()
  @type bridge_opts :: RequestOptions.t() | map() | keyword()
  @type safe_error :: %{
          required(:status) => pos_integer(),
          required(:code) => atom(),
          required(:message) => String.t(),
          required(:param) => nil,
          required(:upstream) => map()
        }
  @type bridge_success :: %{
          required(:body) => map() | nil,
          required(:assignment) => PoolUpstreamAssignment.t(),
          required(:identity) => UpstreamIdentity.t(),
          required(:route_metadata) => map()
        }
  @type bridge_result ::
          {:ok, bridge_success()}
          | {:retry_timeout, bridge_success()}
          | {:error, safe_error() | term()}

  defguardp transport_exception?(exception)
            when is_struct(exception, Finch.TransportError) or
                   is_struct(exception, Req.TransportError) or
                   is_struct(exception, Req.HTTPError) or
                   is_struct(exception, Mint.TransportError) or
                   is_struct(exception, Mint.HTTPError) or
                   is_struct(exception, Finch.HTTPError)

  @spec create_file(payload(), bridge_opts(), RoutingSelection.t()) :: bridge_result()
  def create_file(payload, opts, %RoutingSelection{} = selection) when is_map(payload) do
    endpoint = "/backend-api/files"
    request_options = RequestOptions.for_file_bridge(opts, endpoint, payload)

    create_file_with_selection(payload, request_options, selection)
  end

  @spec upload_file(String.t(), map(), bridge_opts()) :: :ok | {:error, map()}
  def upload_file(upload_url, file, opts \\ %{})

  def upload_file(upload_url, %{"path" => path, "content_type" => content_type}, opts)
      when is_binary(upload_url) do
    with {:ok, body} <- readable_file_stream(path) do
      upload_url
      |> upload_request()
      |> Req.put(upload_req_options(body, content_type))
      |> normalize_upload_response(opts)
    end
  rescue
    exception in [
      Req.TransportError,
      Req.HTTPError,
      Finch.TransportError,
      Finch.HTTPError,
      Mint.TransportError,
      Mint.HTTPError
    ] ->
      normalize_upload_response({:error, exception}, opts)
  end

  def upload_file(_upload_url, _file, _opts) do
    {:error, Error.reason(400, "invalid_request", "file upload is not readable", "file")}
  end

  defp create_file_with_selection(payload, opts, %RoutingSelection{} = selection) do
    with {:ok, target} <- selected_file_bridge_target(selection, "/backend-api/files"),
         request_opts = file_bridge_request_opts(opts, :create, "/backend-api/files", selection),
         {:ok, response} <-
           post_json(target.url, target.identity, target.token, payload, request_opts),
         {:ok, body} <- json_success(response, :create) do
      {:ok,
       %{
         body: body,
         assignment: target.assignment,
         identity: target.identity,
         route_metadata: selection.route_metadata
       }}
    end
  end

  @spec finalize_file(String.t(), bridge_opts(), RoutingSelection.t()) ::
          bridge_result()
  def finalize_file(file_id, opts, %RoutingSelection{} = selection) when is_binary(file_id) do
    endpoint = "/backend-api/files/uploaded"
    request_options = RequestOptions.for_file_bridge(opts, endpoint, %{})

    with {:ok, target} <-
           selected_file_bridge_target(selection, "/backend-api/files/#{file_id}/uploaded") do
      request_options = file_bridge_request_opts(request_options, :finalize, endpoint, selection)

      poll_finalize(
        target.url,
        target.identity,
        target.token,
        retry_options(request_options),
        nil
      )
      |> attach_route_selection(selection)
    end
  end

  defp poll_finalize(url, identity, token, %{deadline: deadline} = retry_opts, last_retry) do
    if retry_budget_exhausted?(deadline, last_retry) do
      {:retry_timeout, last_retry}
    else
      dispatch_finalize_poll(url, identity, token, retry_opts)
    end
  end

  defp dispatch_finalize_poll(url, identity, token, retry_opts) do
    with {:ok, response} <- post_json(url, identity, token, %{}, retry_opts.opts),
         {:ok, body} <- json_success(response, :finalize) do
      handle_finalize_body(body, url, identity, token, retry_opts)
    end
  end

  defp handle_finalize_body(body, url, identity, token, retry_opts) do
    if retry_status?(body) do
      sleep_until_next_retry(retry_opts)
      poll_finalize(url, identity, token, retry_opts, body)
    else
      {:ok, body}
    end
  end

  defp retry_status?(%{"status" => status}) when is_binary(status),
    do: String.downcase(status) == "retry"

  defp retry_status?(_body), do: false

  defp selected_file_bridge_target(%RoutingSelection{} = selection, endpoint) do
    assignment = selection.assignment
    identity = selection.identity

    with {:ok, token} <-
           Secrets.decrypt_active_secret(identity, @secret_kind),
         {:ok, url} <- endpoint_url(identity, assignment, endpoint) do
      {:ok, %{assignment: assignment, identity: identity, token: token, url: url}}
    end
  end

  defp attach_route_selection({:ok, body}, %RoutingSelection{} = selection) do
    {:ok,
     %{
       body: body,
       assignment: selection.assignment,
       identity: selection.identity,
       route_metadata: selection.route_metadata
     }}
  end

  defp attach_route_selection({:retry_timeout, body}, %RoutingSelection{} = selection) do
    {:retry_timeout,
     %{
       body: body,
       assignment: selection.assignment,
       identity: selection.identity,
       route_metadata: selection.route_metadata
     }}
  end

  defp attach_route_selection(
         {:error, %{upstream: upstream} = error},
         %RoutingSelection{} = selection
       )
       when is_map(upstream) do
    {:error, %{error | upstream: Map.merge(upstream, selection.route_metadata)}}
  end

  defp attach_route_selection(result, _selection), do: result

  defp endpoint_url(identity, assignment, endpoint) do
    case EndpointMetadata.endpoint_url(identity, assignment, endpoint) do
      {:ok, url} ->
        {:ok, url}

      {:error, :invalid_upstream_base_url} ->
        {:error,
         safe_error(502, :invalid_upstream_base_url, "upstream file bridge is misconfigured")}
    end
  end

  defp post_json(url, identity, token, payload, opts) do
    timeouts = TransportEnvelope.timeout_config(opts, @timeout_defaults)

    request_options =
      [
        json: payload,
        retry: false,
        headers: headers(identity, token, forwarded_headers(opts))
      ]
      |> Keyword.merge(TransportEnvelope.req_timeout_options(timeouts))

    url
    |> Req.post(request_options)
    |> normalize_transport_result(identity, opts)
  rescue
    exception in [
      Req.TransportError,
      Req.HTTPError,
      Finch.TransportError,
      Finch.HTTPError,
      Mint.TransportError,
      Mint.HTTPError
    ] ->
      log_transport_exception(exception, identity, opts)
      {:error, safe_error(502, :upstream_request_failed, "upstream file bridge request failed")}
  end

  defp normalize_transport_result({:error, exception}, identity, opts)
       when transport_exception?(exception) do
    log_transport_exception(exception, identity, opts)
    {:error, safe_error(502, :upstream_request_failed, "upstream file bridge request failed")}
  end

  defp normalize_transport_result(result, _identity, _opts), do: result

  # Path is the Plug.Upload tempfile, validated to resolve under the system temp dir.
  # sobelow_skip ["Traversal.FileModule"]
  defp readable_file_stream(path) when is_binary(path) do
    with {:ok, path} <- validate_upload_temp_path(path) do
      open_file_stream(path)
    end
  end

  defp readable_file_stream(_path) do
    {:error, Error.reason(400, "invalid_request", "file upload is not readable", "file")}
  end

  defp validate_upload_temp_path(path) do
    expanded_path = Path.expand(path)
    temp_dir = Path.expand(System.tmp_dir!())

    if path_within?(expanded_path, temp_dir) do
      {:ok, expanded_path}
    else
      {:error, Error.reason(400, "invalid_request", "file upload is not readable", "file")}
    end
  end

  defp path_within?(path, root) do
    path == root or String.starts_with?(path, root <> "/")
  end

  defp upload_req_options(body, content_type) do
    configured_upload_req_options()
    |> Keyword.merge(
      body: body,
      headers: [
        {"content-type", content_type || "application/octet-stream"},
        {"x-ms-blob-type", "BlockBlob"}
      ],
      redirect: false,
      retry: false
    )
  end

  @spec upload_request(String.t()) :: Req.Request.t()
  defp upload_request(upload_url) do
    [url: upload_url]
    |> Req.new()
    |> without_request_steps(@upload_request_step_denylist)
  end

  @spec without_request_steps(Req.Request.t(), [atom()]) :: Req.Request.t()
  defp without_request_steps(%Req.Request{} = request, step_names) when is_list(step_names) do
    %{
      request
      | request_steps: Keyword.drop(request.request_steps, step_names),
        current_request_steps:
          Enum.reject(request.current_request_steps, fn step_name -> step_name in step_names end)
    }
  end

  defp configured_upload_req_options do
    case Keyword.get(config(), :upload_req_options, []) do
      opts when is_list(opts) -> Keyword.take(opts, @upload_req_option_allowlist)
      _opts -> []
    end
  end

  # Caller validates the resolved Plug.Upload path before opening it.
  # sobelow_skip ["Traversal.FileModule"]
  defp open_file_stream(path) do
    case File.open(path, [:read]) do
      {:ok, file} ->
        File.close(file)
        {:ok, File.stream!(path, 2048, [])}

      {:error, _reason} ->
        {:error, Error.reason(400, "invalid_request", "file upload is not readable", "file")}
    end
  rescue
    _exception in [File.Error, ErlangError] ->
      {:error, Error.reason(400, "invalid_request", "file upload is not readable", "file")}
  end

  defp normalize_upload_response(result, opts) do
    case result do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status}} ->
        {:error,
         Error.reason(
           502,
           "upstream_file_upload_failed",
           "upstream file upload failed with status #{status}"
         )}

      {:error, exception} when transport_exception?(exception) ->
        upload_transport_error(exception, opts)

      {:error, _reason} ->
        {:error, Error.reason(502, "upstream_file_upload_failed", "upstream file upload failed")}
    end
  end

  defp upload_transport_error(exception, opts) do
    log_transport_exception(exception, nil, opts)
    {:error, Error.reason(502, "upstream_file_upload_failed", "upstream file upload failed")}
  end

  defp file_bridge_request_opts(
         %RequestOptions{} = request_options,
         operation,
         endpoint,
         %RoutingSelection{} = selection
       ) do
    RequestOptions.put_file_bridge(request_options,
      operation: operation,
      endpoint: endpoint,
      pool_upstream_assignment_id: selection.assignment.id,
      upstream_identity_id: selection.identity.id,
      route_metadata: safe_route_metadata(selection.route_metadata)
    )
  end

  defp safe_route_metadata(metadata) do
    Map.take(metadata, [
      :route_class,
      :routing_strategy,
      :routing_candidate_count,
      "route_class",
      "routing_strategy",
      "routing_candidate_count"
    ])
  end

  defp log_transport_exception(exception, identity, opts) do
    Logger.warning(fn ->
      metadata =
        opts
        |> transport_exception_metadata(exception, identity)
        |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{value}" end)

      "file bridge transport failed #{metadata}"
    end)
  end

  defp transport_exception_metadata(%RequestOptions{} = request_options, exception, identity) do
    file_bridge = request_options.file_bridge
    route_metadata = file_bridge.route_metadata || %{}

    [
      operation: safe_log_value(file_bridge.operation),
      endpoint: safe_log_value(file_bridge.endpoint),
      request_id: safe_log_value(request_options.request_metadata.request_id),
      exception: exception |> TransportFailureReason.safe_exception() |> safe_log_value(),
      reason: exception |> TransportFailureReason.safe_reason() |> safe_log_value(),
      pool_upstream_assignment_id: safe_log_value(file_bridge.pool_upstream_assignment_id),
      upstream_identity_id:
        safe_log_value(file_bridge.upstream_identity_id || identity_id(identity)),
      route_class: safe_log_value(route_metadata[:route_class] || route_metadata["route_class"]),
      routing_strategy:
        safe_log_value(route_metadata[:routing_strategy] || route_metadata["routing_strategy"])
    ]
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
  end

  defp transport_exception_metadata(_opts, exception, identity) do
    [
      exception: exception |> TransportFailureReason.safe_exception() |> safe_log_value(),
      reason: exception |> TransportFailureReason.safe_reason() |> safe_log_value(),
      upstream_identity_id: identity |> identity_id() |> safe_log_value()
    ]
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
  end

  defp identity_id(%{id: id}), do: id
  defp identity_id(_identity), do: nil

  defp safe_log_value(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_log_value(value) when is_binary(value), do: value
  defp safe_log_value(value) when is_integer(value), do: Integer.to_string(value)
  defp safe_log_value(_value), do: nil

  defp headers(identity, token, forwarded_headers) do
    TransportEnvelope.headers(
      identity,
      token,
      [{"accept", "application/json"}, {"content-type", "application/json"}],
      include_user_agent?: true,
      forwarded_headers: forwarded_headers
    )
  end

  defp forwarded_headers(%RequestOptions{} = request_options),
    do: request_options.file_bridge.forwarded_headers

  defp json_success(%Req.Response{status: status, body: body}, _operation)
       when status in 200..299 and is_map(body), do: {:ok, body}

  defp json_success(%Req.Response{status: status, body: body}, operation)
       when status in 200..299 do
    {:error,
     safe_error(
       502,
       :upstream_file_bridge_invalid_response,
       "upstream file #{operation} returned invalid JSON",
       response_status: status,
       response_body_bytes: response_body_size(body)
     )}
  end

  defp json_success(%Req.Response{status: status}, operation) do
    {:error,
     safe_error(status, :upstream_file_bridge_failed, "upstream file #{operation} failed")}
  end

  defp retry_options(opts) do
    config = config()
    file_bridge = opts.file_bridge

    timeout_ms =
      (file_bridge.finalize_retry_timeout_ms ||
         Keyword.get(config, :finalize_retry_timeout_ms, @finalize_retry_timeout_ms))
      |> max(0)

    interval_ms =
      (file_bridge.finalize_retry_interval_ms ||
         Keyword.get(config, :finalize_retry_interval_ms, @finalize_retry_interval_ms))
      |> max(0)

    %{
      deadline: System.monotonic_time(:millisecond) + timeout_ms,
      interval_ms: interval_ms,
      opts: opts
    }
  end

  defp retry_budget_exhausted?(_deadline, nil), do: false

  defp retry_budget_exhausted?(deadline, _last_retry),
    do: System.monotonic_time(:millisecond) >= deadline

  defp sleep_until_next_retry(%{interval_ms: 0}), do: :ok

  defp sleep_until_next_retry(%{deadline: deadline, interval_ms: interval_ms}) do
    remaining_ms = deadline - System.monotonic_time(:millisecond)

    if remaining_ms > 0 do
      Process.sleep(min(interval_ms, remaining_ms))
    end
  end

  defp config, do: Application.get_env(:codex_pooler, __MODULE__, [])

  defp safe_error(status, code, message, extra \\ []) do
    %{status: status, code: code, message: message, param: nil, upstream: Map.new(extra)}
  end

  defp response_body_size(body) when is_binary(body), do: byte_size(body)
  defp response_body_size(_body), do: nil
end
