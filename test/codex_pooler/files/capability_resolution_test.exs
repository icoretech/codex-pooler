defmodule CodexPooler.Files.CapabilityResolutionTest do
  use CodexPooler.DataCase, async: true

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Files
  alias CodexPooler.Files.FileRecord
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.{PoolUpstreamAssignment, UpstreamIdentity}
  alias CodexPooler.Upstreams.Secrets

  setup do
    auth = active_api_key_fixture()
    upstream = active_upstream_assignment_fixture(auth.pool)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    file =
      %FileRecord{}
      |> FileRecord.changeset(%{
        pool_id: auth.pool.id,
        api_key_id: auth.api_key.id,
        file_id: "file_capability_active_anchor_#{System.unique_integer([:positive])}",
        purpose: "codex",
        filename: "anchor.bin",
        byte_size: 7,
        status: FileRecord.pending_upload_status(),
        pool_upstream_assignment_id: upstream.assignment.id,
        upstream_identity_id: upstream.identity.id,
        finalize_status: FileRecord.pending_finalize_status(),
        expires_at: DateTime.add(now, 300, :second),
        metadata: %{},
        created_at: now,
        updated_at: now
      })
      |> Repo.insert!()

    resolution = %{
      pool_id: file.pool_id,
      api_key_id: file.api_key_id,
      file_id: file.file_id,
      assignment_id: file.pool_upstream_assignment_id,
      identity_id: file.upstream_identity_id,
      byte_size: file.byte_size
    }

    %{file_record: file, now: now, resolution: resolution, upstream: upstream}
  end

  test "rejects a capability after its assignment is no longer active", context do
    context.upstream.assignment
    |> PoolUpstreamAssignment.changeset(%{status: PoolUpstreamAssignment.paused_status()})
    |> Repo.update!()

    assert {:error, %{code: :invalid_file_capability}} =
             Files.resolve_capability_file(context.resolution, :upload, context.now)
  end

  test "rejects a capability after its identity is no longer active", context do
    context.upstream.identity
    |> UpstreamIdentity.changeset(%{status: UpstreamIdentity.paused_status()})
    |> Repo.update!()

    assert {:error, %{code: :invalid_file_capability}} =
             Files.resolve_capability_file(context.resolution, :upload, context.now)
  end

  test "rejects a capability after its access credential is revoked", context do
    assert {1, _} = Secrets.revoke_active_secrets(context.upstream.identity.id, context.now)

    assert {:error, %{code: :invalid_file_capability}} =
             Files.resolve_capability_file(context.resolution, :upload, context.now)
  end
end
