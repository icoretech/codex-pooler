defmodule CodexPooler.Gateway.Runtime.SavedResetCapacityFenceTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures, only: [active_upstream_assignment_fixture: 2]

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 1, put_model_source_assignments!: 2]

  alias CodexPooler.Access
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.CodexSession
  alias CodexPooler.Gateway.Routing.CandidateEligibility
  alias CodexPooler.Gateway.Routing.RouteFiltering
  alias CodexPooler.Gateway.Routing.SavedResetAutoRedeem
  alias CodexPooler.Gateway.Runtime.Dispatch.PreDispatch
  alias CodexPooler.Gateway.Runtime.Dispatch.RouteState
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.SavedResetRedemption
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  @endpoint "/backend-api/codex/responses"

  test "pre-dispatch continuity narrowing retains sibling capacity for the threshold fence" do
    {:ok, upstream} =
      FakeUpstream.start_link(
        {:path_json,
         %{
           "/api/codex/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}},
           "/api/codex/usage" => {200, usage_payload()}
         }}
      )

    setup = gateway_setup(upstream)

    sibling =
      active_upstream_assignment_fixture(setup.pool, %{
        account_label: "Sibling capacity fixture"
      })

    model = put_model_source_assignments!(setup.model, [setup.assignment, sibling.assignment])

    target_identity =
      setup.identity
      |> put_saved_reset_metadata!(upstream)
      |> enable_threshold_redemption!()

    sibling_identity = enable_threshold_redemption!(sibling.identity)

    put_weekly_quota!(target_identity, "96")
    put_weekly_quota!(sibling_identity, "75")

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    session = active_session!(setup, auth, setup.assignment.id)

    payload = %{
      "model" => model.exposed_model_id,
      "input" => [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [%{"type" => "input_text", "text" => "capacity fence fixture"}]
        }
      ]
    }

    {:ok, policy} = Access.normalize_api_key_policy(auth.api_key)

    request_options =
      %{api_key_policy: policy}
      |> RequestOptions.build(@endpoint, payload)
      |> RequestOptions.put_continuity(codex_session: session)
      |> RequestOptions.put_transport(upstream_websocket_session: self())

    assert {:ok, prepared} =
             PreDispatch.prepare(auth, @endpoint, payload, request_options, model)

    assert [{target_assignment, ^target_identity}] = prepared.candidates
    assert target_assignment.id == setup.assignment.id

    filter_input =
      CandidateEligibility.FilterInput.new(%{
        auth: auth,
        model: model,
        endpoint: @endpoint,
        payload: payload,
        request_options: prepared.request_options,
        candidates: prepared.candidates
      })

    assert {:ok, [{filtered_assignment, ^target_identity}], _request_options, route_state} =
             RouteFiltering.filter_candidates_with_route_state(filter_input, prepared.route_state)

    assert filtered_assignment.id == setup.assignment.id
    assert length(route_state.candidates) == 1

    assert Enum.map(route_state.saved_reset_auto_capacity, fn {assignment, identity} ->
             {assignment.id, identity.id}
           end) == [
             {setup.assignment.id, target_identity.id},
             {sibling.assignment.id, sibling_identity.id}
           ]

    assert Map.has_key?(route_state.quota_snapshots, sibling_identity.id)

    refreshed_route_state = RouteState.refresh_quota_snapshots(route_state)

    assert refreshed_route_state.saved_reset_auto_capacity ==
             route_state.saved_reset_auto_capacity

    assert Map.has_key?(refreshed_route_state.quota_snapshots, sibling_identity.id)

    refute Enum.any?(
             FakeUpstream.requests(upstream),
             &(&1.path == "/api/codex/rate-limit-reset-credits/consume")
           )
  end

  test "invalid paired capacity contexts fail before real provider I/O" do
    {:ok, upstream} =
      FakeUpstream.start_link(
        {:path_json,
         %{
           "/api/codex/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}},
           "/api/codex/usage" => {200, usage_payload()}
         }}
      )

    setup = gateway_setup(upstream)

    identity =
      setup.identity
      |> put_saved_reset_metadata!(upstream)
      |> enable_threshold_redemption!()

    put_weekly_quota!(identity, "96")

    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)

    payload = %{
      "model" => setup.model.exposed_model_id,
      "input" => [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [%{"type" => "input_text", "text" => "invalid capacity context"}]
        }
      ]
    }

    {:ok, policy} = Access.normalize_api_key_policy(auth.api_key)

    request_options =
      RequestOptions.build(%{api_key_policy: policy}, @endpoint, payload)

    assert {:ok, prepared} =
             PreDispatch.prepare(auth, @endpoint, payload, request_options, setup.model)

    filter_input =
      CandidateEligibility.FilterInput.new(%{
        auth: auth,
        model: setup.model,
        endpoint: @endpoint,
        payload: payload,
        request_options: prepared.request_options,
        candidates: prepared.candidates
      })

    context =
      SavedResetAutoRedeem.gateway_auto_context(
        %{filter_input: filter_input, route_state: prepared.route_state},
        setup.assignment,
        identity,
        :threshold_pressure
      )

    outside_assignment_id = Ecto.UUID.generate()
    outside_identity_id = Ecto.UUID.generate()

    invalid_contexts = [
      Map.delete(context, :capacity_identity_ids),
      Map.update!(context, :capacity_assignment_ids, &[Ecto.UUID.generate() | &1]),
      context
      |> Map.update!(:capacity_assignment_ids, &(&1 ++ &1))
      |> Map.update!(:capacity_identity_ids, &(&1 ++ &1)),
      context
      |> Map.put(:capacity_assignment_ids, [setup.assignment.id, outside_assignment_id])
      |> Map.put(:capacity_identity_ids, [identity.id, outside_identity_id])
      |> Map.put(:routable_assignment_ids, [setup.assignment.id, outside_assignment_id])
      |> Map.put(:routable_identity_ids, [identity.id, outside_identity_id]),
      context
      |> Map.update!(:cohort_identity_ids, &[outside_identity_id | &1])
      |> Map.put(:transient_circuit_exclusions, [
        %{
          upstream_identity_id: outside_identity_id,
          pool_upstream_assignment_id: outside_assignment_id,
          routing_circuit_state_id: Ecto.UUID.generate(),
          model_identifier: "incorrect-model",
          route_class: context.route_class
        }
      ]),
      context
      |> Map.update!(:cohort_identity_ids, &[outside_identity_id | &1])
      |> Map.put(:transient_circuit_exclusions, [
        %{
          upstream_identity_id: outside_identity_id,
          pool_upstream_assignment_id: outside_assignment_id,
          routing_circuit_state_id: Ecto.UUID.generate(),
          model_identifier: context.quota_scope.catalog_model,
          route_class: "incorrect-route"
        }
      ])
    ]

    for invalid_context <- invalid_contexts do
      assert {:ok, %{status: :noop, applied?: false, code: code}} =
               SavedResetRedemption.redeem(setup.assignment,
                 trigger_kind: "gateway_auto",
                 gateway_auto_context: invalid_context
               )

      assert code in ["gateway_auto_context_invalid", "gateway_auto_context_mismatch"]
      assert FakeUpstream.requests(upstream) == []
    end
  end

  defp active_session!(setup, auth, assignment_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert!(%CodexSession{
      pool_id: setup.pool.id,
      api_key_id: auth.api_key.id,
      session_key: "capacity-fence-#{System.unique_integer([:positive])}",
      pool_upstream_assignment_id: assignment_id,
      status: "active",
      owner_instance_id: "capacity-fence-test",
      owner_lease_token: Ecto.UUID.generate(),
      owner_lease_expires_at: DateTime.add(now, 1, :hour),
      last_heartbeat_at: now,
      created_at: now,
      updated_at: now
    })
  end

  defp put_saved_reset_metadata!(identity, upstream) do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

    metadata =
      (identity.metadata || %{})
      |> Map.put("usage_base_url", FakeUpstream.url(upstream))
      |> Map.put("saved_resets", %{
        "status" => "reported",
        "available_count" => 1,
        "source" => "codex_usage_api",
        "path_style" => "codex_api",
        "observed_at" => observed_at,
        "usage_path" => "/api/codex/usage",
        "reason" => nil
      })

    identity
    |> UpstreamIdentity.changeset(%{metadata: metadata, updated_at: DateTime.utc_now()})
    |> Repo.update!()
  end

  defp enable_threshold_redemption!(identity) do
    identity
    |> UpstreamIdentity.changeset(%{
      saved_reset_auto_redeem_enabled: true,
      saved_reset_auto_redeem_trigger_mode: "threshold",
      saved_reset_auto_redeem_quota_threshold_percent: 95,
      saved_reset_auto_redeem_min_blocked_minutes: 60,
      saved_reset_auto_redeem_keep_credits: 0,
      updated_at: DateTime.utc_now()
    })
    |> Repo.update!()
  end

  defp put_weekly_quota!(identity, used_percent) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
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

  defp usage_payload do
    %{
      "plan_type" => "plus",
      "rate_limit" => %{
        "primary_window" => %{
          "used_percent" => 0,
          "limit_window_seconds" => 18_000,
          "reset_after_seconds" => 18_000,
          "reset_at" => DateTime.utc_now() |> DateTime.add(18_000, :second) |> DateTime.to_unix()
        },
        "secondary_window" => %{
          "used_percent" => 0,
          "limit_window_seconds" => 604_800,
          "reset_after_seconds" => 604_800,
          "reset_at" => DateTime.utc_now() |> DateTime.add(604_800, :second) |> DateTime.to_unix()
        }
      }
    }
  end
end
