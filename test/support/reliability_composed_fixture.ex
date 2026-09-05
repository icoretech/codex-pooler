defmodule CodexPooler.ReliabilityComposedFixture do
  @moduledoc false
  import Ecto.Query
  import CodexPooler.PoolerFixtures
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport, only: [gateway_setup: 1]

  alias CodexPooler.{Access, Accounting, Repo}
  alias CodexPooler.Accounting.ClientRetry
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn}
  alias CodexPooler.Upstreams.Auth.{AccessTokenExpiry, TokenRefreshMetadata}
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  def fixture!(fake) do
    setup = gateway_setup(fake)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    %{user: owner} = CodexPooler.AccountsFixtures.bootstrap_owner_fixture()
    sibling = active_upstream_assignment_fixture(setup.pool, %{})
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    metadata =
      TokenRefreshMetadata.build_imported(
        sibling.identity.metadata,
        AccessTokenExpiry.unknown(),
        1,
        "synthetic",
        now
      )

    identity = Repo.update!(Ecto.Changeset.change(sibling.identity, metadata: metadata))
    target = enable_target!(setup.identity, fake)
    put_quota!(target, "96")
    put_quota!(identity, "75")
    ids = [target.id, identity.id]
    assignments = [setup.assignment.id, sibling.assignment.id]

    context = %{
      trigger: :threshold_pressure,
      pool_upstream_assignment_id: setup.assignment.id,
      upstream_identity_id: target.id,
      candidate_assignment_ids: [setup.assignment.id],
      candidate_identity_ids: [target.id],
      capacity_assignment_ids: assignments,
      capacity_identity_ids: ids,
      cohort_identity_ids: Enum.sort(ids),
      routable_assignment_ids: assignments,
      routable_identity_ids: ids,
      route_class: "proxy_websocket",
      transient_circuit_exclusions: [],
      hard_pinned_continuity?: false,
      quota_scope: %{
        requested_model: setup.model.exposed_model_id,
        catalog_model: setup.model.exposed_model_id,
        exposed_model_id: setup.model.exposed_model_id,
        upstream_model: setup.model.upstream_model_id,
        upstream_model_id: setup.model.upstream_model_id
      }
    }

    Map.merge(setup, %{
      auth: auth,
      scope: Scope.for_user(owner, ["instance_owner"]),
      sibling: identity,
      context: context
    })
  end

  def predecessor!(setup) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    digest = :crypto.strong_rand_bytes(32)
    semantic_digest = :crypto.strong_rand_bytes(32)
    witness = ClientRetry.original_witness!(digest, setup.api_key.runtime_revocation_epoch)

    {:ok, %{request: predecessor}} =
      Accounting.claim_websocket_turn(setup.auth, setup.model, %{
        endpoint: "/backend-api/codex/responses",
        correlation_id: Ecto.UUID.generate(),
        native_client_retry_witness: witness
      })

    session =
      Repo.insert!(%CodexSession{
        pool_id: setup.pool.id,
        api_key_id: setup.api_key.id,
        session_key: "composed-#{System.unique_integer([:positive, :monotonic])}",
        pool_upstream_assignment_id: setup.assignment.id,
        status: "active",
        created_at: now,
        updated_at: now
      })

    turn =
      Repo.insert!(%CodexTurn{
        codex_session_id: session.id,
        request_id: predecessor.id,
        turn_sequence: 1,
        transport_kind: "websocket",
        semantic_turn_digest: semantic_digest,
        status: "failed",
        error_code: "upstream_stream_error",
        first_visible_output_at: now,
        completed_at: now,
        started_at: now,
        created_at: now,
        updated_at: now
      })

    attempt =
      attempt_fixture(predecessor, setup.assignment, %{
        status: "failed",
        completed_at: now,
        network_error_code: "upstream_stream_error",
        usage_status: "usage_unknown",
        transport: "websocket",
        replay_generation: 0,
        response_metadata: eligible_metadata(now)
      })

    predecessor =
      Repo.update!(
        Ecto.Changeset.change(predecessor,
          status: "failed",
          usage_status: "usage_unknown",
          completed_at: now,
          last_error_code: "upstream_stream_error"
        )
      )

    Repo.update!(Ecto.Changeset.change(turn, final_attempt_id: attempt.id))

    %{
      predecessor: predecessor,
      opts: %{
        endpoint: "/backend-api/codex/responses",
        requested_model: setup.model.exposed_model_id,
        runtime_revocation_epoch: setup.api_key.runtime_revocation_epoch,
        codex_session: session,
        semantic_turn_digest: semantic_digest,
        replay_claim_digest: digest
      }
    }
  end

  def retry(setup, fixture) do
    Accounting.claim_client_retry_successor(
      setup.auth,
      setup.model,
      %{"model" => setup.model.exposed_model_id, "input" => []},
      fixture.opts
    )
  end

  def put_quota!(identity, used_percent) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, [_]} =
      Windows.upsert_quota_windows(identity, [
        %{
          quota_key: "account",
          window_kind: "secondary",
          window_minutes: 10_080,
          used_percent: Decimal.new(used_percent),
          reset_at: DateTime.add(now, 2, :hour),
          observed_at: now,
          last_sync_at: now,
          source: "codex_usage_api",
          source_precision: "observed",
          quota_scope: "account",
          quota_family: "account",
          freshness_state: "fresh"
        }
      ])
  end

  def cleanup!(setup) do
    Repo.delete_all(from pool in CodexPooler.Pools.Pool, where: pool.id == ^setup.pool.id)

    Repo.delete_all(
      from i in UpstreamIdentity, where: i.id in ^[setup.identity.id, setup.sibling.id]
    )

    Repo.delete_all(
      from pricing in CodexPooler.Catalog.PricingSnapshot, where: pricing.id == ^setup.pricing.id
    )
  end

  defp enable_target!(identity, fake) do
    observed_at = DateTime.utc_now() |> DateTime.to_iso8601()

    metadata =
      identity.metadata
      |> Map.put("usage_base_url", CodexPooler.FakeUpstream.url(fake))
      |> Map.put("saved_resets", %{
        "status" => "reported",
        "available_count" => 1,
        "source" => "codex_usage_api",
        "path_style" => "codex_api",
        "observed_at" => observed_at,
        "usage_path" => "/api/codex/usage",
        "reason" => nil
      })

    Repo.update!(
      UpstreamIdentity.changeset(identity, %{
        metadata: metadata,
        saved_reset_auto_redeem_enabled: true,
        saved_reset_auto_redeem_trigger_mode: "threshold",
        saved_reset_auto_redeem_quota_threshold_percent: 95,
        saved_reset_auto_redeem_min_blocked_minutes: 60,
        saved_reset_auto_redeem_keep_credits: 0,
        updated_at: DateTime.utc_now()
      })
    )
  end

  defp eligible_metadata(now) do
    %{
      "transport_failure" => %{
        "phase" => "receive",
        "termination_source" => "peer_close_frame",
        "transport_signal" => "tcp_closed"
      },
      "native_client_retry_observation" => %{
        "version" => 1,
        "authority_complete" => true,
        "output_item_done_count" => 0,
        "output_item_done_count_saturated" => false,
        "partial_reasoning_seen" => true,
        "first_visible_at" => DateTime.to_iso8601(now),
        "terminal_seen" => false,
        "terminal_candidate_seen" => false
      }
    }
  end
end
