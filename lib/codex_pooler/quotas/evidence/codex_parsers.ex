defmodule CodexPooler.Quotas.Evidence.CodexParsers do
  @moduledoc """
  Codex upstream quota dialect parsers for normalized quota evidence.

  This module owns the external payload/header/event shapes. The parent
  `Evidence` module remains the normalized value, validation, and freshness API.
  """

  alias CodexPooler.Quotas.{AccountAvailability, Evidence}

  alias CodexPooler.Quotas.Evidence.CodexParsers.{
    RateLimitEvents,
    RateLimitReachedType,
    ResetTimes,
    ResponseHeaders,
    WindowKinds
  }

  alias CodexPooler.Quotas.Evidence.Descriptors

  @window_kinds ~w(primary secondary)

  @type usage_result :: %{
          required(:windows) => [Evidence.t()],
          required(:account_availability) => AccountAvailability.t() | nil
        }

  @spec parse_codex_usage_result(term(), DateTime.t()) ::
          {:ok, usage_result()}
          | {:error, %{required(:code) => atom(), required(:message) => String.t()}}
  def parse_codex_usage_result(payload, observed_at \\ now())

  def parse_codex_usage_result(%{} = payload, observed_at) do
    credits = codex_usage_credits(payload["credits"])
    account_window_selection = account_window_selection(payload["rate_limit"])

    windows =
      payload
      |> account_usage_evidence(credits, observed_at, :strict)
      |> Kernel.++(additional_usage_evidence(payload, observed_at, :strict))
      |> normalize_many(observed_at)
      |> dedupe_by_identity()

    {:ok,
     %{
       windows: windows,
       account_availability: account_availability(payload, account_window_selection)
     }}
  end

  def parse_codex_usage_result(_payload, _observed_at), do: unusable_usage_payload()

  @spec parse_codex_usage_payload(term(), DateTime.t()) ::
          {:ok, [Evidence.t()]}
          | {:error, %{required(:code) => atom(), required(:message) => String.t()}}
  def parse_codex_usage_payload(payload, observed_at \\ now())

  def parse_codex_usage_payload(payload, observed_at) do
    case legacy_usage_windows(payload, observed_at) do
      [] -> unusable_usage_payload()
      windows -> {:ok, windows}
    end
  end

  defp legacy_usage_windows(%{} = payload, observed_at) do
    credits = codex_usage_credits(payload["credits"])

    payload
    |> account_usage_evidence(credits, observed_at, :legacy)
    |> Kernel.++(additional_usage_evidence(payload, observed_at, :legacy))
    |> normalize_many(observed_at)
    |> dedupe_by_identity()
  end

  defp legacy_usage_windows(_payload, _observed_at), do: []

  @spec legacy_usage_windows_for_strict_result(term(), DateTime.t()) :: [Evidence.t()]
  def legacy_usage_windows_for_strict_result(payload, observed_at) do
    if is_map(payload) and not Map.has_key?(payload, "plan_type") do
      legacy_usage_windows(payload, observed_at)
    else
      []
    end
  end

  defp unusable_usage_payload do
    {:error,
     %{code: :upstream_quota_unusable, message: "upstream quota payload had no usable windows"}}
  end

  defp account_availability(payload, account_windows) do
    signals =
      [
        rate_limit_signal(payload),
        credits_signal(payload),
        spend_control_signal(payload),
        reached_type_signal(payload),
        window_signal(account_windows),
        additional_integrity_signal(payload)
      ]
      |> Enum.reject(&is_nil/1)

    basis = strongest_basis(signals)

    if is_nil(basis) or no_window_plan_invalid?(payload, account_windows) do
      nil
    else
      basis
      |> basis_state()
      |> AccountAvailability.new!(basis, account_windows)
    end
  end

  # The generated wire schema requires both booleans. The upstream client drops
  # them from its snapshot projection, so consuming the complementary positive
  # shape here is deliberately a Pooler direct-wire policy, not client parity.
  defp rate_limit_signal(payload) do
    case Map.fetch(payload, "rate_limit") do
      :error ->
        nil

      {:ok, nil} ->
        nil

      {:ok, %{"allowed" => allowed, "limit_reached" => limit_reached}}
      when is_boolean(allowed) and is_boolean(limit_reached) ->
        complementary_rate_limit_signal(allowed, limit_reached)

      {:ok, _malformed} ->
        :conflict
    end
  end

  defp complementary_rate_limit_signal(true, false), do: :affirmative
  defp complementary_rate_limit_signal(false, true), do: :blocker
  defp complementary_rate_limit_signal(_allowed, _limit_reached), do: :conflict

  defp credits_signal(payload) do
    case Map.fetch(payload, "credits") do
      :error ->
        nil

      {:ok, nil} ->
        nil

      {:ok, %{"has_credits" => has_credits, "unlimited" => unlimited}}
      when is_boolean(has_credits) and is_boolean(unlimited) ->
        if has_credits or unlimited, do: :affirmative, else: :no_proof

      {:ok, _malformed} ->
        :conflict
    end
  end

  defp spend_control_signal(payload) do
    case Map.fetch(payload, "spend_control") do
      :error -> nil
      {:ok, nil} -> nil
      {:ok, %{"reached" => reached}} when is_boolean(reached) -> if(reached, do: :blocker)
      {:ok, _malformed} -> :conflict
    end
  end

  defp reached_type_signal(payload) do
    case Map.fetch(payload, "rate_limit_reached_type") do
      :error -> nil
      {:ok, nil} -> nil
      {:ok, %{"type" => type}} when is_binary(type) -> reached_type_value_signal(type)
      {:ok, _malformed} -> :conflict
    end
  end

  defp reached_type_value_signal(type) do
    if RateLimitReachedType.parse(type), do: :blocker, else: :conflict
  end

  defp account_window_selection(nil), do: :absent

  defp account_window_selection(%{} = rate_limit) do
    [selected_window_state(rate_limit, "primary"), selected_window_state(rate_limit, "secondary")]
    |> combined_window_state()
  end

  defp account_window_selection(_malformed), do: :unknown

  defp selected_window(rate_limit, slot) do
    canonical = "#{slot}_window"

    case Map.fetch(rate_limit, canonical) do
      {:ok, value} when not is_nil(value) -> value
      _missing_or_null -> Map.get(rate_limit, slot)
    end
  end

  defp selected_window_state(rate_limit, slot) do
    case selected_window(rate_limit, slot) do
      nil -> :absent
      %{} = window -> if(valid_usage_window?(window), do: :present, else: :unknown)
      _malformed -> :unknown
    end
  end

  defp combined_window_state(states) do
    cond do
      :unknown in states -> :unknown
      :present in states -> :present
      true -> :absent
    end
  end

  defp valid_usage_window?(%{
         "used_percent" => used_percent,
         "limit_window_seconds" => limit_window_seconds,
         "reset_after_seconds" => reset_after_seconds,
         "reset_at" => reset_at
       }) do
    is_integer(used_percent) and used_percent in 0..100 and
      is_integer(limit_window_seconds) and limit_window_seconds > 0 and
      is_integer(reset_after_seconds) and reset_after_seconds >= 0 and
      is_integer(reset_at) and reset_at > 0
  end

  defp valid_usage_window?(_window), do: false

  defp window_signal(:unknown), do: :conflict
  defp window_signal(_state), do: nil

  defp additional_integrity_signal(payload) do
    case Map.fetch(payload, "additional_rate_limits") do
      :error ->
        nil

      {:ok, nil} ->
        nil

      {:ok, limits} when is_list(limits) ->
        if(Enum.all?(limits, &valid_additional_limit?/1), do: nil, else: :conflict)

      {:ok, _malformed} ->
        :conflict
    end
  end

  defp valid_additional_limit?(
         %{
           "limit_name" => limit_name,
           "metered_feature" => metered_feature
         } = limit
       )
       when is_binary(limit_name) and is_binary(metered_feature) do
    present_string(limit_name) && present_string(metered_feature) &&
      valid_additional_rate_limit?(Map.fetch(limit, "rate_limit"))
  end

  defp valid_additional_limit?(_malformed), do: false

  defp valid_additional_rate_limit?(:error), do: true
  defp valid_additional_rate_limit?({:ok, nil}), do: true

  defp valid_additional_rate_limit?({:ok, %{} = rate_limit}) do
    rate_limit_signal(%{"rate_limit" => rate_limit}) == :affirmative and
      account_window_selection(rate_limit) != :unknown
  end

  defp valid_additional_rate_limit?({:ok, _malformed}), do: false

  defp strongest_basis(signals) do
    Enum.find([:blocker, :conflict, :affirmative, :no_proof], &(&1 in signals))
  end

  defp basis_state(:affirmative), do: :available
  defp basis_state(:blocker), do: :blocked
  defp basis_state(basis) when basis in [:conflict, :no_proof], do: :unknown

  defp no_window_plan_invalid?(payload, account_windows) do
    account_windows != :present and is_nil(present_string(payload["plan_type"]))
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
      kind = if(kind in @window_kinds, do: kind, else: "primary")

      %{}
      |> Map.merge(descriptor)
      |> Map.merge(%{
        window_kind: WindowKinds.normalize_window_kind(kind, window_minutes),
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

  defp account_usage_evidence(
         %{"rate_limit" => %{} = rate_limit},
         credits,
         observed_at,
         validation
       ) do
    primary_window = selected_window(rate_limit, "primary")
    secondary_window = selected_window(rate_limit, "secondary")
    descriptor = Descriptors.account_descriptor()
    provider_status = provider_status_metadata(rate_limit)

    if weekly_window?(primary_window) do
      [
        usage_window_attrs(
          "secondary",
          primary_window,
          credits,
          observed_at,
          descriptor,
          validation
        )
      ]
    else
      [
        usage_window_attrs(
          "primary",
          primary_window,
          credits,
          observed_at,
          descriptor,
          validation
        ),
        usage_window_attrs(
          "secondary",
          secondary_window,
          credits,
          observed_at,
          descriptor,
          validation
        )
      ]
    end
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&put_provider_status(&1, provider_status))
  end

  defp account_usage_evidence(_payload, _credits, _observed_at, _validation), do: []

  defp additional_usage_evidence(%{"additional_rate_limits" => limits}, observed_at, validation)
       when is_list(limits) do
    limits
    |> Enum.flat_map(&additional_limit_evidence(&1, observed_at, validation))
    |> Enum.sort_by(&{&1.quota_key, &1.window_kind})
  end

  defp additional_usage_evidence(_payload, _observed_at, _validation), do: []

  # Reason: additional limits combine model, feature, reset, and usage hints.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp additional_limit_evidence(
         %{"rate_limit" => %{} = rate_limit} = limit,
         observed_at,
         validation
       ) do
    raw_metered_feature = present_string(limit["metered_feature"])
    raw_limit_id = present_string(limit["limit_id"]) || raw_metered_feature

    descriptor_id =
      raw_metered_feature || raw_limit_id ||
        present_string(limit["limit_name"]) || present_string(limit["model"]) ||
        present_string(limit["model_id"]) || present_string(limit["model_identifier"]) ||
        "additional"

    limit_name =
      present_string(limit["limit_name"]) || present_string(limit["model"]) ||
        present_string(limit["model_id"]) || present_string(limit["model_identifier"])

    descriptor =
      Descriptors.limit_descriptor(descriptor_id, limit_name, %{
        display_label: Descriptors.additional_display_label(limit, descriptor_id),
        metered_feature: raw_metered_feature || raw_limit_id,
        raw_limit_id: raw_limit_id,
        raw_metered_feature: raw_metered_feature
      })

    primary_window = selected_window(rate_limit, "primary")
    secondary_window = selected_window(rate_limit, "secondary")

    if weekly_window?(primary_window) do
      [usage_window_attrs("secondary", primary_window, nil, observed_at, descriptor, validation)]
    else
      [
        usage_window_attrs("primary", primary_window, nil, observed_at, descriptor, validation),
        usage_window_attrs(
          "secondary",
          secondary_window,
          nil,
          observed_at,
          descriptor,
          validation
        )
      ]
    end
    |> Enum.reject(&is_nil/1)
  end

  defp additional_limit_evidence(_limit, _observed_at, _validation), do: []

  defp usage_window_attrs(_kind, nil, _credits, _observed_at, _descriptor, _validation), do: nil

  defp usage_window_attrs(kind, %{} = window, credits, observed_at, descriptor, validation) do
    with true <- valid_window_for?(window, validation),
         {:ok, used_percent} <- finite_percent(window["used_percent"]) do
      window_minutes = usage_window_minutes(kind, window)
      reset_at = usage_window_reset_at(window, observed_at)

      %{}
      |> Map.merge(descriptor)
      |> Map.merge(%{
        window_kind: kind,
        window_minutes: window_minutes,
        active_limit: credit_balance_baseline(credits),
        credits: credits,
        reset_at: reset_at,
        used_percent: Decimal.from_float(used_percent),
        source: "codex_usage_api",
        source_precision: ResetTimes.reset_source_precision(window, reset_at),
        freshness_state: "fresh",
        last_sync_at: observed_at,
        observed_at: observed_at,
        metadata:
          compact_metadata(%{
            "limit_window_seconds" => integer_or_nil(window["limit_window_seconds"]),
            "reset_after_seconds" => integer_or_nil(window["reset_after_seconds"]),
            "reset_at_source" => explicit_account_reset_source(window, descriptor)
          })
      })
    else
      _invalid -> nil
    end
  end

  defp usage_window_attrs(
         _kind,
         _malformed,
         _credits,
         _observed_at,
         _descriptor,
         _validation
       ),
       do: nil

  defp valid_window_for?(window, :strict), do: valid_usage_window?(window)

  defp valid_window_for?(window, :legacy),
    do: match?({:ok, _percent}, finite_percent(window["used_percent"]))

  # Account windows treat an absolute reset as canonical even when the provider
  # includes a matching countdown. Model weekly windows deliberately keep the
  # countdown semantics because their floating/anchored proof uses both fields.
  defp explicit_account_reset_source(window, descriptor) do
    if Map.get(descriptor, :quota_scope) == "account" and
         ResetTimes.explicit_reset_at_from(window) do
      "explicit"
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
      Map.update(acc, payload_identity_key(evidence), evidence, fn existing ->
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

  defp payload_identity_key(%Evidence{} = evidence) do
    case canonical_meter_token(evidence) do
      nil ->
        Evidence.identity_key(evidence)

      meter_token ->
        {
          evidence.quota_scope,
          evidence.quota_family,
          evidence.model,
          evidence.upstream_model,
          evidence.quota_key,
          evidence.window_kind,
          evidence.window_minutes,
          evidence.source,
          meter_token
        }
    end
  end

  defp canonical_meter_token(%Evidence{} = evidence),
    do: present_string(evidence.raw_metered_feature) || present_string(evidence.raw_limit_id)

  defp usage_window_minutes(kind, window) do
    case integer_or_nil(window["limit_window_seconds"]) do
      seconds when is_integer(seconds) and seconds > 0 -> div(seconds + 59, 60)
      _missing when kind == "secondary" -> 10_080
      _missing -> 300
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

  # The usage payload reports a current balance, not a total credit capacity.
  # Evidence merging keeps this first balance as the burn-meter baseline once
  # included quota reaches 100% and the balance starts decreasing.
  defp credit_balance_baseline(credits) when is_integer(credits) and credits >= 0, do: credits
  defp credit_balance_baseline(_credits), do: nil

  defp provider_status_metadata(%{"allowed" => allowed, "limit_reached" => limit_reached})
       when is_boolean(allowed) and is_boolean(limit_reached) and allowed == not limit_reached do
    %{
      "rate_limit_allowed" => allowed,
      "rate_limit_reached" => limit_reached
    }
  end

  defp provider_status_metadata(_rate_limit), do: %{}

  defp put_provider_status(attrs, provider_status) do
    Map.update!(attrs, :metadata, &Map.merge(&1, provider_status))
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
