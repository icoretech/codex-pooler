defmodule CodexPooler.Upstreams.SavedResets.AutoEligibility.Context do
  @moduledoc false

  @triggers [:blocked_weekly_exhaustion, :threshold_pressure]

  @type trigger :: :blocked_weekly_exhaustion | :threshold_pressure
  @type t :: %{
          required(:trigger) => trigger(),
          required(:pool_upstream_assignment_id) => Ecto.UUID.t(),
          required(:upstream_identity_id) => Ecto.UUID.t(),
          required(:candidate_assignment_ids) => [Ecto.UUID.t()],
          required(:candidate_identity_ids) => [Ecto.UUID.t()],
          required(:cohort_identity_ids) => [Ecto.UUID.t()],
          required(:routable_identity_ids) => [Ecto.UUID.t()],
          required(:route_class) => String.t(),
          optional(:quota_scope) => quota_scope() | nil,
          optional(:session_continuity?) => boolean()
        }

  @type quota_scope :: %{
          required(:requested_model) => String.t(),
          required(:catalog_model) => String.t(),
          required(:exposed_model_id) => String.t(),
          required(:upstream_model) => String.t(),
          required(:upstream_model_id) => String.t()
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
         {:ok, cohort_identity_ids} <-
           normalize_uuid_list(context_value(context, :cohort_identity_ids),
             deterministic?: true
           ),
         {:ok, routable_identity_ids} <-
           normalize_uuid_list(
             context_value(context, :routable_identity_ids) || candidate_identity_ids,
             deterministic?: true
           ),
         route_class when is_binary(route_class) and route_class != "" <-
           context_value(context, :route_class),
         {:ok, quota_scope} <- normalize_quota_scope(context_value(context, :quota_scope)),
         {:ok, session_continuity?} <-
           normalize_boolean(context_value(context, :session_continuity?), false) do
      {:ok,
       %{
         trigger: trigger,
         pool_upstream_assignment_id: assignment_id,
         upstream_identity_id: identity_id,
         candidate_assignment_ids: candidate_assignment_ids,
         candidate_identity_ids: candidate_identity_ids,
         cohort_identity_ids: cohort_identity_ids,
         routable_identity_ids: routable_identity_ids,
         route_class: route_class,
         quota_scope: quota_scope,
         session_continuity?: session_continuity?
       }}
    else
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

  defp keyword_context?([]), do: true
  defp keyword_context?([{key, _value} | rest]) when is_atom(key), do: keyword_context?(rest)
  defp keyword_context?(_context), do: false

  defp context_value(context, key) do
    Map.get(context, key) || Map.get(context, Atom.to_string(key))
  end
end
