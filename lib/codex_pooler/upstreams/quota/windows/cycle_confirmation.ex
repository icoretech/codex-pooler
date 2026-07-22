defmodule CodexPooler.Upstreams.Quota.Windows.CycleConfirmation do
  @moduledoc false

  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows.RelativeLiveness

  @metadata_key "__quota_cycle_confirmation_v1"
  @version 1
  @source_class "provider_usage"

  @spec confirm(map(), Evidence.t(), DateTime.t()) :: map()
  def confirm(attrs, %Evidence{} = evidence, %DateTime{} = confirmed_at) when is_map(attrs) do
    with true <- RelativeLiveness.provider_proof_valid?(evidence, confirmed_at),
         {:ok, provider_observed_at} <- RelativeLiveness.provider_observed_at(evidence) do
      Map.update!(attrs, :metadata, fn metadata ->
        metadata
        |> Map.put("reset_state", "anchored")
        |> Map.put(
          @metadata_key,
          marker(evidence, provider_observed_at, confirmed_at)
        )
      end)
    else
      _invalid_or_missing -> attrs
    end
  end

  @spec maintain(map(), AccountQuotaWindow.t(), Evidence.t(), DateTime.t()) :: map()
  def maintain(
        attrs,
        %AccountQuotaWindow{} = existing,
        %Evidence{} = evidence,
        %DateTime{} = timestamp
      )
      when is_map(attrs) do
    with true <- selector_valid?(existing, timestamp),
         true <- RelativeLiveness.provider_proof_valid?(evidence, timestamp),
         {:ok, marker} <- valid_marker(existing),
         {:ok, provider_observed_at} <- RelativeLiveness.provider_observed_at(evidence) do
      updated_marker =
        evidence
        |> marker(provider_observed_at, timestamp)
        |> Map.put("confirmed_at", marker["confirmed_at"])

      Map.update!(attrs, :metadata, fn metadata ->
        metadata
        |> Map.put("reset_state", "anchored")
        |> Map.put(@metadata_key, updated_marker)
      end)
    else
      _invalid_or_missing -> attrs
    end
  end

  @spec selector_valid?(AccountQuotaWindow.t(), DateTime.t()) :: boolean()
  def selector_valid?(%AccountQuotaWindow{} = window, %DateTime{} = as_of) do
    with {:ok, marker} <- valid_marker(window),
         {:ok, provider_observed_at} <- parse_datetime(marker["provider_observed_at"]),
         {:ok, confirmed_at} <- parse_datetime(marker["confirmed_at"]),
         true <- Evidence.current_freshness_state(window, as_of) == "fresh",
         true <- nonfuture?(window.observed_at, as_of),
         true <- nonfuture?(provider_observed_at, as_of),
         true <- nonfuture?(confirmed_at, as_of),
         true <- provider_fresh?(provider_observed_at, as_of) do
      true
    else
      _invalid_or_stale -> false
    end
  end

  @spec valid_marker(AccountQuotaWindow.t()) :: {:ok, map()} | :none
  def valid_marker(%AccountQuotaWindow{} = window) do
    with %{
           "version" => @version,
           "scope" => scope,
           "family" => family,
           "key" => key,
           "kind" => kind,
           "minutes" => minutes,
           "model" => model,
           "upstream_model" => upstream_model,
           "reset_at" => reset_at,
           "provider_observed_at" => provider_observed_at,
           "confirmed_at" => confirmed_at,
           "source_class" => @source_class
         } = marker <- Map.get(window.metadata || %{}, @metadata_key),
         true <- map_size(marker) == 12,
         true <- window.metadata["reset_state"] == "anchored",
         true <-
           descriptor_matches?(window, scope, family, key, kind, minutes, model, upstream_model),
         {:ok, parsed_reset_at} <- parse_datetime(reset_at),
         true <- same_datetime?(window.reset_at, parsed_reset_at),
         {:ok, _provider_observed_at} <- parse_datetime(provider_observed_at),
         {:ok, _confirmed_at} <- parse_datetime(confirmed_at) do
      {:ok, marker}
    else
      _invalid -> :none
    end
  end

  defp marker(evidence, provider_observed_at, confirmed_at) do
    %{
      "version" => @version,
      "scope" => evidence.quota_scope,
      "family" => evidence.quota_family,
      "key" => evidence.quota_key,
      "kind" => evidence.window_kind,
      "minutes" => evidence.window_minutes,
      "model" => evidence.model,
      "upstream_model" => evidence.upstream_model,
      "reset_at" => DateTime.to_iso8601(evidence.reset_at),
      "provider_observed_at" => DateTime.to_iso8601(provider_observed_at),
      "confirmed_at" => DateTime.to_iso8601(confirmed_at),
      "source_class" => @source_class
    }
  end

  defp descriptor_matches?(window, scope, family, key, kind, minutes, model, upstream_model) do
    window.quota_scope == scope and window.quota_family == family and window.quota_key == key and
      window.window_kind == kind and window.window_minutes == minutes and window.model == model and
      window.upstream_model == upstream_model
  end

  defp provider_fresh?(provider_observed_at, as_of) do
    DateTime.diff(as_of, provider_observed_at, :second) <= Evidence.freshness_ttl_seconds()
  end

  defp nonfuture?(%DateTime{} = datetime, %DateTime{} = as_of),
    do: DateTime.compare(datetime, as_of) != :gt

  defp nonfuture?(_datetime, _as_of), do: false

  defp same_datetime?(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right) == :eq

  defp same_datetime?(_left, _right), do: false

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _invalid -> :error
    end
  end

  defp parse_datetime(_value), do: :error
end
