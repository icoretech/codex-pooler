defmodule CodexPooler.Upstreams.SavedResets.AutoEligibility.Context do
  @moduledoc false

  @triggers [:blocked_weekly_exhaustion, :threshold_pressure, :expiring_reset]

  @type trigger :: :blocked_weekly_exhaustion | :threshold_pressure | :expiring_reset
  @type t :: %{
          required(:trigger) => trigger(),
          required(:pool_upstream_assignment_id) => Ecto.UUID.t(),
          required(:upstream_identity_id) => Ecto.UUID.t(),
          required(:candidate_assignment_ids) => [Ecto.UUID.t()],
          required(:candidate_identity_ids) => [Ecto.UUID.t()],
          required(:route_class) => String.t()
        }

  @spec normalize(term()) :: {:ok, t()} | {:error, :invalid_gateway_auto_context}
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
         route_class when is_binary(route_class) and route_class != "" <-
           context_value(context, :route_class) do
      {:ok,
       %{
         trigger: trigger,
         pool_upstream_assignment_id: assignment_id,
         upstream_identity_id: identity_id,
         candidate_assignment_ids: candidate_assignment_ids,
         candidate_identity_ids: candidate_identity_ids,
         route_class: route_class
       }}
    else
      _invalid -> {:error, :invalid_gateway_auto_context}
    end
  end

  def normalize(_context), do: {:error, :invalid_gateway_auto_context}

  defp normalize_uuid(value) when is_binary(value), do: Ecto.UUID.cast(value)
  defp normalize_uuid(_value), do: :error

  defp normalize_uuid_list(values) when is_list(values) and values != [] do
    ids = Enum.map(values, &normalize_uuid/1)

    if Enum.all?(ids, &match?({:ok, _id}, &1)) do
      {:ok, Enum.map(ids, fn {:ok, id} -> id end)}
    else
      :error
    end
  end

  defp normalize_uuid_list(_values), do: :error

  defp keyword_context?([]), do: true
  defp keyword_context?([{key, _value} | rest]) when is_atom(key), do: keyword_context?(rest)
  defp keyword_context?(_context), do: false

  defp context_value(context, key) do
    Map.get(context, key) || Map.get(context, Atom.to_string(key))
  end
end
