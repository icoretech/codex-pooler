defmodule CodexPooler.Gateway.Metadata.CodexModelDecodeContract do
  @moduledoc """
  The part of the Codex client's catalog decoder that makes a served model entry
  fail to decode, mirrored for the client versions it was verified against.

  Codex decodes the whole `/models` response as one `ModelsResponse`
  (`codex-rs/protocol/src/openai_models.rs`); one entry that fails the
  `ModelInfo` decode discards the whole catalog and the client falls back to
  its bundled one with only a log line (findings#258 row 258-34).

  The rules below are only those that make serde fail in every client release
  from `0.154.0` through `0.156.1` (every tag reporting those whole versions,
  alphas included): required fields, closed enums, scalar types and the
  instructions rule of `deserialize_model_infos_with_legacy_base`. Anything the
  client tolerates stays out: unknown fields, `#[serde(other)]` enums, any
  string in the tolerant selectors (`tool_mode`, `multi_agent_version`) and
  positional (array-encoded) structs are accepted, and fields added inside the window
  (`available_access_programs`, `supports_reasoning_effort_updates`,
  `supports_experimental_context`, `guardian`) and the nested `model_messages`
  sub-structures are not checked. The contract is therefore never stricter
  than a client inside the window; a client outside it is not judged at all
  (`CatalogRepresentation` serves it the unchecked catalog), because a later
  release may relax a rule and an older one lacks fields this contract types.
  """

  @verified_since {0, 154, 0}
  @verified_through {0, 156, 1}

  @i32_range -2_147_483_648..2_147_483_647
  @i64_range -9_223_372_036_854_775_808..9_223_372_036_854_775_807

  @reasoning_preset {:struct, %{"effort" => {:required, :effort}, "description" => {:required, :string}}}
  @service_tier {:struct, %{"id" => {:required, :string}, "name" => {:required, :string}, "description" => {:required, :string}}}

  # `{:required, type}`: no serde default, so missing or null fails.
  # `{:optional, type}`: `Option<T>`, so missing or null decodes to `None`.
  # `{:defaulted, type}`: `#[serde(default)]` on a non-`Option`, so missing is
  # fine and a present null fails.
  @fields %{
    "slug" => {:required, :string},
    "display_name" => {:required, :string},
    "description" => {:optional, :string},
    "default_reasoning_level" => {:optional, :effort},
    "supported_reasoning_levels" => {:required, {:list, @reasoning_preset}},
    "shell_type" => {:required, {:enum, ~w(unified_exec disabled default local shell_command)}},
    "visibility" => {:required, {:enum, ~w(list hide none)}},
    "supported_in_api" => {:required, :bool},
    "priority" => {:required, :i32},
    "additional_speed_tiers" => {:defaulted, {:list, :string}},
    "service_tiers" => {:defaulted, {:list, @service_tier}},
    "default_service_tier" => {:optional, :string},
    "availability_nux" => {:optional, {:struct, %{"message" => {:required, :string}}}},
    "upgrade" => {:optional, {:struct, %{"model" => {:required, :string}, "migration_markdown" => {:required, :string}}}},
    "model_messages" => {:optional, {:struct, %{"instructions_template" => {:optional, :string}}}},
    "include_skills_usage_instructions" => {:defaulted, :bool},
    "include_plugin_usage_instructions" => {:defaulted, :bool},
    "include_apps_usage_instructions" => {:defaulted, :bool},
    "supports_reasoning_summary_parameter" => {:defaulted, :bool},
    "default_reasoning_summary" => {:defaulted, {:enum, ~w(auto concise detailed none)}},
    "support_verbosity" => {:required, :bool},
    "default_verbosity" => {:optional, {:enum, ~w(low medium high)}},
    "apply_patch_tool_type" => {:optional, {:enum, ~w(freeform)}},
    "web_search_tool_type" => {:defaulted, {:enum, ~w(text text_and_image)}},
    "truncation_policy" => {:required, {:struct, %{"mode" => {:required, {:enum, ~w(bytes tokens)}}, "limit" => {:required, :i64}}}},
    "supports_image_detail_original" => {:defaulted, :bool},
    "context_window" => {:optional, :i64},
    "max_context_window" => {:optional, :i64},
    "auto_compact_token_limit" => {:optional, :i64},
    "comp_hash" => {:optional, :string},
    "effective_context_window_percent" => {:defaulted, :i64},
    "experimental_supported_tools" => {:required, {:list, :string}},
    "input_modalities" => {:defaulted, {:list, {:enum, ~w(text image audio)}}},
    "supports_search_tool" => {:defaulted, :bool},
    "use_responses_lite" => {:defaulted, :bool},
    "node_repl_auto_review_required" => {:defaulted, :bool},
    "node_repl_disabled" => {:defaulted, :bool},
    "auto_review_model_override" => {:optional, :string},
    "model_specialty" => {:optional, :string},
    "tool_mode" => {:optional, :string},
    "multi_agent_version" => {:optional, :string},
    "multi_agent_reasoning_effort" => {:optional, :effort},
    # The legacy top-level field the decoder promotes into the template.
    "base_instructions" => {:optional, :string}
  }

  @instructions_rule "base_instructions|model_messages.instructions_template"

  @doc "The first and last client whole versions the contract was verified against."
  @spec verified_range() :: {{non_neg_integer(), non_neg_integer(), non_neg_integer()}, {non_neg_integer(), non_neg_integer(), non_neg_integer()}}
  def verified_range, do: {@verified_since, @verified_through}

  @doc "Whether a client whole version `{major, minor, patch}` is inside the verified window."
  @spec verified_version?({non_neg_integer(), non_neg_integer(), non_neg_integer()}) :: boolean()
  def verified_version?({_major, _minor, _patch} = version),
    do: version >= @verified_since and version <= @verified_through

  @doc """
  The field paths that make this entry fail the client's decode, sorted by
  field name; `[]` for a decodable entry. Paths name fields only, never values.
  """
  @spec violations(term()) :: [String.t()]
  def violations(entry) when is_map(entry) do
    field_violations = struct_violations(entry, @fields, "")

    if instructions_present?(entry), do: field_violations, else: field_violations ++ [@instructions_rule]
  end

  def violations(_entry), do: ["<entry>"]

  # A model decodes only with a string template or a string legacy field to
  # promote into it. An array-encoded `model_messages` is decoded positionally
  # by the client and is not judged here.
  defp instructions_present?(entry) do
    is_binary(Map.get(entry, "base_instructions")) or
      case Map.get(entry, "model_messages") do
        %{"instructions_template" => template} -> is_binary(template)
        messages when is_list(messages) -> true
        _messages -> false
      end
  end

  defp struct_violations(map, fields, prefix) do
    fields
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {key, spec} -> field_violations(map, key, spec, prefix <> key) end)
  end

  defp field_violations(map, key, {presence, type}, path) do
    case {presence, Map.fetch(map, key)} do
      {:required, :error} -> [path]
      {:required, {:ok, nil}} -> [path]
      {:optional, :error} -> []
      {:optional, {:ok, nil}} -> []
      {:defaulted, :error} -> []
      {:defaulted, {:ok, nil}} -> [path]
      {_presence, {:ok, value}} -> type_violations(value, type, path)
    end
  end

  defp type_violations(value, :string, _path) when is_binary(value), do: []
  defp type_violations(value, :effort, _path) when is_binary(value) and value != "", do: []
  defp type_violations(value, :bool, _path) when is_boolean(value), do: []
  defp type_violations(value, :i32, _path) when is_integer(value) and value in @i32_range, do: []
  defp type_violations(value, :i64, _path) when is_integer(value) and value in @i64_range, do: []

  defp type_violations(value, {:enum, variants}, path) do
    if enum_value?(value, variants), do: [], else: [path]
  end

  defp type_violations(values, {:list, type}, path) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, index} -> element_violations(value, type, "#{path}[#{index}]") end)
  end

  defp type_violations(value, {:struct, fields}, path) when is_map(value),
    do: struct_violations(value, fields, path <> ".")

  # serde decodes a struct from a JSON array positionally; not judged here.
  defp type_violations(value, {:struct, _fields}, _path) when is_list(value), do: []
  defp type_violations(_value, _type, path), do: [path]

  defp element_violations(nil, _type, path), do: [path]
  defp element_violations(value, type, path), do: type_violations(value, type, path)

  # A unit variant decodes from its name, or from a one-key object naming it
  # with a null value.
  defp enum_value?(value, variants) when is_binary(value), do: value in variants

  defp enum_value?(value, variants) when is_map(value) do
    case Map.to_list(value) do
      [{variant, nil}] -> variant in variants
      _entries -> false
    end
  end

  defp enum_value?(_value, _variants), do: false
end
