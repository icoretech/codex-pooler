defmodule CodexPoolerWeb.RelativeTimeTest do
  use ExUnit.Case, async: true

  alias CodexPoolerWeb.{DateTimeDisplay, RelativeTime}

  @tag :relative_countdown_contract
  test "future countdowns use instants while absolute labels remain preference-localized" do
    rome_now = ~U[2026-10-25 00:30:00Z]
    rome_target = ~U[2026-10-25 02:30:00Z]
    new_york_now = ~U[2026-11-01 04:30:00Z]
    new_york_target = ~U[2026-11-01 06:30:00Z]

    assert RelativeTime.seconds_until(rome_target, rome_now) == 7_200
    assert RelativeTime.seconds_until(new_york_target, new_york_now) == 7_200
    assert RelativeTime.seconds_until(rome_now, rome_target) == -7_200
    assert RelativeTime.seconds_until(rome_now, rome_now) == 0

    preference_cases = [
      {%{datetime_format: "default", timezone: "Etc/UTC"}, "2026-10-25 02:30:00 UTC"},
      {%{datetime_format: "short", timezone: "Europe/Rome"}, "2026-10-25 03:30"},
      {%{datetime_format: "long", timezone: "America/New_York"},
       "Oct 24, 2026 22:30:00 America/New_York"},
      {%{datetime_format: "iso8601", timezone: "Europe/Rome"}, "2026-10-25T03:30:00+01:00"},
      {%{datetime_format: "invalid", timezone: "Europe/NotAZone"}, "2026-10-25 02:30:00 UTC"},
      {%{datetime_format: nil, timezone: nil}, "2026-10-25 02:30:00 UTC"},
      {%{datetime_format: "default", timezone: "Europe/Rome"}, "2026-10-25 03:30:00 Europe/Rome"}
    ]

    for {preferences, expected_absolute} <- preference_cases do
      assert DateTimeDisplay.format_datetime(rome_target, preferences) == expected_absolute
      assert RelativeTime.seconds_until(rome_target, rome_now) == 7_200
    end
  end
end
