defmodule CodexPooler.Repo.Migrations.AddSessionOwnerInstanceIncarnation do
  use Ecto.Migration

  # Websocket session ownership named an address rather than a VM.
  # `owner_instance_id` holds the node name, which derives from the pod IP, so a
  # container that restarts in place comes back under it and the successor was
  # accepted as the same owner: it renewed its predecessor's still-active lease
  # and refreshed the session heartbeat of a VM that no longer existed. Measured
  # in production on 2026-09-12, a session whose owner was halted at 03:19:34
  # carried `last_heartbeat_at` 03:30:01 and a lease renewed to 03:35:01, and
  # the liveness guard then read that lease as proof of live work and skipped
  # the orphan behind it.
  #
  # The node name stays exactly where it is. It is also the address owner
  # forwarding routes e-RPC to, and the value durable request metadata, owner
  # cleanup witnesses, replay arm inputs, and admission digests already carry
  # and compare; changing what it holds would break each of those across an
  # upgrade. The incarnation arrives beside it instead, the same companion shape
  # `attempts.owner_instance_boot_id` took, and the pair names a VM.
  #
  # Both columns are null on every session and lease written before this change.
  # A null never equals a live incarnation, so a successor never claims such a
  # row as its own and takes the ordinary owner-unavailable takeover instead; a
  # null also joins no presence row, so the row is never read as absent either.
  # Pre-change ownership therefore keeps today's behaviour in both directions
  # and ages out within one owner-lease TTL. The columns are deliberately kept
  # out of the existing `codex_sessions_check` all-or-nothing owner group for
  # that reason.
  def change do
    alter table(:codex_sessions) do
      add :owner_instance_boot_id, :string
    end

    alter table(:bridge_owner_leases) do
      add :owner_instance_boot_id, :string
    end
  end
end
