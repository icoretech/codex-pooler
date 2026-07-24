defmodule CodexPooler.Upstreams.SavedResets.ObservationOrderingTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Upstreams.SavedResets.ObservationOrdering

  describe "authorize/2" do
    test "canonicalizes an equal candidate and authorizes its idempotent application" do
      assert {:apply, "2026-07-24T03:00:00.123456Z"} =
               ObservationOrdering.authorize(
                 "2026-07-24T05:00:00.123456+02:00",
                 "2026-07-24T03:00:00.123456Z"
               )
    end

    test "authorizes a newer candidate" do
      assert {:apply, "2026-07-24T03:00:01Z"} =
               ObservationOrdering.authorize(
                 ~U[2026-07-24 03:00:01Z],
                 "2026-07-24T03:00:00Z"
               )
    end

    test "rejects an older candidate" do
      assert :skip =
               ObservationOrdering.authorize(
                 "2026-07-24T02:59:59Z",
                 "2026-07-24T03:00:00Z"
               )
    end

    test "rejects a malformed candidate" do
      assert :skip = ObservationOrdering.authorize("not-a-timestamp", nil)
    end

    test "authorizes a valid candidate when the persisted timestamp is absent or malformed" do
      assert {:apply, "2026-07-24T03:00:00Z"} =
               ObservationOrdering.authorize("2026-07-24T03:00:00Z", nil)

      assert {:apply, "2026-07-24T03:00:00Z"} =
               ObservationOrdering.authorize("2026-07-24T03:00:00Z", "malformed")
    end
  end
end
