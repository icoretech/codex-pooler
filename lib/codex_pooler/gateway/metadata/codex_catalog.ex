defmodule CodexPooler.Gateway.Metadata.CodexCatalog do
  @moduledoc false

  alias CodexPooler.Access
  alias CodexPooler.Catalog
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Routing.CandidateEligibility
  alias CodexPooler.Gateway.Routing.ModelMetadata

  @etag_prefix ~s(W/"cp-models-v1-)

  @type normalized_policy :: map()
  @type body :: %{required(String.t()) => [map()]}
  @type result :: %{required(:body) => body(), required(:etag) => String.t()}
  @type pricing_buckets :: Catalog.pricing_bucket_map()
  @type context_window_overrides :: ModelMetadata.context_window_overrides()
  @type effective_model_serving_modes :: %{optional(String.t()) => String.t()}

  @spec build([Model.t()], normalized_policy()) :: result()
  def build(routable_models, normalized_policy)
      when is_list(routable_models) and is_map(normalized_policy) do
    visible_models = policy_visible_models(routable_models, normalized_policy)

    build_visible(
      visible_models,
      normalized_policy,
      Catalog.pricing_buckets_by_identifier(visible_models)
    )
  end

  @spec build([Model.t()], normalized_policy(), pricing_buckets()) :: result()
  def build(routable_models, normalized_policy, pricing_buckets)
      when is_list(routable_models) and is_map(normalized_policy) and is_map(pricing_buckets) do
    build(routable_models, normalized_policy, pricing_buckets, %{})
  end

  @spec build(
          [Model.t()],
          normalized_policy(),
          pricing_buckets(),
          context_window_overrides()
        ) :: result()
  def build(routable_models, normalized_policy, pricing_buckets, context_window_overrides)
      when is_list(routable_models) and is_map(normalized_policy) and is_map(pricing_buckets) and
             is_map(context_window_overrides) do
    routable_models
    |> policy_visible_models(normalized_policy)
    |> build_visible(normalized_policy, pricing_buckets, context_window_overrides)
  end

  @spec build(
          [Model.t()],
          normalized_policy(),
          pricing_buckets(),
          context_window_overrides(),
          effective_model_serving_modes()
        ) :: result()
  def build(
        routable_models,
        normalized_policy,
        pricing_buckets,
        context_window_overrides,
        effective_model_serving_modes
      )
      when is_list(routable_models) and is_map(normalized_policy) and is_map(pricing_buckets) and
             is_map(context_window_overrides) and is_map(effective_model_serving_modes) do
    routable_models
    |> policy_visible_models(normalized_policy)
    |> build_visible(
      normalized_policy,
      pricing_buckets,
      context_window_overrides,
      effective_model_serving_modes
    )
  end

  defp build_visible(
         visible_models,
         normalized_policy,
         pricing_buckets,
         context_window_overrides \\ %{},
         effective_model_serving_modes \\ nil
       ) do
    models =
      visible_models
      |> Enum.map(
        &model_payload(
          &1,
          normalized_policy,
          pricing_buckets,
          context_window_overrides,
          effective_model_serving_modes
        )
      )
      |> Enum.sort_by(&Map.fetch!(&1, "slug"))

    body = %{"models" => models}
    %{body: body, etag: etag(body)}
  end

  defp policy_visible_models(routable_models, normalized_policy) do
    CandidateEligibility.policy_visible_models(routable_models, normalized_policy)
  end

  @spec etag(map()) :: String.t()
  def etag(body) when is_map(body) do
    digest =
      {:codex_pooler_models, 1, canonical_json(body)}
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    @etag_prefix <> digest <> ~s(")
  end

  defp model_payload(
         %Model{} = model,
         policy,
         pricing_buckets,
         context_window_overrides,
         effective_model_serving_modes
       ) do
    {reasoning_levels, reasoning_default} =
      ModelMetadata.reasoning_level_maps_and_default(model)

    reasoning_projection =
      Access.project_reasoning_effort_metadata(policy, reasoning_levels, reasoning_default)

    case effective_model_serving_modes do
      nil ->
        ModelMetadata.codex_model_payload(
          model,
          pricing_buckets,
          reasoning_projection,
          context_window_overrides
        )

      effective_modes ->
        ModelMetadata.codex_model_payload(
          model,
          pricing_buckets,
          reasoning_projection,
          context_window_overrides,
          Map.get(effective_modes, model.exposed_model_id)
        )
    end
  end

  defp canonical_json(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested_value} -> {canonical_key(key), canonical_json(nested_value)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> reject_ambiguous_keys!()
    |> then(&{:object, &1})
  end

  defp canonical_json(value) when is_list(value), do: {:array, Enum.map(value, &canonical_json/1)}
  defp canonical_json(nil), do: {:null}
  defp canonical_json(value) when is_boolean(value), do: {:boolean, value}
  defp canonical_json(value) when is_integer(value), do: {:integer, value}
  defp canonical_json(value) when is_float(value), do: {:float, value}
  defp canonical_json(value) when is_binary(value), do: {:string, value}

  defp canonical_json(value) do
    raise ArgumentError, "unsupported JSON value: #{inspect(value)}"
  end

  defp canonical_key(key) when is_binary(key), do: key
  defp canonical_key(key) when is_atom(key), do: Atom.to_string(key)

  defp canonical_key(key) do
    raise ArgumentError, "unsupported JSON object key: #{inspect(key)}"
  end

  defp reject_ambiguous_keys!(entries) do
    entries
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find(fn [{left, _}, {right, _}] -> left == right end)
    |> case do
      nil -> entries
      [{key, _}, {key, _}] -> raise ArgumentError, "ambiguous JSON object key: #{inspect(key)}"
    end
  end
end
