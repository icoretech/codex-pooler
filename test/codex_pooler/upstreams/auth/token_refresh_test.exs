defmodule CodexPooler.Upstreams.Auth.TokenRefreshTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Upstreams.Auth.TokenRefresh, as: TokenRefresh
  alias CodexPooler.Upstreams.Secrets, as: Secrets

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Jobs
  alias CodexPooler.Jobs.TokenRefreshWorker
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Assignments.PoolAssignments
  alias CodexPooler.Upstreams.Auth.{CodexAuth, TokenRefreshMetadata}
  alias CodexPooler.Upstreams.Lifecycle.CredentialFencing
  alias CodexPooler.Upstreams.Lifecycle.IdentityLifecycle
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias Ecto.Adapters.SQL.Sandbox

  import CodexPooler.PoolerFixtures

  @incomplete_job_states ~w(available scheduled executing retryable)

  describe "provider token refresh lifecycle" do
    test "refresh success rotates the access token, preserves encrypted boundaries, and activates refreshable accounts" do
      access_token = secret("access", "old")
      refresh_token = secret("refresh", "stable")
      new_access_token = secret("access", "new")

      upstream =
        start_path_upstream(%{
          "/oauth/token" => {200, %{"access_token" => new_access_token, "expires_in" => 3600}}
        })

      identity =
        refreshable_identity_fixture("refresh_due", %{"base_url" => FakeUpstream.url(upstream)})

      store_secret!(identity, "access_token", access_token)
      store_secret!(identity, "refresh_token", refresh_token)

      assert {:ok, %{status: :active, retryable?: false} = result} =
               TokenRefresh.refresh_access_token(identity,
                 trigger_kind: "unit_test"
               )

      assert result.identity.status == "active"
      assert result.secret_status == :present

      assert {:ok, ^new_access_token} =
               Secrets.decrypt_active_secret(identity, "access_token")

      assert {:ok, ^refresh_token} =
               Secrets.decrypt_active_secret(identity, "refresh_token")

      persisted = Repo.get!(UpstreamIdentity, identity.id)
      assert persisted.metadata["credential_epoch"] == 2
      assert persisted.metadata["usage_probe_sequence"] == 0
      assert persisted.metadata["usage_probe_applied_sequence"] == 0
      assert persisted.metadata["token_refresh"]["status"] == "succeeded"
      assert persisted.metadata["token_refresh"]["trigger_kind"] == "unit_test"
      assert %DateTime{} = persisted.last_successful_refresh_at
      assert persisted.metadata["access_token_expires_at"]

      refute inspect(result) =~ access_token
      refute inspect(result) =~ refresh_token
      refute inspect(result) =~ new_access_token
    end

    test "valid provider success advances the validated epoch and writes its canonical expiry marker" do
      refresh_token = secret("refresh", "canonical-expiry")
      new_access_token = secret("access", "canonical-expiry")

      upstream =
        start_path_upstream(%{
          "/oauth/token" => {200, %{"access_token" => new_access_token, "expires_in" => "3600"}}
        })

      identity =
        refreshable_identity_fixture("active", %{
          "base_url" => FakeUpstream.url(upstream),
          "credential_epoch" => 4,
          "unrelated" => %{"preserved" => true}
        })

      store_secret!(identity, "refresh_token", refresh_token)

      assert {:ok, %{status: :active, retryable?: false}} =
               TokenRefresh.refresh_access_token(identity, trigger_kind: "canonical_expiry_test")

      persisted = Repo.get!(UpstreamIdentity, identity.id)
      refresh_metadata = persisted.metadata["token_refresh"]

      assert persisted.metadata["credential_epoch"] == 5
      assert persisted.metadata["unrelated"] == %{"preserved" => true}
      assert is_binary(persisted.metadata["access_token_expires_at"])
      refute Map.has_key?(persisted.metadata, "secret_expires_at")

      assert refresh_metadata["access_token_expiry"] == %{
               "version" => 1,
               "credential_epoch" => 5,
               "state" => "known",
               "source" => "expires_in"
             }

      assert refresh_metadata["status"] == "succeeded"
      assert refresh_metadata["trigger_kind"] == "canonical_expiry_test"
      assert is_binary(refresh_metadata["attempt_id"])
      assert is_binary(refresh_metadata["started_at"])
      assert is_integer(refresh_metadata["receive_timeout_ms"])
      assert is_integer(refresh_metadata["stale_after_ms"])
      assert refresh_metadata["rotated_refresh_token"] == false
    end

    test "opaque provider success advances once and records unknown expiry" do
      refresh_token = secret("refresh", "opaque")
      old_access_token = secret("access", "opaque-old")
      new_access_token = secret("access", "opaque-new")

      upstream =
        start_path_upstream(%{
          "/oauth/token" => {200, %{"access_token" => new_access_token}}
        })

      identity =
        refreshable_identity_fixture("refresh_due", %{
          "base_url" => FakeUpstream.url(upstream),
          "credential_epoch" => 7,
          "access_token_expires_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 600))
        })

      store_secret!(identity, "access_token", old_access_token)
      store_secret!(identity, "refresh_token", refresh_token)

      assert {:ok, %{status: :active}} =
               TokenRefresh.refresh_access_token(identity, trigger_kind: "opaque_expiry_test")

      persisted = Repo.get!(UpstreamIdentity, identity.id)
      assert persisted.metadata["credential_epoch"] == 8
      refute Map.has_key?(persisted.metadata, "access_token_expires_at")
      refute Map.has_key?(persisted.metadata, "secret_expires_at")

      assert persisted.metadata["token_refresh"]["access_token_expiry"] == %{
               "version" => 1,
               "credential_epoch" => 8,
               "state" => "unknown",
               "source" => "unavailable"
             }

      assert {:ok, ^new_access_token} = Secrets.decrypt_active_secret(identity, "access_token")
    end

    test "past provider success becomes retryable invalid response and retains the old credential" do
      refresh_token = secret("refresh", "past")
      old_access_token = secret("access", "past-old")
      past_access_token = jwt_with_exp(DateTime.to_unix(DateTime.utc_now()) - 60)
      marker = known_expiry_metadata(3, DateTime.add(DateTime.utc_now(), 600))

      upstream =
        start_path_upstream(%{
          "/oauth/token" => {200, %{"access_token" => past_access_token, "expires_in" => 3600}}
        })

      identity =
        refreshable_identity_fixture(
          "active",
          Map.put(marker, "base_url", FakeUpstream.url(upstream))
        )

      store_secret!(identity, "access_token", old_access_token)
      store_secret!(identity, "refresh_token", refresh_token)

      assert {:ok,
              %{
                status: :refresh_failed,
                retryable?: true,
                reason: "upstream returned an invalid refresh response"
              }} = TokenRefresh.refresh_access_token(identity, trigger_kind: "past_response_test")

      persisted = Repo.get!(UpstreamIdentity, identity.id)
      assert persisted.status == "refresh_failed"
      assert persisted.metadata["credential_epoch"] == 3
      assert persisted.metadata["token_refresh"]["reason"]["code"] == "invalid_refresh_response"
      assert expiry_marker(persisted) == expiry_marker(marker)
      assert {:ok, ^old_access_token} = Secrets.decrypt_active_secret(identity, "access_token")
      refute inspect(persisted.metadata) =~ past_access_token
    end

    test "candidate statuses reject malformed epochs before claim, decrypt, or provider I/O" do
      for status <- ~w(active refresh_due refresh_failed refreshing) do
        upstream =
          start_path_upstream(%{
            "/oauth/token" => {200, %{"access_token" => secret("access", "unused-#{status}")}}
          })

        identity =
          refreshable_identity_fixture(status, %{
            "base_url" => FakeUpstream.url(upstream),
            "credential_epoch" => "broken",
            "token_refresh" => active_attempt_metadata()
          })

        before = Repo.get!(UpstreamIdentity, identity.id)

        assert {:error,
                %{code: :invalid_credential_epoch, message: "credential epoch is invalid"}} =
                 TokenRefresh.refresh_access_token(identity, trigger_kind: "invalid_epoch_test")

        after_attempt = Repo.get!(UpstreamIdentity, identity.id)
        assert after_attempt.status == before.status
        assert after_attempt.metadata == before.metadata
        assert FakeUpstream.count(upstream) == 0
      end
    end

    test "terminal and noncandidate status priority remains ahead of malformed epoch validation" do
      for status <- ~w(paused deleted reauth_required pending) do
        identity =
          refreshable_identity_fixture(status, %{
            "credential_epoch" => "broken",
            "token_refresh" => %{"status" => "preserved"}
          })

        assert {:ok, %{status: :noop, retryable?: false, reason: "account is " <> ^status}} =
                 TokenRefresh.refresh_access_token(identity, trigger_kind: "status_priority_test")

        persisted = Repo.get!(UpstreamIdentity, identity.id)
        assert persisted.status == status
        assert persisted.metadata["credential_epoch"] == "broken"
        assert persisted.metadata["token_refresh"] == %{"status" => "preserved"}
      end
    end

    test "claim, timeout, malformed response, and revoked response preserve the expiry marker" do
      timeout_release_ref = make_ref()

      cases = [
        {:timeout,
         FakeUpstream.timeout_before_headers(notify: self(), release_ref: timeout_release_ref),
         "codex_auth_transient", timeout_release_ref},
        {:malformed, FakeUpstream.json_response(%{"expires_in" => 3600}),
         "codex_oauth_refresh_failed", nil},
        {:revoked, FakeUpstream.json_response(%{"error" => "invalid_grant"}, 400),
         "refresh_token_revoked", nil}
      ]

      for {label, response, expected_code, release_ref} <- cases do
        refresh_token = secret("refresh", Atom.to_string(label))
        marker = known_expiry_metadata(2, DateTime.add(DateTime.utc_now(), 600))
        upstream = start_upstream(response)

        identity =
          refreshable_identity_fixture(
            "active",
            Map.put(marker, "base_url", FakeUpstream.url(upstream))
          )

        store_secret!(identity, "refresh_token", refresh_token)

        result =
          TokenRefresh.refresh_access_token(identity,
            trigger_kind: "marker_#{label}",
            receive_timeout: 25
          )

        if release_ref do
          assert_receive {:fake_upstream_timeout_barrier, :before_headers, upstream_pid,
                          ^release_ref},
                         1_000

          send(upstream_pid, {:fake_upstream_release_timeout, release_ref})
        end

        assert {:ok, %{status: status}} = result
        assert status in [:refresh_failed, :reauth_required]

        persisted = Repo.get!(UpstreamIdentity, identity.id)
        assert expiry_marker(persisted) == expiry_marker(marker)
        assert persisted.metadata["token_refresh"]["credential_epoch"] == 2
        assert persisted.metadata["token_refresh"]["reason"]["code"] == expected_code
      end
    end

    test "provider rejection lifecycle preserves the canonical expiry marker" do
      marker = known_expiry_metadata(2, DateTime.add(DateTime.utc_now(), 600))
      identity = refreshable_identity_fixture("active", marker)
      _assignment = active_assignment_for_identity!(identity)

      assert {:ok, _allocated, fence} = CredentialFencing.allocate_usage_probe(identity)

      assert {:ok, :applied, rejected} =
               CredentialFencing.mark_definitive_rejection(identity, fence)

      assert rejected.status == "reauth_required"
      assert expiry_marker(rejected) == expiry_marker(marker)
      assert TokenRefreshMetadata.project_access_token_expiry(rejected.metadata).state == :known
    end

    test "late provider success cannot overwrite a newer credential epoch" do
      refresh_token = secret("refresh", "late-epoch")
      stale_access_token = secret("access", "late-epoch-stale")
      current_access_token = secret("access", "late-epoch-current")
      release_ref = make_ref()

      upstream =
        start_upstream(
          FakeUpstream.barrier_json_response(
            %{"access_token" => stale_access_token, "expires_in" => 3600},
            notify: self(),
            release_ref: release_ref
          )
        )

      identity =
        refreshable_identity_fixture(
          "active",
          known_expiry_metadata(2, DateTime.add(DateTime.utc_now(), 600))
          |> Map.put("base_url", FakeUpstream.url(upstream))
        )

      store_secret!(identity, "access_token", current_access_token)
      store_secret!(identity, "refresh_token", refresh_token)
      parent = self()

      refresh =
        Task.async(fn ->
          Sandbox.allow(Repo, parent, self())
          TokenRefresh.refresh_access_token(identity, trigger_kind: "late_epoch_test")
        end)

      assert_receive {:fake_upstream_timeout_barrier, :before_headers, upstream_pid,
                      ^release_ref},
                     1_000

      claimed = Repo.get!(UpstreamIdentity, identity.id)

      advanced_metadata =
        claimed.metadata
        |> Map.put("credential_epoch", 3)
        |> put_in(["token_refresh", "access_token_expiry", "credential_epoch"], 3)

      claimed
      |> UpstreamIdentity.changeset(%{metadata: advanced_metadata})
      |> Repo.update!()

      send(upstream_pid, {:fake_upstream_release_timeout, release_ref})

      assert {:ok, %{status: :noop, reason: "refresh attempt was superseded"}} =
               Task.await(refresh, 15_000)

      persisted = Repo.get!(UpstreamIdentity, identity.id)
      assert persisted.status == "refreshing"
      assert persisted.metadata == advanced_metadata

      assert {:ok, ^current_access_token} =
               Secrets.decrypt_active_secret(identity, "access_token")

      refute inspect(persisted.metadata) =~ stale_access_token
    end

    test "malformed epoch at result time leaves the refreshing claim unchanged" do
      refresh_token = secret("refresh", "invalid-result-epoch")
      old_access_token = secret("access", "invalid-result-epoch-old")
      new_access_token = secret("access", "invalid-result-epoch-new")
      release_ref = make_ref()

      upstream =
        start_upstream(
          FakeUpstream.barrier_json_response(
            %{"access_token" => new_access_token, "expires_in" => 3600},
            notify: self(),
            release_ref: release_ref
          )
        )

      identity =
        refreshable_identity_fixture("active", %{
          "base_url" => FakeUpstream.url(upstream),
          "credential_epoch" => 2
        })

      store_secret!(identity, "access_token", old_access_token)
      store_secret!(identity, "refresh_token", refresh_token)
      parent = self()

      refresh =
        Task.async(fn ->
          Sandbox.allow(Repo, parent, self())
          TokenRefresh.refresh_access_token(identity, trigger_kind: "invalid_result_epoch_test")
        end)

      assert_receive {:fake_upstream_timeout_barrier, :before_headers, upstream_pid,
                      ^release_ref},
                     1_000

      claimed = Repo.get!(UpstreamIdentity, identity.id)
      malformed_metadata = Map.put(claimed.metadata, "credential_epoch", %{"invalid" => true})

      claimed
      |> UpstreamIdentity.changeset(%{metadata: malformed_metadata})
      |> Repo.update!()

      send(upstream_pid, {:fake_upstream_release_timeout, release_ref})

      assert {:error, %{code: :invalid_credential_epoch, message: "credential epoch is invalid"}} =
               Task.await(refresh, 15_000)

      persisted = Repo.get!(UpstreamIdentity, identity.id)
      assert persisted.status == "refreshing"
      assert persisted.metadata == malformed_metadata
      assert {:ok, ^old_access_token} = Secrets.decrypt_active_secret(identity, "access_token")
      refute inspect(persisted.metadata) =~ new_access_token
    end

    test "codex refresh uses the OAuth issuer form body and client id" do
      refresh_token = secret("refresh", "shape")
      new_access_token = secret("access", "shape")

      upstream =
        start_path_upstream(%{
          "/oauth/token" => {200, %{"access_token" => new_access_token}}
        })

      identity =
        refreshable_identity_fixture("active", %{
          "token_url" => FakeUpstream.url(upstream) <> "/oauth/token"
        })

      store_secret!(identity, "refresh_token", refresh_token)

      assert {:ok, %{status: :active}} =
               TokenRefresh.refresh_access_token(identity,
                 trigger_kind: "shape_test"
               )

      assert [request] = FakeUpstream.requests(upstream)
      assert request.path == "/oauth/token"
      headers = Map.new(request.headers)

      assert headers["user-agent"] ==
               "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

      assert headers["sec-fetch-site"] == "same-origin"
      assert headers["sec-fetch-mode"] == "cors"
      assert headers["sec-fetch-dest"] == "empty"
      assert headers["origin"] == CodexAuth.issuer()

      form = URI.decode_query(request.body)
      assert form["grant_type"] == "refresh_token"
      assert form["client_id"] == CodexAuth.client_id()
      assert form["refresh_token"] == refresh_token
    end

    test "metadata refresh token URL selects local provider endpoint" do
      refresh_token = secret("refresh", "metadata-url")
      new_access_token = secret("access", "metadata-url")

      metadata_upstream =
        start_path_upstream(%{
          "/oauth/token" => {200, %{"access_token" => new_access_token}}
        })

      identity =
        refreshable_identity_fixture("active", %{
          "refresh_token_url" => FakeUpstream.url(metadata_upstream) <> "/oauth/token"
        })

      store_secret!(identity, "refresh_token", refresh_token)

      assert {:ok, %{status: :active}} =
               TokenRefresh.refresh_access_token(identity,
                 trigger_kind: "metadata_url_test"
               )

      assert FakeUpstream.count(metadata_upstream) == 1

      assert {:ok, ^new_access_token} =
               Secrets.decrypt_active_secret(identity, "access_token")
    end

    test "concurrent refreshes for one identity produce one provider request and one in-progress result" do
      refresh_token = secret("refresh", "single-flight")
      new_access_token = secret("access", "single-flight")
      release_ref = make_ref()

      upstream =
        start_upstream(
          FakeUpstream.barrier_json_response(
            %{"access_token" => new_access_token, "expires_in" => 3600},
            notify: self(),
            release_ref: release_ref
          )
        )

      identity =
        refreshable_identity_fixture("active", %{"base_url" => FakeUpstream.url(upstream)})

      store_secret!(identity, "refresh_token", refresh_token)

      parent = self()

      first =
        Task.async(fn ->
          Sandbox.allow(Repo, parent, self())
          TokenRefresh.refresh_access_token(identity, trigger_kind: "single_flight_first")
        end)

      assert_receive {:fake_upstream_timeout_barrier, :before_headers, upstream_pid,
                      ^release_ref},
                     1_000

      persisted = Repo.get!(UpstreamIdentity, identity.id)
      token_refresh = persisted.metadata["token_refresh"]

      assert {:error, :refresh_in_progress, in_progress} =
               TokenRefresh.refresh_access_token(identity, trigger_kind: "single_flight_second")

      assert in_progress == %{
               attempt_id: token_refresh["attempt_id"],
               generation: token_refresh["generation"],
               started_at: token_refresh["started_at"],
               stale_after_ms: token_refresh["stale_after_ms"]
             }

      assert FakeUpstream.count(upstream) == 1

      send(upstream_pid, {:fake_upstream_release_timeout, release_ref})

      assert {:ok, %{status: :active, retryable?: false}} = Task.await(first, 1_000)
      assert FakeUpstream.count(upstream) == 1

      assert {:ok, ^new_access_token} =
               Secrets.decrypt_active_secret(identity, "access_token")
    end

    test "a stale credential epoch skips the provider refresh and hands back the rotated identity" do
      refresh_token = secret("refresh", "epoch-fence")
      rotated_access_token = secret("access", "epoch-fence")

      upstream =
        start_path_upstream(%{
          "/oauth/token" => {200, %{"access_token" => rotated_access_token, "expires_in" => 3600}}
        })

      identity =
        refreshable_identity_fixture("active", %{"base_url" => FakeUpstream.url(upstream)})

      store_secret!(identity, "refresh_token", refresh_token)

      original_epoch = CredentialFencing.credential_epoch(identity)

      # Probe A refreshes under the epoch it observed; rotation advances it.
      assert {:ok, %{status: :active}} =
               TokenRefresh.refresh_access_token(identity,
                 trigger_kind: "account_reconciliation",
                 expected_credential_epoch: original_epoch
               )

      assert FakeUpstream.count(upstream) == 1

      rotated = Repo.get!(UpstreamIdentity, identity.id)
      assert CredentialFencing.credential_epoch(rotated) == original_epoch + 1

      # Probe B's auth failure was produced under the replaced credentials:
      # the provider must not be called again for stale evidence, and the
      # caller gets the current active identity to retry usage with.
      assert {:ok,
              %{
                status: :active,
                retryable?: false,
                reason: "credential epoch advanced",
                identity: current
              }} =
               TokenRefresh.refresh_access_token(identity,
                 trigger_kind: "account_reconciliation",
                 expected_credential_epoch: original_epoch
               )

      assert FakeUpstream.count(upstream) == 1
      assert current.id == identity.id
      assert {:ok, ^rotated_access_token} = Secrets.decrypt_active_secret(current, "access_token")

      # A stale-epoch caller against a non-active identity gets a noop
      # instead of pretending the account can serve.
      rotated
      |> Ecto.Changeset.change(%{status: "refresh_due"})
      |> Repo.update!()

      assert {:ok, %{status: :noop, reason: "credential epoch advanced"}} =
               TokenRefresh.refresh_access_token(identity,
                 trigger_kind: "account_reconciliation",
                 expected_credential_epoch: original_epoch
               )

      assert FakeUpstream.count(upstream) == 1

      # A caller carrying the current epoch still performs a normal refresh.
      assert {:ok, %{status: :active}} =
               TokenRefresh.refresh_access_token(identity,
                 trigger_kind: "account_reconciliation",
                 expected_credential_epoch: original_epoch + 1
               )

      assert FakeUpstream.count(upstream) == 2
    end

    test "active non-stale attempt returns in-progress without decrypting secrets or provider I/O" do
      upstream =
        start_path_upstream(%{
          "/oauth/token" => {200, %{"access_token" => secret("access", "unused")}}
        })

      metadata = active_attempt_metadata()

      identity =
        refreshable_identity_fixture("refreshing", %{
          "base_url" => FakeUpstream.url(upstream),
          "token_refresh" => metadata
        })

      assert {:error, :refresh_in_progress, in_progress} =
               TokenRefresh.refresh_access_token(identity, trigger_kind: "direct_retry")

      assert in_progress == %{
               attempt_id: metadata["attempt_id"],
               generation: metadata["generation"],
               started_at: metadata["started_at"],
               stale_after_ms: metadata["stale_after_ms"]
             }

      persisted = Repo.get!(UpstreamIdentity, identity.id)
      assert persisted.status == "refreshing"
      assert persisted.metadata["token_refresh"] == metadata
      assert FakeUpstream.count(upstream) == 0
    end

    test "custom receive timeout reaches Codex OAuth refresh request" do
      refresh_token = secret("refresh", "timeout")
      release_ref = make_ref()

      upstream =
        start_upstream(
          FakeUpstream.timeout_before_headers(notify: self(), release_ref: release_ref)
        )

      identity =
        refreshable_identity_fixture("active", %{
          "base_url" => FakeUpstream.url(upstream)
        })

      store_secret!(identity, "refresh_token", refresh_token)

      started_at = System.monotonic_time(:millisecond)

      assert {:ok, %{status: :refresh_failed, retryable?: true}} =
               TokenRefresh.refresh_access_token(identity,
                 trigger_kind: "timeout_test",
                 receive_timeout: 100
               )

      elapsed_ms = System.monotonic_time(:millisecond) - started_at
      assert elapsed_ms < 2_000

      assert_receive {:fake_upstream_timeout_barrier, :before_headers, upstream_pid,
                      ^release_ref},
                     1_000

      send(upstream_pid, {:fake_upstream_release_timeout, release_ref})

      persisted = Repo.get!(UpstreamIdentity, identity.id)
      assert persisted.metadata["token_refresh"]["receive_timeout_ms"] == 100
      assert persisted.metadata["token_refresh"]["status"] == "failed"
      assert FakeUpstream.count(upstream) == 1
    end

    test "stale threshold is derived from custom receive timeout" do
      refresh_token = secret("refresh", "custom-stale")
      new_access_token = secret("access", "custom-stale")

      upstream =
        start_path_upstream(%{
          "/oauth/token" => {200, %{"access_token" => new_access_token}}
        })

      identity = identity_with_refresh_token!("active", upstream, refresh_token)

      assert {:ok, %{status: :active}} =
               TokenRefresh.refresh_access_token(identity,
                 trigger_kind: "custom_stale_test",
                 receive_timeout: 1234
               )

      token_refresh = Repo.get!(UpstreamIdentity, identity.id).metadata["token_refresh"]
      assert token_refresh["receive_timeout_ms"] == 1234
      assert token_refresh["stale_after_ms"] > token_refresh["receive_timeout_ms"]
      assert token_refresh["stale_after_ms"] == 21_234
    end

    test "default stale threshold exceeds provider and worker timeouts" do
      refresh_token = secret("refresh", "default-stale")
      new_access_token = secret("access", "default-stale")

      upstream =
        start_path_upstream(%{
          "/oauth/token" => {200, %{"access_token" => new_access_token}}
        })

      identity = identity_with_refresh_token!("active", upstream, refresh_token)

      assert {:ok, %{status: :active}} =
               TokenRefresh.refresh_access_token(identity, trigger_kind: "default_stale_test")

      token_refresh = Repo.get!(UpstreamIdentity, identity.id).metadata["token_refresh"]
      assert token_refresh["receive_timeout_ms"] == 30_000
      assert token_refresh["stale_after_ms"] == 50_000
      assert token_refresh["stale_after_ms"] > 45_000
    end

    test "stale takeover uses persisted DB-time metadata without sleeping" do
      refresh_token = secret("refresh", "stale-takeover")
      new_access_token = secret("access", "stale-takeover")

      upstream =
        start_path_upstream(%{
          "/oauth/token" => {200, %{"access_token" => new_access_token}}
        })

      stale_metadata = active_attempt_metadata(stale_after_ms: 50_000)

      identity =
        refreshable_identity_fixture("refreshing", %{
          "base_url" => FakeUpstream.url(upstream),
          "token_refresh" => stale_metadata
        })

      store_secret!(identity, "refresh_token", refresh_token)
      seed_stale_started_at!(identity, stale_metadata, 120)

      assert {:ok, %{status: :active}} =
               TokenRefresh.refresh_access_token(identity,
                 trigger_kind: "stale_takeover_test",
                 receive_timeout: 100
               )

      persisted = Repo.get!(UpstreamIdentity, identity.id)
      token_refresh = persisted.metadata["token_refresh"]
      assert token_refresh["status"] == "succeeded"
      assert token_refresh["generation"] == stale_metadata["generation"] + 1
      assert token_refresh["receive_timeout_ms"] == 100
      assert token_refresh["stale_after_ms"] == 20_100
      assert FakeUpstream.count(upstream) == 1
    end

    test "malformed refreshing metadata is reclaimable and not terminal by itself" do
      refresh_token = secret("refresh", "malformed")
      new_access_token = secret("access", "malformed")

      upstream =
        start_path_upstream(%{
          "/oauth/token" => {200, %{"access_token" => new_access_token}}
        })

      identity =
        refreshable_identity_fixture("refreshing", %{
          "base_url" => FakeUpstream.url(upstream),
          "token_refresh" => %{
            "status" => "refreshing",
            "attempt_id" => 123,
            "generation" => "not-an-integer",
            "started_at" => %{},
            "stale_after_ms" => "slow"
          }
        })

      store_secret!(identity, "refresh_token", refresh_token)

      assert {:ok, %{status: :active, retryable?: false}} =
               TokenRefresh.refresh_access_token(identity,
                 trigger_kind: "malformed_metadata_test",
                 receive_timeout: 100
               )

      persisted = Repo.get!(UpstreamIdentity, identity.id)
      assert persisted.status == "active"
      assert persisted.metadata["token_refresh"]["status"] == "succeeded"
      assert persisted.metadata["token_refresh"]["generation"] == 1
      refute persisted.metadata["token_refresh"]["reason"]
    end

    test "late provider success cannot overwrite a newer refresh generation" do
      refresh_token = secret("refresh", "late")
      old_access_token = secret("access", "old-late")
      current_access_token = secret("access", "current-late")
      release_ref = make_ref()

      upstream =
        start_upstream(
          FakeUpstream.barrier_json_response(
            %{"access_token" => old_access_token, "expires_in" => 3600},
            notify: self(),
            release_ref: release_ref
          )
        )

      identity =
        refreshable_identity_fixture("active", %{"base_url" => FakeUpstream.url(upstream)})

      store_secret!(identity, "refresh_token", refresh_token)

      parent = self()

      first =
        Task.async(fn ->
          Sandbox.allow(Repo, parent, self())
          TokenRefresh.refresh_access_token(identity, trigger_kind: "late_first")
        end)

      assert_receive {:fake_upstream_timeout_barrier, :before_headers, upstream_pid,
                      ^release_ref},
                     1_000

      claimed = Repo.get!(UpstreamIdentity, identity.id).metadata["token_refresh"]
      newer_metadata = active_attempt_metadata(generation: claimed["generation"] + 1)

      Repo.get!(UpstreamIdentity, identity.id)
      |> UpstreamIdentity.changeset(%{
        status: "refreshing",
        metadata: %{"token_refresh" => newer_metadata}
      })
      |> Repo.update!()

      store_secret!(identity, "access_token", current_access_token)

      send(upstream_pid, {:fake_upstream_release_timeout, release_ref})

      assert {:error, :refresh_in_progress, in_progress} = Task.await(first, 1_000)
      assert in_progress.generation == newer_metadata["generation"]

      persisted = Repo.get!(UpstreamIdentity, identity.id)
      assert persisted.status == "refreshing"
      assert persisted.metadata["token_refresh"] == newer_metadata

      assert {:ok, ^current_access_token} =
               Secrets.decrypt_active_secret(identity, "access_token")

      refute inspect(persisted.metadata["token_refresh"]) =~ old_access_token
    end

    test "invalid grants mark the account reauth_required without retrying" do
      refresh_token = secret("refresh", "revoked")

      upstream =
        start_path_upstream(%{
          "/oauth/token" => {400, %{"error" => "invalid_grant"}}
        })

      identity =
        refreshable_identity_fixture("active", %{"base_url" => FakeUpstream.url(upstream)})

      assignment = active_assignment_for_identity!(identity)
      store_secret!(identity, "refresh_token", refresh_token)

      assert {:ok, %{status: :reauth_required, retryable?: false} = result} =
               TokenRefresh.refresh_access_token(identity,
                 trigger_kind: "unit_test"
               )

      persisted = Repo.get!(UpstreamIdentity, identity.id)
      assert persisted.status == "reauth_required"
      assert persisted.metadata["token_refresh"]["status"] == "reauth_required"
      assert persisted.metadata["token_refresh"]["reason"]["code"] == "refresh_token_revoked"

      cascaded = Repo.get!(PoolUpstreamAssignment, assignment.id)
      assert cascaded.status == "active"
      assert cascaded.health_status == "disabled"
      assert cascaded.eligibility_status == "ineligible"
      assert %DateTime{} = cascaded.disabled_at
      refute inspect(result) =~ refresh_token
    end

    test "expired refresh tokens mark the account reauth_required without retrying" do
      refresh_token = secret("refresh", "expired")

      upstream =
        start_path_upstream(%{
          "/oauth/token" => {400, %{"error" => %{"code" => "token_expired"}}}
        })

      identity =
        refreshable_identity_fixture("active", %{"base_url" => FakeUpstream.url(upstream)})

      assignment = active_assignment_for_identity!(identity)
      store_secret!(identity, "refresh_token", refresh_token)

      assert {:ok, %{status: :reauth_required, retryable?: false} = result} =
               TokenRefresh.refresh_access_token(identity,
                 trigger_kind: "unit_test"
               )

      persisted = Repo.get!(UpstreamIdentity, identity.id)
      assert persisted.status == "reauth_required"
      assert persisted.metadata["token_refresh"]["status"] == "reauth_required"
      assert persisted.metadata["token_refresh"]["reason"]["code"] == "refresh_token_revoked"

      cascaded = Repo.get!(PoolUpstreamAssignment, assignment.id)
      assert cascaded.health_status == "disabled"
      assert cascaded.eligibility_status == "ineligible"
      refute inspect(result) =~ refresh_token
    end

    test "reused refresh tokens mark the account reauth_required without retrying or storing provider payloads" do
      for {label, provider_body} <- [
            {"flat",
             %{
               "error" => "refresh_token_reused",
               "provider_body" => "raw-provider-body-do-not-leak"
             }},
            {"nested",
             %{
               "error" => %{
                 "code" => "refresh_token_reused",
                 "body" => "nested-provider-body-do-not-leak"
               }
             }}
          ] do
        refresh_token = secret("refresh", "reused-#{label}")

        upstream =
          start_path_upstream(%{
            "/oauth/token" => {400, provider_body}
          })

        identity =
          refreshable_identity_fixture("active", %{"base_url" => FakeUpstream.url(upstream)})

        assignment = active_assignment_for_identity!(identity)
        store_secret!(identity, "refresh_token", refresh_token)

        assert {:ok, %{status: :reauth_required, retryable?: false} = result} =
                 TokenRefresh.refresh_access_token(identity,
                   trigger_kind: "unit_test"
                 )

        persisted = Repo.get!(UpstreamIdentity, identity.id)
        token_refresh = persisted.metadata["token_refresh"]
        metadata_text = inspect(persisted.metadata)

        assert persisted.status == "reauth_required"
        assert token_refresh["status"] == "reauth_required"

        assert token_refresh["reason"] == %{
                 "code" => "refresh_token_revoked",
                 "message" => "refresh token was revoked"
               }

        cascaded = Repo.get!(PoolUpstreamAssignment, assignment.id)
        assert cascaded.health_status == "disabled"
        assert cascaded.eligibility_status == "ineligible"
        assert FakeUpstream.count(upstream) == 1

        refute inspect(result) =~ refresh_token
        refute metadata_text =~ refresh_token
        refute metadata_text =~ "refresh_token_reused"
        refute metadata_text =~ "raw-provider-body-do-not-leak"
        refute metadata_text =~ "nested-provider-body-do-not-leak"
      end
    end

    test "refresh token error descriptions mark the account reauth_required without retrying" do
      refresh_token = secret("refresh", "revoked-description")

      upstream =
        start_path_upstream(%{
          "/oauth/token" =>
            {400,
             %{
               "error" => "invalid_request",
               "error_description" => "The refresh token has been revoked"
             }}
        })

      identity =
        refreshable_identity_fixture("active", %{"base_url" => FakeUpstream.url(upstream)})

      assignment = active_assignment_for_identity!(identity)
      store_secret!(identity, "refresh_token", refresh_token)

      assert {:ok, %{status: :reauth_required, retryable?: false} = result} =
               TokenRefresh.refresh_access_token(identity,
                 trigger_kind: "unit_test"
               )

      persisted = Repo.get!(UpstreamIdentity, identity.id)
      assert persisted.status == "reauth_required"
      assert persisted.metadata["token_refresh"]["status"] == "reauth_required"
      assert persisted.metadata["token_refresh"]["reason"]["code"] == "refresh_token_revoked"

      cascaded = Repo.get!(PoolUpstreamAssignment, assignment.id)
      assert cascaded.health_status == "disabled"
      assert cascaded.eligibility_status == "ineligible"
      refute inspect(result) =~ refresh_token
    end

    test "unrecognized refresh failures stay retryable" do
      refresh_token = secret("refresh", "unknown-oauth-error")

      upstream =
        start_path_upstream(%{
          "/oauth/token" => {400, %{"error" => "invalid_request", "message" => "bad request"}}
        })

      identity = identity_with_refresh_token!("active", upstream, refresh_token)

      assert {:ok, %{status: :refresh_failed, retryable?: true, reason: reason}} =
               TokenRefresh.refresh_access_token(identity,
                 trigger_kind: "unit_test"
               )

      assert reason == "token refresh failed: codex_oauth_refresh_failed"

      persisted = Repo.get!(UpstreamIdentity, identity.id)
      assert persisted.status == "refresh_failed"
      assert persisted.metadata["token_refresh"]["status"] == "failed"
      assert persisted.metadata["token_refresh"]["reason"]["code"] == "codex_oauth_refresh_failed"
      refute inspect(persisted.metadata["token_refresh"]) =~ refresh_token
    end

    test "transient upstream failures mark refresh_failed and stay retryable" do
      refresh_token = secret("refresh", "transient")

      upstream =
        start_path_upstream(%{
          "/oauth/token" => {503, %{"error" => "temporary"}}
        })

      identity = identity_with_refresh_token!("active", upstream, refresh_token)

      assert {:ok, %{status: :refresh_failed, retryable?: true, reason: reason}} =
               TokenRefresh.refresh_access_token(identity,
                 trigger_kind: "unit_test"
               )

      assert reason == "token refresh failed: codex_auth_transient"
      persisted = Repo.get!(UpstreamIdentity, identity.id)
      assert persisted.status == "refresh_failed"
      assert persisted.metadata["token_refresh"]["status"] == "failed"
      assert persisted.metadata["token_refresh"]["reason"]["code"] == "codex_auth_transient"
      refute inspect(persisted.metadata["token_refresh"]) =~ refresh_token
    end

    test "missing refresh token marks reauth_required and does not call the provider" do
      upstream =
        start_path_upstream(%{
          "/oauth/token" => {200, %{"access_token" => secret("access", "unused")}}
        })

      identity =
        refreshable_identity_fixture("active", %{"base_url" => FakeUpstream.url(upstream)})

      assignment = active_assignment_for_identity!(identity)

      assert {:ok, %{status: :reauth_required, retryable?: false}} =
               TokenRefresh.refresh_access_token(identity,
                 trigger_kind: "unit_test"
               )

      assert Repo.get!(UpstreamIdentity, identity.id).status == "reauth_required"

      cascaded = Repo.get!(PoolUpstreamAssignment, assignment.id)
      assert cascaded.status == "active"
      assert cascaded.health_status == "disabled"
      assert cascaded.eligibility_status == "ineligible"
      assert %DateTime{} = cascaded.disabled_at
      assert FakeUpstream.count(upstream) == 0
    end

    test "PAT-like access-only identities cannot hydrate through token refresh" do
      personal_access_token = "at-refresh-pat-do-not-leak-#{System.unique_integer([:positive])}"

      upstream =
        start_path_upstream(%{
          "/oauth/token" => {200, %{"access_token" => secret("access", "unused-pat")}},
          "/api/auth/whoami" => {200, %{"email" => "pat-user@example.com"}}
        })

      identity =
        refreshable_identity_fixture("active", %{"base_url" => FakeUpstream.url(upstream)})

      store_secret!(identity, "access_token", personal_access_token)
      assignment = active_assignment_for_identity!(identity)

      assert {:ok, %{status: :reauth_required, retryable?: false} = result} =
               TokenRefresh.refresh_access_token(identity,
                 trigger_kind: "pat_unsupported_boundary"
               )

      persisted = Repo.get!(UpstreamIdentity, identity.id)
      token_refresh = persisted.metadata["token_refresh"]

      assert persisted.status == "reauth_required"
      assert token_refresh["status"] == "reauth_required"
      assert token_refresh["trigger_kind"] == "pat_unsupported_boundary"

      assert token_refresh["reason"] == %{
               "code" => "missing_refresh_token",
               "message" => "refresh token is missing"
             }

      assert {:ok, ^personal_access_token} =
               Secrets.decrypt_active_secret(identity, "access_token")

      assert {:error, %{code: :upstream_secret_not_found}} =
               Secrets.decrypt_active_secret(identity, "refresh_token")

      cascaded = Repo.get!(PoolUpstreamAssignment, assignment.id)
      assert cascaded.health_status == "disabled"
      assert cascaded.eligibility_status == "ineligible"
      assert FakeUpstream.count(upstream) == 0
      refute inspect(result) =~ personal_access_token
      refute inspect(persisted.metadata) =~ personal_access_token
    end

    test "token refresh jobs are unique per upstream identity" do
      identity = refreshable_identity_fixture("active")

      assert {:ok, first_job} = Jobs.enqueue_token_refresh(identity)
      assert {:ok, second_job} = Jobs.enqueue_token_refresh(identity)

      refute first_job.conflict?
      assert second_job.conflict?
      assert first_job.id == second_job.id
      assert [job] = all_enqueued(worker: TokenRefreshWorker)
      assert job.args["upstream_identity_id"] == identity.id
    end

    test "worker discards missing refresh tokens without retry jobs" do
      identity = refreshable_identity_fixture("active")

      assert {:ok, job} = Jobs.enqueue_token_refresh(identity, trigger_kind: "scheduled")

      assert :discard = perform_job(TokenRefreshWorker, job.args)
      assert Repo.get!(UpstreamIdentity, identity.id).status == "reauth_required"
      assert_only_incomplete_token_refresh_job(identity, job)
    end

    test "worker discards revoked refresh tokens without retry jobs" do
      refresh_token = secret("refresh", "worker-revoked")

      upstream =
        start_path_upstream(%{
          "/oauth/token" => {400, %{"error" => "invalid_grant"}}
        })

      identity =
        refreshable_identity_fixture("active", %{"base_url" => FakeUpstream.url(upstream)})

      active_assignment_for_identity!(identity)
      store_secret!(identity, "refresh_token", refresh_token)

      assert {:ok, job} = Jobs.enqueue_token_refresh(identity, trigger_kind: "scheduled")

      assert :discard = perform_job(TokenRefreshWorker, job.args)

      persisted = Repo.get!(UpstreamIdentity, identity.id)
      assert persisted.status == "reauth_required"
      assert persisted.metadata["token_refresh"]["status"] == "reauth_required"
      assert persisted.metadata["token_refresh"]["reason"]["code"] == "refresh_token_revoked"
      assert_only_incomplete_token_refresh_job(identity, job)
      refute inspect(Repo.all(Oban.Job)) =~ refresh_token
    end

    test "worker success does not enqueue another token refresh job" do
      refresh_token = secret("refresh", "no-self-enqueue")
      new_access_token = secret("access", "no-self-enqueue")

      upstream =
        start_path_upstream(%{
          "/oauth/token" => {200, %{"access_token" => new_access_token}}
        })

      identity =
        refreshable_identity_fixture("refresh_due", %{"base_url" => FakeUpstream.url(upstream)})

      active_assignment_for_identity!(identity)
      store_secret!(identity, "refresh_token", refresh_token)

      before_count = Repo.aggregate(Oban.Job, :count)
      assert {:ok, job} = Jobs.enqueue_token_refresh(identity, trigger_kind: "manual")
      assert Repo.aggregate(Oban.Job, :count) == before_count + 1

      assert :ok = perform_job(TokenRefreshWorker, job.args)

      assert Repo.get!(UpstreamIdentity, identity.id).status == "active"
      assert Repo.aggregate(Oban.Job, :count) == before_count + 1

      assert [persisted_job] =
               Repo.all(
                 from oban_job in Oban.Job,
                   where:
                     oban_job.worker == ^worker_name(TokenRefreshWorker) and
                       fragment("?->>?", oban_job.args, "upstream_identity_id") == ^identity.id
               )

      assert persisted_job.id == job.id
      refute inspect(Repo.all(Oban.Job)) =~ refresh_token
      refute inspect(Repo.all(Oban.Job)) =~ new_access_token
    end

    test "reauth-required identities from missing refresh tokens are not scheduled again" do
      identity = refreshable_identity_fixture("refresh_due")
      active_assignment_for_identity!(identity)

      assert {:ok, job} = Jobs.enqueue_token_refresh(identity, trigger_kind: "scheduled")

      assert :discard = perform_job(TokenRefreshWorker, job.args)
      assert Repo.get!(UpstreamIdentity, identity.id).status == "reauth_required"
      assert_only_incomplete_token_refresh_job(identity, job)

      assert {:ok, %{inserted: [], conflicts: [], errors: []}} =
               Jobs.enqueue_scheduled_token_refreshes(now: DateTime.utc_now())

      assert [persisted_job] = all_enqueued(worker: TokenRefreshWorker)
      assert persisted_job.id == job.id
    end

    test "worker snoozes when another non-stale refresh attempt is already in progress" do
      upstream =
        start_path_upstream(%{
          "/oauth/token" => {200, %{"access_token" => secret("access", "worker-unused")}}
        })

      metadata = active_attempt_metadata()

      identity =
        refreshable_identity_fixture("refreshing", %{
          "base_url" => FakeUpstream.url(upstream),
          "token_refresh" => metadata
        })

      store_secret!(identity, "refresh_token", secret("refresh", "worker-in-progress"))

      assert {:snooze, 5} =
               perform_job(TokenRefreshWorker, %{"upstream_identity_id" => identity.id})

      persisted = Repo.get!(UpstreamIdentity, identity.id)
      assert persisted.status == "refreshing"
      assert persisted.metadata["token_refresh"] == metadata
      assert FakeUpstream.count(upstream) == 0
    end

    test "worker discards reauth-required, paused, and deleted noop accounts without retry jobs" do
      for status <- ["reauth_required", "paused", "deleted"] do
        upstream =
          start_path_upstream(%{
            "/oauth/token" => {200, %{"access_token" => secret("access", status)}}
          })

        identity = identity_with_refresh_token!(status, upstream, secret("refresh", status))

        assert {:ok, job} = Jobs.enqueue_token_refresh(identity, trigger_kind: "scheduled")

        assert :discard = perform_job(TokenRefreshWorker, job.args)

        assert Repo.get!(UpstreamIdentity, identity.id).status == status
        assert FakeUpstream.count(upstream) == 0
        assert_only_incomplete_token_refresh_job(identity, job)
      end
    end
  end

  defp start_upstream(mode) do
    {:ok, upstream} = FakeUpstream.start_link(mode)
    on_exit(fn -> FakeUpstream.stop(upstream) end)
    upstream
  end

  defp active_attempt_metadata(opts \\ []) do
    generation = Keyword.get(opts, :generation, 1)
    receive_timeout_ms = Keyword.get(opts, :receive_timeout_ms, 30_000)
    stale_after_ms = Keyword.get(opts, :stale_after_ms, 60_000)

    %{
      "status" => "refreshing",
      "attempt_id" => Ecto.UUID.generate(),
      "generation" => generation,
      "started_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "trigger_kind" => "test",
      "receive_timeout_ms" => receive_timeout_ms,
      "stale_after_ms" => stale_after_ms
    }
  end

  defp seed_stale_started_at!(identity, metadata, seconds_ago) do
    seeded_metadata = Map.put(identity.metadata || %{}, "token_refresh", metadata)

    query =
      from(i in UpstreamIdentity,
        where: i.id == ^identity.id,
        update: [
          set: [
            metadata:
              fragment(
                ~s[jsonb_set(?::jsonb, '{token_refresh,started_at}', to_jsonb(to_char(transaction_timestamp() - make_interval(secs => ?), 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')), false)],
                ^seeded_metadata,
                ^seconds_ago
              )
          ]
        ]
      )

    assert {1, nil} = Repo.update_all(query, [])
  end

  defp identity_with_refresh_token!(status, upstream, refresh_token) do
    identity = refreshable_identity_fixture(status, %{"base_url" => FakeUpstream.url(upstream)})
    store_secret!(identity, "refresh_token", refresh_token)
    identity
  end

  defp active_assignment_for_identity!(identity) do
    pool = pool_fixture()

    assert {:ok, assignment} =
             PoolAssignments.create_pool_assignment(pool, identity, %{})

    assert {:ok, assignment} =
             PoolAssignments.activate_pool_assignment(assignment)

    assignment
  end

  defp refreshable_identity_fixture(status, metadata \\ %{}) do
    configure_upstream_secret_key!()

    assert {:ok, identity} =
             IdentityLifecycle.create_upstream_identity(%{
               chatgpt_account_id: "acct_#{System.unique_integer([:positive])}",
               account_label: "Refresh account",
               onboarding_method: "import",
               status: status,
               metadata: metadata
             })

    identity
  end

  defp store_secret!(identity, kind, plaintext) do
    assert {:ok, _secret} =
             Upstreams.store_encrypted_secret(identity, %{secret_kind: kind, plaintext: plaintext})
  end

  defp assert_only_incomplete_token_refresh_job(%UpstreamIdentity{} = identity, %Oban.Job{} = job) do
    assert [persisted_job] = incomplete_token_refresh_jobs_for_identity(identity)
    assert persisted_job.id == job.id
  end

  defp incomplete_token_refresh_jobs_for_identity(%UpstreamIdentity{id: identity_id}) do
    Repo.all(
      from oban_job in Oban.Job,
        where:
          oban_job.worker == ^worker_name(TokenRefreshWorker) and
            oban_job.state in ^@incomplete_job_states and
            fragment("?->>? = ?::text", oban_job.args, "upstream_identity_id", ^identity_id)
    )
  end

  defp worker_name(worker), do: worker |> Atom.to_string() |> String.replace_prefix("Elixir.", "")

  defp start_path_upstream(routes) do
    {:ok, upstream} = FakeUpstream.start_link({:path_json, routes})
    on_exit(fn -> FakeUpstream.stop(upstream) end)
    upstream
  end

  defp known_expiry_metadata(epoch, deadline) do
    %{
      "credential_epoch" => epoch,
      "access_token_expires_at" => DateTime.to_iso8601(deadline),
      "token_refresh" => %{
        "status" => "succeeded",
        "access_token_expiry" => %{
          "version" => 1,
          "credential_epoch" => epoch,
          "state" => "known",
          "source" => "explicit"
        }
      }
    }
  end

  defp expiry_marker(%UpstreamIdentity{} = identity), do: expiry_marker(identity.metadata)
  defp expiry_marker(metadata), do: get_in(metadata, ["token_refresh", "access_token_expiry"])

  defp jwt_with_exp(exp) do
    header = Base.url_encode64(Jason.encode!(%{"alg" => "none"}), padding: false)
    payload = Base.url_encode64(Jason.encode!(%{"exp" => exp}), padding: false)
    header <> "." <> payload <> ".signature"
  end

  defp secret(kind, label), do: Enum.join(["token", kind, label, "do", "not", "leak"], "-")

  defp configure_upstream_secret_key! do
    previous = Application.get_env(:codex_pooler, CodexPooler.Upstreams)

    Application.put_env(:codex_pooler, CodexPooler.Upstreams,
      upstream_secret_key: Base.encode64(:crypto.hash(:sha256, "test-upstream-secret-key")),
      upstream_secret_key_version: "test-v1"
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:codex_pooler, CodexPooler.Upstreams, previous)
      else
        Application.delete_env(:codex_pooler, CodexPooler.Upstreams)
      end
    end)
  end
end
