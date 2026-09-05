defmodule CodexPooler.Upstreams.Auth.AccessTokenExpiryTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias CodexPooler.Upstreams.Auth.{AccessTokenExpiry, TokenRefreshMetadata}
  alias CodexPooler.Upstreams.Lifecycle.CredentialFencing
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @received_at ~U[2026-09-05 10:00:00.000000Z]

  describe "resolution and evaluation" do
    test "JWT expiry wins over disagreeing explicit and lifetime deadlines" do
      jwt_deadline = @received_at |> DateTime.add(600, :second) |> DateTime.truncate(:second)
      explicit_deadline = DateTime.add(@received_at, 1_200, :second)

      resolution =
        AccessTokenExpiry.resolve(%{
          access_token: jwt(%{"exp" => DateTime.to_unix(jwt_deadline)}),
          explicit_expires_at: explicit_deadline,
          expires_in: "1800",
          received_at: @received_at
        })

      assert %{state: :known, source: :jwt_exp, deadline: ^jwt_deadline} = resolution

      assert %{state: :known, source: :jwt_exp, deadline: ^jwt_deadline} =
               AccessTokenExpiry.evaluate(resolution, DateTime.add(@received_at, 599, :second))

      assert %{state: :expired, source: :jwt_exp, deadline: ^jwt_deadline} =
               AccessTokenExpiry.evaluate(resolution, jwt_deadline)
    end

    test "numeric-string JWT exp is accepted and explicit expiry wins over expires_in" do
      jwt_deadline = @received_at |> DateTime.add(300, :second) |> DateTime.truncate(:second)

      assert %{state: :known, source: :jwt_exp, deadline: ^jwt_deadline} =
               AccessTokenExpiry.resolve(%{
                 access_token: jwt(%{"exp" => Integer.to_string(DateTime.to_unix(jwt_deadline))}),
                 explicit_expires_at: DateTime.add(@received_at, 600, :second),
                 expires_in: 900,
                 received_at: @received_at
               })

      explicit_deadline = DateTime.add(@received_at, 600, :second)

      assert %{state: :known, source: :explicit, deadline: ^explicit_deadline} =
               AccessTokenExpiry.resolve(%{
                 access_token: "opaque-access-token",
                 explicit_expires_at: explicit_deadline,
                 expires_in: 900,
                 received_at: @received_at
               })
    end

    test "positive integer and numeric-string lifetimes use received_at, not evaluation time" do
      for expires_in <- [120, "120"] do
        resolution =
          AccessTokenExpiry.resolve(%{
            access_token: "opaque-access-token",
            expires_in: expires_in,
            received_at: @received_at
          })

        deadline = @received_at |> DateTime.add(120, :second) |> DateTime.truncate(:second)
        assert %{state: :known, source: :expires_in, deadline: ^deadline} = resolution

        assert %{state: :expired, deadline: ^deadline} =
                 AccessTokenExpiry.evaluate(resolution, DateTime.add(@received_at, 121, :second))
      end
    end

    test "invalid and overflowing lifetimes fall through to unknown without raising" do
      for expires_in <- [0, -1, "0", "-1", "1.5", "invalid", 1 <<< 80, %{}] do
        assert %{state: :unknown, source: :unavailable, deadline: nil} =
                 AccessTokenExpiry.resolve(%{
                   access_token: "opaque-access-token",
                   expires_in: expires_in,
                   received_at: @received_at
                 })
      end
    end

    test "inspected results never contain the access token or decoded claims" do
      token =
        jwt(%{
          "exp" => DateTime.to_unix(DateTime.add(@received_at, 60, :second)),
          "private" => "claim-secret"
        })

      result = AccessTokenExpiry.resolve(%{access_token: token, received_at: @received_at})

      refute inspect(result) =~ token
      refute inspect(result) =~ "claim-secret"
    end
  end

  describe "replacement metadata and canonical projection" do
    test "replacement scrubs both legacy keys and builds exact imported and succeeded envelopes" do
      deadline = @received_at |> DateTime.add(600, :second) |> DateTime.truncate(:second)

      known =
        AccessTokenExpiry.resolve(%{
          access_token: jwt(%{"exp" => DateTime.to_unix(deadline)}),
          received_at: @received_at
        })

      existing = %{
        "credential_epoch" => 2,
        "access_token_expires_at" => "stale-access",
        "secret_expires_at" => "stale-secret",
        "unrelated" => true,
        "token_refresh" => %{"generation" => 4, "attempt_id" => "safe-attempt"}
      }

      imported =
        TokenRefreshMetadata.build_imported(
          existing,
          known,
          3,
          "oauth_browser_link",
          @received_at
        )

      assert imported["unrelated"]
      refute Map.has_key?(imported, "secret_expires_at")
      assert imported["access_token_expires_at"] == DateTime.to_iso8601(deadline)

      assert imported["token_refresh"] == %{
               "status" => "imported",
               "generation" => 5,
               "trigger_kind" => "oauth_browser_link",
               "imported_at" => DateTime.to_iso8601(@received_at),
               "attempt_id" => "safe-attempt",
               "access_token_expiry" => %{
                 "version" => 1,
                 "credential_epoch" => 3,
                 "state" => "known",
                 "source" => "jwt_exp"
               }
             }

      succeeded =
        TokenRefreshMetadata.build_succeeded(
          imported,
          AccessTokenExpiry.resolve(%{}),
          4,
          "usage_auth_401",
          DateTime.add(@received_at, 1, :second),
          %{"attempt_id" => "safe-attempt", "rotated_refresh_token" => true}
        )

      refute Map.has_key?(succeeded, "access_token_expires_at")
      refute Map.has_key?(succeeded, "secret_expires_at")

      assert succeeded["token_refresh"] == %{
               "status" => "succeeded",
               "generation" => 6,
               "trigger_kind" => "usage_auth_401",
               "finished_at" => "2026-09-05T10:00:01.000000Z",
               "attempt_id" => "safe-attempt",
               "rotated_refresh_token" => true,
               "access_token_expiry" => %{
                 "version" => 1,
                 "credential_epoch" => 4,
                 "state" => "unknown",
                 "source" => "unavailable"
               }
             }
    end

    test "trusted markers project only at the matching root epoch" do
      deadline = DateTime.add(@received_at, 600, :second)
      known = known_metadata(deadline, 2)

      assert %{state: :known, source: :explicit, deadline: ^deadline} =
               TokenRefreshMetadata.project_access_token_expiry(known)

      assert %{state: :unknown} =
               TokenRefreshMetadata.project_access_token_expiry(
                 put_in(known, ["credential_epoch"], 3)
               )

      unknown = %{
        "credential_epoch" => 2,
        "access_token_expires_at" => DateTime.to_iso8601(deadline),
        "token_refresh" => %{
          "access_token_expiry" => %{
            "version" => 1,
            "credential_epoch" => 2,
            "state" => "unknown",
            "source" => "unavailable"
          }
        }
      }

      assert %{state: :unknown, source: :unavailable} =
               TokenRefreshMetadata.project_access_token_expiry(unknown)
    end

    test "non-replacement refresh metadata preserves the existing marker without trusting it" do
      deadline = DateTime.add(@received_at, 600, :second)
      metadata = known_metadata(deadline, 2)

      replacement = %{
        "status" => "refreshing",
        "generation" => 5,
        "started_at" => DateTime.to_iso8601(@received_at)
      }

      assert TokenRefreshMetadata.preserve_access_token_expiry(metadata, replacement) ==
               Map.put(
                 replacement,
                 "access_token_expiry",
                 metadata["token_refresh"]["access_token_expiry"]
               )

      malformed = put_in(metadata, ["token_refresh", "access_token_expiry"], "untrusted")

      assert TokenRefreshMetadata.preserve_access_token_expiry(malformed, replacement)[
               "access_token_expiry"
             ] == "untrusted"
    end

    test "raw token_refresh presence disables legacy fallback across epoch shapes" do
      future = DateTime.add(@received_at, 600, :second) |> DateTime.to_iso8601()

      for token_refresh <- [nil, "invalid", [], %{}, %{"access_token_expiry" => nil}],
          epoch <- [nil, 1, 2, "1"] do
        metadata = %{"access_token_expires_at" => future, "token_refresh" => token_refresh}

        metadata =
          if is_nil(epoch), do: metadata, else: Map.put(metadata, "credential_epoch", epoch)

        assert %{state: :unknown} = TokenRefreshMetadata.project_access_token_expiry(metadata)
      end
    end

    test "legacy fallback is limited to absent token_refresh with absent or integer-one epoch" do
      access_deadline = DateTime.add(@received_at, 600, :second)
      secret_deadline = DateTime.add(@received_at, 1_200, :second)

      legacy = %{
        "access_token_expires_at" => DateTime.to_iso8601(access_deadline),
        "secret_expires_at" => DateTime.to_iso8601(secret_deadline)
      }

      for metadata <- [legacy, Map.put(legacy, "credential_epoch", 1)] do
        assert %{state: :known, source: :explicit, deadline: ^access_deadline} =
                 TokenRefreshMetadata.project_access_token_expiry(metadata)
      end

      for epoch <- [2, 0, "1", %{}] do
        assert %{state: :unknown} =
                 legacy
                 |> Map.put("credential_epoch", epoch)
                 |> TokenRefreshMetadata.project_access_token_expiry()
      end
    end
  end

  describe "credential epoch fencing" do
    test "replacement epoch preparation handles pending and existing identities exactly" do
      for {status, metadata, expected_epoch} <- [
            {"pending", %{}, 1},
            {"pending", %{"credential_epoch" => 7}, 7},
            {"active", %{}, 2},
            {"active", %{"credential_epoch" => 7}, 8}
          ] do
        identity = %UpstreamIdentity{status: status, metadata: metadata}

        assert {:ok, prepared, ^expected_epoch} =
                 CredentialFencing.prepare_replacement_metadata(identity)

        assert prepared["credential_epoch"] == expected_epoch
      end
    end

    test "replacement preparation preserves terminal provider rejection recovery" do
      identity = %UpstreamIdentity{
        status: "active",
        metadata: %{
          "credential_epoch" => 2,
          "provider_auth_recovery" => %{"status" => "terminal", "safe_detail" => true}
        }
      }

      assert {:ok, prepared, 3} = CredentialFencing.prepare_replacement_metadata(identity)
      assert prepared["provider_auth_recovery"]["status"] == "awaiting_fresh_quota"
      assert prepared["provider_auth_recovery"]["safe_detail"]
    end

    test "malformed and nonpositive epochs return a bounded error" do
      for epoch <- [nil, 0, -1, "1", %{}] do
        metadata =
          if is_nil(epoch), do: %{"credential_epoch" => nil}, else: %{"credential_epoch" => epoch}

        assert {:error,
                %{code: :invalid_credential_epoch, message: "credential epoch is invalid"}} =
                 CredentialFencing.prepare_replacement_metadata(%UpstreamIdentity{
                   status: "active",
                   metadata: metadata
                 })
      end
    end

    test "lifecycle epoch advance rebinds only exact trusted markers and preserves all other fields" do
      deadline = DateTime.add(@received_at, 600, :second)
      metadata = known_metadata(deadline, 2)
      metadata = put_in(metadata, ["token_refresh", "attempt_id"], "safe-attempt")
      identity = %UpstreamIdentity{status: "active", metadata: metadata}

      advanced = CredentialFencing.advance_credential_epoch_preserving_expiry(identity)

      assert advanced["credential_epoch"] == 3
      assert advanced["token_refresh"]["attempt_id"] == "safe-attempt"
      assert advanced["token_refresh"]["access_token_expiry"]["credential_epoch"] == 3

      assert %{state: :known, deadline: ^deadline} =
               TokenRefreshMetadata.project_access_token_expiry(advanced)

      for untrusted <- [
            Map.delete(metadata, "token_refresh"),
            put_in(metadata, ["token_refresh", "access_token_expiry", "version"], 2),
            put_in(metadata, ["token_refresh", "access_token_expiry", "credential_epoch"], 1),
            Map.put(metadata, "access_token_expires_at", "invalid")
          ] do
        advanced =
          CredentialFencing.advance_credential_epoch_preserving_expiry(%UpstreamIdentity{
            status: "active",
            metadata: untrusted
          })

        assert advanced["credential_epoch"] == 3
        assert %{state: :unknown} = TokenRefreshMetadata.project_access_token_expiry(advanced)
      end

      unknown = %{
        "credential_epoch" => 2,
        "token_refresh" => %{
          "generation" => 1,
          "access_token_expiry" => %{
            "version" => 1,
            "credential_epoch" => 2,
            "state" => "unknown",
            "source" => "unavailable"
          }
        }
      }

      advanced_unknown =
        CredentialFencing.advance_credential_epoch_preserving_expiry(%UpstreamIdentity{
          status: "paused",
          metadata: unknown
        })

      assert advanced_unknown["token_refresh"]["access_token_expiry"]["credential_epoch"] == 3

      assert %{state: :unknown, source: :unavailable} =
               TokenRefreshMetadata.project_access_token_expiry(advanced_unknown)
    end
  end

  defp known_metadata(deadline, epoch) do
    %{
      "credential_epoch" => epoch,
      "access_token_expires_at" => DateTime.to_iso8601(deadline),
      "token_refresh" => %{
        "generation" => 4,
        "access_token_expiry" => %{
          "version" => 1,
          "credential_epoch" => epoch,
          "state" => "known",
          "source" => "explicit"
        }
      }
    }
  end

  defp jwt(claims) do
    header = Base.url_encode64(Jason.encode!(%{"alg" => "none"}), padding: false)
    payload = Base.url_encode64(Jason.encode!(claims), padding: false)
    header <> "." <> payload <> ".signature"
  end
end
