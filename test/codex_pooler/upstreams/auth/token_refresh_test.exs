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
  alias CodexPooler.Upstreams.Auth.CodexAuth
  alias CodexPooler.Upstreams.Lifecycle.IdentityLifecycle
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias Ecto.Adapters.SQL.Sandbox

  import CodexPooler.PoolerFixtures

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
      assert persisted.metadata["token_refresh"]["status"] == "succeeded"
      assert persisted.metadata["token_refresh"]["trigger_kind"] == "unit_test"
      assert %DateTime{} = persisted.last_successful_refresh_at
      assert persisted.metadata["access_token_expires_at"]

      refute inspect(result) =~ access_token
      refute inspect(result) =~ refresh_token
      refute inspect(result) =~ new_access_token
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

    test "worker discards missing refresh tokens without retry spam" do
      identity = refreshable_identity_fixture("active")

      assert :discard = perform_job(TokenRefreshWorker, %{"upstream_identity_id" => identity.id})
      assert Repo.get!(UpstreamIdentity, identity.id).status == "reauth_required"
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

    test "paused and deleted accounts are no-op terminal results" do
      for status <- ["paused", "deleted"] do
        upstream =
          start_path_upstream(%{
            "/oauth/token" => {200, %{"access_token" => secret("access", status)}}
          })

        identity = identity_with_refresh_token!(status, upstream, secret("refresh", status))

        assert {:ok, %{status: :noop, retryable?: false}} =
                 TokenRefresh.refresh_access_token(identity,
                   trigger_kind: "unit_test"
                 )

        assert Repo.get!(UpstreamIdentity, identity.id).status == status
        assert FakeUpstream.count(upstream) == 0
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

  defp start_path_upstream(routes) do
    {:ok, upstream} = FakeUpstream.start_link({:path_json, routes})
    on_exit(fn -> FakeUpstream.stop(upstream) end)
    upstream
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
