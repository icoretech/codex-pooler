defmodule CodexPooler.Upstreams.UpstreamIdentitySavedResetLedgerTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  test "schema exposes an empty version one ledger by default" do
    identity = struct(UpstreamIdentity)

    assert UpstreamIdentity.__schema__(:type, :saved_reset_first_seen_ledger) == :map

    assert Map.fetch!(identity, :saved_reset_first_seen_ledger) == %{
             "version" => 1,
             "entries" => []
           }
  end

  test "generic changeset keeps runtime metadata writable but ignores the durable ledger" do
    ledger = %{
      "version" => 1,
      "entries" => [
        %{
          "expires_at" => "2026-08-01T00:00:00Z",
          "first_seen_at" => "2026-07-01T00:00:00Z"
        }
      ]
    }

    changeset =
      UpstreamIdentity.changeset(%UpstreamIdentity{}, %{
        metadata: %{"saved_resets" => %{"status" => "available"}},
        saved_reset_first_seen_ledger: ledger
      })

    assert Ecto.Changeset.get_change(changeset, :metadata) ==
             %{"saved_resets" => %{"status" => "available"}}

    refute Ecto.Changeset.get_change(changeset, :saved_reset_first_seen_ledger)
  end
end
