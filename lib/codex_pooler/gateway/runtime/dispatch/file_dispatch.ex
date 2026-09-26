defmodule CodexPooler.Gateway.Runtime.Dispatch.FileDispatch do
  @moduledoc """
  Gateway-owned orchestration for upstream-backed backend file routes.

  `CodexPooler.Files` owns validation and metadata persistence. This module owns
  the call into gateway transports so the dependency direction stays one-way.
  """

  alias CodexPooler.Files
  alias CodexPooler.Files.FileRecord
  alias CodexPooler.Gateway.Payloads.{FileRequestMetadata, RequestOptions}
  alias CodexPooler.Gateway.Routing.FileSelection
  alias CodexPooler.RouteClass

  alias CodexPooler.Gateway.Routing.{RouteLifecycle, RoutingSelection}

  alias CodexPooler.Gateway.Transports.FileBridge

  @type file_result :: Files.file_result()
  @type request_opts :: RequestOptions.t()

  @spec create_upstream_file(CodexPooler.Access.auth_context(), map(), request_opts()) ::
          file_result()
  def create_upstream_file(
        %{pool: _pool, api_key: _api_key} = auth,
        params,
        %RequestOptions{} = opts
      )
      when is_map(params) do
    create_pending_file_via_bridge(auth, params, opts, :backend)
  end

  def create_upstream_file(_auth, _params, _opts),
    do: {:error, invalid_auth_error()}

  @spec create_v1_file(
          CodexPooler.Access.auth_context(),
          %{required(:purpose) => String.t(), required(:file) => map()},
          request_opts()
        ) :: file_result()
  def create_v1_file(
        %{pool: _pool, api_key: _api_key} = auth,
        %{purpose: public_purpose, file: file},
        %RequestOptions{} = opts
      )
      when is_binary(public_purpose) and is_map(file) do
    request_options = public_v1_file_request_options(opts, "/v1/files", %{})
    create_payload = v1_create_payload(file)

    with {:ok, create_result} <-
           create_pending_v1_file(
             auth,
             create_payload,
             public_purpose,
             defer_create_request(request_options)
           ),
         :ok <-
           upload_v1_file(
             auth,
             create_result.file,
             create_result.upload_target,
             file,
             request_options
           ) do
      mark_uploaded(auth, create_result.file.file_id, fresh_request_options(request_options))
    end
  end

  def create_v1_file(_auth, _params, _opts),
    do: {:error, invalid_auth_error()}

  defp create_pending_v1_file(auth, params, public_purpose, opts) do
    create_pending_file_via_bridge(auth, params, opts, {:v1, public_purpose})
  end

  defp create_pending_file_via_bridge(auth, params, opts, create_context) do
    with {:ok, create_attrs} <- Files.create_params(params),
         payload = create_file_payload(create_attrs),
         {request_options, bridge_request_options, pending_attrs} <-
           create_file_request_context(opts, payload, create_attrs, create_context),
         {:ok, %RoutingSelection{} = selection} <-
           FileSelection.select(auth, payload, bridge_request_options, "/backend-api/files"),
         {:ok, bridge_result} <-
           payload
           |> FileBridge.create_file(bridge_request_options, selection)
           |> complete_file_bridge_result(auth, bridge_request_options, selection),
         {:ok, upload_target} <- prepare_upload_target(bridge_result, create_context),
         {:ok, result} <-
           Files.create_pending_record_from_bridge_result(
             auth,
             pending_attrs,
             bridge_result,
             FileRequestMetadata.from_request_options(request_options)
           ) do
      {:ok, Map.put(result, :upload_target, upload_target)}
    else
      {:error, %{upstream: _upstream} = bridge_error} ->
        Files.record_create_bridge_failure(
          auth,
          bridge_error,
          failed_create_metadata(opts, create_context)
        )

      {:error, %{status: _status} = validation_error} ->
        {:error, validation_error}

      error ->
        error
    end
  end

  defp prepare_upload_target(%{body: body}, {:v1, _purpose}), do: FileBridge.prepare_upload(Map.get(body, "upload_url"))
  defp prepare_upload_target(_bridge_result, :backend), do: {:ok, nil}

  defp create_file_payload(%{file_name: file_name, file_size: file_size, use_case: use_case}) do
    %{"file_name" => file_name, "file_size" => file_size, "use_case" => use_case}
  end

  defp create_file_request_context(opts, payload, create_attrs, :backend) do
    request_options = RequestOptions.for_file_bridge(opts, "/backend-api/files", payload)
    {request_options, request_options, create_attrs}
  end

  defp create_file_request_context(opts, payload, create_attrs, {:v1, public_purpose}) do
    request_options = public_v1_file_request_options(opts, "/v1/files", payload)

    bridge_request_options =
      backend_file_bridge_request_options(request_options, "/backend-api/files", payload)

    {request_options, bridge_request_options, %{create_attrs | use_case: public_purpose}}
  end

  defp failed_create_metadata(opts, :backend) do
    opts
    |> RequestOptions.for_file_bridge("/backend-api/files", %{})
    |> FileRequestMetadata.from_request_options()
  end

  defp failed_create_metadata(opts, {:v1, _public_purpose}) do
    opts
    |> RequestOptions.for_file_bridge("/v1/files", %{}, route_class: RouteClass.file_upload())
    |> FileRequestMetadata.from_request_options()
  end

  @spec mark_uploaded(CodexPooler.Access.auth_context(), String.t(), request_opts()) ::
          file_result()
  def mark_uploaded(%{pool: _pool, api_key: _api_key} = auth, file_id, %RequestOptions{} = opts)
      when is_binary(file_id) do
    request_options = RequestOptions.for_payload(opts, "/backend-api/files/uploaded", %{})

    bridge_request_options =
      backend_file_bridge_request_options(request_options, "/backend-api/files/uploaded", %{})

    file_request_metadata = FileRequestMetadata.from_request_options(request_options)

    case Files.mark_uploaded_or_prepare_finalize(
           auth,
           file_id,
           file_request_metadata,
           now(request_options)
         ) do
      {:finalize, %FileRecord{} = file} ->
        bridge_result =
          with {:ok, %RoutingSelection{} = selection} <-
                 FileSelection.fetch(
                   auth,
                   file.pool_upstream_assignment_id,
                   bridge_request_options,
                   "/backend-api/files/uploaded"
                 ) do
            file_id
            |> FileBridge.finalize_file(bridge_request_options, selection)
            |> complete_file_bridge_result(auth, bridge_request_options, selection)
          end

        Files.record_finalize_result(
          auth,
          file_id,
          file_request_metadata,
          bridge_result
        )

      result ->
        result
    end
  end

  def mark_uploaded(_auth, _file_id, _opts),
    do: {:error, invalid_auth_error()}

  defp v1_create_payload(%{"filename" => filename, "bytes" => bytes}) do
    %{"file_name" => filename, "file_size" => bytes, "use_case" => "codex"}
  end

  defp complete_file_bridge_result(
         {:ok, _body} = result,
         auth,
         _opts,
         %RoutingSelection{} = selection
       ) do
    RouteLifecycle.log_optional_result(
      "file_bridge_route_success",
      route_lifecycle_metadata(selection),
      RouteLifecycle.selection_success(auth, FileSelection.model(), selection)
    )

    result
  end

  defp complete_file_bridge_result(
         {:retry_timeout, _body} = result,
         auth,
         opts,
         %RoutingSelection{} = selection
       ) do
    complete_routing_failure(auth, opts, selection, "file_bridge_retry_timeout")
    result
  end

  defp complete_file_bridge_result(
         {:error, error} = result,
         auth,
         opts,
         %RoutingSelection{} = selection
       ) do
    case file_bridge_failure_reason(error) do
      nil -> :ok
      reason -> complete_routing_failure(auth, opts, selection, reason)
    end

    result
  end

  defp complete_routing_failure(auth, opts, %RoutingSelection{} = selection, reason) do
    RouteLifecycle.log_optional_result(
      "file_bridge_route_failure",
      route_lifecycle_metadata(selection),
      RouteLifecycle.selection_failure(
        auth,
        FileSelection.model(),
        selection,
        request_id(opts),
        reason
      )
    )

    :ok
  end

  defp route_lifecycle_metadata(%RoutingSelection{} = selection) do
    [
      pool_upstream_assignment_id: selection.assignment.id,
      route_class: selection.route_class
    ]
  end

  defp file_bridge_failure_reason(%{code: code, status: status})
       when status == 429 or status >= 500 do
    "file_bridge_#{code}"
  end

  defp file_bridge_failure_reason(_error), do: nil

  defp request_id(%RequestOptions{} = request_options),
    do: binary_id_or_nil(request_options.request_metadata.request_id)

  defp binary_id_or_nil(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp binary_id_or_nil(_value), do: nil

  defp upload_v1_file(auth, %FileRecord{} = file_record, upload_url, file, request_options) do
    upload_request_options =
      RequestOptions.put_file_bridge(request_options,
        operation: :upload,
        endpoint: "/v1/files/upload",
        pool_upstream_assignment_id: file_record.pool_upstream_assignment_id,
        upstream_identity_id: file_record.upstream_identity_id,
        route_metadata: %{"route_class" => RouteClass.file_upload()}
      )

    case FileBridge.upload_file(upload_url, file, upload_request_options) do
      :ok ->
        :ok

      {:error, reason} ->
        Files.record_upload_failure(
          auth,
          file_record.file_id,
          reason,
          FileRequestMetadata.from_request_options(upload_request_options)
        )
    end
  end

  defp defer_create_request(%RequestOptions{} = request_options) do
    RequestOptions.put_file_bridge(request_options, defer_create_request: true)
  end

  defp public_v1_file_request_options(opts, endpoint, payload) do
    RequestOptions.for_file_bridge(opts, endpoint, payload, route_class: RouteClass.file_upload())
  end

  defp backend_file_bridge_request_options(%RequestOptions{} = request_options, endpoint, payload) do
    RequestOptions.for_file_bridge(request_options, endpoint, payload)
  end

  defp fresh_request_options(%RequestOptions{} = request_options) do
    RequestOptions.put_request_metadata(request_options, request_id: Ecto.UUID.generate())
  end

  defp invalid_auth_error do
    %{status: 400, code: :invalid_request, message: "authenticated pool and api key are required"}
  end

  defp now(%RequestOptions{runtime: %{now: configured_now}}) when not is_nil(configured_now),
    do: configured_now

  defp now(%RequestOptions{}),
    do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
