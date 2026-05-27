defmodule CodexPooler.Gateway.ControlPlaneProxy.Dispatch do
  @moduledoc false

  require Logger

  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.ControlPlaneProxy
  alias CodexPooler.Gateway.ControlPlaneProxy.Metadata
  alias CodexPooler.Gateway.ControlPlaneProxy.Request, as: ProxyRequest
  alias CodexPooler.Gateway.ControlPlaneProxy.RouteLifecycle
  alias CodexPooler.Gateway.Payloads.{RequestOptions, TransportEnvelope}
  alias CodexPooler.Gateway.Routing.RoutingSelection
  alias CodexPooler.Gateway.Transports.TransportFailureReason
  alias CodexPooler.Upstreams.Auth.TokenRefresh
  alias CodexPooler.Upstreams.EndpointMetadata
  alias CodexPooler.Upstreams.Secrets

  @secret_kind "access_token"

  @type dispatch_result ::
          {:ok, Req.Response.t(), non_neg_integer(), map() | nil}
          | {:error, ControlPlaneProxy.gateway_error()}

  @spec run(
          ControlPlaneProxy.auth(),
          ProxyRequest.t(),
          Model.t(),
          RoutingSelection.t(),
          RequestOptions.t()
        ) :: dispatch_result()
  def run(auth, %ProxyRequest{} = request, model, selection, %RequestOptions{} = request_options) do
    case dispatch_once(request, selection, request_options) do
      {:ok, first_response} ->
        if first_response.status == 401 do
          refresh_and_retry(auth, request, model, selection, request_options, first_response)
        else
          RouteLifecycle.record_outcome(auth, model, selection, first_response.status)
          {:ok, first_response, 0, nil}
        end

      {:error, reason} ->
        finalize_dispatch_error(auth, request, model, selection, request_options, 0, nil, reason)
    end
  end

  defp refresh_and_retry(auth, request, model, selection, request_options, first_response) do
    case TokenRefresh.refresh_access_token(selection.identity,
           trigger_kind: "control_plane_proxy_401"
         ) do
      {:ok, %{status: :active, identity: refreshed_identity}} ->
        selection = %{selection | identity: refreshed_identity}
        refresh_metadata = %{"status" => "succeeded"}

        case dispatch_once(request, selection, request_options) do
          {:ok, second_response} ->
            RouteLifecycle.record_outcome(auth, model, selection, second_response.status)
            {:ok, second_response, 1, refresh_metadata}

          {:error, reason} ->
            finalize_dispatch_error(
              auth,
              request,
              model,
              selection,
              request_options,
              1,
              refresh_metadata,
              reason
            )
        end

      {:ok, result} ->
        RouteLifecycle.record_outcome(auth, model, selection, first_response.status)
        {:ok, first_response, 0, %{"status" => to_string(result.status)}}

      {:error, :refresh_in_progress, metadata} ->
        RouteLifecycle.record_outcome(auth, model, selection, first_response.status)
        {:ok, first_response, 0, refresh_in_progress_metadata(metadata)}

      {:error, reason} ->
        RouteLifecycle.record_outcome(auth, model, selection, first_response.status)
        {:ok, first_response, 0, %{"status" => "failed", "reason" => safe_refresh_reason(reason)}}
    end
  end

  defp finalize_dispatch_error(
         auth,
         request,
         model,
         selection,
         request_options,
         retry_count,
         refresh_metadata,
         reason
       ) do
    code = dispatch_error_code(reason)
    RouteLifecycle.record_dispatch_failure(auth, model, selection, code)

    with :ok <-
           Metadata.record_failed_request(
             auth,
             request,
             model,
             selection,
             request_options,
             retry_count,
             refresh_metadata,
             code
           ) do
      {:error, dispatch_error(reason)}
    end
  end

  defp dispatch_once(%ProxyRequest{} = request, selection, request_options) do
    with {:ok, token} <-
           Secrets.decrypt_active_secret(selection.identity, @secret_kind),
         {:ok, url} <- upstream_url(selection, request.upstream_endpoint, request.query_string) do
      outbound_options =
        [
          method: req_method(request.method),
          url: url,
          body: request.body,
          headers: request_headers(selection.identity, token, request, request_options),
          decode_body: false,
          retry: false
        ]
        |> Keyword.merge(TransportEnvelope.req_timeout_options(request_options.timeout_config))

      case Req.request(outbound_options) do
        {:ok, response} ->
          {:ok, response}

        {:error, %Finch.TransportError{} = exception} ->
          control_plane_transport_error(exception, request, selection, request_options)

        {:error, %Req.TransportError{} = exception} ->
          control_plane_transport_error(exception, request, selection, request_options)

        {:error, %Mint.TransportError{} = exception} ->
          control_plane_transport_error(exception, request, selection, request_options)

        {:error, %Mint.HTTPError{} = exception} ->
          control_plane_transport_error(exception, request, selection, request_options)

        {:error, reason} ->
          control_plane_transport_error(reason, request, selection, request_options)
      end
    end
  rescue
    exception in [Req.TransportError, Finch.TransportError, Mint.TransportError, Mint.HTTPError] ->
      control_plane_transport_error(exception, request, selection, request_options)
  end

  defp upstream_url(selection, endpoint, query_string) do
    case EndpointMetadata.endpoint_url(selection.identity, selection.assignment, endpoint) do
      {:ok, url} -> {:ok, append_query_string(url, query_string)}
      {:error, :invalid_upstream_base_url} -> {:error, :invalid_upstream_base_url}
    end
  end

  defp append_query_string(url, query_string) when is_binary(query_string) and query_string != "",
    do: url <> "?" <> query_string

  defp append_query_string(url, _query_string), do: url

  defp request_headers(
         identity,
         token,
         %ProxyRequest{} = request,
         %RequestOptions{} = request_options
       ) do
    source_headers = request.request_headers
    content_type = upstream_content_type(request)
    accept = upstream_accept(source_headers, request)
    request_id = request_options.request_metadata.request_id

    base_headers = [{"accept-encoding", "identity"}, {"accept", accept}]

    base_headers =
      if content_type, do: [{"content-type", content_type} | base_headers], else: base_headers

    base_headers =
      if request_id,
        do: [{"x-request-id", request_id}, {"request-id", request_id} | base_headers],
        else: base_headers

    TransportEnvelope.headers(identity, token, base_headers, include_user_agent?: true)
  end

  defp upstream_content_type(%ProxyRequest{body_mode: {:json, _route}}), do: "application/json"
  defp upstream_content_type(%ProxyRequest{body_mode: :sdp}), do: "application/sdp"
  defp upstream_content_type(_request), do: nil

  defp upstream_accept(source_headers, %ProxyRequest{body_mode: :sdp}),
    do: accepted_source_accept(source_headers, "*/*")

  defp upstream_accept(source_headers, _request),
    do: accepted_source_accept(source_headers, "application/json")

  defp accepted_source_accept(source_headers, fallback) do
    case header_value(source_headers, "accept") do
      value when is_binary(value) and value in ["application/json", "text/event-stream", "*/*"] ->
        value

      _value ->
        fallback
    end
  end

  defp header_value(headers, key) do
    headers
    |> Enum.find_value(fn {name, value} ->
      if String.downcase(to_string(name)) == key, do: value
    end)
  end

  defp req_method(method) when is_binary(method),
    do: method |> String.downcase() |> String.to_existing_atom()

  defp safe_refresh_reason(%{code: code}), do: to_string(code)

  defp refresh_in_progress_metadata(metadata) when is_map(metadata) do
    %{"status" => "refresh_in_progress"}
    |> maybe_put_safe_metadata("attempt_id", metadata[:attempt_id])
    |> maybe_put_safe_metadata("generation", metadata[:generation])
    |> maybe_put_safe_metadata("started_at", metadata[:started_at])
    |> maybe_put_safe_metadata("stale_after_ms", metadata[:stale_after_ms])
  end

  defp maybe_put_safe_metadata(attrs, key, value) when is_binary(value) or is_integer(value),
    do: Map.put(attrs, key, value)

  defp maybe_put_safe_metadata(attrs, _key, _value), do: attrs

  defp dispatch_error(%{status: status, code: code, message: message} = reason) do
    error(status, to_string(code), message, Map.get(reason, :param))
  end

  defp dispatch_error(%{code: code, message: message}) do
    error(502, to_string(code), message)
  end

  defp dispatch_error(:invalid_upstream_base_url) do
    error(502, "invalid_upstream_base_url", "upstream request failed")
  end

  defp dispatch_error_code(%{code: code}), do: to_string(code)
  defp dispatch_error_code(:invalid_upstream_base_url), do: "invalid_upstream_base_url"

  defp control_plane_transport_error(exception, request, selection, request_options) do
    log_control_plane_transport_failure(exception, request, selection, request_options)
    {:error, control_plane_network_error()}
  end

  defp control_plane_network_error do
    error(502, "upstream_network_error", "upstream request failed")
  end

  defp log_control_plane_transport_failure(exception, request, selection, request_options) do
    Logger.warning(fn ->
      metadata =
        exception
        |> control_plane_transport_failure_metadata(request, selection, request_options)
        |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{value}" end)

      "control-plane upstream transport failed #{metadata}"
    end)
  end

  defp control_plane_transport_failure_metadata(
         exception,
         %ProxyRequest{} = request,
         selection,
         %RequestOptions{} = request_options
       ) do
    [
      endpoint: safe_log_value(request.upstream_endpoint),
      local_endpoint: safe_log_value(request.local_endpoint),
      request_id: safe_log_value(request_options.request_metadata.request_id),
      exception: exception |> TransportFailureReason.safe_exception() |> safe_log_value(),
      reason: exception |> TransportFailureReason.safe_reason() |> safe_log_value(),
      upstream_identity_id: safe_log_value(selection.identity.id),
      pool_upstream_assignment_id: safe_log_value(selection.assignment.id),
      route_class: safe_log_value(selection.route_class),
      routing_strategy:
        safe_log_value(
          selection.route_metadata["routing_strategy"] ||
            routing_metadata(selection)["routing_strategy"]
        )
    ]
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
  end

  defp routing_metadata(selection), do: Map.get(selection.route_metadata, "routing", %{})

  defp safe_log_value(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_log_value(value) when is_binary(value), do: value
  defp safe_log_value(value) when is_integer(value), do: Integer.to_string(value)
  defp safe_log_value(_value), do: nil

  defp error(status, code, message, param \\ nil) do
    %{status: status, code: code, message: message, param: param}
  end
end
