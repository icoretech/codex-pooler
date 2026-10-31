defmodule CodexPoolerWeb.DateTimeInputTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Access.APIKey
  alias CodexPoolerWeb.Admin.ApiKeyPolicyForm
  alias CodexPoolerWeb.DateTimeDisplay
  alias CodexPoolerWeb.DateTimeInput

  test "unresolvable stored zones render UTC and malformed calendar bounds fail closed" do
    instant = ~U[2026-07-15 07:54:00Z]
    assert DateTimeInput.local_value(instant, "Unknown/Zone") == "2026-07-15T07:54"
    assert DateTimeInput.describe(instant, "Unknown/Zone") == "2026-07-15 07:54 Etc/UTC (UTC+00:00)"
    assert {:error, :invalid} = DateTimeInput.date_boundary(%{}, :date_from, "Etc/UTC")
    assert {:error, :invalid} = DateTimeInput.date_boundary("2026-07-15", :unknown, "Etc/UTC")
  end

  test "local times use the offset on their date, including far-future daylight saving" do
    for {input, timezone, expected} <- [
          {"2026-07-15T09:54", "Europe/Rome", ~U[2026-07-15 07:54:00Z]},
          {"2026-12-15T09:54", "Europe/Rome", ~U[2026-12-15 08:54:00Z]},
          {"2099-07-15T09:54", "Europe/Rome", ~U[2099-07-15 07:54:00Z]},
          {"2026-07-15T09:54", "Asia/Kathmandu", ~U[2026-07-15 04:09:00Z]},
          {"2026-07-15T09:54", "America/New_York", ~U[2026-07-15 13:54:00Z]},
          {"2026-07-15T09:54", "Etc/UTC", ~U[2026-07-15 09:54:00Z]}
        ] do
      assert {:ok, ^expected} = DateTimeInput.parse(input, timezone)
      assert DateTimeInput.local_value(expected, timezone) == input
    end

    preferences = %{datetime_format: "iso8601", timezone: "Europe/Rome"}
    assert DateTimeDisplay.format_datetime(~U[2099-07-15 07:54:00Z], preferences) == "2099-07-15T09:54:00+02:00"
  end

  test "explicit offsets remain absolute and blank input clears the deadline" do
    assert {:ok, ~U[2026-07-15 07:54:00Z]} = DateTimeInput.parse("2026-07-15T09:54:00+02:00", "America/New_York")
    assert {:ok, nil} = DateTimeInput.parse("  ", "Europe/Rome")
    assert {:ok, nil} = DateTimeInput.parse(nil, "Etc/UTC")
    assert {:error, :invalid} = DateTimeInput.parse("not-a-date", "Europe/Rome")
    assert {:error, :invalid} = DateTimeInput.parse(%{}, "Europe/Rome")
    assert {:error, :unknown_timezone} = DateTimeInput.parse("2026-07-15T09:54", "Unknown/Zone")
  end

  test "clock changes do not silently choose an instant for a new deadline" do
    assert {:error, :gap} = DateTimeInput.parse("2026-03-29T02:30", "Europe/Rome")
    assert {:error, :ambiguous} = DateTimeInput.parse("2026-10-25T02:30", "Europe/Rome")

    params = ApiKeyPolicyForm.empty_params([], "Europe/Rome")
    gap = Map.put(params, "expires_at", "2026-03-29T02:30")
    overlap = Map.put(params, "expires_at", "2026-10-25T02:30")
    assert [expires_at: {gap_error, [timezone: "Europe/Rome"]}] = ApiKeyPolicyForm.expiry_errors(gap)
    assert gap_error == "does not exist in %{timezone} because the clocks move forward"
    assert [expires_at: {overlap_error, [timezone: "Europe/Rome"]}] = ApiKeyPolicyForm.expiry_errors(overlap)
    assert overlap_error == "occurs twice in %{timezone}; choose a time outside the repeated hour"
  end

  test "an existing overlap deadline keeps its exact occurrence and precision" do
    for expiry <- [~U[2026-10-25 00:30:48.123456Z], ~U[2026-10-25 01:30:48.123456Z]] do
      params = ApiKeyPolicyForm.params_for(%APIKey{expires_at: expiry}, [], "Europe/Rome")
      assert params["expires_at"] == "2026-10-25T02:30"
      assert ApiKeyPolicyForm.expiry_errors(params) == []
      assert ApiKeyPolicyForm.attrs(params).expires_at == expiry
    end
  end

  test "submitted params cannot override the trusted timezone or stored deadline" do
    params = ApiKeyPolicyForm.empty_params([], "Europe/Rome")
    params = ApiKeyPolicyForm.merge_params(params, %{"expiry_timezone" => "Etc/UTC", "stored_expires_at" => ~U[2099-01-01 00:00:00Z], "expires_at" => "2026-07-15T09:54"})
    assert ApiKeyPolicyForm.expiry_timezone(params) == "Europe/Rome"
    assert ApiKeyPolicyForm.attrs(params).expires_at == ~U[2026-07-15 07:54:00Z]
  end

  test "summaries name the zone and selected date offset and explain immediate expiry" do
    params = ApiKeyPolicyForm.empty_params([], "Europe/Rome") |> Map.put("expires_at", "2026-07-15T09:54")
    summary = ApiKeyPolicyForm.expiry_summary(params, ~U[2026-07-15 05:54:00Z])
    assert summary =~ "2026-07-15 09:54 Europe/Rome (UTC+02:00)"
    assert summary =~ "in 2 h 0 min"
    assert ApiKeyPolicyForm.expiry_summary(params, ~U[2026-07-15 07:54:00Z]) =~ "Expires immediately on save"
  end

  test "calendar bounds cover 23 and 25 hour days and inclusive microseconds" do
    for {date, first, next, hours} <- [
          {"2026-03-29", ~U[2026-03-28 23:00:00Z], ~U[2026-03-29 22:00:00Z], 23},
          {"2026-10-25", ~U[2026-10-24 22:00:00Z], ~U[2026-10-25 23:00:00Z], 25}
        ] do
      assert {:ok, ^first} = DateTimeInput.date_boundary(date, :date_from, "Europe/Rome")
      assert {:ok, last} = DateTimeInput.date_boundary(date, :date_to, "Europe/Rome")
      assert DateTime.compare(DateTime.add(last, 1, :microsecond), next) == :eq
      assert DateTime.diff(next, first, :hour) == hours
    end
  end

  test "calendar bounds include days with a skipped or repeated midnight" do
    assert {:ok, ~U[2026-09-06 04:00:00Z]} = DateTimeInput.date_boundary("2026-09-06", :date_from, "America/Santiago")
    assert {:ok, ~U[2026-11-01 04:00:00Z]} = DateTimeInput.date_boundary("2026-11-01", :date_from, "America/Havana")
    assert {:error, :gap} = DateTimeInput.date_boundary("2011-12-30", :date_from, "Pacific/Apia")
    assert {:ok, last} = DateTimeInput.date_boundary("2011-12-29", :date_to, "Pacific/Apia")
    assert last == ~U[2011-12-30 09:59:59.999999Z]
    assert {:error, :invalid} = DateTimeInput.date_boundary("2026-02-30", :date_from, "Europe/Rome")
    assert {:error, :unknown_timezone} = DateTimeInput.date_boundary("2026-01-01", :date_to, "Unknown/Zone")
  end
end
