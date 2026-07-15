defmodule CodexPooler.Upstreams.Quota.Windows.RelativeLiveness do
  @moduledoc false

  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow

  @metadata_key "__quota_relative_liveness_v1"
  @candidate_metadata_key "__quota_relative_candidate_liveness_v1"

  @spec valid?(Evidence.t(), DateTime.t()) :: boolean()
  def valid?(%Evidence{} = evidence, timestamp) do
    case provider_observed_at(evidence) do
      {:ok, provider_at} -> valid_at?(provider_at, timestamp)
      :none -> false
    end
  end

  @spec advances?(Evidence.t(), AccountQuotaWindow.t(), DateTime.t()) :: boolean()
  def advances?(%Evidence{} = evidence, %AccountQuotaWindow{} = existing, timestamp) do
    with {:ok, incoming_provider_at} <- provider_observed_at(evidence),
         true <- valid_at?(incoming_provider_at, timestamp) do
      advances_stored_observation?(incoming_provider_at, existing, timestamp)
    else
      _invalid_or_missing -> false
    end
  end

  @spec candidate_pair_valid?(map(), Evidence.t(), DateTime.t()) :: boolean()
  def candidate_pair_valid?(metadata, %Evidence{} = evidence, timestamp) do
    compare_candidate_provider_observations(metadata, evidence, timestamp, &(&1 != :lt))
  end

  @spec candidate_advances?(map(), Evidence.t(), DateTime.t()) :: boolean()
  def candidate_advances?(metadata, %Evidence{} = evidence, timestamp) do
    compare_candidate_provider_observations(metadata, evidence, timestamp, &(&1 == :gt))
  end

  defp compare_candidate_provider_observations(metadata, evidence, timestamp, compare) do
    case provider_observed_at(evidence) do
      :none ->
        false

      {:ok, incoming_provider_at} ->
        with true <- valid_at?(incoming_provider_at, timestamp),
             {:ok, candidate_provider_at} <-
               parse_datetime(Map.get(metadata || %{}, @candidate_metadata_key)),
             true <- valid_at?(candidate_provider_at, timestamp) do
          compare.(DateTime.compare(incoming_provider_at, candidate_provider_at))
        else
          _invalid_or_missing -> false
        end
    end
  end

  @spec put_candidate_metadata(map(), Evidence.t(), DateTime.t()) :: map()
  def put_candidate_metadata(metadata, %Evidence{} = evidence, timestamp) do
    case provider_observed_at(evidence) do
      {:ok, provider_at} when is_map(metadata) ->
        put_valid_candidate_metadata(metadata, provider_at, timestamp)

      _invalid_or_missing ->
        clear_candidate_metadata(metadata)
    end
  end

  @spec clear_candidate_metadata(map()) :: map()
  def clear_candidate_metadata(metadata) when is_map(metadata),
    do: Map.delete(metadata, @candidate_metadata_key)

  @spec put_metadata(map(), Evidence.t(), DateTime.t()) :: map()
  def put_metadata(attrs, %Evidence{} = evidence, timestamp) do
    case provider_observed_at(evidence) do
      {:ok, provider_at} -> put_valid_metadata(attrs, provider_at, timestamp)
      :none -> attrs
    end
  end

  @spec put_canonical_metadata(
          map(),
          Evidence.t(),
          AccountQuotaWindow.t(),
          DateTime.t()
        ) :: map()
  def put_canonical_metadata(
        attrs,
        %Evidence{} = evidence,
        %AccountQuotaWindow{} = existing,
        timestamp
      ) do
    case provider_observed_at(evidence) do
      {:ok, provider_at} when is_map(attrs) ->
        if valid_at?(provider_at, timestamp) do
          put_monotonic_metadata(attrs, provider_at, existing, timestamp)
        else
          put_observation_barrier(attrs, evidence, existing, timestamp)
        end

      :none ->
        put_observation_barrier(attrs, evidence, existing, timestamp)
    end
  end

  defp advances_stored_observation?(incoming_provider_at, existing, timestamp) do
    case stored_provider_observed_at(existing) do
      {:ok, existing_provider_at} ->
        not valid_at?(existing_provider_at, timestamp) or
          DateTime.compare(incoming_provider_at, existing_provider_at) == :gt

      :none ->
        true
    end
  end

  defp put_valid_metadata(attrs, provider_at, timestamp) do
    if valid_at?(provider_at, timestamp) do
      Map.update!(attrs, :metadata, fn metadata ->
        Map.put(metadata, @metadata_key, DateTime.to_iso8601(provider_at))
      end)
    else
      attrs
    end
  end

  defp put_observation_barrier(
         attrs,
         %Evidence{observed_at: %DateTime{} = observed_at},
         existing,
         timestamp
       ),
       do: put_monotonic_metadata(attrs, observed_at, existing, timestamp)

  defp put_observation_barrier(attrs, _evidence, _existing, _timestamp), do: attrs

  defp put_monotonic_metadata(attrs, provider_at, existing, timestamp) do
    case stored_provider_observed_at(existing) do
      {:ok, existing_provider_at} ->
        if valid_at?(existing_provider_at, timestamp) and
             DateTime.compare(provider_at, existing_provider_at) == :lt do
          put_valid_metadata(attrs, existing_provider_at, timestamp)
        else
          put_valid_metadata(attrs, provider_at, timestamp)
        end

      :none ->
        put_valid_metadata(attrs, provider_at, timestamp)
    end
  end

  defp put_valid_candidate_metadata(metadata, provider_at, timestamp) do
    if valid_at?(provider_at, timestamp) do
      Map.put(metadata, @candidate_metadata_key, DateTime.to_iso8601(provider_at))
    else
      clear_candidate_metadata(metadata)
    end
  end

  defp stored_provider_observed_at(%AccountQuotaWindow{
         reset_at: reset_at,
         observed_at: observed_at,
         metadata: metadata
       }) do
    metadata = metadata || %{}

    case parse_datetime(Map.get(metadata, @metadata_key)) do
      {:ok, provider_at} -> {:ok, provider_at}
      :error -> stored_reset_provider_observed_at(reset_at, observed_at, metadata)
    end
  end

  defp stored_provider_observed_at(_existing), do: :none

  defp stored_reset_provider_observed_at(%DateTime{} = reset_at, observed_at, metadata) do
    case provider_observed_at(reset_at, metadata) do
      {:ok, provider_at} -> {:ok, provider_at}
      :none -> stored_observation_barrier(observed_at)
    end
  end

  defp stored_reset_provider_observed_at(_reset_at, observed_at, _metadata),
    do: stored_observation_barrier(observed_at)

  defp stored_observation_barrier(%DateTime{} = observed_at), do: {:ok, observed_at}
  defp stored_observation_barrier(_observed_at), do: :none

  defp provider_observed_at(%Evidence{reset_at: %DateTime{} = reset_at, metadata: metadata}),
    do: provider_observed_at(reset_at, metadata)

  defp provider_observed_at(_evidence), do: :none

  defp provider_observed_at(reset_at, metadata) do
    case reset_after_seconds(metadata) do
      {:ok, seconds} -> {:ok, DateTime.add(reset_at, -seconds, :second)}
      :absent_or_invalid -> :none
    end
  end

  defp reset_after_seconds(%{} = metadata) do
    case Map.get(metadata, "reset_after_seconds") || Map.get(metadata, :reset_after_seconds) do
      seconds when is_integer(seconds) and seconds >= 0 -> {:ok, seconds}
      _absent_or_invalid -> :absent_or_invalid
    end
  end

  defp reset_after_seconds(_metadata), do: :absent_or_invalid

  defp valid_at?(provider_at, timestamp) do
    DateTime.diff(timestamp, provider_at, :second) <= Evidence.freshness_ttl_seconds() and
      DateTime.diff(provider_at, timestamp, :second) <=
        Evidence.future_observed_skew_seconds()
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _invalid -> :error
    end
  end

  defp parse_datetime(_value), do: :error
end
