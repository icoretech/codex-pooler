defmodule CodexPooler.Gateway.Metadata do
  @moduledoc false

  alias CodexPooler.Access
  alias CodexPooler.Catalog
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Contracts
  alias CodexPooler.Gateway.Denials
  alias CodexPooler.Gateway.Facade.Catalog, as: FacadeCatalog
  alias CodexPooler.Gateway.Facade.Dispatch, as: FacadeDispatch
  alias CodexPooler.Gateway.Metadata.Accounting, as: MetadataAccounting
  alias CodexPooler.Gateway.Metadata.CodexCatalog
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Routing.CandidateEligibility
  alias CodexPooler.Gateway.Routing.ModelMetadata
  alias CodexPooler.Pools
  alias CodexPooler.Pools.ModelServingMode
  alias CodexPooler.Pools.ModelServingOverride

  @type auth :: Access.auth_context()
  @type opts :: RequestOptions.t()
  @type gateway_error :: Contracts.gateway_error()
  @type policy_result :: {:ok, map()} | {:error, gateway_error()}
  @type gateway_result :: Contracts.body_result()
  @type codex_catalog_snapshot :: %{
          required(:body) => CodexCatalog.body(),
          required(:etag) => String.t(),
          required(:visible_models) => [Model.t()],
          required(:source_identity) => CodexPooler.Upstreams.Schemas.UpstreamIdentity.t() | nil
        }

  @spec serve_codex_models(auth(), opts()) :: {:ok, gateway_result()} | {:error, gateway_error()}
  def serve_codex_models(auth, %RequestOptions{} = request_options) do
    endpoint = request_endpoint(request_options, "/backend-api/codex/models")
    request_options = request_options(request_options, endpoint, %{})

    with {:ok, snapshot} <- codex_catalog_snapshot(auth, endpoint, request_options),
         :ok <-
           record_metadata_request(auth, endpoint, request_options, snapshot) do
      {:ok,
       %{status: 200, headers: [{"etag", snapshot.etag} | json_headers()], body: snapshot.body}}
    end
  end

  @spec codex_catalog_snapshot(auth(), String.t(), opts()) ::
          {:ok, codex_catalog_snapshot()} | {:error, gateway_error()}
  def codex_catalog_snapshot(auth, endpoint, %RequestOptions{} = request_options)
      when is_binary(endpoint) do
    with {:ok, policy} <- normalize_policy_or_log(auth, endpoint, request_options) do
      hydration = CandidateEligibility.hydrate_model_visibility(auth.pool)
      resolution = FacadeCatalog.resolve(auth, policy, hydration)
      visible_models = resolution.models
      context_window_overrides = OperationalSettings.current().model_context_window_overrides

      effective_model_serving_modes =
        effective_model_serving_modes(auth, hydration, visible_models)

      catalog =
        FacadeCatalog.codex_catalog(
          resolution,
          context_window_overrides,
          effective_model_serving_modes
        )

      {:ok,
       Map.merge(catalog, %{
         visible_models: visible_models,
         source_identity: resolution.source_identity
       })}
    end
  end

  @spec effective_model_serving_modes(
          auth(),
          CandidateEligibility.model_visibility_hydration(),
          [Model.t()]
        ) :: CodexCatalog.effective_model_serving_modes()
  defp effective_model_serving_modes(auth, hydration, visible_models) do
    overrides =
      auth.pool.id
      |> then(&Pools.model_serving_modes_by_pool_ids([&1]))
      |> Map.get(auth.pool.id, %{})

    Map.new(visible_models, fn model ->
      resolution =
        ModelServingMode.resolve(
          Map.get(
            overrides,
            ModelServingOverride.canonical_exposed_model_id(model.exposed_model_id)
          ),
          ModelMetadata.metadata(model),
          routable_source_ids(hydration, model)
        )

      effective_mode =
        case resolution do
          {:ok, resolved} -> resolved.effective_mode
          :no_runtime_model -> nil
        end

      {model.exposed_model_id, effective_mode}
    end)
  end

  @spec routable_source_ids(CandidateEligibility.model_visibility_hydration(), Model.t()) ::
          [Ecto.UUID.t()]
  defp routable_source_ids(hydration, model) do
    hydration
    |> Map.get(:candidates_by_model_id, %{})
    |> Map.get(model.id, [])
    |> Enum.map(fn {assignment, _identity} -> assignment.id end)
  end

  @spec serve_openai_models(auth(), opts()) :: {:ok, gateway_result()} | {:error, gateway_error()}
  def serve_openai_models(auth, %RequestOptions{} = request_options) do
    request_options = request_options(request_options, "/v1/models", %{})

    with {:ok, visibility} <- facade_catalog(auth, "/v1/models", request_options),
         :ok <- record_metadata_request(auth, "/v1/models", request_options, visibility) do
      {:ok,
       %{
         status: 200,
         headers: json_headers(),
         body:
           FacadeCatalog.openai_body(
             visibility,
             OperationalSettings.current().model_context_window_overrides
           )
       }}
    end
  end

  @spec serve_openai_model(auth(), opts()) :: {:ok, gateway_result()} | {:error, gateway_error()}
  def serve_openai_model(auth, %RequestOptions{} = request_options) do
    endpoint = "/v1/models"
    request_options = request_options(request_options, endpoint, %{})

    with {:ok, visibility} <- facade_catalog(auth, endpoint, request_options) do
      model =
        FacadeCatalog.openai_detail(
          visibility,
          OperationalSettings.current().model_context_window_overrides
        )

      status = if is_map(model), do: 200, else: 503

      with :ok <- record_metadata_request(auth, endpoint, request_options, visibility, status) do
        if is_map(model) do
          {:ok, %{status: 200, headers: json_headers(), body: model}}
        else
          {:error, FacadeDispatch.unavailable_error()}
        end
      end
    end
  end

  defp record_metadata_request(
         auth,
         endpoint,
         %RequestOptions{} = request_options,
         %{source_identity: source_identity},
         response_status_code \\ 200
       ) do
    request_metadata = request_options.request_metadata

    MetadataAccounting.record_metadata_request(:record_models_metadata_request, auth, %{
      endpoint: endpoint,
      transport: "http_json",
      correlation_id: RequestOptions.server_correlation_id(request_options),
      idempotency_key: request_metadata.idempotency_key,
      client_ip: request_metadata.client_ip,
      user_agent: request_metadata.user_agent,
      response_status_code: response_status_code,
      upstream_identity: source_identity,
      request_metadata:
        %{
          "key_prefix" => auth.key_prefix,
          "endpoint" => endpoint,
          "operation" => "models",
          "model_source" => Catalog.model_source_snapshot(source_identity)
        }
        |> Map.merge(RequestOptions.client_request_metadata(request_options))
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()
    })
  end

  defp facade_catalog(auth, endpoint, %RequestOptions{} = request_options) do
    with {:ok, policy} <- normalize_policy_or_log(auth, endpoint, request_options) do
      hydration = CandidateEligibility.hydrate_model_visibility(auth.pool)
      {:ok, FacadeCatalog.resolve(auth, policy, hydration)}
    end
  end

  @spec normalize_policy_or_log(auth(), String.t(), opts()) :: policy_result()
  defp normalize_policy_or_log(auth, endpoint, %RequestOptions{} = request_options) do
    case Access.normalize_api_key_policy(auth.api_key) do
      {:ok, policy} ->
        {:ok, policy}

      {:error, reason} ->
        Denials.log_policy(denial_context(auth, reason, endpoint, request_options))
    end
  end

  defp denial_context(auth, reason, endpoint, %RequestOptions{} = request_options) do
    %Denials.Context{
      auth: auth,
      model: nil,
      reason: reason,
      endpoint: endpoint,
      payload: %{},
      opts: request_options
    }
  end

  defp request_endpoint(%RequestOptions{transport: %{upstream_endpoint: endpoint}}, _default)
       when is_binary(endpoint),
       do: endpoint

  defp request_endpoint(%RequestOptions{}, default), do: default

  defp request_options(%RequestOptions{} = request_options, endpoint, payload),
    do: RequestOptions.for_payload(request_options, endpoint, payload)

  defp json_headers, do: [{"content-type", "application/json"}]
end
