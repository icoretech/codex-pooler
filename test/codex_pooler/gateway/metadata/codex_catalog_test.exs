defmodule CodexPooler.Gateway.Metadata.CodexCatalogTest do
  use ExUnit.Case, async: false

  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Metadata.CodexCatalog
  alias CodexPooler.Gateway.OperationalSettings

  test "build/3 is independent of operational context-window settings" do
    previous_env = Application.get_env(:codex_pooler, OperationalSettings)

    on_exit(fn -> restore_operational_settings(previous_env) end)

    inputs = {[context_model()], unrestricted_policy(), %{}}

    put_context_window_override(128_000)
    first = apply(CodexCatalog, :build, Tuple.to_list(inputs))

    put_context_window_override(256_000)
    second = apply(CodexCatalog, :build, Tuple.to_list(inputs))

    assert first.body == second.body
    assert first.etag == second.etag
  end

  test "keeps the existing effective context projection contract" do
    result = CodexCatalog.build([context_model()], unrestricted_policy(), %{})
    [model] = result.body["models"]

    assert model["context_window"] == 258_400
    assert model["max_context_window"] == 272_000
    assert model["auto_compact_token_limit"] == 232_560
    assert model["effective_context_window_percent"] == 95
  end

  test "projects GPT-5.6 raw context into the effective Codex metadata" do
    result =
      CodexCatalog.build(
        [model("gpt-5.6-context", gpt56_context_metadata())],
        unrestricted_policy(),
        %{},
        %{}
      )

    [model] = result.body["models"]

    assert model["context_window"] == 258_400
    assert model["max_context_window"] == 272_000
    assert model["auto_compact_token_limit"] == 232_560
    assert model["effective_context_window_percent"] == 95
  end

  test "builds a slug-sorted catalog with an exact deterministic weak revision" do
    result = CodexCatalog.build(Enum.reverse(models()), unrestricted_policy(), %{})

    assert Enum.map(result.body["models"], & &1["slug"]) == ["gpt-a", "gpt-b"]
    assert result.etag =~ ~r/^W\/"cp-models-v1-[0-9a-f]{64}"$/
    assert result == CodexCatalog.build(models(), unrestricted_policy(), %{})
  end

  test "canonicalizes equivalent JSON object forms and preserves list semantics" do
    atom_body = %{models: [%{slug: "gpt-a", nested: %{enabled: true}, values: [1, 1.0, nil]}]}

    string_body = %{
      "models" => [
        Map.new([
          {"values", [1, 1.0, nil]},
          {"nested", Map.new([{"enabled", true}])},
          {"slug", "gpt-a"}
        ])
      ]
    }

    assert CodexCatalog.etag(atom_body) == CodexCatalog.etag(string_body)

    refute CodexCatalog.etag(string_body) ==
             CodexCatalog.etag(
               put_in(string_body, ["models", Access.at(0), "values"], [1.0, 1, nil])
             )
  end

  test "rejects unsupported values and ambiguous equivalent object keys" do
    assert_raise ArgumentError, ~r/ambiguous JSON object key/, fn ->
      CodexCatalog.etag(%{:slug => "gpt-a", "slug" => "gpt-a"})
    end

    assert_raise ArgumentError, ~r/unsupported JSON object key/, fn ->
      CodexCatalog.etag(%{1 => "gpt-a"})
    end

    assert_raise ArgumentError, ~r/unsupported JSON value/, fn ->
      CodexCatalog.etag(%{"slug" => {:not, :json}})
    end
  end

  test "changes the revision for any final field or model membership change" do
    result = CodexCatalog.build(models(), unrestricted_policy(), %{})

    changed_field =
      CodexCatalog.build(
        [model("gpt-a", %{"description" => "changed"})],
        unrestricted_policy(),
        %{}
      )

    changed_membership = CodexCatalog.build([hd(models())], unrestricted_policy(), %{})

    refute result.etag == changed_field.etag
    refute result.etag == changed_membership.etag
  end

  test "projects unrestricted, maximum, and enforced reasoning from normalized policy" do
    model = model("gpt-a", reasoning_metadata())

    unrestricted = CodexCatalog.build([model], unrestricted_policy(), %{})
    maximum = CodexCatalog.build([model], policy(maximum_reasoning_effort: "medium"), %{})
    enforced = CodexCatalog.build([model], policy(enforced_reasoning_effort: "high"), %{})

    assert reasoning_projection(unrestricted) == {~w(low medium high), "medium"}
    assert reasoning_projection(maximum) == {~w(low medium), "medium"}
    assert reasoning_projection(enforced) == {["high"], "high"}
    refute unrestricted.etag == maximum.etag
    refute maximum.etag == enforced.etag
  end

  test "different policies with the same final body have the same revision" do
    model = model("gpt-a", reasoning_metadata())

    unrestricted = CodexCatalog.build([model], unrestricted_policy(), %{})
    maximum = CodexCatalog.build([model], policy(maximum_reasoning_effort: "ultra"), %{})

    assert unrestricted.body == maximum.body
    assert unrestricted.etag == maximum.etag
  end

  test "effective serving modes determine only the emitted Lite boolean and final-body revision" do
    aggregate_lite_model = model("gpt-a", %{"use_responses_lite" => true})
    aggregate_full_model = model("gpt-a", %{"use_responses_lite" => false})

    aggregate_lite =
      CodexCatalog.build(
        [aggregate_lite_model],
        unrestricted_policy(),
        %{},
        %{}
      )

    explicit_lite =
      CodexCatalog.build(
        [aggregate_full_model],
        unrestricted_policy(),
        %{},
        %{},
        %{"gpt-a" => "lite"}
      )

    explicit_full =
      CodexCatalog.build(
        [aggregate_lite_model],
        unrestricted_policy(),
        %{},
        %{},
        %{"gpt-a" => "full"}
      )

    assert get_in(aggregate_lite.body, ["models", Access.at(0), "use_responses_lite"])
    assert explicit_lite.body == aggregate_lite.body
    assert explicit_lite.etag == aggregate_lite.etag

    refute get_in(explicit_full.body, ["models", Access.at(0), "use_responses_lite"])
    refute explicit_full.body == aggregate_lite.body
    refute explicit_full.etag == aggregate_lite.etag

    assert get_in(explicit_full.body, ["models", Access.at(0), "supports_parallel_tool_calls"])
  end

  test "missing and malformed effective mode entries default to Full without aggregate fallback" do
    aggregate_lite_model = model("gpt-a", %{"use_responses_lite" => true})

    aggregate_fallback =
      CodexCatalog.build([aggregate_lite_model], unrestricted_policy(), %{}, %{})

    for effective_modes <- [
          %{"other-model" => "full"},
          %{"gpt-a" => "auto"},
          %{"gpt-a" => true},
          %{gpt_a: "full"}
        ] do
      result =
        CodexCatalog.build(
          [aggregate_lite_model],
          unrestricted_policy(),
          %{},
          %{},
          effective_modes
        )

      refute get_in(result.body, ["models", Access.at(0), "use_responses_lite"])
      refute result.body == aggregate_fallback.body
      refute result.etag == aggregate_fallback.etag
    end
  end

  test "filters the complete routable list through normalized model policy" do
    result =
      CodexCatalog.build(
        models(),
        unrestricted_policy()
        |> Map.put(:allowed_model_identifiers, ["gpt-b"])
        |> Map.put(:api_key_id, "ignored-source-identity"),
        %{}
      )

    assert Enum.map(result.body["models"], & &1["slug"]) == ["gpt-b"]

    assert result.etag ==
             CodexCatalog.build(
               Enum.reverse(models()),
               Map.delete(result_policy("gpt-b"), :api_key_id),
               %{}
             ).etag
  end

  defp models do
    [
      model("gpt-a", %{"reasoning_levels" => [%{"effort" => "low"}, %{"effort" => "high"}]}),
      model("gpt-b", %{"reasoning_levels" => [%{"effort" => "medium"}]})
    ]
  end

  defp model(slug, metadata) do
    %Model{
      upstream_model_id: slug,
      exposed_model_id: slug,
      display_name: slug,
      status: "active",
      supports_responses: true,
      supports_streaming: true,
      supports_tools: true,
      supports_reasoning: true,
      metadata: metadata
    }
  end

  defp unrestricted_policy do
    %{
      allowed_model_identifiers: nil,
      enforced_model_identifier: nil,
      enforced_reasoning_effort: nil,
      maximum_reasoning_effort: nil
    }
  end

  defp policy(overrides), do: Map.merge(unrestricted_policy(), Map.new(overrides))

  defp result_policy(model_identifier) do
    Map.put(unrestricted_policy(), :allowed_model_identifiers, [model_identifier])
  end

  defp reasoning_metadata do
    %{
      "default_reasoning_level" => "medium",
      "supported_reasoning_levels" => [
        %{"effort" => "low", "description" => "low"},
        %{"effort" => "medium", "description" => "medium"},
        %{"effort" => "high", "description" => "high"}
      ]
    }
  end

  defp reasoning_projection(result) do
    [model] = result.body["models"]

    {Enum.map(model["supported_reasoning_levels"], & &1["effort"]),
     model["default_reasoning_level"]}
  end

  defp context_model do
    model("gpt-context", %{
      "context_window" => 272_000,
      "max_context_window" => 272_000,
      "auto_compact_token_limit" => nil
    })
  end

  defp gpt56_context_metadata do
    %{
      "context_window" => 272_000,
      "max_context_window" => 272_000,
      "effective_context_window_percent" => 95,
      "auto_compact_token_limit" => nil
    }
  end

  defp put_context_window_override(context_window) do
    Application.put_env(:codex_pooler, OperationalSettings,
      settings: %OperationalSettings{
        model_context_window_overrides: %{"gpt-context" => context_window}
      }
    )
  end

  defp restore_operational_settings(nil),
    do: Application.delete_env(:codex_pooler, OperationalSettings)

  defp restore_operational_settings(previous_env),
    do: Application.put_env(:codex_pooler, OperationalSettings, previous_env)
end
