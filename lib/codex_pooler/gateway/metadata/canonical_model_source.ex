defmodule CodexPooler.Gateway.Metadata.CanonicalModelSource do
  @moduledoc """
  Pure projection boundary for a pristine per-assignment Codex model entry.

  Catalog partition selection remains outside this module. A selected source may
  only receive Pooler context-window and effective Responses Lite overlays.
  """

  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Metadata.CodexCatalog
  alias CodexPooler.Gateway.Routing.ModelMetadata

  @forbidden_keys ~w[
                    manual_smoke_provisioned
                    source_assignment_ids
                    source_assignment_missing_sync_run_ids
                    source_assignment_models
                    upstream_model
                  ]

  @type pricing_buckets :: ModelMetadata.pricing_buckets()
  @type context_window_overrides :: ModelMetadata.context_window_overrides()
  @type effective_model_serving_mode :: ModelMetadata.effective_model_serving_mode()
  @type result :: {:ok, map()} | {:error, :invalid_model_metadata}
  @type canonical_source :: %{required(:digest) => String.t(), required(:source) => map()}

  @spec canonical_source(term()) :: {:ok, canonical_source()} | {:error, :invalid_model_metadata}
  def canonical_source(source) when is_map(source) do
    with {:ok, source} <- canonical_json_map(source) do
      source = Map.drop(source, @forbidden_keys)
      {:ok, %{digest: canonical_digest(source), source: source}}
    end
  end

  def canonical_source(_source), do: {:error, :invalid_model_metadata}

  @spec project(
          map(),
          Model.t(),
          pricing_buckets(),
          context_window_overrides(),
          effective_model_serving_mode()
        ) :: result()
  def project(
        source,
        %Model{} = model,
        pricing_buckets,
        context_window_overrides,
        effective_model_serving_mode
      )
      when is_map(source) and is_map(pricing_buckets) and is_map(context_window_overrides) do
    with {:ok, %{source: source}} <- canonical_source(source) do
      payload =
        source
        |> ModelMetadata.apply_context_window_policy(
          model,
          pricing_buckets,
          context_window_overrides
        )
        |> Map.put("use_responses_lite", effective_model_serving_mode == "lite")

      {:ok, payload}
    end
  end

  def project(_source, %Model{}, _pricing_buckets, _context_window_overrides, _mode),
    do: {:error, :invalid_model_metadata}

  defp canonical_json_map(source) do
    _etag = CodexCatalog.etag(source)
    {:ok, stringify_keys(source)}
  rescue
    ArgumentError -> {:error, :invalid_model_metadata}
  end

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} -> {to_string(key), stringify_keys(nested_value)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp canonical_digest(source) do
    source
    |> CodexCatalog.etag()
    |> String.replace_prefix(~s(W/"cp-models-v1-), "")
    |> String.trim_trailing(~s("))
  end
end
