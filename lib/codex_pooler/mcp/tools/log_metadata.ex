defmodule CodexPooler.MCP.Tools.LogMetadata do
  @moduledoc """
  Metadata-only MCP tools for request logs and audit logs.
  """

  alias CodexPooler.Accounting
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Audit
  alias CodexPooler.MCP.ToolRegistry
  alias CodexPooler.MCP.Tools.DetailEnvelope
  alias CodexPooler.MCP.Tools.LogMetadata.{AuditLogPresenter, RequestLogPresenter}
  alias CodexPooler.Pools

  @default_limit 25
  @max_limit 50

  @read_only_annotations %{
    "readOnlyHint" => true,
    "destructiveHint" => false,
    "idempotentHint" => true,
    "openWorldHint" => false
  }

  @spec tools() :: [map()]
  def tools do
    [
      list_request_logs_tool(),
      get_request_log_tool(),
      list_audit_logs_tool(),
      get_audit_log_tool()
    ]
  end

  @spec list_request_logs(map(), map()) :: {:ok, map(), String.t()} | {:error, map()}
  def list_request_logs(arguments, context) do
    limit = limit_arg(arguments)
    offset = offset_arg(arguments)

    with {:ok, scope} <- scope_from_context(context),
         {:ok, filters} <- request_log_filters(arguments),
         {:ok, page} <- request_log_page(scope, arguments, limit, offset, filters) do
      structured = page_output(page, &RequestLogPresenter.list_item/1)
      {:ok, structured, RequestLogPresenter.list_text(structured)}
    end
  end

  @spec get_request_log(map(), map()) :: {:ok, map(), String.t()} | {:error, map()}
  def get_request_log(%{"id" => id}, context) do
    with {:ok, scope} <- scope_from_context(context) do
      scope
      |> request_log_detail(id)
      |> detail_output(&RequestLogPresenter.item/1, "request_log")
      |> then(fn structured -> {:ok, structured, RequestLogPresenter.detail_text(structured)} end)
    end
  end

  @spec list_audit_logs(map(), map()) :: {:ok, map(), String.t()} | {:error, map()}
  def list_audit_logs(arguments, context) do
    limit = limit_arg(arguments)
    offset = offset_arg(arguments)

    with {:ok, scope} <- scope_from_context(context),
         {:ok, filters} <- audit_log_filters(arguments),
         {:ok, page} <- audit_log_page(scope, arguments, limit, offset, filters) do
      structured = page_output(page, &AuditLogPresenter.item/1)
      {:ok, structured, AuditLogPresenter.list_text(structured)}
    end
  end

  @spec get_audit_log(map(), map()) :: {:ok, map(), String.t()} | {:error, map()}
  def get_audit_log(%{"id" => id}, context) do
    with {:ok, scope} <- scope_from_context(context) do
      scope
      |> audit_log_detail(id)
      |> detail_output(&AuditLogPresenter.item/1, "audit_log")
      |> then(fn structured -> {:ok, structured, AuditLogPresenter.detail_text(structured)} end)
    end
  end

  def get_audit_log(_arguments, _context), do: mcp_actor_unavailable()

  defp list_request_logs_tool do
    %{
      name: "codex_pooler_list_request_logs",
      title: "List request-log metadata",
      description:
        ToolRegistry.metadata_description(
          use_when:
            "an operator needs a bounded, read-only MCP summary of runtime request logs for visible Pools",
          returns:
            "concise metadata rows with pool, route, status, model, usage, timing, retry, safe routing, and sanitized metadata summaries",
          never_returns:
            "raw URLs with secrets, query strings, files, websocket frames, raw idempotency keys, upload URLs, raw API keys, or raw gateway debug payloads",
          filters_limits:
            "accepts optional pool_id, status, model, request_id, upstream_identity_id, date_from, date_to, limit, and offset; limit is clamped to 1-50 and output is sorted newest first"
        ),
      input_schema: request_logs_input_schema(),
      output_schema: request_logs_page_output_schema(),
      annotations: @read_only_annotations,
      handler: {__MODULE__, :list_request_logs}
    }
  end

  defp list_audit_logs_tool do
    %{
      name: "codex_pooler_list_audit_logs",
      title: "List audit-log metadata",
      description:
        ToolRegistry.metadata_description(
          use_when:
            "an operator needs a bounded, read-only MCP summary of administrative audit events for visible Pools",
          returns:
            "concise metadata rows with actor class, masked actor identity, action, target, outcome, request correlation, pool, time, and re-sanitized detail summaries",
          never_returns:
            "raw before/after blobs, dirty details blobs, secret settings, websocket frames, bearer tokens, raw idempotency keys, temporary passwords, TOTP secrets, recovery secrets, SMTP secrets, metrics HMACs, or fingerprints",
          filters_limits:
            "accepts optional pool_id, outcome, actor_type, actor, action, target, request, date_from, date_to, limit, and offset; limit is clamped to 1-50 and output is sorted newest first"
        ),
      input_schema: audit_logs_input_schema(),
      output_schema: page_output_schema(),
      annotations: @read_only_annotations,
      handler: {__MODULE__, :list_audit_logs}
    }
  end

  defp get_request_log_tool do
    %{
      name: "codex_pooler_get_request_log",
      title: "Get request-log metadata",
      description:
        ToolRegistry.metadata_description(
          use_when:
            "an operator needs one exact request-log metadata record by id for a visible Pool",
          returns:
            "a concise found/not-found envelope with the same sanitized pool, route, status, model, usage, timing, retry, safe routing, and metadata summary fields as the bounded list tool",
          never_returns:
            "raw URLs with secrets, query strings, files, websocket frames, raw idempotency keys, upload URLs, raw API keys, or raw gateway debug payloads",
          filters_limits:
            "requires id; lookup is exact, scoped to the authenticated operator's visible Pools, and returns at most one metadata row"
        ),
      input_schema: detail_input_schema(),
      output_schema: detail_output_schema(),
      annotations: @read_only_annotations,
      handler: {__MODULE__, :get_request_log}
    }
  end

  defp get_audit_log_tool do
    %{
      name: "codex_pooler_get_audit_log",
      title: "Get audit-log metadata",
      description:
        ToolRegistry.metadata_description(
          use_when:
            "an operator needs one exact administrative audit-event metadata record by id for a visible Pool",
          returns:
            "a concise found/not-found envelope with the same sanitized actor, target, outcome, request correlation, pool, time, and re-sanitized detail summaries as the bounded list tool",
          never_returns:
            "raw before/after blobs, dirty details blobs, secret settings, websocket frames, bearer tokens, raw idempotency keys, temporary passwords, TOTP secrets, recovery secrets, SMTP secrets, metrics HMACs, or fingerprints",
          filters_limits:
            "requires id; lookup is exact, scoped to the authenticated operator's visible Pools, with owner-only system events, and returns at most one metadata row"
        ),
      input_schema: detail_input_schema(),
      output_schema: detail_output_schema(),
      annotations: @read_only_annotations,
      handler: {__MODULE__, :get_audit_log}
    }
  end

  defp request_logs_input_schema do
    strict_schema(%{
      "pool_id" => string_property(),
      "status" => string_property(),
      "model" => string_property(),
      "request_id" => string_property(),
      "upstream_identity_id" => string_property(),
      "date_from" => string_property(),
      "date_to" => string_property(),
      "limit" => integer_property(),
      "offset" => integer_property()
    })
  end

  defp audit_logs_input_schema do
    strict_schema(%{
      "pool_id" => string_property(),
      "outcome" => string_property(),
      "actor_type" => string_property(),
      "actor" => string_property(),
      "action" => string_property(),
      "target" => string_property(),
      "request" => string_property(),
      "date_from" => string_property(),
      "date_to" => string_property(),
      "limit" => integer_property(),
      "offset" => integer_property()
    })
  end

  defp detail_input_schema do
    %{
      "type" => "object",
      "properties" => %{"id" => string_property()},
      "required" => ["id"],
      "additionalProperties" => false
    }
  end

  defp page_output_schema do
    %{
      "type" => "object",
      "required" => ["items", "total", "limit", "offset", "nextOffset"],
      "additionalProperties" => false,
      "properties" => %{
        "items" => %{"type" => "array"},
        "total" => %{"type" => "integer"},
        "limit" => %{"type" => "integer"},
        "offset" => %{"type" => "integer"},
        "nextOffset" => %{"type" => ["integer", "null"]}
      }
    }
  end

  defp request_logs_page_output_schema do
    %{
      "type" => "object",
      "required" => ["items", "total", "limit", "offset", "nextOffset"],
      "additionalProperties" => false,
      "properties" => %{
        "items" => %{"type" => "array", "items" => request_log_item_output_schema()},
        "total" => %{"type" => "integer"},
        "limit" => %{"type" => "integer"},
        "offset" => %{"type" => "integer"},
        "nextOffset" => %{"type" => ["integer", "null"]}
      }
    }
  end

  defp request_log_item_output_schema do
    %{
      "type" => "object",
      "properties" => %{
        "debug" => %{
          "type" => "object",
          "required" => ["continuity", "failure", "attempt"],
          "additionalProperties" => false,
          "properties" => %{
            "continuity" => request_log_continuity_output_schema(),
            "failure" => request_log_failure_output_schema(),
            "attempt" => request_log_attempt_output_schema()
          }
        }
      }
    }
  end

  defp request_log_continuity_output_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "status" => nullable_string_property(),
        "session_ref" => nullable_string_property(),
        "session_source" => nullable_string_property(),
        "turn_ref" => nullable_string_property(),
        "turn_status" => nullable_string_property(),
        "turn_status_source" => nullable_string_property(),
        "has_open_turn" => %{"type" => ["boolean", "null"]},
        "terminal_state" => nullable_string_property(),
        "terminal_state_source" => nullable_string_property()
      }
    }
  end

  defp request_log_failure_output_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "error_code" => nullable_string_property(),
        "error_source" => nullable_string_property()
      }
    }
  end

  defp request_log_attempt_output_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "latest_attempt_number" => %{"type" => ["integer", "null"]},
        "latest_attempt_status" => nullable_string_property(),
        "latest_attempt_retryable" => %{"type" => ["boolean", "null"]},
        "latest_upstream_status_code" => %{"type" => ["integer", "null"]},
        "attempt_count" => %{"type" => "integer"}
      }
    }
  end

  defp detail_output_schema do
    DetailEnvelope.output_schema()
  end

  defp strict_schema(properties) do
    %{
      "type" => "object",
      "properties" => properties,
      "required" => [],
      "additionalProperties" => false
    }
  end

  defp string_property, do: %{"type" => "string"}
  defp nullable_string_property, do: %{"type" => ["string", "null"]}
  defp integer_property, do: %{"type" => "integer"}

  defp request_log_page(scope, arguments, limit, offset, filters) do
    pool_id = string_arg(arguments, "pool_id")

    cond do
      is_nil(pool_id) ->
        {:ok,
         Accounting.list_request_logs_for_scope(scope,
           limit: limit,
           offset: offset,
           filters: filters
         )}

      visible_pool_id?(scope, pool_id) ->
        {:ok,
         Accounting.list_request_logs(pool_id, limit: limit, offset: offset, filters: filters)}

      true ->
        {:ok, empty_page(limit, offset)}
    end
  end

  defp audit_log_page(scope, arguments, limit, offset, filters) do
    pool_id = string_arg(arguments, "pool_id")

    cond do
      is_nil(pool_id) ->
        {:ok, Audit.list_events_for_scope(scope, limit: limit, offset: offset, filters: filters)}

      visible_pool_id?(scope, pool_id) ->
        {:ok, Audit.list_events(pool_id, limit: limit, offset: offset, filters: filters)}

      true ->
        {:ok, empty_page(limit, offset)}
    end
  end

  defp request_log_detail(scope, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        Accounting.get_request_log_for_scope(scope, uuid)

      :error ->
        nil
    end
  end

  defp audit_log_detail(scope, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        page = Audit.list_events_for_scope(scope, limit: 1, filters: [id: uuid])
        Enum.find(page.items, &(&1.id == uuid))

      :error ->
        nil
    end
  end

  defp scope_from_context(%{auth: %{scope: %Scope{} = scope}}), do: {:ok, scope}

  defp scope_from_context(%{auth: %{operator: operator}}), do: {:ok, Scope.for_user(operator)}

  defp scope_from_context(_context), do: mcp_actor_unavailable()

  defp mcp_actor_unavailable do
    {:error, %{code: :tool_execution_failed, message: "MCP authenticated actor is unavailable"}}
  end

  defp request_log_filters(arguments) do
    with {:ok, date_from} <- date_filter(arguments, "date_from", :start),
         {:ok, date_to} <- date_filter(arguments, "date_to", :end) do
      {:ok,
       [
         status: string_arg(arguments, "status"),
         model: string_arg(arguments, "model"),
         request_id: string_arg(arguments, "request_id"),
         upstream_identity_id: string_arg(arguments, "upstream_identity_id"),
         date_from: date_from,
         date_to: date_to
       ]
       |> reject_nil_values()}
    end
  end

  defp audit_log_filters(arguments) do
    with {:ok, date_from} <- date_filter(arguments, "date_from", :start),
         {:ok, date_to} <- date_filter(arguments, "date_to", :end) do
      {:ok,
       [
         outcome: string_arg(arguments, "outcome"),
         actor_type: string_arg(arguments, "actor_type"),
         actor: string_arg(arguments, "actor"),
         action: string_arg(arguments, "action"),
         target: string_arg(arguments, "target"),
         request: string_arg(arguments, "request"),
         date_from: date_from,
         date_to: date_to
       ]
       |> reject_nil_values()}
    end
  end

  defp page_output(page, item_fun) do
    items = Enum.map(page.items, item_fun)

    %{
      "items" => items,
      "total" => page.total,
      "limit" => page.limit,
      "offset" => page.offset,
      "nextOffset" => next_offset(page)
    }
  end

  defp detail_output(nil, _item_fun, kind),
    do: DetailEnvelope.not_found(kind, "#{kind} selector did not match")

  defp detail_output(item, item_fun, kind) do
    DetailEnvelope.ok(kind, item_fun.(item))
  end

  defp next_offset(%{offset: offset, limit: limit, total: total}) when offset + limit < total,
    do: offset + limit

  defp next_offset(_page), do: nil

  defp visible_pool_id?(scope, pool_id) do
    scope
    |> Pools.list_log_filter_pools()
    |> Enum.any?(&(&1.id == pool_id))
  end

  defp empty_page(limit, offset), do: %{items: [], total: 0, limit: limit, offset: offset}

  defp limit_arg(arguments) do
    case Map.get(arguments, "limit") do
      limit when is_integer(limit) -> limit |> max(1) |> min(@max_limit)
      _other -> @default_limit
    end
  end

  defp offset_arg(arguments) do
    case Map.get(arguments, "offset") do
      offset when is_integer(offset) -> max(offset, 0)
      _other -> 0
    end
  end

  defp date_filter(arguments, key, boundary) do
    case string_arg(arguments, key) do
      nil ->
        {:ok, nil}

      value ->
        parse_date_filter(value, key, boundary)
    end
  end

  defp parse_date_filter(value, key, boundary) do
    with {:error, _reason} <- DateTime.from_iso8601(value),
         {:error, _reason} <- Date.from_iso8601(value) do
      {:error, %{code: :invalid_arguments, message: "Invalid #{key}"}}
    else
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:ok, date} -> {:ok, date_boundary(date, boundary)}
    end
  end

  defp date_boundary(date, :end), do: DateTime.new!(date, ~T[23:59:59.999999], "Etc/UTC")
  defp date_boundary(date, _boundary), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")

  defp string_arg(arguments, key) do
    arguments
    |> Map.get(key)
    |> blank_to_nil()
  end

  defp reject_nil_values(filters), do: Enum.reject(filters, fn {_key, value} -> is_nil(value) end)

  defp blank_to_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp blank_to_nil(_value), do: nil
end
