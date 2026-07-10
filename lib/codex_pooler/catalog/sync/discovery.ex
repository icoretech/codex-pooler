defmodule CodexPooler.Catalog.Sync.Discovery do
  @moduledoc """
  Upstream model catalog discovery and payload normalization.
  """

  alias CodexPooler.Upstreams.CloudflareCookies
  alias CodexPooler.Upstreams.CodexClientIdentity
  alias CodexPooler.Upstreams.EndpointMetadata
  alias CodexPooler.Upstreams.Secrets

  @default_codex_upstream_base_url "https://chatgpt.com"
  @secret_kind "access_token"

  @type catalog_error :: %{required(:code) => atom(), required(:message) => String.t()}

  @spec discover_models([map()], (map() -> {:ok, [map()]} | {:error, term()})) ::
          {:ok, [map()]} | {:error, term()}
  def discover_models(assignments, fetcher) do
    Enum.reduce_while(assignments, {:ok, []}, fn source, {:ok, discovered} ->
      case fetcher.(source) do
        {:ok, models} when is_list(models) ->
          source_models = Enum.map(models, &Map.put(normalize_model_attrs(&1), :source, source))
          {:cont, {:ok, discovered ++ source_models}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  @spec fetch_models_for_assignment(map()) :: {:ok, [map()]} | {:error, catalog_error() | term()}
  def fetch_models_for_assignment(%{assignment: assignment, identity: identity}) do
    with {:ok, token} <-
           Secrets.decrypt_active_secret(identity, @secret_kind),
         {:ok, url} <- model_catalog_url(identity, assignment) do
      case Req.get(url,
             retry: false,
             receive_timeout: 30_000,
             headers:
               CloudflareCookies.request_headers(url, model_catalog_headers(identity, token))
           )
           |> store_cloudflare_cookies(url) do
        {:ok, %{status: 200, body: %{"data" => models}}} when is_list(models) ->
          {:ok, models}

        {:ok, %{status: 200, body: %{"models" => models}}} when is_list(models) ->
          {:ok, models}

        {:ok, %{status: 200, body: models}} when is_list(models) ->
          {:ok, models}

        {:ok, %{status: status}} ->
          {:error,
           catalog_error(
             :upstream_model_list_failed,
             "model list request failed with #{status}"
           )}

        {:error, reason} ->
          {:error, catalog_error(:upstream_model_list_failed, Exception.message(reason))}
      end
    end
  end

  defp store_cloudflare_cookies(result, url) do
    CloudflareCookies.store_from_result(url, result)
    result
  end

  defp model_catalog_url(identity, assignment) do
    case EndpointMetadata.endpoint_url(
           identity,
           assignment,
           model_catalog_path(),
           @default_codex_upstream_base_url
         ) do
      {:ok, url} ->
        {:ok, url}

      {:error, :invalid_upstream_base_url} ->
        {:error, catalog_error(:invalid_upstream_base_url, "upstream base URL is invalid")}
    end
  end

  defp model_catalog_path do
    "/backend-api/codex/models?client_version=" <>
      URI.encode_www_form(CodexClientIdentity.version())
  end

  defp model_catalog_headers(identity, token) do
    headers =
      [
        {"authorization", "Bearer #{String.trim(token)}"},
        {"accept", "application/json"}
      ] ++ CodexClientIdentity.headers()

    case present_string(identity.chatgpt_account_id) do
      nil -> headers
      account_id -> [{"chatgpt-account-id", account_id} | headers]
    end
  end

  # Reason: model imports accept multiple upstream metadata spellings.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp normalize_model_attrs(attrs) when is_map(attrs) do
    upstream_model_id =
      string_attr(attrs, "id") || string_attr(attrs, :id) || string_attr(attrs, "slug") ||
        string_attr(attrs, :slug)

    exposed_model_id = string_attr(attrs, "exposed_model_id") || upstream_model_id

    display_name =
      string_attr(attrs, "display_name") || string_attr(attrs, "name") || upstream_model_id

    owned_by = string_attr(attrs, "owned_by")
    capabilities = map_attr(attrs, "capabilities") || %{}

    %{
      upstream_model_id: upstream_model_id,
      exposed_model_id: exposed_model_id,
      display_name: display_name,
      supports_responses:
        bool_attr(attrs, "supports_responses", bool_default(capabilities, "responses", true)),
      supports_streaming:
        bool_attr(
          attrs,
          "supports_streaming",
          bool_default(
            capabilities,
            "streaming",
            bool_default(attrs, "prefer_websockets", false)
          )
        ),
      supports_tools:
        bool_attr(
          attrs,
          "supports_tools",
          bool_default(
            capabilities,
            "tools",
            bool_default(attrs, "supports_parallel_tool_calls", false)
          )
        ),
      supports_reasoning:
        bool_attr(
          attrs,
          "supports_reasoning",
          bool_default(
            capabilities,
            "reasoning",
            match?([_ | _], Map.get(attrs, "supported_reasoning_levels"))
          )
        ),
      pricing_ref: string_attr(attrs, "pricing_ref"),
      owned_by: owned_by,
      upstream_model: attrs
    }
    |> then(fn model ->
      Map.put(
        model,
        :pricing_ref,
        model.pricing_ref || if(model.upstream_model_id, do: "openai/#{model.upstream_model_id}")
      )
    end)
  end

  defp catalog_error(code, message), do: %{code: code, message: message}

  defp string_attr(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) -> String.trim(value)
      _value -> nil
    end
  end

  defp map_attr(attrs, key) do
    case Map.get(attrs, key) do
      value when is_map(value) -> value
      _value -> nil
    end
  end

  defp bool_attr(attrs, key, default) do
    case Map.get(attrs, key) do
      value when is_boolean(value) -> value
      _value -> default
    end
  end

  defp bool_default(attrs, key, default) do
    case Map.get(attrs, key) do
      value when is_boolean(value) -> value
      _value -> default
    end
  end

  defp present_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp present_string(_value), do: nil
end
