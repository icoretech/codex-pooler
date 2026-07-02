defmodule CodexPooler.Alerts.IncidentMatchInput do
  @moduledoc false

  alias CodexPooler.Accounting
  alias CodexPooler.Alerts.Schemas.AlertIncident

  @input_keys ~w(
    dedupe_key scope_type rule_kind severity pool_id upstream_identity_id matched_at observed_at
    safe_evidence_snapshot suppression_metadata targets rule_id metadata cleared_at
  )a

  @type target_input :: %{
          required(:rule_id) => Ecto.UUID.t(),
          required(:pool_id) => Ecto.UUID.t(),
          optional(:metadata) => map()
        }
  @type match_attrs :: %{
          required(:dedupe_key) => String.t(),
          required(:scope_type) => AlertIncident.scope_type(),
          required(:rule_kind) => AlertIncident.rule_kind(),
          required(:severity) => AlertIncident.severity(),
          optional(:pool_id) => Ecto.UUID.t(),
          optional(:upstream_identity_id) => Ecto.UUID.t(),
          optional(:safe_evidence_snapshot) => map(),
          optional(:suppression_metadata) => map(),
          required(:targets) => [target_input()],
          optional(:matched_at) => DateTime.t()
        }
  @type clear_attrs :: %{
          required(:dedupe_key) => String.t(),
          optional(:cleared_at) => DateTime.t()
        }
  @type lifecycle_error :: %{required(:code) => atom(), required(:message) => String.t()}

  @spec normalize_match(map()) :: {:ok, match_attrs()} | {:error, lifecycle_error()}
  def normalize_match(attrs) when is_map(attrs) do
    attrs = atomized_attrs(attrs)
    timestamp = timestamp_attr(attrs, :matched_at) || timestamp_attr(attrs, :observed_at) || now()

    with {:ok, dedupe_key} <- required_string(attrs, :dedupe_key, "dedupe key is required"),
         {:ok, scope_type} <- allowed_string(attrs, :scope_type, AlertIncident.scope_types()),
         {:ok, rule_kind} <- allowed_string(attrs, :rule_kind, AlertIncident.rule_kinds()),
         {:ok, severity} <- allowed_string(attrs, :severity, AlertIncident.severities()),
         {:ok, scope_ids} <- scope_ids(scope_type, attrs),
         {:ok, targets} <- normalize_targets(Map.get(attrs, :targets)) do
      {:ok,
       Map.merge(scope_ids, %{
         dedupe_key: dedupe_key,
         scope_type: scope_type,
         rule_kind: rule_kind,
         severity: severity,
         safe_evidence_snapshot: safe_metadata_map(Map.get(attrs, :safe_evidence_snapshot, %{})),
         suppression_metadata: safe_metadata_map(Map.get(attrs, :suppression_metadata, %{})),
         targets: targets,
         matched_at: timestamp
       })}
    end
  end

  @spec normalize_clear(map()) :: {:ok, clear_attrs()} | {:error, lifecycle_error()}
  def normalize_clear(attrs) when is_map(attrs) do
    attrs = atomized_attrs(attrs)

    with {:ok, dedupe_key} <- required_string(attrs, :dedupe_key, "dedupe key is required") do
      {:ok, %{dedupe_key: dedupe_key, cleared_at: timestamp_attr(attrs, :cleared_at) || now()}}
    end
  end

  @spec lifecycle_error(atom(), String.t()) :: lifecycle_error()
  def lifecycle_error(code, message), do: %{code: code, message: message}

  defp scope_ids("pool", attrs) do
    with {:ok, pool_id} <- required_string(attrs, :pool_id, "pool id is required") do
      {:ok, %{pool_id: pool_id, upstream_identity_id: nil}}
    end
  end

  defp scope_ids("upstream_identity", attrs) do
    with {:ok, upstream_identity_id} <-
           required_string(attrs, :upstream_identity_id, "upstream identity id is required") do
      {:ok, %{pool_id: nil, upstream_identity_id: upstream_identity_id}}
    end
  end

  defp normalize_targets(targets) when is_list(targets) and targets != [] do
    targets
    |> Enum.reduce_while({:ok, []}, fn target, {:ok, acc} ->
      case normalize_target(target) do
        {:ok, target} -> {:cont, {:ok, [target | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, targets} ->
        {:ok, targets |> Enum.reverse() |> Enum.uniq_by(&{&1.rule_id, &1.pool_id})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_targets(_targets),
    do: {:error, lifecycle_error(:invalid_request, "incident targets must be a non-empty list")}

  defp normalize_target(target) when is_map(target) do
    target = atomized_attrs(target)

    with {:ok, rule_id} <- required_string(target, :rule_id, "target rule id is required"),
         {:ok, pool_id} <- required_string(target, :pool_id, "target pool id is required") do
      {:ok,
       %{
         rule_id: rule_id,
         pool_id: pool_id,
         metadata: safe_metadata_map(Map.get(target, :metadata, %{}))
       }}
    end
  end

  defp normalize_target(_target),
    do: {:error, lifecycle_error(:invalid_request, "incident target must be a map")}

  defp allowed_string(attrs, key, allowed) do
    with {:ok, value} <- required_string(attrs, key, "#{key} is required") do
      if value in allowed do
        {:ok, value}
      else
        {:error, lifecycle_error(:invalid_request, "#{key} is invalid")}
      end
    end
  end

  defp required_string(attrs, key, message) do
    case Map.get(attrs, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, lifecycle_error(:invalid_request, message)}
          trimmed -> {:ok, trimmed}
        end

      _value ->
        {:error, lifecycle_error(:invalid_request, message)}
    end
  end

  defp safe_metadata_map(value) when is_map(value) do
    case Accounting.sanitize_metadata(value) do
      sanitized when is_map(sanitized) -> sanitized
      _value -> %{}
    end
  end

  defp safe_metadata_map(_value), do: %{}

  defp timestamp_attr(attrs, key) do
    case Map.get(attrs, key) do
      %DateTime{} = timestamp -> DateTime.truncate(timestamp, :microsecond)
      _value -> nil
    end
  end

  defp atomized_attrs(attrs) do
    Enum.reduce(attrs, %{}, fn {key, value}, acc ->
      case normalize_key(key) do
        key when is_atom(key) and not is_nil(key) -> Map.put(acc, key, value)
        nil -> acc
      end
    end)
  end

  defp normalize_key(key) when is_atom(key) and key in @input_keys, do: key

  defp normalize_key(key) when is_binary(key) do
    Enum.find(@input_keys, &(Atom.to_string(&1) == key))
  end

  defp normalize_key(_key), do: nil

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
