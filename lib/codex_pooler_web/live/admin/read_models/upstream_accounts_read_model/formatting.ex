defmodule CodexPoolerWeb.Admin.UpstreamAccountsReadModel.Formatting do
  @moduledoc false

  use Gettext, backend: CodexPoolerWeb.Gettext

  alias CodexPoolerWeb.{DateTimeDisplay, RelativeTime}

  @spec timestamp_status_label(String.t(), DateTime.t() | nil, DateTimeDisplay.preferences()) :: String.t()
  def timestamp_status_label(status, %DateTime{} = timestamp, datetime_preferences) do
    bindings = [timestamp: DateTimeDisplay.format_datetime(timestamp, datetime_preferences), relative_time: relative_time_label(timestamp)]

    case status do
      "auth imported" -> gettext("auth imported %{timestamp} · %{relative_time}", bindings)
      "auth verified" -> gettext("auth verified %{timestamp} · %{relative_time}", bindings)
      "token refresh succeeded" -> gettext("token refresh succeeded %{timestamp} · %{relative_time}", bindings)
      "token refresh started" -> gettext("token refresh started %{timestamp} · %{relative_time}", bindings)
      "token refresh imported" -> gettext("token refresh imported %{timestamp} · %{relative_time}", bindings)
      "access token expires" -> gettext("access token expires %{timestamp} · %{relative_time}", bindings)
      "access token expired" -> gettext("access token expired %{timestamp} · %{relative_time}", bindings)
      status -> gettext("%{status} %{timestamp} · %{relative_time}", Keyword.put(bindings, :status, status))
    end
  end

  def timestamp_status_label(status, _timestamp, _datetime_preferences) do
    case status do
      "auth imported" -> gettext("auth imported not reported")
      "auth verified" -> gettext("auth verified not reported")
      "token refresh succeeded" -> gettext("token refresh succeeded not reported")
      "token refresh started" -> gettext("token refresh started not reported")
      "token refresh imported" -> gettext("token refresh imported not reported")
      "access token expires" -> gettext("access token expires not reported")
      "access token expired" -> gettext("access token expired not reported")
      status -> gettext("%{status} not reported", status: status)
    end
  end

  @spec timestamp_value_label(DateTime.t() | nil, DateTimeDisplay.preferences()) :: String.t()
  def timestamp_value_label(%DateTime{} = timestamp, datetime_preferences) do
    gettext("%{timestamp} · %{relative_time}", timestamp: DateTimeDisplay.format_datetime(timestamp, datetime_preferences), relative_time: relative_time_label(timestamp))
  end

  def timestamp_value_label(_timestamp, _datetime_preferences), do: gettext("not reported")

  @spec relative_time_label(DateTime.t()) :: String.t()
  def relative_time_label(%DateTime{} = timestamp) do
    relative_time_label(timestamp, DateTime.utc_now())
  end

  @spec relative_time_label(DateTime.t(), DateTime.t()) :: String.t()
  def relative_time_label(%DateTime{} = timestamp, %DateTime{} = now) do
    seconds_until = RelativeTime.seconds_until(timestamp, now)

    cond do
      seconds_until > 60 -> gettext("in %{duration}", duration: format_reset_duration(seconds_until))
      seconds_until > -60 -> gettext("just now")
      true -> gettext("%{duration} ago", duration: format_reset_duration(-seconds_until))
    end
  end

  @spec parse_datetime(term()) :: DateTime.t() | nil
  def parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :microsecond)
      _invalid -> nil
    end
  end

  def parse_datetime(%DateTime{} = value), do: DateTime.truncate(value, :microsecond)
  def parse_datetime(_value), do: nil

  @spec parse_timestamp(term()) :: DateTime.t() | nil
  def parse_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> timestamp
      {:error, _reason} -> nil
    end
  end

  def parse_timestamp(%DateTime{} = timestamp), do: timestamp
  def parse_timestamp(_value), do: nil

  @spec present_string?(term()) :: boolean()
  def present_string?(value) when is_binary(value), do: String.trim(value) != ""
  def present_string?(_value), do: false

  @spec present_string(term()) :: String.t() | nil
  def present_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  def present_string(_value), do: nil

  @spec format_reset_duration(non_neg_integer()) :: String.t()
  def format_reset_duration(seconds) when seconds >= 86_400 do
    days = div(seconds, 86_400)
    hours = seconds |> rem(86_400) |> div(3_600)

    duration_parts([{days, "d"}, {hours, "h"}])
  end

  def format_reset_duration(seconds) when seconds >= 3_600 do
    total_minutes = div(seconds + 59, 60)
    hours = div(total_minutes, 60)
    minutes = rem(total_minutes, 60)

    duration_parts([{hours, "h"}, {minutes, "m"}])
  end

  def format_reset_duration(seconds) when seconds >= 60 do
    minutes = div(seconds + 59, 60)

    duration_parts([{minutes, "m"}])
  end

  def format_reset_duration(_seconds), do: "<1m"

  @spec format_integer(integer()) :: String.t()
  def format_integer(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")
  end

  @spec localize_routing_readiness(CodexPooler.Admin.UpstreamRoutingReadiness.t() | nil) :: CodexPooler.Admin.UpstreamRoutingReadiness.t() | nil
  def localize_routing_readiness(nil), do: nil

  def localize_routing_readiness(readiness) do
    label = readiness_text(readiness.label)

    reason =
      if Map.get(readiness, :state) == "quota_blocked" and Map.get(readiness, :reason_code) not in ["provider_credits_disabled", "provider_credit_capacity_unverified", "saved_reset_probe_pending"] do
        gettext("Quota readiness blocks model routing: %{label}.", label: label)
      else
        readiness_text(Map.get(readiness, :reason))
      end

    readiness
    |> Map.put(:label, label)
    |> maybe_put_localized(:reason, reason)
    |> maybe_put_localized(:recovery_action, readiness_text(Map.get(readiness, :recovery_action)))
    |> maybe_update_quota_readiness()
  end

  defp readiness_text("Circuit protection active"), do: gettext("Circuit protection active")
  defp readiness_text("One or more model and route lanes are blocked; unaffected routes may remain available."), do: gettext("One or more model and route lanes are blocked; unaffected routes may remain available.")
  defp readiness_text("Wait for circuit protection to clear before relying on affected routes."), do: gettext("Wait for circuit protection to clear before relying on affected routes.")
  defp readiness_text("Circuit recovery in progress"), do: gettext("Circuit recovery in progress")
  defp readiness_text("One or more model and route lanes are recovering; unaffected routes may remain available."), do: gettext("One or more model and route lanes are recovering; unaffected routes may remain available.")
  defp readiness_text("Wait for circuit recovery to complete before relying on affected routes."), do: gettext("Wait for circuit recovery to complete before relying on affected routes.")
  defp readiness_text("Auth refresh failed"), do: gettext("Auth refresh failed")
  defp readiness_text("Token refresh failed; this account is excluded from model routing until auth is recovered."), do: gettext("Token refresh failed; this account is excluded from model routing until auth is recovered.")
  defp readiness_text("Relink credentials or complete a successful token refresh."), do: gettext("Relink credentials or complete a successful token refresh.")
  defp readiness_text("Reauthentication required"), do: gettext("Reauthentication required")
  defp readiness_text("Reauthentication is required before this account can be selected for model routing."), do: gettext("Reauthentication is required before this account can be selected for model routing.")
  defp readiness_text("Reauthenticate or replace the stored credentials."), do: gettext("Reauthenticate or replace the stored credentials.")
  defp readiness_text("Token refresh due"), do: gettext("Token refresh due")
  defp readiness_text("Token refresh is due before this account can be selected for model routing."), do: gettext("Token refresh is due before this account can be selected for model routing.")
  defp readiness_text("Refresh the account token."), do: gettext("Refresh the account token.")
  defp readiness_text("Account deleted"), do: gettext("Account deleted")
  defp readiness_text("Deleted upstream accounts are excluded from model routing."), do: gettext("Deleted upstream accounts are excluded from model routing.")
  defp readiness_text("Account disabled"), do: gettext("Account disabled")
  defp readiness_text("Disabled upstream accounts are excluded from model routing."), do: gettext("Disabled upstream accounts are excluded from model routing.")
  defp readiness_text("Enable the upstream account before routing."), do: gettext("Enable the upstream account before routing.")
  defp readiness_text("Account errored"), do: gettext("Account errored")
  defp readiness_text("The upstream account lifecycle is errored and excluded from model routing."), do: gettext("The upstream account lifecycle is errored and excluded from model routing.")
  defp readiness_text("Inspect the sanitized account error and recover the upstream account."), do: gettext("Inspect the sanitized account error and recover the upstream account.")
  defp readiness_text("Account paused"), do: gettext("Account paused")
  defp readiness_text("Paused upstream accounts are excluded from model routing."), do: gettext("Paused upstream accounts are excluded from model routing.")
  defp readiness_text("Resume the upstream account before routing."), do: gettext("Resume the upstream account before routing.")
  defp readiness_text("Account pending"), do: gettext("Account pending")
  defp readiness_text("Pending upstream accounts are excluded from model routing until setup completes."), do: gettext("Pending upstream accounts are excluded from model routing until setup completes.")
  defp readiness_text("Complete account setup and reconciliation."), do: gettext("Complete account setup and reconciliation.")
  defp readiness_text("Limited model availability"), do: gettext("Limited model availability")
  defp readiness_text("Only the independently evidenced Spark allowance permits model routing; ordinary account quota remains blocked."), do: gettext("Only the independently evidenced Spark allowance permits model routing; ordinary account quota remains blocked.")
  defp readiness_text("Use Spark or wait for ordinary account quota to recover."), do: gettext("Use Spark or wait for ordinary account quota to recover.")
  defp readiness_text("Identity unavailable"), do: gettext("Identity unavailable")
  defp readiness_text("Identity lifecycle status is unavailable, so model routing cannot select this account."), do: gettext("Identity lifecycle status is unavailable, so model routing cannot select this account.")
  defp readiness_text("Verify the upstream account lifecycle state."), do: gettext("Verify the upstream account lifecycle state.")
  defp readiness_text("Routing while refreshing"), do: gettext("Routing while refreshing")
  defp readiness_text("Identity refresh is in progress, but this lifecycle state remains visible for model routing."), do: gettext("Identity refresh is in progress, but this lifecycle state remains visible for model routing.")
  defp readiness_text("Routing ready via credits"), do: gettext("Routing ready via credits")
  defp readiness_text("Current provider credit permission, identity lifecycle and assignment availability allow routing. Each request still checks its model, transport and serving mode; this does not identify a billing debit."), do: gettext("Current provider credit permission, identity lifecycle and assignment availability allow routing. Each request still checks its model, transport and serving mode; this does not identify a billing debit.")
  defp readiness_text("Availability is conditional on the request model, transport and serving mode. The account summary is not permission for every model or route."), do: gettext("Availability is conditional on the request model, transport and serving mode. The account summary is not permission for every model or route.")
  defp readiness_text("Check the request-specific capacity decision before relying on this account."), do: gettext("Check the request-specific capacity decision before relying on this account.")
  defp readiness_text("Routing ready"), do: gettext("Routing ready")
  defp readiness_text("Identity lifecycle, assignment availability, and quota readiness allow model routing."), do: gettext("Identity lifecycle, assignment availability, and quota readiness allow model routing.")
  defp readiness_text("Lifecycle blocked"), do: gettext("Lifecycle blocked")
  defp readiness_text("This upstream account lifecycle state is excluded from model routing."), do: gettext("This upstream account lifecycle state is excluded from model routing.")
  defp readiness_text("Recover the upstream account lifecycle before routing."), do: gettext("Recover the upstream account lifecycle before routing.")
  defp readiness_text("Assignment unavailable"), do: gettext("Assignment unavailable")
  defp readiness_text("No active, healthy, eligible pool assignment is available for this upstream account."), do: gettext("No active, healthy, eligible pool assignment is available for this upstream account.")
  defp readiness_text("Enable a healthy, eligible pool assignment."), do: gettext("Enable a healthy, eligible pool assignment.")
  defp readiness_text("Provider credit-dependent admission is disabled; independently valid included capacity, ordinary provider permission and authorized banked-reset recovery remain separate."), do: gettext("Provider credit-dependent admission is disabled; independently valid included capacity, ordinary provider permission and authorized banked-reset recovery remain separate.")
  defp readiness_text("Observed balance does not grant routing; current account evidence does not establish usable provider credit permission."), do: gettext("Observed balance does not grant routing; current account evidence does not establish usable provider credit permission.")
  defp readiness_text("Waiting for a request on included quota to confirm the reset. Requests paid with provider credits do not count."), do: gettext("Waiting for a request on included quota to confirm the reset. Requests paid with provider credits do not count.")
  defp readiness_text("Refresh quota evidence or wait for quota reset."), do: gettext("Refresh quota evidence or wait for quota reset.")
  defp readiness_text("Quota ready"), do: gettext("Quota ready")
  defp readiness_text("Weekly quota probe"), do: gettext("Weekly quota probe")
  defp readiness_text("Provider available"), do: gettext("Provider available")
  defp readiness_text("Quota exhausted"), do: gettext("Quota exhausted")
  defp readiness_text("Quota refresh needed"), do: gettext("Quota refresh needed")
  defp readiness_text("Quota missing"), do: gettext("Quota missing")
  defp readiness_text("Quota blocked"), do: gettext("Quota blocked")
  defp readiness_text("Conditional provider availability"), do: gettext("Conditional provider availability")
  defp readiness_text("Banked-reset recovery pending"), do: gettext("Banked-reset recovery pending")
  defp readiness_text("Provider credits disabled"), do: gettext("Provider credits disabled")
  defp readiness_text("Provider credit capacity unverified"), do: gettext("Provider credit capacity unverified")
  defp readiness_text(value), do: value

  defp maybe_put_localized(readiness, key, value) do
    if Map.has_key?(readiness, key), do: Map.put(readiness, key, value), else: readiness
  end

  defp maybe_update_quota_readiness(readiness) do
    case Map.get(readiness, :quota_readiness) do
      nil -> readiness
      quota -> Map.put(readiness, :quota_readiness, %{quota | label: readiness_text(quota.label)})
    end
  end

  defp duration_parts(parts) do
    parts
    |> Enum.reject(fn {value, _unit} -> value <= 0 end)
    |> Enum.map_join(" ", fn {value, unit} ->
      "#{format_integer(value)}#{unit}"
    end)
  end
end
