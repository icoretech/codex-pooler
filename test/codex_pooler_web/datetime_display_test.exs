defmodule CodexPoolerWeb.DateTimeDisplayTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Accounts.User
  alias CodexPoolerWeb.DateTimeDisplay

  @example_instant ~U[2026-05-27 13:45:06Z]
  @winter_instant ~U[2026-01-27 13:45:06Z]

  describe "timezone database" do
    test "global timezone database remains unset so UTC arithmetic stays on defaults" do
      assert Application.get_env(:elixir, :time_zone_database) == Calendar.UTCOnlyTimeZoneDatabase
      assert %DateTime{} = DateTime.add(DateTime.utc_now(), 30_000, :millisecond)
    end

    test "explicit timezone database converts UTC instants to real IANA zones" do
      assert {:ok, rome_time} =
               DateTime.shift_zone(@example_instant, "Europe/Rome", Tzdata.TimeZoneDatabase)

      assert rome_time.year == 2026
      assert rome_time.month == 5
      assert rome_time.day == 27
      assert rome_time.hour == 15
      assert rome_time.minute == 45
      assert rome_time.second == 6
      assert rome_time.utc_offset == 3600
      assert rome_time.std_offset == 3600
      assert rome_time.zone_abbr == "CEST"
      assert rome_time.time_zone == "Europe/Rome"
    end

    test "explicit timezone database rejects invalid IANA zones" do
      assert {:error, :time_zone_not_found} =
               DateTime.shift_zone(@example_instant, "Europe/NotAZone", Tzdata.TimeZoneDatabase)
    end
  end

  describe "preferences_for_user/1" do
    test "returns default preferences without a user" do
      assert DateTimeDisplay.preferences_for_user(nil) == %{
               datetime_format: "default",
               timezone: "Etc/UTC"
             }
    end

    test "normalizes nil user preference fields" do
      assert DateTimeDisplay.preferences_for_user(%User{}) == %{
               datetime_format: "default",
               timezone: "Etc/UTC"
             }
    end

    test "returns stored user preference fields" do
      user = %User{datetime_format: "long", timezone: "Europe/Rome"}

      assert DateTimeDisplay.preferences_for_user(user) == %{
               datetime_format: "long",
               timezone: "Europe/Rome"
             }
    end

    test "unknown stored formats fall back to default" do
      user = %User{datetime_format: "relative", timezone: "Europe/Rome"}

      assert DateTimeDisplay.preferences_for_user(user) == %{
               datetime_format: "default",
               timezone: "Europe/Rome"
             }
    end
  end

  describe "format_options/0" do
    test "returns the frozen presets in stable order" do
      assert DateTimeDisplay.format_options() == [
               {"Default", "default"},
               {"Short", "short"},
               {"Long", "long"},
               {"ISO 8601", "iso8601"}
             ]
    end
  end

  describe "timezone_options/0" do
    test "returns Etc/UTC first and remaining IANA zones alphabetically" do
      options = DateTimeDisplay.timezone_options()

      assert List.first(options) == {"Etc/UTC", "Etc/UTC"}
      assert {"Europe/Rome", "Europe/Rome"} in options
      assert {"America/New_York", "America/New_York"} in options

      remaining_zone_ids =
        options
        |> Enum.drop(1)
        |> Enum.map(fn {label, value} ->
          assert label == value
          value
        end)

      refute "Etc/UTC" in remaining_zone_ids
      assert remaining_zone_ids == Enum.sort(remaining_zone_ids)
      assert length(options) == length(Enum.uniq(options))
    end
  end

  describe "format_datetime/3" do
    test "formats the default preset in UTC" do
      preferences = %{datetime_format: "default", timezone: "Etc/UTC"}

      assert DateTimeDisplay.format_datetime(@example_instant, preferences) ==
               "2026-05-27 13:45:06 UTC"
    end

    test "formats the default preset in the operator timezone" do
      preferences = %{datetime_format: "default", timezone: "Europe/Rome"}

      assert DateTimeDisplay.format_datetime(@example_instant, preferences) ==
               "2026-05-27 15:45:06 Europe/Rome"
    end

    test "formats the short preset" do
      preferences = %{datetime_format: "short", timezone: "Europe/Rome"}

      assert DateTimeDisplay.format_datetime(@example_instant, preferences) == "2026-05-27 15:45"
    end

    test "formats the long preset" do
      preferences = %{datetime_format: "long", timezone: "Europe/Rome"}

      assert DateTimeDisplay.format_datetime(@example_instant, preferences) ==
               "May 27, 2026 15:45:06 Europe/Rome"
    end

    test "formats the iso8601 preset with the selected timezone offset" do
      preferences = %{datetime_format: "iso8601", timezone: "Europe/Rome"}

      assert DateTimeDisplay.format_datetime(@example_instant, preferences) ==
               "2026-05-27T15:45:06+02:00"
    end

    test "treats naive datetimes as UTC before applying the operator timezone" do
      naive_datetime = ~N[2026-05-27 13:45:06]
      preferences = %{datetime_format: "default", timezone: "Europe/Rome"}

      assert DateTimeDisplay.format_datetime(naive_datetime, preferences) ==
               "2026-05-27 15:45:06 Europe/Rome"
    end

    test "uses the default missing label for nil datetimes" do
      preferences = %{datetime_format: "default", timezone: "Europe/Rome"}

      assert DateTimeDisplay.format_datetime(nil, preferences) == "-"
    end

    test "uses the only supported nil-display override" do
      preferences = %{datetime_format: "default", timezone: "Europe/Rome"}

      assert DateTimeDisplay.format_datetime(nil, preferences, missing_label: "not recorded") ==
               "not recorded"
    end

    test "falls back to UTC when stored timezone data is invalid" do
      preferences = %{datetime_format: "default", timezone: "Europe/NotAZone"}

      assert DateTimeDisplay.format_datetime(@winter_instant, preferences) ==
               "2026-01-27 13:45:06 UTC"
    end

    test "falls back to the default preset when stored format data is invalid" do
      preferences = %{datetime_format: "relative", timezone: "Europe/Rome"}

      assert DateTimeDisplay.format_datetime(@example_instant, preferences) ==
               "2026-05-27 15:45:06 Europe/Rome"
    end
  end
end
