defmodule CodexPooler.Upstreams.SavedResets.AutoEligibility.Context do
  @moduledoc false

  @triggers [:blocked_weekly_exhaustion, :threshold_pressure]

  @type trigger :: :blocked_weekly_exhaustion | :threshold_pressure
  @type transient_circuit_exclusion :: %{
          required(:upstream_identity_id) => Ecto.UUID.t(),
          required(:pool_upstream_assignment_id) => Ecto.UUID.t(),
          required(:routing_circuit_state_id) => Ecto.UUID.t(),
          required(:model_identifier) => String.t(),
          required(:route_class) => String.t()
        }
  @type t :: %{
          required(:trigger) => trigger(),
          required(:pool_upstream_assignment_id) => Ecto.UUID.t(),
          required(:upstream_identity_id) => Ecto.UUID.t(),
          required(:candidate_assignment_ids) => [Ecto.UUID.t()],
          required(:candidate_identity_ids) => [Ecto.UUID.t()],
          required(:capacity_assignment_ids) => [Ecto.UUID.t()],
          required(:capacity_identity_ids) => [Ecto.UUID.t()],
          required(:cohort_identity_ids) => [Ecto.UUID.t()],
          required(:routable_assignment_ids) => [Ecto.UUID.t()],
          required(:routable_identity_ids) => [Ecto.UUID.t()],
          required(:route_class) => String.t(),
          required(:transient_circuit_exclusions) => [transient_circuit_exclusion()],
          optional(:quota_scope) => quota_scope() | nil,
          optional(:hard_pinned_continuity?) => boolean()
        }

  @type quota_scope :: %{
          required(:requested_model) => String.t(),
          required(:catalog_model) => String.t(),
          required(:exposed_model_id) => String.t(),
          required(:upstream_model) => String.t(),
          required(:upstream_model_id) => String.t()
        }

  @type normalize_error :: :invalid_gateway_auto_context | :gateway_auto_context_mismatch

  @spec normalize(term()) :: {:ok, t()} | {:error, normalize_error()}
  def normalize(context) when is_list(context) do
    if keyword_context?(context) do
      context |> Map.new() |> normalize()
    else
      {:error, :invalid_gateway_auto_context}
    end
  end

  def normalize(context) when is_map(context) do
    with trigger when trigger in @triggers <- context_value(context, :trigger),
         {:ok, assignment_id} <-
           normalize_uuid(context_value(context, :pool_upstream_assignment_id)),
         {:ok, identity_id} <- normalize_uuid(context_value(context, :upstream_identity_id)),
         {:ok, candidate_assignment_ids} <-
           normalize_uuid_list(context_value(context, :candidate_assignment_ids)),
         {:ok, candidate_identity_ids} <-
           normalize_uuid_list(context_value(context, :candidate_identity_ids)),
         {:ok, capacity_assignment_ids} <-
           normalize_uuid_list(context_value(context, :capacity_assignment_ids)),
         {:ok, capacity_identity_ids} <-
           normalize_uuid_list(context_value(context, :capacity_identity_ids)),
         {:ok, cohort_identity_ids} <-
           normalize_uuid_list(context_value(context, :cohort_identity_ids),
             deterministic?: true
           ),
         {:ok, routable_assignment_ids} <-
           normalize_uuid_list(context_value(context, :routable_assignment_ids)),
         {:ok, routable_identity_ids} <-
           normalize_uuid_list(context_value(context, :routable_identity_ids)),
         :ok <-
           validate_candidate_sets(
             {assignment_id, identity_id},
             %{
               dispatch: {candidate_assignment_ids, candidate_identity_ids},
               capacity: {capacity_assignment_ids, capacity_identity_ids},
               routable: {routable_assignment_ids, routable_identity_ids},
               cohort_identity_ids: cohort_identity_ids
             }
           ),
         route_class when is_binary(route_class) and route_class != "" <-
           context_value(context, :route_class),
         {:ok, quota_scope} <- normalize_quota_scope(context_value(context, :quota_scope)),
         {:ok, hard_pinned_continuity?} <-
           normalize_boolean(context_value(context, :hard_pinned_continuity?), false),
         {:ok, transient_circuit_exclusions} <-
           normalize_transient_circuit_exclusions(
             context_value(context, :transient_circuit_exclusions),
             length(cohort_identity_ids)
           ),
         :ok <-
           validate_transient_circuit_exclusions(
             transient_circuit_exclusions,
             cohort_identity_ids,
             candidate_identity_ids,
             quota_scope,
             route_class
           ) do
      {:ok,
       %{
         trigger: trigger,
         pool_upstream_assignment_id: assignment_id,
         upstream_identity_id: identity_id,
         candidate_assignment_ids: candidate_assignment_ids,
         candidate_identity_ids: candidate_identity_ids,
         capacity_assignment_ids: capacity_assignment_ids,
         capacity_identity_ids: capacity_identity_ids,
         cohort_identity_ids: cohort_identity_ids,
         routable_assignment_ids: routable_assignment_ids,
         routable_identity_ids: routable_identity_ids,
         route_class: route_class,
         transient_circuit_exclusions: transient_circuit_exclusions,
         quota_scope: quota_scope,
         hard_pinned_continuity?: hard_pinned_continuity?
       }}
    else
      {:error, :gateway_auto_context_mismatch} = error -> error
      _invalid -> {:error, :invalid_gateway_auto_context}
    end
  end

  def normalize(_context), do: {:error, :invalid_gateway_auto_context}

  defp normalize_uuid(value) when is_binary(value), do: Ecto.UUID.cast(value)
  defp normalize_uuid(_value), do: :error

  defp normalize_uuid_list(values, opts \\ [])

  defp normalize_uuid_list(values, opts) when is_list(values) and values != [] do
    ids = Enum.map(values, &normalize_uuid/1)

    if Enum.all?(ids, &match?({:ok, _id}, &1)) do
      normalized_ids = Enum.map(ids, fn {:ok, id} -> id end)

      if Keyword.get(opts, :deterministic?, false) do
        {:ok, normalized_ids |> Enum.uniq() |> Enum.sort()}
      else
        {:ok, normalized_ids}
      end
    else
      :error
    end
  end

  defp normalize_uuid_list(_values, _opts), do: :error

  defp validate_candidate_sets(
         target_pair,
         %{
           dispatch: {candidate_assignment_ids, candidate_identity_ids},
           capacity: {capacity_assignment_ids, capacity_identity_ids},
           routable: {routable_assignment_ids, routable_identity_ids},
           cohort_identity_ids: cohort_identity_ids
         }
       ) do
    dispatch_pairs = aligned_pairs(candidate_assignment_ids, candidate_identity_ids)
    capacity_pairs = aligned_pairs(capacity_assignment_ids, capacity_identity_ids)
    routable_pairs = aligned_pairs(routable_assignment_ids, routable_identity_ids)

    if valid_unique_pairs?(dispatch_pairs, candidate_assignment_ids, candidate_identity_ids) and
         valid_unique_pairs?(capacity_pairs, capacity_assignment_ids, capacity_identity_ids) and
         valid_unique_pairs?(routable_pairs, routable_assignment_ids, routable_identity_ids) and
         target_pair in dispatch_pairs and
         subset?(dispatch_pairs, routable_pairs) and
         subset?(routable_pairs, capacity_pairs) and
         subset?(capacity_identity_ids, cohort_identity_ids) do
      :ok
    else
      {:error, :gateway_auto_context_mismatch}
    end
  end

  defp aligned_pairs(assignment_ids, identity_ids) do
    if length(assignment_ids) == length(identity_ids),
      do: Enum.zip(assignment_ids, identity_ids),
      else: []
  end

  defp valid_unique_pairs?(pairs, assignment_ids, identity_ids) do
    pairs != [] and length(pairs) == length(assignment_ids) and
      length(pairs) == length(identity_ids) and length(pairs) == length(Enum.uniq(pairs)) and
      length(assignment_ids) == length(Enum.uniq(assignment_ids)) and
      length(identity_ids) == length(Enum.uniq(identity_ids))
  end

  defp subset?(members, set), do: Enum.all?(members, &(&1 in set))

  defp normalize_quota_scope(nil), do: {:ok, nil}

  defp normalize_quota_scope(scope) when is_map(scope) do
    keys = [
      :requested_model,
      :catalog_model,
      :exposed_model_id,
      :upstream_model,
      :upstream_model_id
    ]

    values = Map.new(keys, &{&1, context_value(scope, &1)})

    if Enum.all?(values, fn {_key, value} -> is_binary(value) and value != "" end),
      do: {:ok, values},
      else: :error
  end

  defp normalize_quota_scope(_scope), do: :error

  defp normalize_boolean(nil, default), do: {:ok, default}
  defp normalize_boolean(value, _default) when is_boolean(value), do: {:ok, value}
  defp normalize_boolean(_value, _default), do: :error

  defp normalize_transient_circuit_exclusions(nil, _cohort_size), do: {:ok, []}

  defp normalize_transient_circuit_exclusions(exclusions, cohort_size)
       when is_list(exclusions) and length(exclusions) <= cohort_size do
    with {:ok, normalized} <- normalize_transient_circuit_exclusion_entries(exclusions),
         true <- unique_transient_circuit_ids?(normalized) do
      {:ok, normalized}
    else
      _invalid -> :error
    end
  end

  defp normalize_transient_circuit_exclusions(_exclusions, _cohort_size), do: :error

  defp normalize_transient_circuit_exclusion_entries(exclusions) do
    Enum.reduce_while(exclusions, {:ok, []}, fn exclusion, {:ok, normalized} ->
      case normalize_transient_circuit_exclusion(exclusion) do
        {:ok, entry} -> {:cont, {:ok, [entry | normalized]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      :error -> :error
    end
  end

  defp normalize_transient_circuit_exclusion(exclusion) when is_map(exclusion) do
    with {:ok, identity_id} <-
           normalize_uuid(context_value(exclusion, :upstream_identity_id)),
         {:ok, assignment_id} <-
           normalize_uuid(context_value(exclusion, :pool_upstream_assignment_id)),
         {:ok, circuit_id} <-
           normalize_uuid(context_value(exclusion, :routing_circuit_state_id)),
         {:ok, model_identifier} <-
           normalize_nonempty_binary(context_value(exclusion, :model_identifier)),
         {:ok, route_class} <-
           normalize_nonempty_binary(context_value(exclusion, :route_class)) do
      {:ok,
       %{
         upstream_identity_id: identity_id,
         pool_upstream_assignment_id: assignment_id,
         routing_circuit_state_id: circuit_id,
         model_identifier: model_identifier,
         route_class: route_class
       }}
    else
      _invalid -> :error
    end
  end

  defp normalize_transient_circuit_exclusion(_exclusion), do: :error

  defp normalize_nonempty_binary(value) when is_binary(value) do
    if String.trim(value) == "", do: :error, else: {:ok, value}
  end

  defp normalize_nonempty_binary(_value), do: :error

  defp unique_transient_circuit_ids?(exclusions) do
    unique_by?(exclusions, :upstream_identity_id) and
      unique_by?(exclusions, :pool_upstream_assignment_id) and
      unique_by?(exclusions, :routing_circuit_state_id)
  end

  defp unique_by?(entries, key) do
    entries
    |> Enum.map(&Map.fetch!(&1, key))
    |> then(&(length(&1) == length(Enum.uniq(&1))))
  end

  defp validate_transient_circuit_exclusions(
         exclusions,
         cohort_identity_ids,
         candidate_identity_ids,
         quota_scope,
         route_class
       ) do
    request_model_identifier = request_model_identifier(quota_scope)

    if Enum.all?(exclusions, fn exclusion ->
         exclusion.upstream_identity_id in cohort_identity_ids and
           exclusion.upstream_identity_id not in candidate_identity_ids and
           exclusion.route_class == route_class and
           exclusion.model_identifier == request_model_identifier
       end) do
      :ok
    else
      {:error, :gateway_auto_context_mismatch}
    end
  end

  defp request_model_identifier(%{catalog_model: model_identifier}), do: model_identifier
  defp request_model_identifier(_quota_scope), do: nil

  defp keyword_context?([]), do: true
  defp keyword_context?([{key, _value} | rest]) when is_atom(key), do: keyword_context?(rest)
  defp keyword_context?(_context), do: false

  defp context_value(context, key) do
    Map.get(context, key) || Map.get(context, Atom.to_string(key))
  end
end
