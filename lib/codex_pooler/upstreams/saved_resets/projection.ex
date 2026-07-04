defmodule CodexPooler.Upstreams.SavedResets do
  @moduledoc """
  Metadata-only helpers for Codex saved reset observations and policy projection.
  """

  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @reported "reported"
  @unreported "unreported"
  @unavailable "unavailable"
  @usage_source "codex_usage_api"
  @reset_credits_source "codex_reset_credits_api"
  @codex_path_style "codex_api"
  @chatgpt_path_style "chatgpt_api"
  @unknown_path_style "unknown"
  @default_min_blocked_minutes 60
  @default_keep_credits 0
  @default_trigger_mode "blocked"
  @default_quota_threshold_percent 95
  @expiration_refresh_ttl_seconds 6 * 60 * 60
  @expiring_soon_seconds 24 * 60 * 60
  @redemption_projection_receive_timeout_ms 15_000
  @redemption_projection_stale_grace_ms 60_000

  @type count_parse_result :: {:reported, non_neg_integer()} | :unreported
  @type available_expiration_row :: %{
          required(:expires_at) => String.t(),
          required(:first_seen_at) => String.t() | nil
        }
  @type stored_available_expiration_row :: %{
          required(String.t()) => String.t()
        }
  @type saved_reset_metadata :: %{
          required(String.t()) =>
            String.t()
            | non_neg_integer()
            | [String.t()]
            | [stored_available_expiration_row()]
            | map()
            | nil
        }
  @type snapshot_projection :: %{
          required(:status) => String.t(),
          required(:available_count) => non_neg_integer() | nil,
          required(:reported?) => boolean(),
          required(:available?) => boolean(),
          required(:label) => String.t(),
          required(:source) => String.t() | nil,
          required(:path_style) => String.t() | nil,
          required(:usage_path) => String.t() | nil,
          required(:observed_at) => String.t() | nil,
          required(:available_expires_at) => [String.t()],
          required(:available_expirations) => [available_expiration_row()],
          required(:next_expires_at) => String.t() | nil,
          required(:expires_observed_at) => String.t() | nil,
          required(:expires_refresh_attempted_at) => String.t() | nil,
          required(:expires_reported?) => boolean(),
          required(:in_progress?) => boolean(),
          required(:redemption_stale?) => boolean(),
          required(:last_redemption) => map() | nil
        }
  @type auto_policy_projection :: %{
          required(:enabled?) => boolean(),
          required(:min_blocked_minutes) => non_neg_integer(),
          required(:keep_credits) => non_neg_integer(),
          required(:trigger_mode) => String.t(),
          required(:quota_threshold_percent) => 1..100
        }

  @spec count_from_usage_payload(term()) :: count_parse_result()
  def count_from_usage_payload(%{"rate_limit_reset_credits" => %{} = reset_credits}) do
    reset_credits
    |> Map.get("available_count")
    |> non_negative_truncated_integer()
    |> case do
      {:ok, count} -> {:reported, count}
      :error -> :unreported
    end
  end

  def count_from_usage_payload(_payload), do: :unreported

  @spec usage_snapshot(term(), DateTime.t(), String.t() | nil) :: saved_reset_metadata()
  def usage_snapshot(payload, %DateTime{} = observed_at, usage_url),
    do: usage_snapshot(payload, observed_at, usage_url, nil)

  @spec usage_snapshot(term(), DateTime.t(), String.t() | nil, UpstreamIdentity.t() | map() | nil) ::
          saved_reset_metadata()
  def usage_snapshot(payload, %DateTime{} = observed_at, usage_url, previous_metadata) do
    {usage_path, path_style} = usage_path_style(usage_url)

    case count_from_usage_payload(payload) do
      {:reported, count} ->
        %{
          "status" => @reported,
          "available_count" => count,
          "source" => @usage_source,
          "path_style" => path_style,
          "observed_at" => DateTime.to_iso8601(observed_at),
          "usage_path" => usage_path,
          "reason" => nil
        }
        |> Map.merge(expiration_metadata_from_payload(payload, observed_at, previous_metadata))

      :unreported ->
        %{
          "status" => @unreported,
          "available_count" => nil,
          "source" => @usage_source,
          "path_style" => path_style,
          "observed_at" => DateTime.to_iso8601(observed_at),
          "usage_path" => usage_path,
          "available_expires_at" => [],
          "available_expirations" => [],
          "next_expires_at" => nil,
          "expires_observed_at" => nil,
          "expires_refresh_attempted_at" => nil,
          "reason" => %{"code" => "saved_resets_unreported"}
        }
    end
  end

  @spec credit_list_snapshot(term(), DateTime.t(), String.t() | nil) :: saved_reset_metadata()
  def credit_list_snapshot(payload, %DateTime{} = observed_at, usage_url),
    do: credit_list_snapshot(payload, observed_at, usage_url, nil)

  @spec credit_list_snapshot(
          term(),
          DateTime.t(),
          String.t() | nil,
          UpstreamIdentity.t() | map() | nil
        ) ::
          saved_reset_metadata()
  def credit_list_snapshot(payload, %DateTime{} = observed_at, usage_url, previous_metadata) do
    {usage_path, path_style} = usage_path_style(usage_url)

    %{
      "status" => @reported,
      "available_count" => available_count_from_credit_list(payload),
      "source" => @reset_credits_source,
      "path_style" => path_style,
      "observed_at" => DateTime.to_iso8601(observed_at),
      "usage_path" => usage_path,
      "reason" => nil
    }
    |> Map.merge(expiration_metadata_from_payload(payload, observed_at, previous_metadata))
  end

  @spec unavailable_snapshot(DateTime.t(), String.t()) :: saved_reset_metadata()
  def unavailable_snapshot(%DateTime{} = observed_at, code) when is_binary(code) do
    %{
      "status" => @unavailable,
      "available_count" => nil,
      "source" => @reset_credits_source,
      "path_style" => @unknown_path_style,
      "observed_at" => DateTime.to_iso8601(observed_at),
      "usage_path" => nil,
      "available_expires_at" => [],
      "available_expirations" => [],
      "next_expires_at" => nil,
      "expires_observed_at" => nil,
      "expires_refresh_attempted_at" => nil,
      "reason" => %{"code" => code}
    }
  end

  @spec snapshot(UpstreamIdentity.t() | map() | nil) :: snapshot_projection()
  def snapshot(identity_or_metadata), do: snapshot(identity_or_metadata, now())

  @spec snapshot(UpstreamIdentity.t() | map() | nil, DateTime.t()) :: snapshot_projection()
  def snapshot(%UpstreamIdentity{} = identity, %DateTime{} = timestamp),
    do: snapshot(identity.metadata, timestamp)

  def snapshot(%{} = metadata, %DateTime{} = timestamp) do
    snapshot = Map.get(metadata, "saved_resets", metadata)
    redemption = Map.get(metadata, "saved_reset_redemption")
    redemption_state = redemption_state(redemption, timestamp)
    status = snapshot_status(snapshot)
    available_count = snapshot_available_count(snapshot, status)
    available_expires_at = snapshot_available_expires_at(snapshot)
    available_expirations = snapshot_available_expirations(snapshot, available_expires_at)
    next_expires_at = snapshot_next_expires_at(snapshot, available_expires_at)
    expires_observed_at = snapshot_expires_observed_at(snapshot)
    expires_refresh_attempted_at = snapshot_expires_refresh_attempted_at(snapshot)
    reported? = status == @reported
    available? = reported? and is_integer(available_count) and available_count > 0

    %{
      status: status,
      available_count: available_count,
      reported?: reported?,
      available?: available?,
      label: label(status, available_count),
      source: string_or_nil(snapshot["source"]),
      path_style: string_or_nil(snapshot["path_style"]),
      usage_path: string_or_nil(snapshot["usage_path"]),
      observed_at: string_or_nil(snapshot["observed_at"]),
      available_expires_at: available_expires_at,
      available_expirations: available_expirations,
      next_expires_at: next_expires_at,
      expires_observed_at: expires_observed_at,
      expires_refresh_attempted_at: expires_refresh_attempted_at,
      expires_reported?: next_expires_at != nil,
      in_progress?: redemption_state == :in_progress,
      redemption_stale?: redemption_state == :stale,
      last_redemption: redemption_or_nil(redemption)
    }
  end

  def snapshot(_identity_or_metadata, %DateTime{} = timestamp) do
    snapshot(%{"saved_resets" => %{}}, timestamp)
  end

  @spec reset_credit_list_refresh_due?(
          UpstreamIdentity.t() | map(),
          non_neg_integer(),
          DateTime.t()
        ) ::
          boolean()
  def reset_credit_list_refresh_due?(
        identity_or_metadata,
        available_count,
        %DateTime{} = timestamp
      )
      when is_integer(available_count) do
    snapshot = snapshot(identity_or_metadata)

    cond do
      available_count <= 0 ->
        false

      snapshot.available_count != available_count ->
        true

      expiration_refresh_recent?(snapshot.expires_refresh_attempted_at, timestamp) ->
        false

      snapshot.expires_observed_at == nil ->
        true

      expiration_observation_stale?(snapshot.expires_observed_at, timestamp) ->
        true

      not next_expiration_future?(snapshot.next_expires_at, timestamp) ->
        true

      true ->
        false
    end
  end

  def reset_credit_list_refresh_due?(_identity_or_metadata, _available_count, _timestamp),
    do: false

  @spec reuse_expiration_metadata(term(), UpstreamIdentity.t() | map()) :: term()
  @spec reuse_expiration_metadata(term(), UpstreamIdentity.t() | map(), DateTime.t() | nil) ::
          term()
  def reuse_expiration_metadata(payload, identity_or_metadata, attempted_at \\ nil)

  def reuse_expiration_metadata(payload, identity_or_metadata, attempted_at)
      when is_map(payload) do
    snapshot = snapshot(identity_or_metadata)

    Map.update(payload, "rate_limit_reset_credits", %{}, fn
      %{} = reset_credits -> put_expiration_summary(reset_credits, snapshot, attempted_at)
      other -> other
    end)
  end

  def reuse_expiration_metadata(payload, _identity_or_metadata, _attempted_at), do: payload

  @spec expires_soon?(UpstreamIdentity.t() | map(), DateTime.t()) :: boolean()
  @spec expires_soon?(UpstreamIdentity.t() | map(), DateTime.t(), non_neg_integer()) :: boolean()
  def expires_soon?(
        identity_or_metadata,
        %DateTime{} = timestamp,
        within_seconds \\ @expiring_soon_seconds
      )
      when is_integer(within_seconds) and within_seconds >= 0 do
    snapshot = snapshot(identity_or_metadata)

    with next_expires_at when is_binary(next_expires_at) <- snapshot.next_expires_at,
         {:ok, expires_at, _offset} <- DateTime.from_iso8601(next_expires_at) do
      seconds_until_expiration = DateTime.diff(expires_at, timestamp, :second)

      seconds_until_expiration >= 0 and seconds_until_expiration <= within_seconds
    else
      _invalid -> false
    end
  end

  @spec auto_policy(UpstreamIdentity.t()) :: auto_policy_projection()
  def auto_policy(%UpstreamIdentity{} = identity) do
    %{
      enabled?: identity.saved_reset_auto_redeem_enabled == true,
      min_blocked_minutes:
        non_negative_policy_value(
          identity.saved_reset_auto_redeem_min_blocked_minutes,
          @default_min_blocked_minutes
        ),
      keep_credits:
        non_negative_policy_value(
          identity.saved_reset_auto_redeem_keep_credits,
          @default_keep_credits
        ),
      trigger_mode: trigger_mode(identity.saved_reset_auto_redeem_trigger_mode),
      quota_threshold_percent:
        percent_policy_value(
          identity.saved_reset_auto_redeem_quota_threshold_percent,
          @default_quota_threshold_percent
        )
    }
  end

  defp usage_path_style(usage_url) when is_binary(usage_url) do
    case URI.parse(usage_url).path do
      path when path in ["/api/codex/usage", "/backend-api/codex/usage"] ->
        {path, @codex_path_style}

      path
      when path in [
             "/wham/usage",
             "/backend-api/wham/usage",
             "/wham/rate-limit-reset-credits",
             "/backend-api/wham/rate-limit-reset-credits"
           ] ->
        {chatgpt_usage_path(path), @chatgpt_path_style}

      _path ->
        {nil, @unknown_path_style}
    end
  end

  defp usage_path_style(_usage_url), do: {nil, @unknown_path_style}

  defp chatgpt_usage_path("/wham/rate-limit-reset-credits"), do: "/wham/usage"

  defp chatgpt_usage_path("/backend-api/wham/rate-limit-reset-credits"),
    do: "/backend-api/wham/usage"

  defp chatgpt_usage_path(path), do: path

  defp non_negative_truncated_integer(value) when is_integer(value), do: {:ok, max(value, 0)}

  defp non_negative_truncated_integer(value) when is_float(value) do
    {:ok, value |> trunc() |> max(0)}
  rescue
    _error -> :error
  end

  defp non_negative_truncated_integer(%Decimal{} = value) do
    {:ok, value |> Decimal.round(0, :down) |> Decimal.to_integer() |> max(0)}
  rescue
    _error -> :error
  end

  defp non_negative_truncated_integer(value) when is_binary(value) do
    value = String.trim(value)

    with false <- value == "",
         {decimal, ""} <- Decimal.parse(value) do
      non_negative_truncated_integer(decimal)
    else
      _invalid -> :error
    end
  rescue
    _error -> :error
  end

  defp non_negative_truncated_integer(_value), do: :error

  defp snapshot_status(%{"status" => @reported}), do: @reported
  defp snapshot_status(%{"status" => @unavailable}), do: @unavailable
  defp snapshot_status(%{"status" => @unreported}), do: @unreported
  defp snapshot_status(_snapshot), do: @unreported

  defp snapshot_available_count(%{"available_count" => count}, @reported) do
    case non_negative_truncated_integer(count) do
      {:ok, count} -> count
      :error -> nil
    end
  end

  defp snapshot_available_count(_snapshot, _status), do: nil

  defp snapshot_available_expires_at(%{"available_expires_at" => values}) when is_list(values) do
    values
    |> Enum.map(&safe_iso8601/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort_by(&datetime_sort_key/1)
  end

  defp snapshot_available_expires_at(_snapshot), do: []

  @spec snapshot_available_expirations(map(), [String.t()]) :: [available_expiration_row()]
  defp snapshot_available_expirations(%{"available_expirations" => rows}, _fallback_values)
       when is_list(rows) do
    rows
    |> Enum.map(&available_expiration_row_from_metadata/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.expires_at)
    |> Enum.sort_by(&datetime_sort_key(&1.expires_at))
  end

  defp snapshot_available_expirations(_snapshot, fallback_values) do
    Enum.map(fallback_values, fn expires_at ->
      %{expires_at: expires_at, first_seen_at: nil}
    end)
  end

  defp snapshot_next_expires_at(%{"next_expires_at" => value}, fallback_values) do
    safe_iso8601(value) || List.first(fallback_values)
  end

  defp snapshot_next_expires_at(_snapshot, fallback_values), do: List.first(fallback_values)

  defp snapshot_expires_observed_at(%{"expires_observed_at" => value}), do: safe_iso8601(value)
  defp snapshot_expires_observed_at(_snapshot), do: nil

  defp snapshot_expires_refresh_attempted_at(%{"expires_refresh_attempted_at" => value}),
    do: safe_iso8601(value)

  defp snapshot_expires_refresh_attempted_at(%{"expires_observed_at" => value}),
    do: safe_iso8601(value)

  defp snapshot_expires_refresh_attempted_at(_snapshot), do: nil

  @spec expiration_metadata_from_payload(term(), DateTime.t(), UpstreamIdentity.t() | map() | nil) ::
          %{
            required(String.t()) =>
              [String.t()] | [stored_available_expiration_row()] | String.t() | nil
          }
  defp expiration_metadata_from_payload(payload, observed_at, previous_metadata) do
    case credit_list_payload(payload) do
      {:ok, credits} -> expiration_metadata_from_credits(credits, observed_at, previous_metadata)
      :error -> expiration_metadata_from_summary(payload, observed_at, previous_metadata)
    end
  end

  @spec expiration_metadata_from_credits(
          [term()],
          DateTime.t(),
          UpstreamIdentity.t() | map() | nil
        ) ::
          %{
            required(String.t()) =>
              [String.t()] | [stored_available_expiration_row()] | String.t() | nil
          }
  defp expiration_metadata_from_credits(credits, observed_at, previous_metadata) do
    expires_at = available_expiration_iso8601s(credits)
    observed_at_iso8601 = DateTime.to_iso8601(observed_at)
    previous_first_seen = previous_first_seen_by_expires_at(previous_metadata)

    %{
      "available_expires_at" => expires_at,
      "available_expirations" =>
        available_expiration_rows(expires_at, previous_first_seen, observed_at_iso8601),
      "next_expires_at" => List.first(expires_at),
      "expires_observed_at" => observed_at_iso8601,
      "expires_refresh_attempted_at" => observed_at_iso8601
    }
  end

  @spec expiration_metadata_from_summary(term(), DateTime.t(), UpstreamIdentity.t() | map() | nil) ::
          %{
            required(String.t()) =>
              [String.t()] | [stored_available_expiration_row()] | String.t() | nil
          }
  defp expiration_metadata_from_summary(payload, observed_at, previous_metadata) do
    summary = reset_credit_summary(payload)
    expires_at = summary_available_expiration_iso8601s(summary)
    observed_at_iso8601 = DateTime.to_iso8601(observed_at)
    previous_first_seen = previous_first_seen_by_expires_at(previous_metadata)

    %{
      "available_expires_at" => expires_at,
      "available_expirations" =>
        available_expiration_rows(expires_at, previous_first_seen, observed_at_iso8601),
      "next_expires_at" => snapshot_next_expires_at(summary, expires_at),
      "expires_observed_at" => snapshot_expires_observed_at(summary),
      "expires_refresh_attempted_at" => snapshot_expires_refresh_attempted_at(summary)
    }
  end

  defp available_count_from_credit_list(%{} = payload) do
    case non_negative_truncated_integer(Map.get(payload, "available_count")) do
      {:ok, count} -> count
      :error -> payload |> credit_list_from_payload() |> Enum.count(&available_credit?/1)
    end
  end

  defp available_count_from_credit_list(_payload), do: 0

  defp put_expiration_summary(reset_credits, snapshot, attempted_at) do
    reset_credits
    |> Map.put("available_expires_at", snapshot.available_expires_at)
    |> Map.put(
      "available_expirations",
      stored_available_expiration_rows(snapshot.available_expirations)
    )
    |> Map.put("next_expires_at", snapshot.next_expires_at)
    |> Map.put("expires_observed_at", snapshot.expires_observed_at)
    |> Map.put(
      "expires_refresh_attempted_at",
      expiration_refresh_attempted_at(snapshot, attempted_at)
    )
  end

  defp expiration_refresh_attempted_at(_snapshot, %DateTime{} = attempted_at),
    do: DateTime.to_iso8601(attempted_at)

  defp expiration_refresh_attempted_at(snapshot, _attempted_at),
    do: snapshot.expires_refresh_attempted_at

  defp expiration_refresh_recent?(attempted_at, timestamp) when is_binary(attempted_at) do
    case DateTime.from_iso8601(attempted_at) do
      {:ok, attempted_at, _offset} ->
        DateTime.diff(timestamp, attempted_at, :second) < @expiration_refresh_ttl_seconds

      _invalid ->
        false
    end
  end

  defp expiration_refresh_recent?(_attempted_at, _timestamp), do: false

  defp expiration_observation_stale?(observed_at, timestamp) when is_binary(observed_at) do
    case DateTime.from_iso8601(observed_at) do
      {:ok, observed_at, _offset} ->
        DateTime.diff(timestamp, observed_at, :second) >= @expiration_refresh_ttl_seconds

      _invalid ->
        true
    end
  end

  defp expiration_observation_stale?(_observed_at, _timestamp), do: true

  defp next_expiration_future?(expires_at, timestamp) when is_binary(expires_at) do
    case DateTime.from_iso8601(expires_at) do
      {:ok, expires_at, _offset} ->
        DateTime.compare(expires_at, timestamp) == :gt

      _invalid ->
        false
    end
  end

  defp next_expiration_future?(_expires_at, _timestamp), do: false

  defp reset_credit_summary(%{"rate_limit_reset_credits" => %{} = reset_credits}),
    do: reset_credits

  defp reset_credit_summary(%{} = payload), do: payload
  defp reset_credit_summary(_payload), do: %{}

  defp credit_list_payload(%{"rate_limit_reset_credits" => %{"credits" => credits}})
       when is_list(credits),
       do: {:ok, credits}

  defp credit_list_payload(%{"credits" => credits}) when is_list(credits), do: {:ok, credits}
  defp credit_list_payload(_payload), do: :error

  defp credit_list_from_payload(payload) do
    case credit_list_payload(payload) do
      {:ok, credits} -> credits
      :error -> []
    end
  end

  defp available_expiration_iso8601s(credits) when is_list(credits) do
    credits
    |> Enum.filter(&available_credit?/1)
    |> Enum.map(fn credit -> safe_iso8601(credit["expires_at"]) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort_by(&datetime_sort_key/1)
  end

  @spec summary_available_expiration_iso8601s(map()) :: [String.t()]
  defp summary_available_expiration_iso8601s(summary) do
    (snapshot_available_expires_at(summary) ++ summary_available_expiration_row_iso8601s(summary))
    |> Enum.uniq()
    |> Enum.sort_by(&datetime_sort_key/1)
  end

  @spec summary_available_expiration_row_iso8601s(map()) :: [String.t()]
  defp summary_available_expiration_row_iso8601s(%{"available_expirations" => rows})
       when is_list(rows) do
    rows
    |> Enum.map(&available_expiration_expires_at/1)
    |> Enum.reject(&is_nil/1)
  end

  defp summary_available_expiration_row_iso8601s(_summary), do: []

  defp available_expiration_expires_at(%{"expires_at" => expires_at}),
    do: safe_iso8601(expires_at)

  defp available_expiration_expires_at(%{expires_at: expires_at}), do: safe_iso8601(expires_at)
  defp available_expiration_expires_at(_row), do: nil

  @spec available_expiration_rows([String.t()], map(), String.t()) :: [
          stored_available_expiration_row()
        ]
  defp available_expiration_rows(expires_at_values, previous_first_seen, observed_at)
       when is_list(expires_at_values) and is_map(previous_first_seen) and is_binary(observed_at) do
    Enum.map(expires_at_values, fn expires_at ->
      %{
        "expires_at" => expires_at,
        "first_seen_at" => Map.get(previous_first_seen, expires_at, observed_at)
      }
    end)
  end

  @spec previous_first_seen_by_expires_at(UpstreamIdentity.t() | map() | nil) :: map()
  defp previous_first_seen_by_expires_at(%UpstreamIdentity{} = identity),
    do: previous_first_seen_by_expires_at(identity.metadata)

  defp previous_first_seen_by_expires_at(%{} = metadata) do
    snapshot = Map.get(metadata, "saved_resets", metadata)
    expires_at_values = snapshot_available_expires_at(snapshot)

    snapshot
    |> snapshot_available_expirations(expires_at_values)
    |> Enum.reduce(%{}, fn
      %{expires_at: expires_at, first_seen_at: first_seen_at}, acc
      when is_binary(first_seen_at) ->
        Map.put(acc, expires_at, first_seen_at)

      _row, acc ->
        acc
    end)
  end

  defp previous_first_seen_by_expires_at(_previous_metadata), do: %{}

  @spec stored_available_expiration_rows([available_expiration_row()]) :: [
          stored_available_expiration_row()
        ]
  defp stored_available_expiration_rows(rows) when is_list(rows) do
    rows
    |> Enum.map(fn
      %{expires_at: expires_at, first_seen_at: first_seen_at}
      when is_binary(expires_at) and is_binary(first_seen_at) ->
        %{"expires_at" => expires_at, "first_seen_at" => first_seen_at}

      _row ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  @spec available_expiration_row_from_metadata(term()) :: available_expiration_row() | nil
  defp available_expiration_row_from_metadata(%{"expires_at" => expires_at} = row) do
    with expires_at when is_binary(expires_at) <- safe_iso8601(expires_at) do
      %{
        expires_at: expires_at,
        first_seen_at: safe_iso8601(row["first_seen_at"])
      }
    end
  end

  defp available_expiration_row_from_metadata(%{expires_at: expires_at} = row) do
    with expires_at when is_binary(expires_at) <- safe_iso8601(expires_at) do
      %{
        expires_at: expires_at,
        first_seen_at: safe_iso8601(row[:first_seen_at])
      }
    end
  end

  defp available_expiration_row_from_metadata(_row), do: nil

  defp available_credit?(%{"status" => status}) when is_binary(status), do: status == "available"
  defp available_credit?(%{}), do: true
  defp available_credit?(_credit), do: false

  defp safe_iso8601(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_iso8601(datetime)
      _invalid -> nil
    end
  end

  defp safe_iso8601(_value), do: nil

  defp datetime_sort_key(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :microsecond)
      _invalid -> 0
    end
  end

  defp datetime_sort_key(_value), do: 0

  defp label(@reported, 1), do: "1 saved reset"
  defp label(@reported, count) when is_integer(count) and count > 1, do: "#{count} saved resets"
  defp label(@reported, _count), do: "No saved resets"
  defp label(@unavailable, _count), do: "Saved resets unavailable"
  defp label(_status, _count), do: "Saved resets not reported"

  @spec redemption_state(map() | term(), DateTime.t()) :: :in_progress | :stale | :complete
  defp redemption_state(
         %{"status" => "redeeming", "started_at" => started_at},
         %DateTime{} = timestamp
       )
       when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, started_at, _offset} ->
        if fresh_redemption?(started_at, timestamp), do: :in_progress, else: :stale

      _invalid ->
        :stale
    end
  end

  defp redemption_state(%{"status" => "redeeming"}, _timestamp), do: :stale
  defp redemption_state(_redemption, _timestamp), do: :complete

  @spec fresh_redemption?(DateTime.t(), DateTime.t()) :: boolean()
  defp fresh_redemption?(%DateTime{} = started_at, %DateTime{} = timestamp) do
    DateTime.diff(timestamp, started_at, :millisecond) <
      @redemption_projection_receive_timeout_ms + @redemption_projection_stale_grace_ms
  end

  @spec now() :: DateTime.t()
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp redemption_or_nil(%{} = redemption), do: redemption
  defp redemption_or_nil(_redemption), do: nil

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_value), do: nil

  defp trigger_mode("threshold"), do: "threshold"
  defp trigger_mode(_mode), do: @default_trigger_mode

  defp percent_policy_value(value, _default)
       when is_integer(value) and value >= 1 and value <= 100,
       do: value

  defp percent_policy_value(_value, default), do: default

  defp non_negative_policy_value(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_negative_policy_value(_value, default), do: default
end
