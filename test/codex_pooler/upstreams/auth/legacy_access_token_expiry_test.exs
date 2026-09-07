defmodule CodexPooler.Upstreams.Auth.LegacyAccessTokenExpiryTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Upstreams

  alias CodexPooler.Upstreams.Auth.{
    AccessTokenExpiry,
    LegacyAccessTokenExpiry,
    TokenRefreshMetadata
  }

  alias CodexPooler.Upstreams.Schemas.EncryptedSecret
  alias CodexPooler.Upstreams.Secrets

  test "normal reconciliation recovers legacy expiry from the active encrypted token" do
    {:ok, fake} =
      FakeUpstream.start_link(
        {:path_json,
         %{
           "/backend-api/wham/usage" =>
             {200,
              %{
                "rate_limit" => %{
                  "primary_window" => %{
                    "used_percent" => 1,
                    "limit_window_seconds" => 18_000,
                    "reset_after_seconds" => 3_600
                  }
                }
              }}
         }}
      )

    on_exit(fn -> FakeUpstream.stop(fake) end)
    pool = pool_fixture()
    %{identity: identity, assignment: assignment} = active_upstream_assignment_fixture(pool)
    deadline = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.truncate(:second)
    token = jwt(deadline)
    store!(identity, token)
    metadata = legacy_metadata() |> Map.put("usage_base_url", FakeUpstream.url(fake))
    identity = identity |> Ecto.Changeset.change(metadata: metadata) |> Repo.update!()
    secret_rows = Repo.all(EncryptedSecret)
    assert %{state: :unknown} = TokenRefreshMetadata.project_access_token_expiry(metadata)

    assert {:ok, %{status: :succeeded}} = Upstreams.reconcile_pool_account(pool, assignment)

    repaired = Repo.reload!(identity)

    assert %{state: :known, source: :jwt_exp, deadline: ^deadline} =
             TokenRefreshMetadata.project_access_token_expiry(repaired.metadata)

    assert repaired.metadata["credential_epoch"] == 6
    assert repaired.metadata["token_refresh"]["generation"] == 5
    assert repaired.metadata["token_refresh"]["status"] == "succeeded"
    assert Repo.all(EncryptedSecret) == secret_rows
    refute inspect(repaired.metadata) =~ token
  end

  test "repair ignores stale caller data and uses the current active secret exactly once" do
    %{identity: identity} = active_upstream_assignment_fixture(pool_fixture())
    old = DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.truncate(:second)
    current = DateTime.add(old, 7200)
    store!(identity, jwt(old))
    stale = identity |> Ecto.Changeset.change(metadata: legacy_metadata()) |> Repo.update!()
    store!(identity, jwt(current))
    assert {:ok, repaired} = LegacyAccessTokenExpiry.repair(stale)

    assert %{state: :known, deadline: ^current} =
             TokenRefreshMetadata.project_access_token_expiry(repaired.metadata)

    assert {:ok, repeated} = LegacyAccessTokenExpiry.repair(stale)
    assert repeated == repaired
    assert repaired.auth_fresh_at == stale.auth_fresh_at
    assert repaired.auth_verified_at == stale.auth_verified_at
    assert repaired.status == stale.status

    assert repaired.metadata["token_refresh"] |> Map.delete("access_token_expiry") ==
             legacy_metadata()["token_refresh"]
  end

  test "opaque tokens become explicit unknown and never revive legacy timestamps" do
    %{identity: identity} = active_upstream_assignment_fixture(pool_fixture())
    store!(identity, "synthetic-opaque-token")
    identity = identity |> Ecto.Changeset.change(metadata: legacy_metadata()) |> Repo.update!()
    assert {:ok, repaired} = LegacyAccessTokenExpiry.repair(identity)

    assert %{state: :unknown} =
             TokenRefreshMetadata.project_access_token_expiry(repaired.metadata)

    refute Map.has_key?(repaired.metadata, "access_token_expires_at")
    refute Map.has_key?(repaired.metadata, "secret_expires_at")
    assert repaired.metadata["token_refresh"]["access_token_expiry"]["state"] == "unknown"
  end

  test "imported credentials without old dates recover expiry without changing lifecycle" do
    %{identity: identity} = active_upstream_assignment_fixture(pool_fixture())
    deadline = DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.truncate(:second)
    store!(identity, jwt(deadline))

    metadata = %{
      "credential_epoch" => 6,
      "token_refresh" => %{"status" => "imported", "trigger_kind" => "oauth_device_link"}
    }

    identity =
      identity
      |> Ecto.Changeset.change(metadata: metadata, status: "reauth_required")
      |> Repo.update!()

    assert {:ok, repaired} = LegacyAccessTokenExpiry.repair(identity)
    assert repaired.status == "reauth_required"
    assert Secrets.secret_status(repaired) == :reauth_required

    assert %{state: :known, deadline: ^deadline} =
             TokenRefreshMetadata.project_access_token_expiry(repaired.metadata)
  end

  test "missing or unreadable active credentials and deleted identities remain unchanged" do
    %{identity: identity} = active_upstream_assignment_fixture(pool_fixture())
    identity = identity |> Ecto.Changeset.change(metadata: legacy_metadata()) |> Repo.update!()
    Secrets.revoke_active_secrets(identity.id, DateTime.utc_now())
    assert {:ok, ^identity} = LegacyAccessTokenExpiry.repair(identity)
    store!(identity, jwt(DateTime.utc_now() |> DateTime.add(3600)))
    secret = Repo.one!(from(secret in EncryptedSecret, where: secret.status == "active"))
    secret |> Ecto.Changeset.change(ciphertext: "invalid") |> Repo.update!()
    assert {:ok, ^identity} = LegacyAccessTokenExpiry.repair(identity)
    store!(identity, jwt(DateTime.utc_now() |> DateTime.add(3600)))
    deleted = identity |> Ecto.Changeset.change(status: "deleted") |> Repo.update!()
    assert {:ok, ^deleted} = LegacyAccessTokenExpiry.repair(deleted)
  end

  test "existing markers and malformed epochs or refresh containers stay untouched" do
    %{identity: identity} = active_upstream_assignment_fixture(pool_fixture())
    deadline = DateTime.utc_now() |> DateTime.add(3600)
    store!(identity, jwt(deadline))

    known =
      TokenRefreshMetadata.build_imported(
        %{},
        AccessTokenExpiry.known(deadline, :explicit),
        6,
        "oauth_browser_link",
        DateTime.utc_now()
      )

    unknown =
      TokenRefreshMetadata.build_imported(
        %{},
        AccessTokenExpiry.unknown(),
        6,
        "oauth_browser_link",
        DateTime.utc_now()
      )

    cases =
      [
        known,
        unknown,
        put_in(known, ["token_refresh", "access_token_expiry", "credential_epoch"], 7)
      ] ++
        Enum.map([nil, "6", %{}, 0, -1], &Map.put(legacy_metadata(), "credential_epoch", &1)) ++
        Enum.map([nil, [], "invalid"], &Map.put(legacy_metadata(), "token_refresh", &1)) ++
        [put_in(legacy_metadata(), ["token_refresh", "access_token_expiry"], nil)]

    for metadata <- cases do
      current = identity |> Ecto.Changeset.change(metadata: metadata) |> Repo.update!()
      assert {:ok, ^current} = LegacyAccessTokenExpiry.repair(current)
      assert Repo.reload!(current) == current
    end
  end

  defp legacy_metadata do
    %{
      "credential_epoch" => 6,
      "access_token_expires_at" => "2020-01-01T00:00:00Z",
      "secret_expires_at" => "2099-01-01T00:00:00Z",
      "unrelated" => "preserved",
      "token_refresh" => %{
        "status" => "succeeded",
        "generation" => 5,
        "finished_at" => "2026-08-31T00:00:00Z"
      }
    }
  end

  defp store!(identity, token) do
    assert {:ok, _} =
             Secrets.store_encrypted_secret(identity, %{
               secret_kind: "access_token",
               plaintext: token
             })
  end

  defp jwt(deadline) do
    payload =
      CodexPooler.JSON.encode!(%{"exp" => DateTime.to_unix(deadline)})
      |> Base.url_encode64(padding: false)

    "synthetic." <> payload <> ".signature"
  end
end
