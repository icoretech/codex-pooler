defmodule CodexPooler.Quotas.Evidence.CodexParsers.RateLimitEvents do
  @moduledoc false

  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Quotas.Evidence.CodexParsers.{ResetTimes, WindowKinds}
  alias CodexPooler.Quotas.Evidence.Descriptors

  @spec parse(term(), DateTime.t()) :: [Evidence.t()]
  def parse(%{"type" => "codex.rate_limits"} = event, observed_at) do
    limits = event["rate_limits"] || %{}

    limit_id = rate_limit_event_limit_id(event)
    limit_name = rate_limit_event_limit_name(event, limit_id)

    descriptor = Descriptors.limit_descriptor(limit_id, limit_name, %{})

    [
      rate_limit_event_window_attrs("primary", limits["primary"], observed_at, descriptor),
      rate_limit_event_window_attrs("secondary", limits["secondary"], observed_at, descriptor)
    ]
    |> Enum.reject(&is_nil/1)
    |> normalize_many(observed_at)
    |> dedupe_by_identity()
  end

  def parse(_event, _observed_at), do: []

  defp rate_limit_event_limit_id(event) do
    present_string(event["metered_limit_name"]) || present_string(event["metered_feature"]) ||
      present_string(event["limit_id"]) || present_string(event["limit_name"]) ||
      present_string(event["model"]) || present_string(event["model_id"]) ||
      present_string(event["model_identifier"]) || "codex"
  end

  defp rate_limit_event_limit_name(event, limit_id) do
    if normalize_quota_key(limit_id) == "codex" do
      nil
    else
      present_string(event["limit_name"]) || present_string(event["model"]) ||
        present_string(event["model_id"]) || present_string(event["model_identifier"])
    end
  end

  defp rate_limit_event_window_attrs(kind, %{} = window, observed_at, descriptor) do
    with {:ok, used_percent} <- finite_percent(window["used_percent"]),
         window_minutes when is_integer(window_minutes) and window_minutes > 0 <-
           integer_or_nil(window["window_minutes"]) do
      reset_at = rate_limit_event_reset_at(window, window_minutes, observed_at)

      %{}
      |> Map.merge(descriptor)
      |> Map.merge(%{
        window_kind: WindowKinds.normalize_window_kind(kind, window_minutes),
        window_minutes: window_minutes,
        reset_at: reset_at,
        used_percent: Decimal.from_float(used_percent),
        source: "codex_rate_limit_event",
        source_precision: ResetTimes.reset_source_precision(window, reset_at),
        freshness_state: "fresh",
        last_sync_at: observed_at,
        observed_at: observed_at,
        metadata: compact_metadata(%{"event_limit_id" => Map.get(descriptor, :raw_limit_id)})
      })
    else
      _missing_or_invalid -> nil
    end
  end

  defp rate_limit_event_window_attrs(_kind, _window, _observed_at, _descriptor), do: nil

  defp rate_limit_event_reset_at(window, 10_080, _observed_at),
    do: ResetTimes.explicit_reset_at_from(window)

  defp rate_limit_event_reset_at(window, _window_minutes, observed_at),
    do: ResetTimes.reset_at_from(window, observed_at)

  defp normalize_many(attrs_list, observed_at) do
    attrs_list
    |> Enum.map(&Evidence.new(&1, observed_at))
    |> Enum.flat_map(fn
      {:ok, evidence} -> [evidence]
      {:error, _errors} -> []
    end)
  end

  defp dedupe_by_identity(evidences) do
    evidences
    |> Enum.reduce(%{}, fn evidence, acc ->
      Map.update(acc, Evidence.identity_key(evidence), evidence, fn existing ->
        # Reason: reduce callback keeps only the strongest duplicate evidence row.
        # credo:disable-for-next-line Credo.Check.Refactor.Nesting
        if quota_used_percent(evidence) >= quota_used_percent(existing),
          do: evidence,
          else: existing
      end)
    end)
    |> Map.values()
    |> Enum.sort_by(&{&1.quota_key, &1.window_kind, &1.source, &1.raw_limit_id || ""})
  end

  defp compact_metadata(metadata) do
    metadata
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp normalize_quota_key(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp present_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp present_string(_value), do: nil

  defp integer_or_nil(value) when is_integer(value), do: value
  defp integer_or_nil(value) when is_float(value), do: trunc(value)

  defp integer_or_nil(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _invalid -> nil
    end
  end

  defp integer_or_nil(_value), do: nil

  defp quota_used_percent(%{used_percent: %Decimal{} = percent}), do: Decimal.to_float(percent)
  defp quota_used_percent(%{used_percent: percent}) when is_number(percent), do: percent / 1
  defp quota_used_percent(_attrs), do: -1.0

  defp finite_percent(value) when is_integer(value) and value >= 0 and value <= 100,
    do: {:ok, value / 1}

  defp finite_percent(value) when is_float(value) and value >= 0 and value <= 100,
    do: {:ok, value}

  defp finite_percent(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {percent, ""} when percent >= 0 and percent <= 100 -> {:ok, percent}
      _invalid -> :error
    end
  end

  defp finite_percent(%Decimal{} = value), do: finite_percent(Decimal.to_float(value))
  defp finite_percent(_value), do: :error
end
