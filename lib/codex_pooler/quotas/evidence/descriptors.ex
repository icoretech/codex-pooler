defmodule CodexPooler.Quotas.Evidence.Descriptors do
  @moduledoc """
  Quota descriptor and canonical naming rules for normalized evidence.
  """

  @account_quota_key "account"
  @spark_quota_key "codex_spark"
  @spark_model "gpt-5.3-codex-spark"
  @spark_display_label "GPT-5.3-Codex-Spark"
  @spark_tokens ~w(codex_spark codex_bengalfox gpt_5_3_codex_spark codex_other)
  @weekly_minutes 10_080

  @spec account_descriptor() :: map()
  def account_descriptor do
    %{
      quota_key: @account_quota_key,
      quota_scope: "account",
      quota_family: "account",
      display_label: "Account"
    }
  end

  @spec limit_descriptor(term(), term(), map()) :: map()
  def limit_descriptor(limit_id, limit_name, overrides) do
    normalized_id = normalize_quota_key(limit_id) || "additional"
    normalized_name = normalize_quota_key(limit_name)
    canonical = canonical_additional_quota(limit_id, limit_name)

    base =
      cond do
        canonical != nil ->
          %{
            quota_key: canonical.quota_key,
            quota_scope: "model",
            quota_family: "codex_model",
            model: canonical.model,
            display_label: canonical.display_label,
            limit_name: limit_name,
            metered_feature: limit_id,
            raw_limit_id: limit_id,
            raw_limit_name: limit_name,
            raw_metered_feature: limit_id
          }

        present_string(limit_name) ->
          %{
            quota_key: normalized_name,
            quota_scope: "model",
            quota_family: "codex_model",
            model: limit_name,
            display_label: model_limit_display_label(limit_name),
            limit_name: limit_name,
            metered_feature: limit_id,
            raw_limit_id: limit_id,
            raw_limit_name: limit_name,
            raw_metered_feature: limit_id
          }

        true ->
          %{
            quota_key: normalized_id,
            quota_scope: "feature",
            quota_family: normalized_id,
            display_label: limit_id,
            metered_feature: limit_id,
            raw_limit_id: limit_id,
            raw_metered_feature: limit_id
          }
      end

    if normalized_id == "codex" and is_nil(present_string(limit_name)) do
      Map.merge(account_descriptor(), Map.drop(overrides, [:raw_limit_id, :raw_metered_feature]))
    else
      Map.merge(base, overrides)
    end
  end

  @spec canonical_additional_quota(term(), term()) :: map() | nil
  def canonical_additional_quota(limit_id, limit_name) do
    normalized_limit_id = normalize_quota_key(limit_id)
    normalized_limit_name = normalize_quota_key(limit_name)

    if spark_token?(normalized_limit_id) or spark_token?(normalized_limit_name) do
      %{
        quota_key: @spark_quota_key,
        model: @spark_model,
        display_label: @spark_display_label
      }
    end
  end

  @spec canonical_logical_window_key(tuple()) :: tuple()
  def canonical_logical_window_key(
        {scope, _family, model, upstream_model, quota_key, kind, minutes} = logical_key
      )
      when scope in ["model", "upstream_model"] and kind in ["primary", "secondary"] do
    active_dimension = if scope == "model", do: model, else: upstream_model

    if spark_token?(quota_key) or spark_token?(active_dimension) do
      canonical_spark_logical_key(scope, kind, minutes)
    else
      logical_key
    end
  end

  def canonical_logical_window_key(logical_key), do: logical_key

  @spec additional_display_label(map(), term()) :: String.t() | nil
  def additional_display_label(limit, limit_id) do
    present_string(limit["display_label"]) || model_limit_display_label(limit["limit_name"]) ||
      model_limit_display_label(limit["model"]) || model_limit_display_label(limit["model_id"]) ||
      model_limit_display_label(limit["model_identifier"]) ||
      present_string(limit["metered_feature"]) ||
      present_string(limit_id) || humanized_limit_id(limit_id)
  end

  @spec infer_scope(String.t() | nil, String.t() | nil, String.t() | nil) :: String.t()
  def infer_scope(model, _upstream_model, _quota_key) when is_binary(model), do: "model"

  def infer_scope(_model, upstream_model, _quota_key) when is_binary(upstream_model),
    do: "upstream_model"

  def infer_scope(_model, _upstream_model, "account"), do: "account"
  def infer_scope(_model, _upstream_model, _quota_key), do: "feature"

  defp model_limit_display_label(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" ->
        nil

      value ->
        value |> String.split(~r/[-_]/, trim: true) |> Enum.map_join("-", &model_label_part/1)
    end
  end

  defp model_limit_display_label(_value), do: nil

  defp model_label_part(part) do
    if String.downcase(part) == "gpt", do: "GPT", else: String.capitalize(part)
  end

  defp humanized_limit_id(limit_id) do
    limit_id
    |> to_string()
    |> String.replace("_", " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp normalize_quota_key(nil), do: nil

  defp normalize_quota_key(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_quota_key(value), do: value |> to_string() |> normalize_quota_key()

  defp spark_token?(value), do: normalize_quota_key(value) in @spark_tokens

  defp canonical_spark_logical_key("model", kind, minutes) do
    {"model", "codex_model", @spark_model, nil, @spark_quota_key,
     canonical_window_kind(kind, minutes), minutes}
  end

  defp canonical_spark_logical_key("upstream_model", kind, minutes) do
    {"upstream_model", "codex_model", nil, @spark_model, @spark_quota_key,
     canonical_window_kind(kind, minutes), minutes}
  end

  defp canonical_window_kind("primary", @weekly_minutes), do: "secondary"
  defp canonical_window_kind(kind, _minutes), do: kind

  defp present_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp present_string(_value), do: nil
end
