defmodule CodexPooler.CodexCatalogShapes do
  @moduledoc """
  Synthetic native Codex catalog sources and every served-body projection the
  Pooler builds from them, for the catalog decode contract (findings#258 row
  258-34).

  `served_bodies/0` runs the real `CodexCatalog` builders over a synced-shaped
  source (the key set of a provider catalog entry, synthetic values), the
  legacy instructions shape, minimal and null-heavy entries, under Full and
  Lite serving modes, context-window overrides, both pricing context buckets,
  API-key reasoning/model policies, a multi-partition reasoning union and
  every instructions representation. `decode_vectors/0` lists single-entry
  mutations with the violations the contract reports for them; an empty list
  marks a shape the released client tolerates. Values are synthetic only.
  """

  alias CodexPooler.Catalog.Model
  alias CodexPooler.Gateway.Metadata.CodexCatalog
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment

  @representations [:verbatim, :instructions_template, :decode_checked]
  @template "Synthetic instructions template."

  @doc "A catalog source with the key set a synced provider entry carries."
  @spec synced_source(String.t(), map()) :: map()
  def synced_source(slug, overrides \\ %{}) do
    Map.merge(
      %{
        "slug" => slug,
        "display_name" => "Synthetic #{slug}",
        "description" => "Synthetic catalog entry",
        "default_reasoning_level" => "medium",
        "supported_reasoning_levels" => [
          %{"effort" => "low", "description" => "Synthetic low"},
          %{"effort" => "medium", "description" => "Synthetic medium"},
          %{"effort" => "high", "description" => "Synthetic high"},
          %{"effort" => "xhigh", "description" => "Synthetic xhigh"}
        ],
        "shell_type" => "shell_command",
        "visibility" => "list",
        "supported_in_api" => true,
        "priority" => 1,
        "additional_speed_tiers" => ["fast"],
        "service_tiers" => [%{"id" => "priority", "name" => "Fast", "description" => "Synthetic tier"}],
        "availability_nux" => nil,
        "upgrade" => nil,
        "model_messages" => %{
          "persistent_instructions" => "Synthetic persistent instructions.",
          "instructions_template" => @template,
          "instructions_variables" => nil,
          "approvals" => %{"on_request" => nil, "on_request_auto_review" => "Synthetic approval.", "never" => nil, "unless_trusted" => nil},
          "collaboration_modes" => %{"default" => nil, "plan" => nil},
          "auto_review" => nil,
          "permissions" => nil,
          "multi_agent" => nil
        },
        "include_skills_usage_instructions" => false,
        "include_plugin_usage_instructions" => false,
        "include_apps_usage_instructions" => false,
        "default_reasoning_summary" => "auto",
        "support_verbosity" => true,
        "default_verbosity" => "low",
        "apply_patch_tool_type" => "freeform",
        "web_search_tool_type" => "text_and_image",
        "truncation_policy" => %{"mode" => "tokens", "limit" => 10_000},
        "supports_image_detail_original" => true,
        "context_window" => 272_000,
        "max_context_window" => 872_000,
        "comp_hash" => "c0de",
        "effective_context_window_percent" => 95,
        "experimental_supported_tools" => ["synthetic_tool"],
        "input_modalities" => ["text", "image"],
        "supports_search_tool" => true,
        "supports_experimental_context" => true,
        "use_responses_lite" => false,
        "supports_reasoning_effort_updates" => false,
        "node_repl_auto_review_required" => true,
        "node_repl_disabled" => false,
        "tool_mode" => "code_mode_only",
        "multi_agent_version" => "v2",
        "multi_agent_reasoning_effort" => "xhigh",
        "guardian" => %{"shell" => "adaptive", "future_scope" => "synchronous"},
        "base_instructions" => @template,
        "future_schema_field" => %{"nested" => [true, 7, nil]}
      },
      overrides
    )
  end

  @doc "An older entry whose instructions live only in the legacy top-level field."
  @spec legacy_source(String.t()) :: map()
  def legacy_source(slug) do
    slug
    |> synced_source(%{"base_instructions" => @template})
    |> Map.delete("model_messages")
  end

  @doc "Only the fields the client requires, plus the instructions."
  @spec minimal_source(String.t()) :: map()
  def minimal_source(slug) do
    %{
      "slug" => slug,
      "display_name" => "Synthetic #{slug}",
      "supported_reasoning_levels" => [],
      "shell_type" => "unified_exec",
      "visibility" => "hide",
      "supported_in_api" => false,
      "priority" => 0,
      "support_verbosity" => false,
      "truncation_policy" => %{"mode" => "bytes", "limit" => 10_000},
      "experimental_supported_tools" => [],
      "model_messages" => %{"instructions_template" => @template}
    }
  end

  @doc "Every `Option` field present as null."
  @spec null_optional_source(String.t()) :: map()
  def null_optional_source(slug) do
    Map.merge(minimal_source(slug), %{
      "description" => nil,
      "default_reasoning_level" => nil,
      "default_service_tier" => nil,
      "availability_nux" => nil,
      "upgrade" => nil,
      "default_verbosity" => nil,
      "apply_patch_tool_type" => nil,
      "context_window" => nil,
      "max_context_window" => nil,
      "auto_compact_token_limit" => nil,
      "comp_hash" => nil,
      "auto_review_model_override" => nil,
      "model_specialty" => nil,
      "tool_mode" => nil,
      "multi_agent_version" => nil,
      "multi_agent_reasoning_effort" => nil,
      "guardian" => nil,
      "available_access_programs" => nil,
      "base_instructions" => nil
    })
  end

  @doc "`{label, representation, body}` for every served projection."
  @spec served_bodies() :: [{String.t(), atom(), map()}]
  def served_bodies do
    sources = [
      {model("gpt-shape-synced"), synced_source("gpt-shape-synced")},
      {model("gpt-shape-legacy"), legacy_source("gpt-shape-legacy")},
      {model("gpt-shape-minimal"), minimal_source("gpt-shape-minimal")},
      {model("gpt-shape-nulls"), null_optional_source("gpt-shape-nulls")},
      {model("gpt-shape-no-window"), Map.drop(synced_source("gpt-shape-no-window"), ["context_window", "max_context_window", "effective_context_window_percent"])},
      {model("gpt-shape-short"), synced_source("gpt-shape-short", %{"auto_compact_token_limit" => 250_000})},
      {model("gpt-shape-lite-source"), synced_source("gpt-shape-lite-source", %{"use_responses_lite" => true})}
    ]

    slugs = Enum.map(sources, fn {model, _source} -> model.exposed_model_id end)

    variants = [
      {"synced", unrestricted_policy(), %{}, %{}, %{}},
      {"full", unrestricted_policy(), %{}, %{}, Map.new(slugs, &{&1, "full"})},
      {"lite", unrestricted_policy(), %{}, %{}, Map.new(slugs, &{&1, "lite"})},
      {"context-override", unrestricted_policy(), %{}, Map.new(slugs, &{&1, 400_000}), %{}},
      {"long-context-pricing", unrestricted_policy(), Map.new(slugs, &{&1, ["long_context"]}), %{}, %{}},
      {"short-context-pricing", unrestricted_policy(), Map.new(slugs, &{&1, ["short_context"]}), %{}, %{}},
      {"reasoning-policy", policy(maximum_reasoning_effort: "low", enforced_service_tier: "default"), %{}, %{}, %{}},
      {"enforced-reasoning-policy", policy(enforced_reasoning_effort: "high", enforced_service_tier: "priority"), %{}, %{}, %{}},
      {"model-policy", policy(allowed_model_identifiers: ["gpt-shape-synced", "gpt-shape-legacy"]), %{}, %{}, %{}}
    ]

    selected =
      for {label, policy, pricing, overrides, modes} <- variants,
          representation <- @representations do
        {:ok, result} = CodexCatalog.build_selected_sources(sources, policy, pricing, overrides, modes, representation)
        {"#{label}/#{representation}", representation, result.body}
      end

    selected ++ reasoning_union_bodies()
  end

  # Three assignments whose sources differ only in reasoning levels: the
  # catalog advertises the union the builder writes itself.
  defp reasoning_union_bodies do
    slug = "gpt-shape-union"
    ids = ["00000000-0000-4000-8000-0000000000a1", "00000000-0000-4000-8000-0000000000a2", "00000000-0000-4000-8000-0000000000a3"]
    base = synced_source(slug)

    variant =
      base
      |> Map.put("default_reasoning_level", "max")
      |> Map.put("supported_reasoning_levels", [
        %{"effort" => "low", "description" => "Synthetic low"},
        %{"effort" => "max", "description" => "Synthetic max"},
        %{"effort" => "turbo", "description" => "Synthetic future effort"}
      ])

    model = %{model(slug) | id: Ecto.UUID.generate(), metadata: %{"source_assignment_models" => Map.new(Enum.zip(ids, [base, base, variant]))}}

    candidates =
      ids
      |> Enum.with_index()
      |> Enum.map(fn {id, index} ->
        {%PoolUpstreamAssignment{id: id, created_at: DateTime.add(~U[2026-07-30 08:00:00.000000Z], index, :second)}, nil}
      end)

    for representation <- @representations do
      result =
        CodexCatalog.build_canonical([model], %{model.id => candidates}, unrestricted_policy(), %{}, %{}, %{},
          routable_assignment_ids_by_model_id: fn -> %{model.id => MapSet.new(ids)} end,
          representation: representation
        )

      {"reasoning-union/#{representation}", representation, result.body}
    end
  end

  @doc """
  `{label, entry, violations}`: one mutated entry each. A non-empty list is
  what the contract reports and the released client must reject; `[]` marks
  a shape the client must accept.
  """
  @spec decode_vectors() :: [{String.t(), map(), [String.t()]}]
  def decode_vectors do
    base = synced_source("gpt-vector")
    minimal = minimal_source("gpt-vector")

    missing =
      for key <- ~w(slug display_name supported_reasoning_levels shell_type visibility supported_in_api priority support_verbosity truncation_policy experimental_supported_tools) do
        {"missing #{key}", Map.delete(base, key), [key]}
      end

    broken = [
      {"null display_name", Map.put(base, "display_name", nil), ["display_name"]},
      {"unknown shell_type", Map.put(base, "shell_type", "sandboxed"), ["shell_type"]},
      {"unknown visibility", Map.put(base, "visibility", "public"), ["visibility"]},
      {"unknown truncation mode", put_in(base, ["truncation_policy", "mode"], "chars"), ["truncation_policy.mode"]},
      {"missing truncation limit", update_in(base, ["truncation_policy"], &Map.delete(&1, "limit")), ["truncation_policy.limit"]},
      {"unknown default_verbosity", Map.put(base, "default_verbosity", "max"), ["default_verbosity"]},
      {"unknown apply_patch_tool_type", Map.put(base, "apply_patch_tool_type", "json"), ["apply_patch_tool_type"]},
      {"unknown web_search_tool_type", Map.put(base, "web_search_tool_type", "image"), ["web_search_tool_type"]},
      {"unknown default_reasoning_summary", Map.put(base, "default_reasoning_summary", "verbose"), ["default_reasoning_summary"]},
      {"unknown input modality", Map.put(base, "input_modalities", ["text", "video"]), ["input_modalities[1]"]},
      {"float priority", Map.put(base, "priority", 1.5), ["priority"]},
      {"integral float priority", Map.put(base, "priority", 1.0), ["priority"]},
      {"priority over i32", Map.put(base, "priority", 2_147_483_648), ["priority"]},
      {"string priority", Map.put(base, "priority", "1"), ["priority"]},
      {"string supported_in_api", Map.put(base, "supported_in_api", "true"), ["supported_in_api"]},
      {"string context_window", Map.put(base, "context_window", "272000"), ["context_window"]},
      {"null defaulted percent", Map.put(base, "effective_context_window_percent", nil), ["effective_context_window_percent"]},
      {"null defaulted bool", Map.put(base, "include_skills_usage_instructions", nil), ["include_skills_usage_instructions"]},
      {"null defaulted list", Map.put(base, "additional_speed_tiers", nil), ["additional_speed_tiers"]},
      {"service tier without description", Map.put(base, "service_tiers", [%{"id" => "priority", "name" => "Fast"}]), ["service_tiers[0].description"]},
      {"reasoning level without description", Map.put(base, "supported_reasoning_levels", [%{"effort" => "high"}]), ["supported_reasoning_levels[0].description"]},
      {"reasoning level as a string", Map.put(base, "supported_reasoning_levels", ["high"]), ["supported_reasoning_levels[0]"]},
      {"empty default effort", Map.put(base, "default_reasoning_level", ""), ["default_reasoning_level"]},
      {"null tool name", Map.put(base, "experimental_supported_tools", [nil]), ["experimental_supported_tools[0]"]},
      {"empty availability_nux", Map.put(base, "availability_nux", %{}), ["availability_nux.message"]},
      {"upgrade without markdown", Map.put(base, "upgrade", %{"model" => "gpt-next"}), ["upgrade.migration_markdown"]},
      {"numeric description", Map.put(base, "description", 7), ["description"]},
      {"numeric tool_mode", Map.put(base, "tool_mode", 3), ["tool_mode"]},
      {"string model_messages", base |> Map.delete("base_instructions") |> Map.put("model_messages", "text"), ["model_messages", "base_instructions|model_messages.instructions_template"]},
      {"no instructions", base |> Map.delete("base_instructions") |> Map.delete("model_messages"), ["base_instructions|model_messages.instructions_template"]},
      {"null template and no legacy field", base |> Map.delete("base_instructions") |> put_in(["model_messages", "instructions_template"], nil), ["base_instructions|model_messages.instructions_template"]},
      {"numeric legacy field", base |> Map.delete("model_messages") |> Map.put("base_instructions", 5), ["base_instructions", "base_instructions|model_messages.instructions_template"]}
    ]

    tolerated = [
      {"synced shape", base, []},
      {"minimal shape", minimal, []},
      {"null optionals", null_optional_source("gpt-vector"), []},
      {"legacy instructions only", legacy_source("gpt-vector"), []},
      {"template only", Map.delete(base, "base_instructions"), []},
      {"unknown fields", Map.merge(base, %{"future_flag" => "x", "future_struct" => %{"a" => [1, nil]}}), []},
      {"custom reasoning effort", Map.put(base, "supported_reasoning_levels", [%{"effort" => "turbo", "description" => "Synthetic"}]), []},
      {"unknown tool_mode and multi_agent_version", Map.merge(base, %{"tool_mode" => "future_mode", "multi_agent_version" => "v9"}), []},
      {"shell_type aliases", Map.put(base, "shell_type", "default"), []},
      {"shell_type local", Map.put(base, "shell_type", "local"), []},
      {"negative priority", Map.put(base, "priority", -5), []},
      {"unknown guardian modes", Map.put(base, "guardian", %{"shell" => "future_mode", "other_tools" => "future_mode"}), []},
      {"unknown access program", Map.put(base, "available_access_programs", %{"cyber" => ["future_program"]}), []},
      {"skip-deserialized field of any type", Map.put(base, "used_fallback_model_metadata", "not a bool"), []},
      {"enum as a one-key object", put_in(base, ["truncation_policy", "mode"], %{"bytes" => nil}), []},
      {"struct as a positional array", Map.put(base, "truncation_policy", ["tokens", 5]), []},
      {"upgrade with any retirement value", Map.put(base, "upgrade", %{"model" => "gpt-next", "migration_markdown" => "", "retirement_at" => 12}), []},
      {"empty strings", Map.merge(base, %{"slug" => "", "display_name" => "", "description" => ""}), []}
    ]

    missing ++ broken ++ tolerated
  end

  @doc """
  Entries the released client rejects that the contract deliberately does not
  judge: fields added inside the verified window and nested `model_messages`
  and `guardian` structures, which an older client in the window ignores.
  The Pooler never writes any of them; they come verbatim from the provider.
  """
  @spec blind_vectors() :: [{String.t(), map()}]
  def blind_vectors do
    base = synced_source("gpt-vector")

    [
      {"access programs without cyber", Map.put(base, "available_access_programs", %{})},
      {"string reasoning-effort-updates flag", Map.put(base, "supports_reasoning_effort_updates", "yes")},
      {"string guardian policy", Map.put(base, "guardian", "adaptive")},
      {"string approvals messages", put_in(base, ["model_messages", "approvals"], "text")}
    ]
  end

  defp model(slug) do
    %Model{
      id: nil,
      exposed_model_id: slug,
      upstream_model_id: "provider-#{slug}",
      display_name: "Synthetic #{slug}",
      status: "active",
      supports_responses: true,
      supports_streaming: true,
      supports_tools: true,
      supports_reasoning: true,
      metadata: %{}
    }
  end

  defp unrestricted_policy do
    %{allowed_model_identifiers: nil, enforced_model_identifier: nil, enforced_reasoning_effort: nil, maximum_reasoning_effort: nil}
  end

  defp policy(overrides), do: Map.merge(unrestricted_policy(), Map.new(overrides))
end
