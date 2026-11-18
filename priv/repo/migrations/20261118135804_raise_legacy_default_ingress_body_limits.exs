defmodule CodexPooler.Repo.Migrations.RaiseLegacyDefaultIngressBodyLimits do
  use Ecto.Migration

  # The instance settings row is written with the defaults of the release that first booted the installation, so an
  # installation created before the 128 MiB / 256 MiB defaults still stores the former 32 MiB / 64 MiB pair even if no
  # owner ever chose it. Max decompressed bytes also caps native websocket messages and is advertised to Codex in
  # `x-codex-websocket-max-message-bytes`, so such an installation turns every Codex request above 64 MiB into a 413.
  # Raise exactly that pair; any other saved value is an owner's choice and stays. `lock_version` moves so a System
  # page opened before the upgrade cannot save the old pair back over the new one.
  @legacy_compressed 33_554_432
  @legacy_decompressed 67_108_864
  @compressed 134_217_728
  @decompressed 268_435_456

  def up do
    execute("""
    UPDATE instance_settings
    SET ingress = ingress
          || jsonb_build_object('max_compressed_body_bytes', #{@compressed}, 'max_decompressed_body_bytes', #{@decompressed}),
        lock_version = lock_version + 1,
        updated_at = now()
    WHERE ingress -> 'max_compressed_body_bytes' = to_jsonb(#{@legacy_compressed})
      AND ingress -> 'max_decompressed_body_bytes' = to_jsonb(#{@legacy_decompressed})
    """)
  end

  # A raised row cannot be told apart from an installation created with the current defaults, so rolling back keeps
  # the larger limits rather than lowering installations that never had the former pair.
  def down, do: :ok
end
