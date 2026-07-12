defmodule CodexPooler.Quotas.Evidence.CodexParsers.ResponseHeaders do
  @moduledoc false

  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Quotas.Evidence.CodexParsers.{RateLimitReachedType, ResetTimes, WindowKinds}
  alias CodexPooler.Quotas.Evidence.Descriptors

  @window_kinds ~w(primary secondary)

  @spec parse([{String.t(), String.t()}] | map() | term(), DateTime.t()) :: [Evidence.t()]
  def parse(headers, observed_at) do
    header_map = normalize_headers(headers)

    rate_limit_reached_type = RateLimitReachedType.parse_header(header_map)

    header_map
    |> rate_limit_header_limit_ids()
    |> Enum.flat_map(
      &codex_header_evidence_for_limit(&1, header_map, observed_at, rate_limit_reached_type)
    )
    |> normalize_many(observed_at)
    |> dedupe_by_identity()
  end

  defp codex_header_evidence_for_limit(limit_id, header_map, observed_at, rate_limit_reached_type) do
    limit_name = header_limit_name(limit_id, header_map)
    descriptor = Descriptors.limit_descriptor(limit_id, limit_name, %{raw_limit_id: limit_id})

    [
      header_window_attrs(
        "primary",
        limit_id,
        header_map,
        observed_at,
        descriptor,
        rate_limit_reached_type
      ),
      header_window_attrs(
        "secondary",
        limit_id,
        header_map,
        observed_at,
        descriptor,
        rate_limit_reached_type
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp header_window_attrs(
         kind,
         limit_id,
         header_map,
         observed_at,
         descriptor,
         rate_limit_reached_type
       ) do
    prefix = header_prefix(limit_id, kind)

    with {:ok, used_percent} <- finite_percent(header_map["#{prefix}-used-percent"]),
         window_minutes when is_integer(window_minutes) and window_minutes > 0 <-
           integer_or_nil(header_map["#{prefix}-window-minutes"]) do
      reset_at =
        ResetTimes.reset_at_from(%{"reset_at" => header_map["#{prefix}-reset-at"]}, observed_at)

      %{}
      |> Map.merge(descriptor)
      |> Map.merge(%{
        window_kind: WindowKinds.normalize_window_kind(kind, window_minutes),
        window_minutes: window_minutes,
        reset_at: reset_at,
        used_percent: Decimal.from_float(used_percent),
        source: "codex_response_headers",
        source_precision: if(is_nil(reset_at), do: "inferred", else: "observed"),
        freshness_state: "fresh",
        last_sync_at: observed_at,
        observed_at: observed_at,
        metadata:
          compact_metadata(%{
            "header_limit_id" => limit_id,
            "rate_limit_reached_type" => rate_limit_reached_type
          })
      })
    else
      _missing_or_invalid -> nil
    end
  end

  defp normalize_headers(headers) when is_list(headers) do
    Map.new(headers, fn
      {name, values} ->
        value = if is_list(values), do: List.first(values), else: values
        {String.downcase(to_string(name)), value}
    end)
  end

  defp normalize_headers(%{} = headers), do: headers |> Map.to_list() |> normalize_headers()
  defp normalize_headers(_headers), do: %{}

  defp rate_limit_header_limit_ids(header_map) do
    detected =
      header_map
      |> Map.keys()
      |> Enum.flat_map(fn header_name ->
        case header_limit_id(header_name) do
          nil -> []
          limit_id -> [limit_id]
        end
      end)

    ["codex" | detected]
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp header_limit_id(header_name) do
    Enum.find_value(@window_kinds, fn kind ->
      suffixes = ["-#{kind}-used-percent", "-#{kind}-window-minutes", "-#{kind}-reset-at"]

      Enum.find_value(suffixes, fn suffix ->
        # Reason: nested suffix scan keeps header parsing table-driven.
        # credo:disable-for-next-line Credo.Check.Refactor.Nesting
        with true <- String.ends_with?(header_name, suffix),
             "x-" <> limit_id <- String.replace_suffix(header_name, suffix, "") do
          limit_id |> String.replace("-", "_") |> normalize_quota_key()
        else
          _not_rate_limit -> nil
        end
      end)
    end)
  end

  defp header_prefix("codex", kind), do: "x-codex-#{kind}"

  defp header_prefix(limit_id, kind) do
    header_limit = limit_id |> to_string() |> String.replace("_", "-")
    "x-#{header_limit}-#{kind}"
  end

  defp header_limit_name("codex", _header_map), do: nil

  defp header_limit_name(limit_id, header_map) do
    limit_id
    |> header_prefix("limit")
    |> String.replace_suffix("-limit", "-limit-name")
    |> then(&present_string(header_map[&1]))
  end

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
