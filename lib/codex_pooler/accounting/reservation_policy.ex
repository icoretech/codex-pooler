defmodule CodexPooler.Accounting.ReservationPolicy do
  @moduledoc false

  import Ecto.Query

  alias CodexPooler.Access.APIKeyPolicyBinding
  alias CodexPooler.Accounting.LedgerReads
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

  @spec enforce_reservation_limits(term(), struct() | nil, map(), DateTime.t() | nil) ::
          :ok | {:error, Metadata.accounting_error()}
  def enforce_reservation_limits(api_key, policy, estimate, timestamp \\ nil) do
    with :ok <- enforce_active_request_limit(api_key) do
      enforce_policy_limits(api_key, policy, estimate, timestamp)
    end
  end

  # Caller holds the per-key reservation advisory mutex through insertion.
  # The cap is independent of the effective model binding and token windows.
  defp enforce_active_request_limit(%{max_active_requests: limit} = api_key)
       when is_integer(limit) and limit > 0 do
    if LedgerReads.outstanding_reservation_count(api_key.id) >= limit do
      {:error,
       Metadata.accounting_error(
         :api_key_concurrency_limit_exceeded,
         "api key active request limit reached; retry shortly"
       )}
    else
      :ok
    end
  end

  defp enforce_active_request_limit(_api_key), do: :ok

  defp enforce_policy_limits(_api_key, nil, _estimate, _timestamp), do: :ok

  defp enforce_policy_limits(api_key, policy, estimate, timestamp) do
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
    timestamp = timestamp || enforcement_timestamp(api_key, policy)

    limits =
      [
        {:max_requests_per_minute, policy.max_requests_per_minute, :minute, DateTime.add(timestamp, -60, :second), :effective_request_count, 1, "request_count", "minute"},
        {:max_tokens_per_day, policy.max_tokens_per_day, :daily, beginning_of_day(timestamp), :effective_total_tokens, estimate.total_tokens, "total_tokens", "daily"},
        {:max_tokens_per_week, policy.max_tokens_per_week, :weekly, DateTime.add(timestamp, -7, :day), :effective_total_tokens, estimate.total_tokens, "total_tokens", "weekly"}
      ]
      |> Enum.reject(fn {_field, max_value, _window, _since, _usage_field, _delta, _metric, _label} ->
        is_nil(max_value)
      end)

    with :ok <- enforce_windows_can_admit_request(limits) do
      enforce_window_usages(api_key, limits, timestamp)
    end
  end

  defp enforce_window_usages(api_key, limits, timestamp) do
    window_usages =
      limits
      |> Map.new(fn {_field, _max_value, window, since, _usage_field, _delta, _metric, _label} ->
        {window, since}
      end)
      |> then(&LedgerEntries.window_usages(api_key.id, &1, timestamp))

    Enum.reduce_while(limits, :ok, fn
      {field, max_value, window, _since, usage_field, delta, metric, label}, :ok ->
        current = window_usages |> Map.fetch!(window) |> Map.fetch!(usage_field)

        limit = {field, max_value, current, delta, metric, label}

        case enforce_window_limit(limit) do
          :ok -> {:cont, :ok}
          {:error, error} -> {:halt, {:error, put_window_retry_hint(error, label, timestamp)}}
        end
    end)
  end

  # A window whose max is below the request's own estimate never admits that
  # request, whatever the window holds or when it moves: it is refused like a
  # per-request estimate cap, with no hint, not as a window the client could
  # wait out (findings#206 row 206-448). Every window is judged this way
  # before any is judged on its usage, so an exhausted daily window never
  # promises a reset that a weekly max below the estimate would refuse again.
  # The minute window counts one request against a positive max, so only a
  # token window refuses here.
  defp enforce_windows_can_admit_request(limits) do
    Enum.find_value(limits, :ok, fn {field, max_value, _window, _since, _usage_field, delta, metric, label} ->
      delta = decimal_to_integer(delta)
      max_value = decimal_to_integer(max_value)

      if delta > max_value do
        {:error,
         :api_key_policy_limit_exceeded
         |> Metadata.accounting_error("api key policy #{field} exceeded for #{metric} in #{label} window: request estimate #{delta} exceeds max #{max_value}")
         |> Map.put(:limit_scope, :request)}
      end
    end)
  end

  # Called only after reservation authorization holds the per-key mutex and
  # reader lock. Admission time stays on the ledger; every enforcement window
  # instead shares this database clock, including committed mutex predecessors.
  # A predecessor stamped by a node whose clock runs ahead of the database is
  # dated after that clock, and the windows exclude rows dated after their
  # end, so the window end moves up to the key's latest future-dated recorded
  # entry: a committed predecessor always counts, whatever the node clock skew
  # (findings#206).
  defp enforcement_timestamp(_api_key, %{
         max_requests_per_minute: nil,
         max_tokens_per_day: nil,
         max_tokens_per_week: nil
       }),
       do: DateTime.utc_now()

  defp enforcement_timestamp(api_key, _policy) do
    %{rows: [[as_of]]} =
      Repo.query!(
        """
        SELECT greatest(clock.as_of, (
          SELECT max(occurred_at) FROM public.ledger_entries
          WHERE api_key_id = $1::uuid AND amount_status = 'recorded' AND occurred_at > clock.as_of
        ))
        FROM (SELECT clock_timestamp() AS as_of) AS clock
        """,
        [Ecto.UUID.dump!(api_key.id)]
      )

    as_of
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
         )
         |> Map.put(:limit_scope, :request)}

      positive_limit_exceeded?(policy.max_output_tokens_per_request, estimate.output_tokens) ->
        {:error,
         policy_limit_error(
           "max_output_tokens_per_request",
           "output_tokens",
           "request",
           estimate.output_tokens,
           policy.max_output_tokens_per_request
         )
         |> Map.put(:limit_scope, :request)}

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

  # A window refusal admits the request again once the window moves; a
  # per-request estimate cap never does. The retry hint is the window's own
  # boundary: every admission the minute window counts has left it 60 s later,
  # and the daily window restarts at 00:00 UTC. The trailing week has no
  # boundary of its own, so it carries none; settling in-flight work can free
  # any window earlier, so the hint is advice, never a promise.
  defp put_window_retry_hint(error, "minute", _timestamp),
    do: Map.merge(error, %{limit_scope: :window, retry_after_seconds: 60})

  defp put_window_retry_hint(error, "daily", timestamp) do
    next_day = timestamp |> beginning_of_day() |> DateTime.add(1, :day)
    Map.merge(error, %{limit_scope: :window, retry_after_seconds: max(DateTime.diff(next_day, timestamp), 1)})
  end

  defp put_window_retry_hint(error, _label, _timestamp), do: Map.put(error, :limit_scope, :window)

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
