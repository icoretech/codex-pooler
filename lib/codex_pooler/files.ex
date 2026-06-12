defmodule CodexPooler.Files do
  @moduledoc """
  File metadata foundations for Codex backend compatibility.
  """

  import Ecto.Query

  alias CodexPooler.Accounting.Request

  alias CodexPooler.Files.{
    CreateValidation,
    FileRecord,
    FileState,
    RequestLog,
    RequestMetadata,
    UploadLifecycle,
    UploadUrlPolicy
  }

  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Repo

  @default_file_ttl_seconds 24 * 60 * 60

  @type file_error :: %{
          required(:status) => pos_integer(),
          required(:code) => atom() | String.t(),
          required(:message) => String.t(),
          optional(:param) => String.t() | nil
        }
  @type auth :: CodexPooler.Access.auth_context()
  @type file_id :: String.t()
  @type file_opts :: RequestMetadata.t() | map() | keyword()
  @type finalize_bridge_error :: %{
          required(:status) => pos_integer(),
          required(:code) => atom() | String.t()
        }
  @type finalize_bridge_result ::
          {:ok, map()} | {:retry_timeout, map()} | {:error, finalize_bridge_error()}
  @type file_result :: {:ok, map()} | {:error, file_error()}
  @type affinity_result ::
          {:ok, %{optional(String.t()) => Ecto.UUID.t()}} | {:error, file_error()}

  @spec max_file_size_bytes() :: pos_integer()
  def max_file_size_bytes do
    CreateValidation.max_file_size_bytes()
  end

  @spec file_ttl_seconds() :: pos_integer()
  def file_ttl_seconds do
    config_file_ttl_seconds() || OperationalSettings.current().upload_ttl_seconds ||
      @default_file_ttl_seconds
  end

  @spec create_pending_record_from_bridge_result(auth(), map(), map(), file_opts()) ::
          file_result()
  def create_pending_record_from_bridge_result(auth, create_attrs, bridge_result, opts \\ %{})

  def create_pending_record_from_bridge_result(
        %{pool: pool, api_key: api_key} = auth,
        %{file_name: file_name, file_size: file_size, use_case: use_case},
        %{body: body, assignment: assignment, identity: identity} = bridge_result,
        opts
      ) do
    now = now(opts)

    with {:ok, upstream_file_id} <- CreateValidation.upstream_file_id(body),
         :ok <- CreateValidation.upload_url_present(body),
         :ok <- UploadUrlPolicy.validate(Map.get(body, "upload_url")) do
      expires_at = DateTime.add(now, file_ttl_seconds(), :second)
      request_opts = create_file_request_opts(opts)

      attrs = %{
        pool_id: pool.id,
        api_key_id: api_key.id,
        file_id: upstream_file_id,
        purpose: use_case,
        filename: file_name,
        byte_size: file_size,
        assignment_id: assignment.id,
        identity_id: identity.id,
        expires_at: expires_at,
        created_at: now,
        metadata: file_record_metadata("backend-api/files/upstream", opts)
      }

      create_pending_file_transaction(auth, request_opts, attrs, bridge_result)
    end
  end

  def create_pending_record_from_bridge_result(_auth, _create_attrs, _bridge_result, _opts),
    do: {:error, error(400, :invalid_request, "authenticated pool and api key are required")}

  @spec record_create_bridge_failure(auth(), map(), file_opts()) ::
          {:error, file_error()}
  def record_create_bridge_failure(auth, bridge_error, opts \\ %{})

  def record_create_bridge_failure(%{pool: _pool, api_key: _api_key} = auth, bridge_error, opts)
      when is_map(bridge_error) do
    status = Map.get(bridge_error, :status, 502)

    with {:ok, _request} <-
           RequestLog.record_file_request(
             auth,
             "failed",
             status,
             create_file_request_opts(opts),
             %{
               "operation" => "create",
               "error_code" =>
                 bridge_error |> Map.get(:code, :upstream_file_bridge_failed) |> to_string()
             }
             |> Map.merge(RequestLog.bridge_route_metadata(bridge_error))
           ) do
      {:error, Map.drop(bridge_error, [:upstream])}
    end
  end

  def record_create_bridge_failure(_auth, _bridge_error, _opts),
    do: {:error, error(400, :invalid_request, "authenticated pool and api key are required")}

  defdelegate create_params(params), to: CreateValidation

  @spec assignment_affinities(auth(), [file_id()], keyword() | map()) :: affinity_result()
  def assignment_affinities(auth, file_ids, opts \\ [])

  def assignment_affinities(%{pool: pool, api_key: api_key}, file_ids, opts)
      when is_list(file_ids) do
    now = now(Map.new(opts))
    ids = file_ids |> Enum.filter(&is_binary/1) |> Enum.uniq()

    records = Repo.all(assignment_affinity_query(pool.id, api_key.id, ids, now))

    affinities =
      Map.new(records, fn {file_id, assignment_id} -> {file_id, assignment_id} end)

    if Enum.any?(ids, &(not is_binary(Map.get(affinities, &1)))) do
      {:error, error(404, :file_not_found, "file was not found", "file_id")}
    else
      {:ok, affinities}
    end
  end

  def assignment_affinities(_auth, _file_ids, _opts),
    do: {:error, error(400, :invalid_request, "authenticated pool and api key are required")}

  @spec response_assignment_affinities(auth(), [file_id()], keyword() | map()) ::
          affinity_result()
  def response_assignment_affinities(auth, file_ids, opts \\ [])

  def response_assignment_affinities(%{pool: pool, api_key: api_key} = auth, file_ids, opts)
      when is_list(file_ids) do
    opts = Map.new(opts)
    ids = file_ids |> Enum.filter(&is_binary/1) |> Enum.uniq()

    case assignment_affinities(auth, ids, opts) do
      {:ok, affinities} ->
        {:ok, affinities}

      {:error, %{code: code}} when code in [:file_not_found, "file_not_found"] ->
        classify_response_assignment_affinity_error(pool.id, api_key.id, ids, now(opts))

      error ->
        error
    end
  end

  def response_assignment_affinities(_auth, _file_ids, _opts),
    do: {:error, error(400, :invalid_request, "authenticated pool and api key are required")}

  @spec record_upload_failure(auth(), file_id(), map(), file_opts()) :: {:error, file_error()}
  defdelegate record_upload_failure(auth, file_id, upload_error, opts \\ %{}),
    to: UploadLifecycle

  @spec mark_uploaded_or_prepare_finalize(auth(), file_id(), map(), DateTime.t()) ::
          {:finalize, FileRecord.t()} | file_result()
  defdelegate mark_uploaded_or_prepare_finalize(auth, file_id, request_opts, now),
    to: UploadLifecycle

  @spec record_finalize_result(auth(), file_id(), RequestMetadata.t(), finalize_bridge_result()) ::
          file_result()
  defdelegate record_finalize_result(auth, file_id, request_opts, bridge_result),
    to: UploadLifecycle

  @spec retrieve_file(auth(), file_id(), file_opts()) :: file_result()
  def retrieve_file(auth, file_id, opts \\ %{})

  def retrieve_file(%{pool: pool, api_key: api_key} = auth, file_id, opts)
      when is_binary(file_id) do
    now = now(opts)

    request_opts = RequestMetadata.build(opts, "/v1/files")

    Repo.transaction(fn ->
      file = locked_owned_file(file_id, pool.id, api_key.id)

      file
      |> FileState.classify(now)
      |> retrieve_classified_file(file, auth, file_id, request_opts, now)
    end)
    |> unwrap_nested_transaction()
  end

  def retrieve_file(_auth, _file_id, _opts),
    do: {:error, error(400, :invalid_request, "authenticated pool and api key are required")}

  defp retrieve_file_not_found(auth, file_id, request_opts) do
    with {:ok, _request} <-
           record_file_request_or_rollback(auth, "failed", 404, request_opts, %{
             "file" => %{"id" => file_id},
             "operation" => "retrieve",
             "error_code" => "file_not_found"
           }) do
      {:error, error(404, :file_not_found, "file was not found")}
    end
  end

  @spec list_files(auth(), file_opts()) :: file_result()
  def list_files(auth, opts \\ %{})

  def list_files(%{pool: pool, api_key: api_key} = auth, opts) do
    request_opts = RequestMetadata.build(opts, "/v1/files")
    now = now(opts)
    visible_statuses = [FileRecord.pending_upload_status(), FileRecord.uploaded_status()]

    files =
      Repo.all(
        from file in FileRecord,
          where:
            file.pool_id == ^pool.id and file.api_key_id == ^api_key.id and
              file.status in ^visible_statuses and file.expires_at > ^now,
          order_by: [desc: file.created_at, desc: file.id]
      )

    with {:ok, request} <-
           RequestLog.record_file_request(auth, "succeeded", 200, request_opts, %{
             "operation" => "list",
             "file_count" => length(files)
           }) do
      {:ok, %{files: files, request: request}}
    end
  end

  def list_files(_auth, _opts),
    do: {:error, error(400, :invalid_request, "authenticated pool and api key are required")}

  @spec record_unsupported_operation(auth(), file_id(), String.t(), file_opts()) ::
          {:ok, Request.t()} | {:error, file_error()}
  def record_unsupported_operation(auth, file_id, operation, opts \\ %{})

  def record_unsupported_operation(
        %{pool: _pool, api_key: _api_key} = auth,
        file_id,
        operation,
        opts
      )
      when is_binary(file_id) and is_binary(operation) do
    request_opts = RequestMetadata.build(opts, "/v1/files")

    RequestLog.record_file_request(auth, "failed", 404, request_opts, %{
      "file" => %{"id" => file_id},
      "operation" => operation,
      "error_code" => "unsupported_endpoint"
    })
  end

  def record_unsupported_operation(_auth, _file_id, _operation, _opts),
    do: {:error, error(400, :invalid_request, "authenticated pool and api key are required")}

  @spec cleanup_expired(DateTime.t()) ::
          {:ok,
           %{
             required(:abandoned_files) => non_neg_integer(),
             required(:expired_files) => non_neg_integer()
           }}
  def cleanup_expired(now \\ now()) do
    now = DateTime.truncate(now, :microsecond)
    pending_upload_status = FileRecord.pending_upload_status()
    uploaded_status = FileRecord.uploaded_status()
    abandoned_status = FileRecord.abandoned_status()
    expired_status = FileRecord.expired_status()
    expirable_statuses = [pending_upload_status, uploaded_status]

    Repo.transaction(fn ->
      {abandoned_files, _} =
        FileRecord
        |> where([file], file.status == ^pending_upload_status and file.expires_at <= ^now)
        |> Repo.update_all(set: [status: abandoned_status, deleted_at: now, updated_at: now])

      {expired_files, _} =
        FileRecord
        |> where(
          [file],
          file.status in ^expirable_statuses and file.expires_at <= ^now
        )
        |> Repo.update_all(set: [status: expired_status, deleted_at: now, updated_at: now])

      %{
        abandoned_files: abandoned_files,
        expired_files: expired_files
      }
    end)
  end

  @spec response_shape(FileRecord.t()) :: map()
  def response_shape(%FileRecord{} = file) do
    %{
      "id" => file.file_id,
      "object" => "file",
      "bytes" => file.byte_size,
      "created_at" => file.created_at |> DateTime.to_unix(),
      "filename" => file.filename,
      "purpose" => file.purpose,
      "status" => file.status,
      "expires_at" => file.expires_at |> DateTime.to_unix()
    }
  end

  defp create_file_request_opts(opts), do: RequestMetadata.build(opts, "/backend-api/files")

  defp create_pending_file_transaction(auth, request_opts, attrs, bridge_result) do
    Repo.transaction(fn ->
      insert_pending_file_from_bridge(auth, request_opts, attrs, bridge_result)
    end)
    |> unwrap_transaction()
  end

  defp insert_pending_file_from_bridge(auth, request_opts, attrs, bridge_result) do
    case maybe_record_create_success(auth, request_opts, bridge_result) do
      {:ok, request} ->
        file =
          %FileRecord{}
          |> FileRecord.changeset(%{
            pool_id: attrs.pool_id,
            api_key_id: attrs.api_key_id,
            request_id: request_id(request),
            file_id: attrs.file_id,
            purpose: attrs.purpose,
            filename: safe_filename(attrs.filename),
            content_type: nil,
            byte_size: attrs.byte_size,
            status: "pending_upload",
            pool_upstream_assignment_id: attrs.assignment_id,
            upstream_identity_id: attrs.identity_id,
            finalize_status: "pending",
            uploaded_at: nil,
            expires_at: attrs.expires_at,
            metadata: attrs.metadata,
            created_at: attrs.created_at,
            updated_at: attrs.created_at
          })
          |> Repo.insert!()

        %{file: file, request: request, body: bridge_result.body}

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp locked_owned_file(file_id, pool_id, api_key_id) do
    Repo.one(
      from file in FileRecord,
        where:
          file.file_id == ^file_id and file.pool_id == ^pool_id and
            file.api_key_id == ^api_key_id,
        lock: "FOR UPDATE"
    )
  end

  defp retrieve_classified_file(:expired, file, auth, file_id, request_opts, now) do
    FileState.expire!(file, now)
    retrieve_file_not_found(auth, file_id, request_opts)
  end

  defp retrieve_classified_file(state, file, auth, file_id, request_opts, _now)
       when state in [:uploaded, :local_pending, :upstream_pending] do
    retrieve_visible_file(file, auth, file_id, request_opts)
  end

  defp retrieve_classified_file(_state, _file, auth, file_id, request_opts, _now) do
    retrieve_file_not_found(auth, file_id, request_opts)
  end

  defp maybe_record_create_success(auth, request_opts, bridge_result) do
    if defer_create_request?(request_opts) do
      {:ok, nil}
    else
      with {:ok, request} <-
             RequestLog.record_file_request(auth, "succeeded", 200, request_opts, %{
               "operation" => "create",
               "upstream" => %{
                 "pool_upstream_assignment_id" => bridge_result.assignment.id,
                 "upstream_identity_id" => bridge_result.identity.id
               }
             }) do
        RequestLog.merge_bridge_route_metadata(request, bridge_result)
      end
    end
  end

  defp record_file_request_or_rollback(auth, status, response_status, request_opts, metadata) do
    case RequestLog.record_file_request(auth, status, response_status, request_opts, metadata) do
      {:ok, request} -> {:ok, request}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp retrieve_visible_file(file, auth, file_id, request_opts) do
    with {:ok, request} <-
           record_file_request_or_rollback(auth, "succeeded", 200, request_opts, %{
             "file" => %{"id" => file_id},
             "operation" => "retrieve"
           }) do
      {:ok, %{file: file, request: request}}
    end
  end

  defp defer_create_request?(%RequestMetadata{defer_create_request: defer_create_request?}),
    do: defer_create_request? == true

  defp request_id(nil), do: nil
  defp request_id(%{id: id}), do: id

  defp config, do: Application.get_env(:codex_pooler, __MODULE__, [])

  defp config_file_ttl_seconds do
    config()
    |> Keyword.get(:file_ttl_seconds)
    |> positive_integer_or_nil()
  end

  defp positive_integer_or_nil(value) when is_integer(value) and value > 0, do: value
  defp positive_integer_or_nil(_value), do: nil

  defp file_record_metadata(source, _opts) do
    %{"source" => source}
  end

  defp safe_filename(filename) when is_binary(filename) do
    filename |> Path.basename() |> String.slice(0, 255)
  end

  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, value}), do: {:error, value}

  defp unwrap_nested_transaction({:ok, {:ok, value}}), do: {:ok, value}
  defp unwrap_nested_transaction({:ok, {:error, value}}), do: {:error, value}
  defp unwrap_nested_transaction({:error, value}), do: {:error, value}

  defp assignment_affinity_query(pool_id, api_key_id, ids, now) do
    from file in FileRecord,
      where:
        file.pool_id == ^pool_id and file.api_key_id == ^api_key_id and
          file.file_id in ^ids and file.status == "uploaded" and
          file.finalize_status == "succeeded" and
          not is_nil(file.pool_upstream_assignment_id) and file.expires_at > ^now,
      select: {file.file_id, file.pool_upstream_assignment_id}
  end

  defp classify_response_assignment_affinity_error(pool_id, api_key_id, ids, now) do
    records = Repo.all(response_assignment_affinity_record_query(pool_id, api_key_id, ids))

    if Enum.any?(records, &response_file_not_ready?(&1, now)) do
      {:error,
       error(409, :file_not_ready, "referenced file is not ready for responses use", "file_id")}
    else
      {:error, error(404, :file_not_found, "file was not found", "file_id")}
    end
  end

  defp response_assignment_affinity_record_query(pool_id, api_key_id, ids) do
    from file in FileRecord,
      where:
        file.pool_id == ^pool_id and file.api_key_id == ^api_key_id and
          file.file_id in ^ids,
      select: %{
        status: file.status,
        finalize_status: file.finalize_status,
        expires_at: file.expires_at,
        pool_upstream_assignment_id: file.pool_upstream_assignment_id
      }
  end

  defp response_file_not_ready?(record, now) do
    not response_file_expired?(record.expires_at, now) and
      not (record.status == "uploaded" and record.finalize_status == "succeeded" and
             is_binary(record.pool_upstream_assignment_id))
  end

  defp response_file_expired?(%DateTime{} = expires_at, now),
    do: DateTime.compare(expires_at, now) != :gt

  defp response_file_expired?(_expires_at, _now), do: false

  defp error(status, code, message, param \\ nil),
    do: %{status: status, code: code, message: message, param: param}

  defp now(%RequestMetadata{now: configured_now}) when not is_nil(configured_now),
    do: configured_now

  defp now(%RequestMetadata{}), do: now()
  defp now(opts) when is_list(opts), do: Keyword.get(opts, :now) || now()
  defp now(opts), do: Map.get(opts, :now) || now()

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
