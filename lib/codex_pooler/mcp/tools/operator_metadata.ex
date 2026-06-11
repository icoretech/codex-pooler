defmodule CodexPooler.MCP.Tools.OperatorMetadata do
  @moduledoc """
  Metadata-only MCP tools for operator and invite records.
  """

  import Ecto.Query

  alias CodexPooler.Access
  alias CodexPooler.Accounts
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.MCP
  alias CodexPooler.MCP.{OperatorMCPKey, PrivacyMatrix}
  alias CodexPooler.MCP.ToolRegistry
  alias CodexPooler.MCP.Tools.DetailEnvelope
  alias CodexPooler.MCP.Tools.ReadableText
  alias CodexPooler.Pools
  alias CodexPooler.Repo

  @default_limit 50
  @max_limit 100
  @read_only_annotations %{
    "readOnlyHint" => true,
    "destructiveHint" => false,
    "idempotentHint" => true,
    "openWorldHint" => false
  }

  @list_input_schema %{
    "type" => "object",
    "properties" => %{
      "limit" => %{"type" => "integer"},
      "status" => %{"type" => "string"},
      "query" => %{"type" => "string"}
    },
    "required" => [],
    "additionalProperties" => false
  }

  @get_input_schema %{
    "type" => "object",
    "properties" => %{"selector" => %{"type" => "string"}},
    "required" => ["selector"],
    "additionalProperties" => false
  }

  @list_invites_input_schema %{
    "type" => "object",
    "properties" => %{
      "limit" => %{"type" => "integer"},
      "status" => %{"type" => "string"},
      "pool_id" => %{"type" => "string"},
      "email" => %{"type" => "string"}
    },
    "required" => [],
    "additionalProperties" => false
  }

  @spec tools() :: [map()]
  def tools do
    [
      list_operators_tool(),
      get_operator_tool(),
      list_invites_tool(),
      get_invite_tool()
    ]
  end

  @spec list_operators(map(), map()) :: {:ok, map(), String.t()} | {:error, map()}
  def list_operators(arguments, context) do
    with {:ok, scope} <- scope_from_context(context) do
      limit = bounded_limit(arguments)
      status = blank_to_nil(Map.get(arguments, "status"))
      query = blank_to_nil(Map.get(arguments, "query"))

      operators =
        if Pools.owner?(scope) do
          Accounts.list_operators()
          |> filter_operator_status(status)
          |> filter_operator_query(query)
        else
          []
        end

      items =
        operators
        |> Enum.take(limit)
        |> Enum.map(&present_operator/1)

      structured = %{
        "operators" => items,
        "total" => length(operators),
        "limit" => limit,
        "filters" => filter_summary(%{status: status, query: query})
      }

      {:ok, structured, operator_list_text(structured)}
    end
  end

  @spec get_operator(map(), map()) :: {:ok, map(), String.t()} | {:error, map()}
  def get_operator(%{"selector" => selector}, context) do
    with {:ok, scope} <- scope_from_context(context),
         true <- Pools.owner?(scope) do
      selector
      |> String.trim()
      |> operator_match_result()
    else
      false -> operator_not_found()
      error -> error
    end
  end

  @spec list_invites(map(), map()) :: {:ok, map(), String.t()} | {:error, map()}
  def list_invites(arguments, context) do
    with {:ok, scope} <- scope_from_context(context) do
      limit = bounded_limit(arguments)
      filters = invite_filters(arguments)
      page = Access.list_invites(scope, limit: limit, filters: filters)
      items = Enum.map(page.items, &present_invite/1)

      structured = %{
        "invites" => items,
        "total" => page.total,
        "limit" => page.limit,
        "filters" => filter_summary(filters)
      }

      {:ok, structured, invite_list_text(structured)}
    end
  end

  @spec get_invite(map(), map()) :: {:ok, map(), String.t()} | {:error, map()}
  def get_invite(%{"selector" => selector}, context) do
    with {:ok, scope} <- scope_from_context(context) do
      selector = String.trim(selector)

      case invite_matches(scope, selector) do
        [] ->
          {:ok, DetailEnvelope.not_found("invite", "Invite selector did not match"),
           ReadableText.not_found("invite metadata record")}

        [invite] ->
          presented = present_invite(invite)

          {:ok, DetailEnvelope.ok("invite", presented), invite_text(presented)}

        matches ->
          candidates = Enum.map(matches, &invite_candidate/1)

          {:ok, DetailEnvelope.ambiguous("invite", candidates, "Invite selector is ambiguous"),
           ReadableText.ambiguous("invite metadata record", candidates, invite_candidate_fields())}
      end
    end
  end

  defp operator_match_result(selector) do
    case operator_matches(selector) do
      [] ->
        operator_not_found()

      [operator] ->
        presented = present_operator(operator)

        {:ok, DetailEnvelope.ok("operator", presented), operator_text(presented)}

      matches ->
        candidates = Enum.map(matches, &operator_candidate/1)

        {:ok, DetailEnvelope.ambiguous("operator", candidates, "Operator selector is ambiguous"),
         ReadableText.ambiguous(
           "operator metadata record",
           candidates,
           operator_candidate_fields()
         )}
    end
  end

  defp list_operators_tool do
    %{
      name: "codex_pooler_list_operators",
      title: "List operators",
      description:
        ToolRegistry.metadata_description(
          use_when:
            "an MCP client needs bounded owner-only discovery of Codex Pooler operator accounts before selecting one for detail lookup",
          returns:
            "masked operator metadata, account status, password-change requirement, TOTP status, MCP gate summary, MCP key count, and timestamps",
          never_returns:
            "password hashes, temporary passwords, session tokens, TOTP secrets, recovery secrets, MCP tokens, or MCP token hashes",
          filters_limits:
            "owner-only; optional status and query filters are applied in memory to active operator rows; limit is clamped to 1..100 and defaults to 50"
        ),
      input_schema: @list_input_schema,
      output_schema: list_output_schema("operators"),
      annotations: @read_only_annotations,
      handler: {__MODULE__, :list_operators}
    }
  end

  defp get_operator_tool do
    %{
      name: "codex_pooler_get_operator",
      title: "Get operator",
      description:
        ToolRegistry.metadata_description(
          use_when:
            "an MCP client needs one owner-only operator metadata record by id, masked email, or display-name/email selector",
          returns:
            "one masked operator metadata record, a not-found marker, or structured ambiguity candidates when the selector matches multiple operators",
          never_returns:
            "password hashes, temporary passwords, session tokens, TOTP secrets, recovery secrets, MCP tokens, or MCP token hashes",
          filters_limits:
            "owner-only; selector is required; ambiguity candidates are bounded to 10 and no arbitrary first match is chosen"
        ),
      input_schema: @get_input_schema,
      output_schema: get_output_schema(),
      annotations: @read_only_annotations,
      handler: {__MODULE__, :get_operator}
    }
  end

  defp list_invites_tool do
    %{
      name: "codex_pooler_list_invites",
      title: "List invites",
      description:
        ToolRegistry.metadata_description(
          use_when:
            "an MCP client needs bounded discovery of pool invite metadata visible to the authenticated operator",
          returns:
            "masked invite recipient metadata, pool metadata, invite status, acceptance/send/revocation timestamps, and creator id summary",
          never_returns: "invite tokens, invite URLs, token hashes, or Pool API keys",
          filters_limits:
            "optional status, pool_id, and email filters use the existing invite read model; limit is clamped to 1..100 and defaults to 50"
        ),
      input_schema: @list_invites_input_schema,
      output_schema: list_output_schema("invites"),
      annotations: @read_only_annotations,
      handler: {__MODULE__, :list_invites}
    }
  end

  defp get_invite_tool do
    %{
      name: "codex_pooler_get_invite",
      title: "Get invite",
      description:
        ToolRegistry.metadata_description(
          use_when:
            "an MCP client needs one pool invite metadata record by id, pool slug, pool name, status, or recipient selector",
          returns:
            "one masked invite metadata record, a not-found marker, or structured ambiguity candidates when the selector matches multiple invites",
          never_returns: "invite tokens, invite URLs, token hashes, or Pool API keys",
          filters_limits:
            "selector is required; visible invites are capped before matching and ambiguity candidates are bounded to 10"
        ),
      input_schema: @get_input_schema,
      output_schema: get_output_schema(),
      annotations: @read_only_annotations,
      handler: {__MODULE__, :get_invite}
    }
  end

  defp list_output_schema(item_key) do
    %{
      "type" => "object",
      "required" => [item_key, "total", "limit", "filters"],
      "additionalProperties" => false,
      "properties" => %{
        item_key => %{"type" => "array"},
        "total" => %{"type" => "integer"},
        "limit" => %{"type" => "integer"},
        "filters" => %{"type" => "object"}
      }
    }
  end

  defp get_output_schema, do: DetailEnvelope.output_schema()

  defp present_operator(operator) do
    projected =
      :operators
      |> PrivacyMatrix.project!(%{
        id: operator.id,
        display_name: operator.display_name || "Operator",
        email: operator.email,
        status: operator.status,
        password_change_required: operator.password_change_required,
        totp_status: operator.totp_status || "disabled",
        mcp_enabled: MCP.operator_mcp_enabled?(operator),
        mcp_key_count: mcp_key_count(operator.id),
        last_login_at: operator.last_login_at,
        created_at: operator.created_at,
        updated_at: operator.updated_at,
        deleted_at: operator.deleted_at
      })

    stringify_keys(projected)
  end

  defp present_invite(invite) do
    projected =
      :invites
      |> PrivacyMatrix.project!(%{
        id: invite.id,
        pool_id: invite.pool_id,
        pool_name: invite.pool_name,
        pool_slug: invite.pool_slug,
        status: invite.status,
        expires_at: invite.expires_at,
        created_at: invite.created_at,
        accepted_at: invite.accepted_at,
        email_sent_at: invite.email_sent_at,
        revoked_at: invite.revoked_at,
        invited_email: invite.invited_email,
        accepted_by_email: invite.accepted_by_email,
        created_by_user_id: invite[:created_by_user_id]
      })

    stringify_keys(projected)
  end

  defp operator_matches(selector) do
    operators = Accounts.list_operators()

    exact_id = Enum.filter(operators, &(&1.id == selector))

    case exact_id do
      [_operator] -> exact_id
      [] -> operators |> filter_operator_query(selector) |> Enum.take(10)
    end
  end

  defp operator_not_found do
    {:ok, DetailEnvelope.not_found("operator", "Operator selector did not match"),
     ReadableText.not_found("operator metadata record")}
  end

  defp invite_matches(scope, selector) do
    page = Access.list_invites(scope, limit: @max_limit, filters: [])

    exact_id = Enum.filter(page.items, &(&1.id == selector))

    case exact_id do
      [_invite] -> exact_id
      [] -> page.items |> filter_invite_selector(selector) |> Enum.take(10)
    end
  end

  defp filter_operator_status(operators, nil), do: operators

  defp filter_operator_status(operators, status),
    do: Enum.filter(operators, &(&1.status == status))

  defp filter_operator_query(operators, nil), do: operators

  defp filter_operator_query(operators, query) do
    needle = String.downcase(String.trim(query))

    Enum.filter(operators, fn operator ->
      [operator.email, operator.display_name, operator.id]
      |> Enum.reject(&is_nil/1)
      |> Enum.any?(&String.contains?(String.downcase(&1), needle))
    end)
  end

  defp filter_invite_selector(invites, selector) do
    needle = String.downcase(String.trim(selector))

    Enum.filter(invites, fn invite ->
      [
        invite.invited_email,
        invite.accepted_by_email,
        invite.pool_slug,
        invite.pool_name,
        invite.status
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.any?(&String.contains?(String.downcase(&1), needle))
    end)
  end

  defp operator_candidate(operator) do
    operator
    |> present_operator()
    |> Map.take(["id", "display_name", "email", "status"])
  end

  defp invite_candidate(invite) do
    invite
    |> present_invite()
    |> Map.take(["id", "pool_name", "pool_slug", "invited_email", "status"])
  end

  defp scope_from_context(%{auth: %{scope: %Scope{} = scope}}), do: {:ok, scope}

  defp scope_from_context(%{auth: %{operator: operator}}), do: {:ok, Scope.for_user(operator)}

  defp scope_from_context(_context) do
    {:error, %{code: :tool_execution_failed, message: "MCP authenticated actor is unavailable"}}
  end

  defp bounded_limit(arguments) do
    case Map.get(arguments, "limit") do
      limit when is_integer(limit) -> limit |> max(1) |> min(@max_limit)
      _value -> @default_limit
    end
  end

  defp invite_filters(arguments) do
    %{}
    |> maybe_put_filter(:status, Map.get(arguments, "status"))
    |> maybe_put_filter(:pool_id, Map.get(arguments, "pool_id"))
    |> maybe_put_filter(:email, Map.get(arguments, "email"))
  end

  defp maybe_put_filter(filters, _key, nil), do: filters
  defp maybe_put_filter(filters, _key, ""), do: filters
  defp maybe_put_filter(filters, key, value), do: Map.put(filters, key, value)

  defp mcp_key_count(operator_id) do
    Repo.aggregate(from(key in OperatorMCPKey, where: key.operator_id == ^operator_id), :count)
  end

  defp filter_summary(filters) do
    applied =
      filters
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
      |> Enum.map(fn {key, _value} -> {Atom.to_string(key), %{"applied" => true}} end)
      |> Map.new()

    %{"count" => map_size(applied), "applied" => applied}
  end

  defp stringify_keys(map),
    do: Map.new(map, fn {key, value} -> {Atom.to_string(key), normalize_value(value)} end)

  defp normalize_value(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp normalize_value(value), do: value

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  defp operator_list_text(%{"operators" => operators, "total" => total}) do
    ReadableText.list(
      "operator metadata records",
      Enum.map(operators, &operator_text_row/1),
      operator_list_fields(),
      total: total
    )
  end

  defp invite_list_text(%{"invites" => invites, "total" => total}) do
    ReadableText.list(
      "invite metadata records",
      Enum.map(invites, &invite_text_row/1),
      invite_list_fields(),
      total: total
    )
  end

  defp operator_text(operator) do
    ReadableText.detail(
      "operator metadata record",
      operator_text_row(operator),
      operator_detail_fields()
    )
  end

  defp invite_text(invite) do
    ReadableText.detail(
      "invite metadata record",
      invite_text_row(invite),
      invite_detail_fields()
    )
  end

  defp operator_text_row(operator) do
    operator
    |> Map.take([
      "display_name",
      "status",
      "email",
      "mcp_key_count",
      "password_change_required",
      "totp_status",
      "created_at",
      "updated_at"
    ])
    |> Map.put("mcp", gate_text(operator["mcp_enabled"]))
  end

  defp invite_text_row(invite) do
    invite
    |> Map.take([
      "status",
      "invited_email",
      "email_sent_at",
      "created_at",
      "created_by_user_id"
    ])
    |> Map.put("pool", invite["pool_slug"] || invite["pool_name"])
    |> Map.put("accepted", invite["accepted_at"] || "none")
  end

  defp operator_list_fields do
    [
      {"display_name", "name", required: true},
      {"status", "status", required: true},
      {"email", "email", required: true},
      {"mcp", "mcp", required: true},
      {"mcp_key_count", "keys", required: true},
      {"password_change_required", "password_change_required"},
      {"totp_status", "totp"}
    ]
  end

  defp operator_detail_fields do
    operator_list_fields() ++
      [
        {"created_at", "created"},
        {"updated_at", "updated"}
      ]
  end

  defp operator_candidate_fields do
    [
      {"display_name", "name", required: true},
      {"status", "status", required: true},
      {"email", "email", required: true},
      {"id", "id"}
    ]
  end

  defp invite_list_fields do
    [
      {"status", "status", required: true},
      {"invited_email", "recipient", required: true},
      {"pool", "pool", required: true},
      {"email_sent_at", "sent", required: true},
      {"accepted", "accepted", required: true}
    ]
  end

  defp invite_detail_fields do
    invite_list_fields() ++
      [
        {"created_by_user_id", "creator"}
      ]
  end

  defp invite_candidate_fields do
    [
      {"status", "status", required: true},
      {"invited_email", "recipient", required: true},
      {"pool_slug", "pool", required: true},
      {"id", "id"}
    ]
  end

  defp gate_text(true), do: "enabled"
  defp gate_text(false), do: "disabled"
  defp gate_text(_value), do: "unknown"
end
