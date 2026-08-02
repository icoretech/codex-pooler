defmodule CodexPooler.Accounting.ReservationPolicy do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Access.APIKeyPolicyBinding
  alias CodexPooler.Accounting.Metadata
  alias CodexPooler.Accounting.RequestLifecycle.LedgerEntries
  alias CodexPooler.Catalog.Model
  alias CodexPooler.Repo

  @spec policy_for_update(term(), String.t() | nil, struct() | nil) :: struct() | nil
  def policy_for_update(api_key, requested_model, candidate_policy \\ nil) do
    lock_candidate_policy(api_key, requested_model, candidate_policy) ||
      lock_effective_policy(api_key, requested_model)
  end

  @spec effective_model(Model.t(), String.t() | nil, map()) :: String.t() | nil
  def effective_model(%Model{} = model, requested_model, opts) do
    attr(opts, :effective_model) || model.exposed_model_id || requested_model
  end

  @spec enforce_reservation_limits(term(), struct() | nil, map(), DateTime.t()) ::
          :ok | {:error, Metadata.accounting_error()}
  def enforce_reservation_limits(_api_key, nil, _estimate, _timestamp), do: :ok

  def enforce_reservation_limits(api_key, policy, estimate, timestamp) do
    case enforce_request_token_limits(policy, estimate) do
      :ok -> enforce_window_reservation_limits(api_key, policy, estimate, timestamp)
      {:error, _reason} = error -> error
    end
  end

  defp effective_policy_query(api_key_id, requested_model) do
    key = String.downcase(String.trim(requested_model || ""))

    from b in APIKeyPolicyBinding,
      where: b.api_key_id == ^api_key_id and b.status == "active",
      where:
        b.binding_scope == "default" or
          (b.binding_scope == "model" and fragment("lower(?)", b.model_identifier) == ^key),
      order_by: [desc: b.binding_scope],
      limit: 1
  end

  defp lock_candidate_policy(_api_key, _requested_model, nil), do: nil

  defp lock_candidate_policy(api_key, requested_model, %APIKeyPolicyBinding{id: id}) do
    locked_policy =
      Repo.one(
        from b in APIKeyPolicyBinding,
          where: b.id == ^id and b.api_key_id == ^api_key.id and b.status == "active",
          lock: "FOR UPDATE"
      )

    if effective_binding?(locked_policy, requested_model), do: locked_policy
  end

  defp lock_effective_policy(api_key, requested_model) do
    api_key.id
    |> effective_policy_query(requested_model)
    |> then(&Repo.one(from b in &1, lock: "FOR UPDATE"))
  end

  defp effective_binding?(%APIKeyPolicyBinding{binding_scope: "default"}, _requested_model),
    do: true

  defp effective_binding?(%APIKeyPolicyBinding{binding_scope: "model"} = binding, requested_model) do
    String.downcase(to_string(binding.model_identifier || "")) ==
      String.downcase(String.trim(requested_model || ""))
  end

  defp effective_binding?(_binding, _requested_model), do: false

  defp enforce_window_reservation_limits(api_key, policy, estimate, timestamp) do
    limits =
      [
        {:max_requests_per_minute, policy.max_requests_per_minute, :minute,
         DateTime.add(timestamp, -60, :second), :effective_request_count, 1, "request_count",
         "minute"},
        {:max_tokens_per_day, policy.max_tokens_per_day, :daily, beginning_of_day(timestamp),
         :effective_total_tokens, estimate.total_tokens, "total_tokens", "daily"},
        {:max_tokens_per_week, policy.max_tokens_per_week, :weekly,
         DateTime.add(timestamp, -7, :day), :effective_total_tokens, estimate.total_tokens,
         "total_tokens", "weekly"}
      ]
      |> Enum.reject(fn {_field, max_value, _window, _since, _usage_field, _delta, _metric,
                         _label} ->
        is_nil(max_value)
      end)

    window_usages =
      limits
      |> Map.new(fn {_field, _max_value, window, since, _usage_field, _delta, _metric, _label} ->
        {window, since}
      end)
      |> then(&LedgerEntries.window_usages(api_key.id, &1))

    Enum.reduce_while(limits, :ok, fn
      {field, max_value, window, _since, usage_field, delta, metric, label}, :ok ->
        current = window_usages |> Map.fetch!(window) |> Map.fetch!(usage_field)

        limit = {field, max_value, current, delta, metric, label}

        case enforce_window_limit(limit) do
          :ok -> {:cont, :ok}
          {:error, error} -> {:halt, {:error, error}}
        end
    end)
  end

  defp enforce_request_token_limits(policy, estimate) do
    cond do
      positive_limit_exceeded?(policy.max_input_tokens_per_request, estimate.input_tokens) ->
        {:error,
         policy_limit_error(
           "max_input_tokens_per_request",
           "input_tokens",
           "request",
           estimate.input_tokens,
           policy.max_input_tokens_per_request
         )}

      positive_limit_exceeded?(policy.max_output_tokens_per_request, estimate.output_tokens) ->
        {:error,
         policy_limit_error(
           "max_output_tokens_per_request",
           "output_tokens",
           "request",
           estimate.output_tokens,
           policy.max_output_tokens_per_request
         )}

      true ->
        :ok
    end
  end

  defp enforce_window_limit({field, max_value, current, delta, metric, window}) do
    current = decimal_to_integer(current)
    delta = decimal_to_integer(delta)
    max_value = decimal_to_integer(max_value)

    if current + delta > max_value do
      {:error, policy_limit_error(field, metric, window, current + delta, max_value)}
    else
      :ok
    end
  end

  defp positive_limit_exceeded?(nil, _value), do: false

  defp positive_limit_exceeded?(limit, value),
    do: decimal_to_integer(value) > decimal_to_integer(limit)

  defp policy_limit_error(field, metric, window, attempted, max_value) do
    Metadata.accounting_error(
      :api_key_policy_limit_exceeded,
      "api key policy #{field} exceeded for #{metric} in #{window} window: attempted #{attempted}, max #{max_value}"
    )
  end

  defp attr(map, key) when is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp decimal_to_integer(nil), do: 0

  defp decimal_to_integer(%Decimal{} = value),
    do: value |> Decimal.round(0) |> Decimal.to_integer()

  defp decimal_to_integer(value) when is_integer(value), do: value

  defp beginning_of_day(timestamp) do
    timestamp
    |> DateTime.to_date()
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
  end
end
