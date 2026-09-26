defmodule CodexPoolerWeb.Admin.SavedResetCalendarTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias CodexPoolerWeb.Admin.SavedResetCalendar
  alias CodexPoolerWeb.Admin.UpstreamPageComponents.SavedResetComponents

  @now ~U[2026-09-26 10:00:00Z]
  @identity_id "00000000-0000-4000-8000-000000000001"
  @url "https://example.com/admin/upstreams/#{@identity_id}"

  test "exports every reported future expiration in UTC with stable upstream-specific UIDs" do
    expirations = ["2026-10-05T09:40:00+02:00", "2026-09-26T09:59:59Z", "2026-10-04T07:44:00Z", "2026-09-26T10:00:00Z", "invalid", "2026-10-04T07:44:00Z"]
    identity = identity(%{"available_expires_at" => expirations})

    assert {:ok, body} = SavedResetCalendar.build(identity, @url, @now)
    assert SavedResetCalendar.available?(identity, @now)
    assert properties(body, "DTSTART") == ["20261004T074400Z", "20261005T074000Z"]
    assert properties(body, "DTSTAMP") == ["20260926T100000Z", "20260926T100000Z"]
    assert properties(body, "DURATION") == ["PT1M", "PT1M"]
    assert properties(body, "SUMMARY") == List.duplicate("Banked reset expires — Sample upstream", 2)
    assert properties(body, "URL") == [@url, @url]
    assert length(properties(body, "UID")) == 2
    assert Enum.uniq(properties(body, "UID")) == properties(body, "UID")
    assert String.starts_with?(body, "BEGIN:VCALENDAR\r\nVERSION:2.0\r\n")
    assert String.ends_with?(body, "END:VCALENDAR\r\n")

    assert {:ok, later} = SavedResetCalendar.build(identity, @url, DateTime.add(@now, 1, :second))
    assert properties(later, "UID") == properties(body, "UID")

    assert {:ok, other} = SavedResetCalendar.build(%{identity | id: "00000000-0000-4000-8000-000000000002"}, @url, @now)
    assert MapSet.disjoint?(MapSet.new(properties(body, "UID")), MapSet.new(properties(other, "UID")))
  end

  test "uses current detailed inventory and supports the legacy expiration list" do
    identity = identity(%{"available_expires_at" => ["2026-10-01T00:00:00Z"], "available_expirations" => [%{"expires_at" => "2026-10-02T00:00:00Z", "first_seen_at" => "2026-09-25T00:00:00Z"}, %{"expires_at" => "2026-10-03T00:00:00Z", "first_seen_at" => nil}]})
    assert {:ok, body} = SavedResetCalendar.build(identity, @url, @now)
    assert properties(body, "DTSTART") == ["20261002T000000Z", "20261003T000000Z"]

    legacy = identity(%{"available_expires_at" => ["2026-10-01T00:00:00Z"], "available_expirations" => []})
    assert {:ok, body} = SavedResetCalendar.build(legacy, @url, @now)
    assert properties(body, "DTSTART") == ["20261001T000000Z"]
  end

  test "does not invent events for an empty, unavailable, expired or malformed bank" do
    for snapshot <- [
          %{"available_count" => 0, "available_expires_at" => ["2026-10-04T07:44:00Z"]},
          %{"status" => "unreported", "available_expires_at" => ["2026-10-04T07:44:00Z"]},
          %{"status" => "unavailable", "available_expires_at" => ["2026-10-04T07:44:00Z"]},
          %{"available_expires_at" => []},
          %{"available_expires_at" => ["2026-09-26T10:00:00Z", "bad"]}
        ] do
      assert {:error, :no_upcoming_expirations} = SavedResetCalendar.build(identity(snapshot), @url, @now)
      refute SavedResetCalendar.available?(identity(snapshot), @now)
    end
  end

  test "preserves absolute instants through midnight and both daylight-saving changes" do
    cases = [
      {"2026-03-29T01:30:00+01:00", "20260329T003000Z", "2026-03-29 01:30 +0100"},
      {"2026-03-29T03:30:00+02:00", "20260329T013000Z", "2026-03-29 03:30 +0200"},
      {"2026-10-25T02:30:00+02:00", "20261025T003000Z", "2026-10-25 02:30 +0200"},
      {"2026-10-25T02:30:00+01:00", "20261025T013000Z", "2026-10-25 02:30 +0100"},
      {"2026-10-26T00:15:00+01:00", "20261025T231500Z", "2026-10-26 00:15 +0100"}
    ]

    identity = identity(%{"available_expires_at" => Enum.map(cases, &elem(&1, 0))})
    assert {:ok, body} = SavedResetCalendar.build(identity, @url, ~U[2026-01-01 00:00:00Z])
    assert properties(body, "DTSTART") == Enum.map(cases, &elem(&1, 1))

    for {source, _utc, local} <- cases do
      assert {:ok, instant, _offset} = DateTime.from_iso8601(source)
      assert instant |> DateTime.shift_zone!("Europe/Rome", Zoneinfo.TimeZoneDatabase) |> Calendar.strftime("%Y-%m-%d %H:%M %z") == local
    end

    refute body =~ "TZID"
    refute body =~ "DTEND"
    assert properties(body, "DURATION") == List.duplicate("PT1M", 5)
    assert length(Enum.uniq(properties(body, "UID"))) == 5
  end

  test "escapes text and folds by UTF-8 octets without leaking unrelated metadata" do
    label = "Sample, team; \\ " <> String.duplicate("東京", 35) <> "\r\nBEGIN:VEVENT\r\nSUMMARY:injected"
    identity = %{identity(%{"available_expires_at" => ["2026-10-04T07:44:00Z"]}) | account_label: label, account_email: "hidden@example.com", chatgpt_account_id: "private-provider-account"}
    identity = %{identity | metadata: Map.put(identity.metadata, "private", "private-metadata-marker")}

    assert {:ok, body} = SavedResetCalendar.build(identity, @url, @now)
    assert String.valid?(body)
    assert String.contains?(body, "\r\n ")
    assert Enum.all?(String.split(body, "\r\n"), &(byte_size(&1) <= 75 and String.valid?(&1)))
    assert String.replace(body, "\r\n", "") |> String.contains?("\n") == false
    assert length(properties(body, "BEGIN") |> Enum.filter(&(&1 == "VEVENT"))) == 1
    assert [summary] = properties(body, "SUMMARY")
    assert summary =~ "Sample\\, team\\; \\\\ "
    assert summary =~ "\\nBEGIN:VEVENT\\nSUMMARY:injected"
    refute body =~ "hidden@example.com"
    refute body =~ "private-provider-account"
    refute body =~ "private-metadata-marker"
  end

  test "only valid future countdowns link to the same complete upstream calendar" do
    path = "/admin/upstreams/#{@identity_id}/saved-reset-expirations.ics"

    document =
      render_component(&SavedResetComponents.saved_reset_expiration_table/1,
        id: "sample-expirations",
        saved_resets: %{available_expirations: [], available_expires_at: ["2026-10-04T07:44:00Z", "2026-10-05T07:40:00Z", "2026-09-26T10:00:00Z", "2026-09-25T10:00:00Z", "invalid"]},
        datetime_preferences: %{datetime_format: "short", timezone: "Etc/UTC"},
        calendar_path: path,
        now: @now
      )
      |> LazyHTML.from_fragment()

    assert LazyHTML.query(document, "a[data-role='saved-reset-expiration-time-left']") |> LazyHTML.attribute("href") == [path, path]
    for index <- [0, 1], do: assert(Enum.count(LazyHTML.query(document, "a#sample-expirations-time-left-#{index}[title='Download all upcoming banked reset expirations (.ics)']")) == 1)
    for index <- [2, 3, 4], do: assert(Enum.count(LazyHTML.query(document, "p#sample-expirations-time-left-#{index}")) == 1)
  end

  defp identity(snapshot) do
    %UpstreamIdentity{id: @identity_id, account_label: "Sample upstream", metadata: %{"saved_resets" => Map.merge(%{"status" => "reported", "available_count" => 5}, snapshot)}}
  end

  defp properties(body, name) do
    body
    |> String.replace("\r\n ", "")
    |> String.split("\r\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, name <> ":"))
    |> Enum.map(&String.replace_prefix(&1, name <> ":", ""))
  end
end
