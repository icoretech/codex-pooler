defmodule CodexPooler.MCP.Tools.PoolMetadata.Common do
  @moduledoc false

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.MCP.PrivacyMatrix
  alias CodexPooler.MCP.Tools.DetailEnvelope
  alias CodexPooler.Pools
  alias CodexPooler.Pools.Pool

  @default_limit 25
  @max_limit 100

  @read_only_annotations %{
    "readOnlyHint" => true,
    "destructiveHint" => false,
    "idempotentHint" => true,
    "openWorldHint" => false
  }

  @selector_schema %{
    "type" => "object",
    "properties" => %{
      "selector" => %{"type" => "string"}
    },
    "required" => ["selector"],
    "additionalProperties" => false
  }

  @list_schema %{
    "type" => "object",
    "properties" => %{
      "query" => %{"type" => "string"},
      "status" => %{"type" => "string"},
      "pool_selector" => %{"type" => "string"},
      "limit" => %{"type" => "integer"}
    },
    "required" => [],
    "additionalProperties" => false
  }

  @list_output_schema %{
    "type" => "object",
    "required" => ["status", "count", "limit", "items"],
    "additionalProperties" => false,
    "properties" => %{
      "status" => %{"type" => "string"},
      "count" => %{"type" => "integer"},
      "limit" => %{"type" => "integer"},
      "items" => %{"type" => "array"}
    }
  }

  @spec max_limit() :: pos_integer()
  def max_limit, do: @max_limit

  @spec read_only_annotations() :: map()
  def read_only_annotations, do: @read_only_annotations

  @spec selector_schema() :: map()
  def selector_schema, do: @selector_schema

  @spec list_schema() :: map()
  def list_schema, do: @list_schema

  @spec list_output_schema() :: map()
  def list_output_schema, do: @list_output_schema

  @spec get_output_schema() :: map()
  def get_output_schema, do: DetailEnvelope.output_schema()

  @spec scope_from_context(map()) :: {:ok, Scope.t()} | {:error, map()}
  def scope_from_context(%{auth: %{scope: %Scope{} = scope}}), do: {:ok, scope}

  def scope_from_context(%{auth: %{operator: operator}}), do: {:ok, Scope.for_user(operator)}

  def scope_from_context(_context) do
    {:error, %{code: :tool_execution_failed, message: "MCP authenticated actor is unavailable"}}
  end

  @spec required_argument(String.t()) :: {:error, map()}
  def required_argument(name) do
    {:error, %{code: :invalid_arguments, message: "#{name} is required"}}
  end

  @spec load_pools(Scope.t()) :: {:ok, [Pool.t()]}
  def load_pools(scope), do: {:ok, Pools.list_visible_pools(scope)}

  @spec resolve_optional_pool([Pool.t()], term()) :: {:ok, Pool.t() | nil} | {:error, map()}
  def resolve_optional_pool(_pools, selector) when selector in [nil, ""], do: {:ok, nil}

  def resolve_optional_pool(pools, selector) do
    case resolve_pool(pools, selector) do
      {:ok, pool} ->
        {:ok, pool}

      {:ambiguous, candidates} ->
        {:error, ambiguity_error("Pool selector matched #{length(candidates)} candidates")}

      :not_found ->
        {:error, %{code: :tool_execution_failed, message: "Pool selector did not match"}}
    end
  end

  @spec resolve_pool([Pool.t()], term()) ::
          {:ok, Pool.t()} | {:ambiguous, [Pool.t()]} | :not_found
  def resolve_pool(pools, selector) do
    selector = normalize_selector(selector)

    cond do
      pool = Enum.find(pools, &(&1.id == selector)) ->
        {:ok, pool}

      pool = Enum.find(pools, &(String.downcase(&1.slug || "") == selector)) ->
        {:ok, pool}

      true ->
        pools
        |> Enum.filter(&(String.downcase(&1.name || "") == selector))
        |> one_ambiguous_or_missing()
    end
  end

  @spec one_ambiguous_or_missing([term()]) :: {:ok, term()} | {:ambiguous, [term()]} | :not_found
  def one_ambiguous_or_missing([item]), do: {:ok, item}
  def one_ambiguous_or_missing([]), do: :not_found
  def one_ambiguous_or_missing(items), do: {:ambiguous, items}

  @spec filter_by_status([term()], term()) :: [term()]
  def filter_by_status(items, status) when status in [nil, "", "all"], do: items

  def filter_by_status(items, status) do
    normalized = normalize_selector(status)
    Enum.filter(items, &(String.downcase(Map.get(&1, :status, "")) == normalized))
  end

  @spec filter_by_query([term()], term(), (term() -> String.t())) :: [term()]
  def filter_by_query(items, query, _search_fun) when query in [nil, ""], do: items

  def filter_by_query(items, query, search_fun) do
    normalized = normalize_selector(query)
    Enum.filter(items, &(search_fun.(&1) |> String.contains?(normalized)))
  end

  @spec bounded_limit(map()) :: pos_integer()
  def bounded_limit(%{"limit" => limit}) when is_integer(limit) do
    limit |> max(1) |> min(@max_limit)
  end

  def bounded_limit(_arguments), do: @default_limit

  @spec normalize_selector(term()) :: String.t()
  def normalize_selector(selector),
    do: selector |> to_string() |> String.trim() |> String.downcase()

  @spec searchable([term()]) :: String.t()
  def searchable(parts) do
    parts
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(" ", &to_string/1)
    |> String.downcase()
  end

  @spec summary_text(map(), String.t()) :: String.t() | nil
  def summary_text(item, key) do
    case Map.get(item, key) do
      %{"summary" => summary} -> summary
      _other -> nil
    end
  end

  @spec timestamp(term()) :: String.t() | nil
  def timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def timestamp(_value), do: nil

  @spec workspace_ref(term()) :: String.t()
  def workspace_ref(nil), do: "legacy"

  def workspace_ref(workspace_id) when is_binary(workspace_id) do
    digest =
      :crypto.hash(:sha256, workspace_id) |> Base.encode16(case: :lower) |> String.slice(0, 8)

    "ws:" <> digest
  end

  def workspace_ref(_workspace_id), do: "legacy"

  @spec metadata_status(term()) :: String.t()
  def metadata_status(metadata) when is_map(metadata) and map_size(metadata) > 0, do: "present"
  def metadata_status(_metadata), do: "empty"

  @spec safe_label(term()) :: term()
  def safe_label(value) when is_binary(value) do
    if String.match?(value, ~r/^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/) do
      PrivacyMatrix.project!(:operators, %{email: value})[:email]
    else
      value
    end
  end

  def safe_label(value), do: value

  @spec stringify_keys(term()) :: term()
  def stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  def stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  def stringify_keys(value), do: value

  @spec ambiguity_error(String.t()) :: map()
  def ambiguity_error(message), do: %{code: :tool_execution_failed, message: message}
end
