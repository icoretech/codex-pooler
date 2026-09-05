defmodule CodexPooler.Quotas.Evidence.DescriptorsTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Quotas.Evidence.Descriptors

  @spark_tokens [
    "codex_spark",
    "codex_bengalfox",
    "gpt_5_3_codex_spark",
    "codex_other",
    "gpt-5.3-codex-spark"
  ]

  test "given a generic feature descriptor, when it is normalized, then its existing fields remain unchanged" do
    descriptor =
      Descriptors.limit_descriptor("image_generation", nil, %{
        quota_scope: "feature",
        quota_family: "image_generation"
      })

    assert descriptor == %{
             display_label: "image_generation",
             metered_feature: "image_generation",
             quota_family: "image_generation",
             quota_key: "image_generation",
             quota_scope: "feature",
             raw_limit_id: "image_generation",
             raw_metered_feature: "image_generation"
           }
  end

  test "a stable meter token preserves the legacy model descriptor while its display label changes" do
    assert Descriptors.limit_descriptor("stable_meter", "Initial provider label", %{}) == %{
             quota_key: "initial_provider_label",
             quota_scope: "model",
             quota_family: "codex_model",
             display_label: "Initial provider label",
             model: "Initial provider label",
             limit_name: "Initial provider label",
             metered_feature: "stable_meter",
             raw_limit_id: "stable_meter",
             raw_limit_name: "Initial provider label",
             raw_metered_feature: "stable_meter"
           }

    assert Descriptors.limit_descriptor("stable_meter", "Renamed provider label", %{})
           |> Map.take([
             :quota_scope,
             :quota_family,
             :metered_feature,
             :raw_limit_id,
             :raw_metered_feature
           ]) == %{
             quota_scope: "model",
             quota_family: "codex_model",
             metered_feature: "stable_meter",
             raw_limit_id: "stable_meter",
             raw_metered_feature: "stable_meter"
           }
  end

  test "recognized weekly Spark tokens canonicalize from either eligible field in both target scopes" do
    for token <- @spark_tokens,
        value <- [token, String.upcase(token)],
        scope <- ["model", "upstream_model"],
        field <- [:quota_key, :active_dimension] do
      logical_key = spark_logical_key(scope, field, value)

      assert Descriptors.canonical_logical_window_key(logical_key) ==
               canonical_spark_key(scope)
    end
  end

  test "legacy weekly primary Spark identities canonicalize to the secondary window" do
    for scope <- ["model", "upstream_model"] do
      logical_key =
        scope
        |> spark_logical_key(:quota_key, "codex_bengalfox")
        |> put_elem(5, "primary")

      assert Descriptors.canonical_logical_window_key(logical_key) ==
               canonical_spark_key(scope)
    end
  end

  test "Spark target canonicalization is symmetric across nonweekly primary and weekly secondary windows" do
    primary_key =
      {"model", "codex_model", "sample-codex-spark", nil, "codex_spark", "primary", 300}

    weekly_key =
      {"model", "codex_model", "sample-codex-spark", nil, "codex_spark", "secondary", 10_080}

    assert {"model", "codex_model", "gpt-5.3-codex-spark", nil, "codex_spark", "primary", 300} =
             Descriptors.canonical_logical_window_key(primary_key)

    assert {"model", "codex_model", "gpt-5.3-codex-spark", nil, "codex_spark", "secondary",
            10_080} = Descriptors.canonical_logical_window_key(weekly_key)
  end

  test "feature and account rows containing codex_other are not converted" do
    for scope <- ["feature", "account"] do
      logical_key =
        {scope, scope, nil, nil, "CODEX_OTHER", "secondary", 10_080}

      assert Descriptors.canonical_logical_window_key(logical_key) == logical_key
    end
  end

  test "unrelated weekly target identifiers remain distinct" do
    logical_key =
      {"model", "codex_model", "gpt-5.3-codex-spark-preview", nil, "codex_otherwise", "secondary",
       10_080}

    assert Descriptors.canonical_logical_window_key(logical_key) == logical_key
  end

  test "recognized Spark tokens in inactive target-scope dimensions do not canonicalize" do
    for token <- @spark_tokens do
      model_scope_key =
        {"model", "unrelated-family", "unrelated-model", token, "unrelated-quota", "secondary",
         10_080}

      upstream_model_scope_key =
        {"upstream_model", "unrelated-family", token, "unrelated-upstream-model",
         "unrelated-quota", "secondary", 10_080}

      assert Descriptors.canonical_logical_window_key(model_scope_key) == model_scope_key

      assert Descriptors.canonical_logical_window_key(upstream_model_scope_key) ==
               upstream_model_scope_key
    end
  end

  defp spark_logical_key("model", field, token) do
    model = if field == :active_dimension, do: token, else: "unrelated-model"
    quota_key = if field == :quota_key, do: token, else: "unrelated-quota"

    {"model", "unrelated-family", model, "ignored-upstream", quota_key, "secondary", 10_080}
  end

  defp spark_logical_key("upstream_model", field, token) do
    upstream_model = if field == :active_dimension, do: token, else: "unrelated-upstream-model"
    quota_key = if field == :quota_key, do: token, else: "unrelated-quota"

    {"upstream_model", "unrelated-family", "ignored-model", upstream_model, quota_key,
     "secondary", 10_080}
  end

  defp canonical_spark_key("model") do
    {"model", "codex_model", "gpt-5.3-codex-spark", nil, "codex_spark", "secondary", 10_080}
  end

  defp canonical_spark_key("upstream_model") do
    {"upstream_model", "codex_model", nil, "gpt-5.3-codex-spark", "codex_spark", "secondary",
     10_080}
  end
end
