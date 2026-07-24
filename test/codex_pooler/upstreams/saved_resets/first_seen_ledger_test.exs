defmodule CodexPooler.Upstreams.SavedResets.FirstSeenLedgerTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Upstreams.SavedResets.FirstSeenLedger

  @now ~U[2026-07-24 12:00:00Z]

  test "merge canonicalizes equivalent offsets and fractions and keeps earliest first seen" do
    entries = [
      entry("2026-08-01T02:00:00.1+02:00", "2026-07-03T02:00:00+02:00"),
      entry("2026-08-01T00:00:00.100000Z", "2026-07-01T00:00:00.000000Z"),
      entry("2026-08-01T00:00:00.100Z", "2026-07-02T00:00:00Z")
    ]

    assert {:ok, ledger} =
             FirstSeenLedger.merge(FirstSeenLedger.empty(), entries, [], @now)

    assert ledger == %{
             "version" => 1,
             "entries" => [
               entry("2026-08-01T00:00:00.100000Z", "2026-07-01T00:00:00Z")
             ]
           }
  end

  test "merge ignores malformed entries without inventing timestamps" do
    entries = [
      entry("2026-08-01T00:00:00Z", "2026-07-01T00:00:00Z"),
      %{"expires_at" => "not-a-timestamp", "first_seen_at" => "2026-07-01T00:00:00Z"},
      %{"expires_at" => "2026-08-02T00:00:00Z"},
      %{"expires_at" => 123, "first_seen_at" => "2026-07-01T00:00:00Z"},
      "not-an-entry"
    ]

    assert {:ok, ledger} =
             FirstSeenLedger.merge(FirstSeenLedger.empty(), entries, [], @now)

    assert ledger["entries"] == [
             entry("2026-08-01T00:00:00Z", "2026-07-01T00:00:00Z")
           ]
  end

  test "merge keeps the earliest first seen across persisted and incoming entries" do
    ledger = %{
      "version" => 1,
      "entries" => [
        entry("2026-08-01T00:00:00Z", "2026-07-03T00:00:00Z")
      ]
    }

    incoming = [
      entry("2026-08-01T00:00:00Z", "2026-07-01T00:00:00Z"),
      entry("2026-08-02T00:00:00Z", "2026-07-02T00:00:00Z")
    ]

    assert {:ok, merged} = FirstSeenLedger.merge(ledger, incoming, [], @now)

    assert merged["entries"] == [
             entry("2026-08-01T00:00:00Z", "2026-07-01T00:00:00Z"),
             entry("2026-08-02T00:00:00Z", "2026-07-02T00:00:00Z")
           ]
  end

  test "lookup canonicalizes the requested expiration" do
    ledger = %{
      "version" => 1,
      "entries" => [
        entry("2026-08-01T00:00:00.100Z", "2026-07-01T02:00:00+02:00")
      ]
    }

    assert {:ok, "2026-07-01T00:00:00Z"} =
             FirstSeenLedger.lookup(ledger, "2026-08-01T02:00:00.100000+02:00")

    assert :error = FirstSeenLedger.lookup(ledger, "malformed")
  end

  test "retention includes the exact thirty day boundary and removes older non-current entries" do
    exact_boundary = DateTime.add(@now, -30, :day)
    outside_boundary = DateTime.add(exact_boundary, -1, :microsecond)

    entries = [
      entry(iso(exact_boundary), "2026-06-01T00:00:00Z"),
      entry(iso(outside_boundary), "2026-06-01T00:00:00Z")
    ]

    assert {:ok, ledger} =
             FirstSeenLedger.merge(FirstSeenLedger.empty(), entries, [], @now)

    assert ledger["entries"] == [
             entry(iso(exact_boundary), "2026-06-01T00:00:00Z")
           ]
  end

  test "retention keeps every current expiration even after its expiry" do
    expired = DateTime.add(@now, -90, :day)
    expires_at = iso(expired)

    assert {:ok, ledger} =
             FirstSeenLedger.merge(
               FirstSeenLedger.empty(),
               [entry(expires_at, "2026-01-01T00:00:00Z")],
               [expires_at],
               @now
             )

    assert ledger["entries"] == [
             entry(expires_at, "2026-01-01T00:00:00Z")
           ]
  end

  test "retention deterministically caps non-current entries at the newest 128 expirations" do
    entries =
      for hours_ago <- 1..130 do
        @now
        |> DateTime.add(-hours_ago, :hour)
        |> iso()
        |> entry("2026-07-01T00:00:00Z")
      end

    assert {:ok, ledger} =
             FirstSeenLedger.merge(FirstSeenLedger.empty(), entries, [], @now)

    expirations = Enum.map(ledger["entries"], & &1["expires_at"])

    assert length(expirations) == 128
    assert iso(DateTime.add(@now, -1, :hour)) in expirations
    assert iso(DateTime.add(@now, -128, :hour)) in expirations
    refute iso(DateTime.add(@now, -129, :hour)) in expirations
    refute iso(DateTime.add(@now, -130, :hour)) in expirations
    assert expirations == Enum.sort(expirations)
  end

  test "unknown versions remain opaque and are never rewritten" do
    ledger = %{"version" => 2, "entries" => [%{"provider" => "opaque"}]}
    incoming = [entry("2026-08-01T00:00:00Z", "2026-07-01T00:00:00Z")]

    assert {:opaque, ^ledger} = FirstSeenLedger.merge(ledger, incoming, [], @now)
    assert {:opaque, ^ledger} = FirstSeenLedger.lookup(ledger, "2026-08-01T00:00:00Z")
  end

  defp entry(expires_at, first_seen_at) do
    %{"expires_at" => expires_at, "first_seen_at" => first_seen_at}
  end

  defp iso(datetime), do: DateTime.to_iso8601(datetime)
end
