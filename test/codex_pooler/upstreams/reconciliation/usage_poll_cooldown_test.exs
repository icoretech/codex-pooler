defmodule CodexPooler.Upstreams.Reconciliation.UsagePollCooldownTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Reconciliation.UsagePollCooldown
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @received_at ~U[2026-09-22 12:00:00.000000Z]

  describe "Retry-After instruction" do
    test "delay-seconds become a deadline, and only a nonnegative decimal integer counts" do
      assert UsagePollCooldown.instruction(response(["120"]), @received_at) ==
               {:retry_after, ~U[2026-09-22 12:02:00.000000Z]}

      assert UsagePollCooldown.instruction(response(["  120  "]), @received_at) ==
               {:retry_after, ~U[2026-09-22 12:02:00.000000Z]}

      # A valid instruction that has already elapsed: the provider did throttle
      # this read, so the chain stops, but there is nothing to remember.
      assert UsagePollCooldown.instruction(response(["0"]), @received_at) == :retry_now

      for unusable <- ["-5", "+5", "1.5", "1e3", "12 0", "abc", "", "   ", "0x10"] do
        assert UsagePollCooldown.instruction(response([unusable]), @received_at) == :absent,
               "expected #{inspect(unusable)} to carry no instruction"
      end
    end

    test "a header we cannot read whole is no instruction at all" do
      # Two values, an absent header, a non-binary, and one byte past the bound.
      assert UsagePollCooldown.instruction(response(["60", "120"]), @received_at) == :absent
      assert UsagePollCooldown.instruction(response([]), @received_at) == :absent
      assert UsagePollCooldown.instruction(response([60]), @received_at) == :absent
      assert UsagePollCooldown.instruction(:not_a_response, @received_at) == :absent

      assert UsagePollCooldown.instruction(response([String.duplicate("1", 128)]), @received_at) ==
               :absent

      assert UsagePollCooldown.instruction(response([String.duplicate("9", 129)]), @received_at) ==
               :absent
    end

    test "a delay that cannot be represented is rejected rather than clamped down" do
      # Nearly 8,000 years out is still a date, and it is honored in full
      # rather than trimmed to something more plausible.
      assert {:retry_after, %DateTime{year: 9980}} =
               UsagePollCooldown.instruction(response(["251000000000"]), @received_at)

      # Past the end of a representable date there is no deadline to keep, so
      # the instruction is unusable rather than clamped back inside the range.
      assert UsagePollCooldown.instruction(response(["999999999999"]), @received_at) == :absent

      assert UsagePollCooldown.instruction(response([String.duplicate("9", 128)]), @received_at) ==
               :absent
    end

    test "all three HTTP-date forms are read, and an impossible calendar date is not" do
      assert UsagePollCooldown.instruction(
               response(["Wed, 23 Sep 2026 00:00:00 GMT"]),
               @received_at
             ) == {:retry_after, ~U[2026-09-23 00:00:00Z]}

      assert UsagePollCooldown.instruction(response(["Wed Sep 23 00:00:00 2026"]), @received_at) ==
               {:retry_after, ~U[2026-09-23 00:00:00Z]}

      # asctime space-pads a single-digit day.
      assert UsagePollCooldown.instruction(response(["Wed Oct  7 00:00:00 2026"]), @received_at) ==
               {:retry_after, ~U[2026-10-07 00:00:00Z]}

      assert UsagePollCooldown.instruction(
               response(["Wednesday, 23-Sep-26 00:00:00 GMT"]),
               @received_at
             ) == {:retry_after, ~U[2026-09-23 00:00:00Z]}

      # A date already past is a valid instruction with nothing to remember.
      assert UsagePollCooldown.instruction(
               response(["Sun, 06 Nov 1994 08:49:37 GMT"]),
               @received_at
             ) == :retry_now

      # OTP parses the shape without checking the calendar, so day 32 and hour
      # 25 have to be caught here.
      for impossible <- [
            "Sun, 32 Nov 1994 08:49:37 GMT",
            "Sun, 06 Nov 1994 25:49:37 GMT",
            "Sun, 30 Feb 2027 08:49:37 GMT",
            "Sun, 06 Xxx 1994 08:49:37 GMT",
            "Sun, 6 Nov 1994 08:49:37 GMT",
            "Wed, 23 Sep 2026 00:00:00 UTC"
          ] do
        assert UsagePollCooldown.instruction(response([impossible]), @received_at) == :absent,
               "expected #{inspect(impossible)} to carry no instruction"
      end
    end

    test "a two-digit year more than fifty years ahead is the most recent past year" do
      # RFC 9110's correction. OTP reads `94` as 2094; from 2026 that is 68
      # years ahead, so it means 1994 and the pause is already over.
      assert UsagePollCooldown.instruction(
               response(["Sunday, 06-Nov-94 08:49:37 GMT"]),
               @received_at
             ) == :retry_now

      # Exactly fifty years ahead is not more than fifty, so it stands.
      assert UsagePollCooldown.instruction(
               response(["Saturday, 22-Sep-76 12:00:01 GMT"]),
               @received_at
             ) == {:retry_after, ~U[2076-09-22 12:00:01Z]}

      # Fifty-one years ahead is corrected back a century.
      assert UsagePollCooldown.instruction(
               response(["Wednesday, 22-Sep-77 12:00:01 GMT"]),
               @received_at
             ) == :retry_now

      # A four-digit year says what it means and is never corrected.
      assert UsagePollCooldown.instruction(
               response(["Tue, 22 Sep 2099 12:00:01 GMT"]),
               @received_at
             ) == {:retry_after, ~U[2099-09-22 12:00:01Z]}
    end
  end

  describe "provider origin" do
    test "an origin is scheme, host and effective port, and nothing else" do
      default_https = UsagePollCooldown.origin_key("https://usage.example.test/backend-api/usage")

      assert default_https == UsagePollCooldown.origin_key("https://usage.example.test:443/other?q=1")
      assert default_https == UsagePollCooldown.origin_key("HTTPS://USAGE.EXAMPLE.TEST/backend-api/usage")
      assert default_https == UsagePollCooldown.origin_key("https://user:pw@usage.example.test/x")

      refute default_https == UsagePollCooldown.origin_key("http://usage.example.test/backend-api/usage")
      refute default_https == UsagePollCooldown.origin_key("https://usage.example.test:8443/backend-api/usage")
      refute default_https == UsagePollCooldown.origin_key("https://other.example.test/backend-api/usage")

      for unusable <- ["", "not a url", "/relative/path", "https://", nil, 42] do
        assert UsagePollCooldown.origin_key(unusable) == nil,
               "expected #{inspect(unusable)} to have no origin"
      end
    end
  end

  describe "committed deadlines" do
    setup do
      %{identity: identity} = active_upstream_assignment_fixture(pool_fixture(), %{})
      %{identity: identity, origin: UsagePollCooldown.origin_key("https://usage.example.test/x")}
    end

    test "a recorded deadline defers every reader of that identity, epoch and origin", %{
      identity: identity,
      origin: origin
    } do
      not_before = DateTime.add(@received_at, 3_600, :second)

      assert {:ok, ^not_before} = UsagePollCooldown.record(identity.id, 1, origin, 429, not_before, @received_at)

      assert {:deferred, ^not_before} =
               UsagePollCooldown.admit_current(identity.id, 1, origin, @received_at)

      # The pause ends on its own; nothing has to clear it.
      assert :ok = UsagePollCooldown.admit_current(identity.id, 1, origin, not_before)
      assert :ok = UsagePollCooldown.admit_current(identity.id, 1, origin, DateTime.add(not_before, 1, :second))

      # It says nothing about another origin, another epoch, or an unknown one.
      other_origin = UsagePollCooldown.origin_key("https://other.example.test/x")
      assert :ok = UsagePollCooldown.admit_current(identity.id, 1, other_origin, @received_at)
      assert :ok = UsagePollCooldown.admit_current(identity.id, 2, origin, @received_at)
      assert :ok = UsagePollCooldown.admit_current(identity.id, 1, nil, @received_at)
    end

    test "independent origins of one identity keep their own pauses", %{identity: identity} do
      first = UsagePollCooldown.origin_key("https://first.example.test/x")
      second = UsagePollCooldown.origin_key("https://second.example.test/x")
      early = DateTime.add(@received_at, 60, :second)
      late = DateTime.add(@received_at, 7_200, :second)

      assert {:ok, ^early} = UsagePollCooldown.record(identity.id, 1, first, 429, early, @received_at)
      assert {:ok, ^late} = UsagePollCooldown.record(identity.id, 1, second, 503, late, @received_at)

      assert {:deferred, ^early} = UsagePollCooldown.admit_current(identity.id, 1, first, @received_at)
      assert {:deferred, ^late} = UsagePollCooldown.admit_current(identity.id, 1, second, @received_at)
    end

    test "a pause is never shortened, and an expired one stops taking up room", %{
      identity: identity,
      origin: origin
    } do
      long = DateTime.add(@received_at, 7_200, :second)
      short = DateTime.add(@received_at, 60, :second)

      assert {:ok, ^long} = UsagePollCooldown.record(identity.id, 1, origin, 429, long, @received_at)
      assert {:ok, ^long} = UsagePollCooldown.record(identity.id, 1, origin, 429, short, @received_at)
      assert {:deferred, ^long} = UsagePollCooldown.admit_current(identity.id, 1, origin, @received_at)

      longer = DateTime.add(@received_at, 10_800, :second)
      assert {:ok, ^longer} = UsagePollCooldown.record(identity.id, 1, origin, 503, longer, @received_at)
      assert {:deferred, ^longer} = UsagePollCooldown.admit_current(identity.id, 1, origin, @received_at)

      # Writing well after everything expired prunes the stale entry while the
      # one being written survives.
      future = DateTime.add(longer, 86_400, :second)
      stale_origin = UsagePollCooldown.origin_key("https://stale.example.test/x")
      assert {:ok, _} = UsagePollCooldown.record(identity.id, 1, stale_origin, 429, DateTime.add(future, 60, :second), future)

      origins =
        Repo.get!(UpstreamIdentity, identity.id).metadata
        |> Map.fetch!(UsagePollCooldown.metadata_key())
        |> Map.fetch!("origins")

      assert Map.keys(origins) == [stale_origin]
    end

    test "a response from a credential we have replaced cannot impose a pause", %{
      identity: identity,
      origin: origin
    } do
      not_before = DateTime.add(@received_at, 3_600, :second)

      assert {:error, :stale_credential_epoch} =
               UsagePollCooldown.record(identity.id, 2, origin, 429, not_before, @received_at)

      assert :ok = UsagePollCooldown.admit_current(identity.id, 1, origin, @received_at)
    end

    test "a record from an earlier epoch is replaced rather than merged", %{
      identity: identity,
      origin: origin
    } do
      not_before = DateTime.add(@received_at, 3_600, :second)
      assert {:ok, ^not_before} = UsagePollCooldown.record(identity.id, 1, origin, 429, not_before, @received_at)

      identity
      |> Ecto.Changeset.change(metadata: Map.put(identity.metadata || %{}, "credential_epoch", 2))
      |> Repo.update!()

      # The old epoch's pause no longer applies, and writing under the new one
      # leaves no trace of it.
      assert :ok = UsagePollCooldown.admit_current(identity.id, 2, origin, @received_at)

      other = UsagePollCooldown.origin_key("https://other.example.test/x")
      later = DateTime.add(@received_at, 120, :second)
      assert {:ok, ^later} = UsagePollCooldown.record(identity.id, 2, other, 429, later, @received_at)

      record = Repo.get!(UpstreamIdentity, identity.id).metadata |> Map.fetch!(UsagePollCooldown.metadata_key())
      assert record["credential_epoch"] == 2
      assert Map.keys(record["origins"]) == [other]
    end

    test "an unknown status carries no pause and an unknown identity is a bounded error", %{
      identity: identity,
      origin: origin
    } do
      not_before = DateTime.add(@received_at, 60, :second)

      assert UsagePollCooldown.record(identity.id, 1, origin, 500, not_before, @received_at) ==
               {:error, :invalid_usage_poll_cooldown}

      assert UsagePollCooldown.record(identity.id, 1, nil, 429, not_before, @received_at) ==
               {:error, :invalid_usage_poll_cooldown}

      assert UsagePollCooldown.record(Ecto.UUID.generate(), 1, origin, 429, not_before, @received_at) ==
               {:error, :upstream_identity_not_found}
    end

    test "the record never displaces unrelated identity metadata", %{identity: identity, origin: origin} do
      before = Repo.get!(UpstreamIdentity, identity.id).metadata

      assert {:ok, _} =
               UsagePollCooldown.record(identity.id, 1, origin, 429, DateTime.add(@received_at, 60, :second), @received_at)

      after_metadata = Repo.get!(UpstreamIdentity, identity.id).metadata

      assert Map.drop(after_metadata, [UsagePollCooldown.metadata_key()]) == before
      refute Map.has_key?(before, UsagePollCooldown.metadata_key())
    end

    test "the operator projection lists exactly the pauses admit/4 would defer on, latest first", %{
      identity: identity,
      origin: origin
    } do
      other = UsagePollCooldown.origin_key("https://other.example.test/x")
      shorter = DateTime.add(@received_at, 600, :second)
      longer = DateTime.add(@received_at, 7_200, :second)

      assert {:ok, _} = UsagePollCooldown.record(identity.id, 1, origin, 429, shorter, @received_at)
      assert {:ok, _} = UsagePollCooldown.record(identity.id, 1, other, 503, longer, @received_at)
      metadata = Repo.get!(UpstreamIdentity, identity.id).metadata

      assert UsagePollCooldown.active_pauses(metadata, 1, @received_at) == [
               %{origin_key: other, not_before: longer, status: "unavailable", status_code: 503, source: "retry_after"},
               %{origin_key: origin, not_before: shorter, status: "throttled", status_code: 429, source: "retry_after"}
             ]

      # A deadline that has passed, another credential epoch, or no record at all
      # is no pause - the same answer admit/4 gives.
      assert [%{origin_key: ^other}] = UsagePollCooldown.active_pauses(metadata, 1, shorter)
      assert UsagePollCooldown.active_pauses(metadata, 1, longer) == []
      assert UsagePollCooldown.active_pauses(metadata, 2, @received_at) == []
      assert UsagePollCooldown.active_pauses(%{}, 1, @received_at) == []
      assert UsagePollCooldown.active_pauses(nil, 1, @received_at) == []

      # An entry whose status or source this module never writes still defers
      # reads, so it is still a pause; only the words it cannot name are absent.
      tampered =
        put_in(metadata, [UsagePollCooldown.metadata_key(), "origins", origin], %{
          "not_before" => DateTime.to_iso8601(shorter),
          "status" => "<script>",
          "source" => "somewhere"
        })

      assert {:deferred, ^shorter} = UsagePollCooldown.admit(tampered, 1, origin, @received_at)

      assert %{status: nil, status_code: nil, source: nil, not_before: ^shorter} =
               tampered |> UsagePollCooldown.active_pauses(1, @received_at) |> Enum.find(&(&1.origin_key == origin))
    end
  end

  defp response(values) do
    %Req.Response{
      status: 429,
      headers: %{"retry-after" => values},
      body: %{}
    }
  end
end
