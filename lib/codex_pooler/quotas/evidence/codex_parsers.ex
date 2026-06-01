defmodule CodexPooler.Quotas.Evidence.CodexParsers do
  @moduledoc """
  Codex upstream quota dialect parsers for normalized quota evidence.

  This module owns the external payload/header/event shapes. The parent
  `Evidence` module remains the normalized value, validation, and freshness API.
  """

  alias CodexPooler.Quotas.Evidence
  alias CodexPooler.Quotas.Evidence.CodexParsers.{RateLimitEvents, ResetTimes, ResponseHeaders}
  alias CodexPooler.Quotas.Evidence.Descriptors

  @window_kinds ~w(primary secondary)

  @spec parse_codex_usage_payload(term(), DateTime.t()) ::
          {:ok, [Evidence.t()]}
          | {:error, %{required(:code) => atom(), required(:message) => String.t()}}
  def parse_codex_usage_payload(payload, observed_at \\ now())

  def parse_codex_usage_payload(%{"rate_limit" => %{} = rate_limit} = payload, observed_at) do
    credits = codex_usage_credits(payload["credits"])

    evidences =
      rate_limit
      |> account_usage_evidence(credits, observed_at)
      |> Kernel.++(additional_usage_evidence(payload, observed_at))
      |> normalize_many(observed_at)
      |> dedupe_by_identity()

    if evidences == [] do
      {:error,
       %{code: :upstream_quota_unusable, message: "upstream quota payload had no usable windows"}}
    else
      {:ok, evidences}
    end
  end

  def parse_codex_usage_payload(_payload, _observed_at) do
    {:error,
     %{code: :upstream_quota_unusable, message: "upstream quota payload had no usable windows"}}
  end

  @spec parse_codex_headers([{String.t(), String.t()}] | map() | term(), DateTime.t()) ::
          [Evidence.t()]
  def parse_codex_headers(headers, observed_at \\ now()) do
    ResponseHeaders.parse(headers, observed_at)
  end

  @spec parse_codex_rate_limit_event(term(), DateTime.t()) :: [Evidence.t()]
  def parse_codex_rate_limit_event(event, observed_at \\ now())

  def parse_codex_rate_limit_event(event, observed_at),
    do: RateLimitEvents.parse(event, observed_at)

  @spec parse_rate_limit_error(term(), DateTime.t()) :: [Evidence.t()]
  def parse_rate_limit_error(payload, observed_at \\ now())

  # Reason: parser accepts several upstream rate-limit error dialects.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def parse_rate_limit_error(%{} = payload, observed_at) do
    family =
      present_string(payload["limit_id"] || payload["limit_name"] || payload["metered_feature"]) ||
        "codex"

    limit_name = present_string(payload["limit_name"])
    descriptor = Descriptors.limit_descriptor(family, limit_name, %{})
    reset_at = ResetTimes.reset_at_from(payload, observed_at)

    window_minutes =
      positive_integer(payload["window_minutes"] || payload["limit_window_minutes"])

    used_percent = finite_percent_value(payload["used_percent"] || payload["usage_percent"])

    if is_nil(reset_at) or is_nil(window_minutes) do
      []
    else
      kind = normalize_token(payload["window_kind"] || payload["kind"] || "primary")

      %{}
      |> Map.merge(descriptor)
      |> Map.merge(%{
        window_kind: if(kind in @window_kinds, do: kind, else: "primary"),
        window_minutes: window_minutes,
        reset_at: reset_at,
        used_percent: used_percent,
        source: "codex_rate_limit_error",
        source_precision: "observed",
        freshness_state: "fresh",
        last_sync_at: observed_at,
        observed_at: observed_at,
        metadata: compact_metadata(%{"error_limit_id" => family})
      })
      |> then(&normalize_many([&1], observed_at))
    end
  end

  def parse_rate_limit_error(_payload, _observed_at), do: []

  defp account_usage_evidence(rate_limit, credits, observed_at) do
    primary_window = rate_limit["primary_window"] || rate_limit["primary"]
    secondary_window = rate_limit["secondary_window"] || rate_limit["secondary"]
    descriptor = Descriptors.account_descriptor()

    if weekly_window?(primary_window) do
      [usage_window_attrs("secondary", primary_window, credits, observed_at, descriptor)]
    else
      [
        usage_window_attrs("primary", primary_window, credits, observed_at, descriptor),
        usage_window_attrs("secondary", secondary_window, credits, observed_at, descriptor)
      ]
    end
    |> Enum.reject(&is_nil/1)
  end

  defp additional_usage_evidence(%{"additional_rate_limits" => limits}, observed_at)
       when is_list(limits) do
    limits
    |> Enum.flat_map(&additional_limit_evidence(&1, observed_at))
    |> keep_highest_percent_per_identity()
    |> Enum.sort_by(&{&1.quota_key, &1.window_kind})
  end

  defp additional_usage_evidence(_payload, _observed_at), do: []

  # Reason: additional limits combine model, feature, reset, and usage hints.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp additional_limit_evidence(%{"rate_limit" => %{} = rate_limit} = limit, observed_at) do
    limit_id =
      present_string(limit["metered_feature"]) || present_string(limit["limit_id"]) ||
        present_string(limit["limit_name"]) || present_string(limit["model"]) ||
        present_string(limit["model_id"]) || present_string(limit["model_identifier"]) ||
        "additional"

    limit_name =
      present_string(limit["limit_name"]) || present_string(limit["model"]) ||
        present_string(limit["model_id"]) || present_string(limit["model_identifier"])

    descriptor =
      Descriptors.limit_descriptor(limit_id, limit_name, %{
        display_label: Descriptors.additional_display_label(limit, limit_id),
        raw_limit_id: limit_id,
        raw_metered_feature: present_string(limit["metered_feature"])
      })

    primary_window = rate_limit["primary_window"] || rate_limit["primary"]
    secondary_window = rate_limit["secondary_window"] || rate_limit["secondary"]

    if weekly_window?(primary_window) do
      [usage_window_attrs("secondary", primary_window, nil, observed_at, descriptor)]
    else
      [
        usage_window_attrs("primary", primary_window, nil, observed_at, descriptor),
        usage_window_attrs("secondary", secondary_window, nil, observed_at, descriptor)
      ]
    end
    |> Enum.reject(&is_nil/1)
  end

  defp additional_limit_evidence(_limit, _observed_at), do: []

  defp usage_window_attrs(_kind, nil, _credits, _observed_at, _descriptor), do: nil

  defp usage_window_attrs(kind, %{} = window, credits, observed_at, descriptor) do
    with {:ok, used_percent} <- finite_percent(window["used_percent"]),
         window_minutes <- usage_window_minutes(kind, window) do
      reset_at = usage_window_reset_at(window, observed_at)

      %{}
      |> Map.merge(descriptor)
      |> Map.merge(%{
        window_kind: kind,
        window_minutes: window_minutes,
        active_limit: infer_active_limit(credits, used_percent),
        credits: credits,
        reset_at: reset_at,
        used_percent: Decimal.from_float(used_percent),
        source: "codex_usage_api",
        source_precision: if(is_nil(reset_at), do: "inferred", else: "observed"),
        freshness_state: "fresh",
        last_sync_at: observed_at,
        observed_at: observed_at,
        metadata:
          compact_metadata(%{
            "limit_window_seconds" => integer_or_nil(window["limit_window_seconds"]),
            "reset_after_seconds" => integer_or_nil(window["reset_after_seconds"])
          })
      })
    end
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

  defp keep_highest_percent_per_identity(attrs_list) do
    attrs_list
    |> Enum.reduce(%{}, fn attrs, acc ->
      key = {
        Map.get(attrs, :quota_key),
        Map.get(attrs, :window_kind)
      }

      Map.update(acc, key, attrs, fn existing ->
        # Reason: reduce callback keeps the highest observed usage percent.
        # credo:disable-for-next-line Credo.Check.Refactor.Nesting
        if quota_used_percent(attrs) >= quota_used_percent(existing), do: attrs, else: existing
      end)
    end)
    |> Map.values()
  end

  defp usage_window_minutes(kind, window) do
    seconds = integer_or_nil(window["limit_window_seconds"])

    cond do
      is_integer(seconds) and seconds > 0 -> div(seconds + 59, 60)
      kind == "secondary" -> 10_080
      true -> 300
    end
  end

  defp weekly_window?(%{} = window), do: integer_or_nil(window["limit_window_seconds"]) == 604_800
  defp weekly_window?(_window), do: false

  defp usage_window_reset_at(%{} = window, observed_at) do
    if weekly_window?(window) do
      ResetTimes.explicit_reset_at_from(window)
    else
      ResetTimes.reset_at_from(window, observed_at)
    end
  end

  defp codex_usage_credits(%{"balance" => balance}), do: codex_credit_balance(balance)
  defp codex_usage_credits(_credits), do: nil

  defp codex_credit_balance(balance) when is_integer(balance) and balance >= 0, do: balance

  defp codex_credit_balance(balance) when is_float(balance) do
    cond do
      balance == 0 -> 0
      balance > 0 -> round(balance)
      true -> nil
    end
  end

  defp codex_credit_balance(balance) when is_binary(balance) do
    balance = String.trim(balance)

    cond do
      balance == "" ->
        nil

      match?({_, ""}, Integer.parse(balance)) ->
        {value, ""} = Integer.parse(balance)
        if value >= 0, do: value

      true ->
        case Float.parse(balance) do
          {value, ""} when value == 0 -> 0
          {value, ""} when value > 0 -> round(value)
          _invalid -> nil
        end
    end
  end

  defp codex_credit_balance(_balance), do: nil

  defp infer_active_limit(nil, _used_percent), do: nil
  defp infer_active_limit(credits, used_percent) when used_percent <= 0, do: credits
  defp infer_active_limit(_credits, used_percent) when used_percent >= 100, do: nil

  defp infer_active_limit(credits, used_percent) do
    max(round(credits / (1.0 - used_percent / 100.0)), credits)
  end

  defp quota_used_percent(%{used_percent: %Decimal{} = percent}), do: Decimal.to_float(percent)
  defp quota_used_percent(%{used_percent: percent}) when is_number(percent), do: percent / 1
  defp quota_used_percent(_attrs), do: -1.0

  defp compact_metadata(metadata) do
    metadata
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp normalize_token(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_token(value), do: value

  defp present_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp present_string(_value), do: nil

  defp positive_integer(value) do
    case integer_or_nil(value) do
      integer when is_integer(integer) and integer > 0 -> integer
      _invalid -> nil
    end
  end

  defp integer_or_nil(value) when is_integer(value), do: value
  defp integer_or_nil(value) when is_float(value), do: trunc(value)

  defp integer_or_nil(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _invalid -> nil
    end
  end

  defp integer_or_nil(_value), do: nil

  defp finite_percent_value(value) do
    case finite_percent(value) do
      {:ok, percent} -> Decimal.from_float(percent)
      :error -> nil
    end
  end

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

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
