defmodule CodexPoolerWeb.Admin.UpstreamAccountsReadModelTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import Phoenix.LiveViewTest

  alias CodexPooler.Accounting.Reporting
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Admin.UpstreamCircuitReadiness
  alias CodexPooler.Gateway.Persistence.RoutingCircuitState
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.TokenBurnProjection
  alias CodexPoolerWeb.Admin.UpstreamCockpitReadModel

  setup :register_and_log_in_user

  test "owner snapshot attaches sorted observed and preserved model rows",
       %{conn: conn, scope: scope} do
    pool = pool_fixture(%{name: "Visible routing Pool"})
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    sentinel = "provider-private-#{System.unique_integer([:positive])}"

    model_fixture(pool, %{
      exposed_model_id: "gpt-example-zeta",
      metadata: %{
        "source_assignment_models" => %{
          assignment.id => %{
            "supports_responses" => true,
            "supports_streaming" => false,
            "supports_tools" => sentinel,
            "capabilities" => %{"reasoning" => true},
            "provider" => %{"raw" => sentinel}
          }
        },
        "source_assignment_missing_sync_run_ids" => %{assignment.id => Ecto.UUID.generate()}
      }
    })

    model_fixture(pool, %{
      exposed_model_id: "gpt-example-alpha",
      metadata: %{
        "source_assignment_models" => %{
          assignment.id => %{
            "capabilities" => %{
              "responses" => false,
              "streaming" => true,
              "tools" => true,
              "reasoning" => false
            }
          }
        }
      }
    })

    [account] = UpstreamAccountsReadModel.list_visible_accounts(scope, [pool])
    [snapshot] = account.assignments

    assert snapshot.model_count == 2
    assert snapshot.advertised_state == :advertised
    assert snapshot.model_freshness == :mixed

    assert Enum.map(snapshot.models, & &1.exposed_model_id) ==
             ~w(gpt-example-alpha gpt-example-zeta)

    assert [alpha, zeta] = snapshot.models
    assert alpha.provenance == :observed
    assert zeta.provenance == :preserved

    assert alpha.capabilities == %{
             responses: false,
             streaming: true,
             tools: true,
             reasoning: false
           }

    assert zeta.capabilities == %{
             responses: true,
             streaming: false,
             tools: :unknown,
             reasoning: true
           }

    refute inspect(snapshot) =~ sentinel

    {:ok, _view, html} = live(conn, ~p"/admin/upstreams")
    refute html =~ sentinel
  end

  test "token burn ranks per-model settled usage inside the recent window", %{scope: scope} do
    pool = pool_fixture(%{name: "Token burn Pool"})
    %{identity: identity, assignment: assignment} = upstream_assignment_fixture(pool)
    %{api_key: api_key} = api_key_fixture(pool)

    busy_model = model_fixture(pool, %{exposed_model_id: "gpt-example-busy"})
    quiet_model = model_fixture(pool, %{exposed_model_id: "gpt-example-quiet"})

    seed_settlement = fn model, total_tokens, offset_seconds, attrs ->
      request =
        request_fixture(%{pool: pool, api_key: api_key}, %{
          model_id: model.id,
          requested_model: model.exposed_model_id
        })

      ledger_entry_fixture(
        request,
        Map.merge(
          %{
            pool_upstream_assignment_id: assignment.id,
            upstream_identity_id: identity.id,
            total_tokens: total_tokens,
            occurred_at: DateTime.add(DateTime.utc_now(), offset_seconds, :second)
          },
          attrs
        )
      )
    end

    seed_settlement.(busy_model, 40_000, -60, %{settled_cost_micros: 240_000})
    seed_settlement.(busy_model, 2_000, -240, %{settled_cost_micros: 12_000})
    seed_settlement.(quiet_model, 1_500, -120, %{settled_cost_micros: 9_000})

    # Outside the five-minute window, or with unusable usage, never counts.
    seed_settlement.(busy_model, 999_000, -20 * 60, %{settled_cost_micros: 5_994_000})

    seed_settlement.(quiet_model, 555_000, -90, %{
      usage_status: "usage_unknown",
      settled_cost_micros: 3_330_000
    })

    [account] = UpstreamAccountsReadModel.list_visible_accounts(scope, [pool])

    assert account.token_burn.recent_tokens == 43_500

    # The unknown-usage settlement still counts as a served request, the
    # out-of-window one never does. Neither contributes tokens or cost.
    assert account.token_burn.recent_requests == 4

    assert account.token_burn.recent_models == [
             %{label: "gpt-example-busy", tokens: 42_000, cost_micros: 252_000},
             %{label: "gpt-example-quiet", tokens: 1_500, cost_micros: 9_000}
           ]
  end

  test "token burn preserves complete, partial, unknown, and idle usage completeness" do
    now = ~U[2026-07-22 12:00:00.000000Z]

    {_idle_pool, idle_identity, _idle_assignment, _idle_api_key} = token_burn_fixture()
    {zero_pool, zero_identity, zero_assignment, zero_api_key} = token_burn_fixture()

    {positive_pool, positive_identity, positive_assignment, positive_api_key} =
      token_burn_fixture()

    {partial_pool, partial_identity, partial_assignment, partial_api_key} = token_burn_fixture()
    {unknown_pool, unknown_identity, unknown_assignment, unknown_api_key} = token_burn_fixture()

    seed_token_burn_settlement!(
      zero_pool,
      zero_api_key,
      zero_assignment,
      zero_identity,
      now,
      -60,
      %{total_tokens: 0, settled_cost_micros: 0}
    )

    seed_token_burn_settlement!(
      positive_pool,
      positive_api_key,
      positive_assignment,
      positive_identity,
      now,
      -60,
      %{total_tokens: 40, settled_cost_micros: 400}
    )

    seed_token_burn_settlement!(
      partial_pool,
      partial_api_key,
      partial_assignment,
      partial_identity,
      now,
      -60,
      %{total_tokens: 20, settled_cost_micros: 200}
    )

    seed_token_burn_settlement!(
      partial_pool,
      partial_api_key,
      partial_assignment,
      partial_identity,
      now,
      -120,
      %{
        usage_status: "usage_unknown",
        total_tokens: 999_999,
        settled_cost_micros: 999_999
      }
    )

    seed_token_burn_settlement!(
      unknown_pool,
      unknown_api_key,
      unknown_assignment,
      unknown_identity,
      now,
      -60,
      %{
        usage_status: "usage_unknown",
        total_tokens: 999_999,
        settled_cost_micros: 999_999
      }
    )

    seed_token_burn_settlement!(
      unknown_pool,
      unknown_api_key,
      unknown_assignment,
      unknown_identity,
      now,
      -301,
      %{total_tokens: 123, settled_cost_micros: 1_230}
    )

    {summaries, queries} =
      count_repo_sources(fn ->
        TokenBurnProjection.summaries(
          [idle_identity, zero_identity, positive_identity, partial_identity, unknown_identity],
          now: now
        )
      end)

    assert Map.get(queries, "ledger_entries", 0) == 2

    assert summaries[idle_identity.id]
           |> Map.take([
             :label,
             :title,
             :usage_state,
             :recent_requests,
             :known_request_count,
             :unknown_request_count,
             :recent_tokens
           ]) ==
             %{
               label: "x0",
               title: "No requests in the last 5 minutes.",
               usage_state: :idle,
               recent_requests: 0,
               known_request_count: 0,
               unknown_request_count: 0,
               recent_tokens: 0
             }

    assert summaries[zero_identity.id]
           |> Map.take([
             :label,
             :title,
             :usage_state,
             :level,
             :recent_requests,
             :known_request_count,
             :unknown_request_count,
             :recent_tokens
           ]) ==
             %{
               label: "x0",
               title: "last 5m: 0 tokens; previous 1h: 0 tokens; complete usage for 1 request",
               usage_state: :complete,
               level: 0,
               recent_requests: 1,
               known_request_count: 1,
               unknown_request_count: 0,
               recent_tokens: 0
             }

    assert summaries[positive_identity.id]
           |> Map.take([
             :label,
             :title,
             :usage_state,
             :recent_requests,
             :known_request_count,
             :unknown_request_count,
             :recent_tokens
           ]) ==
             %{
               label: "x1",
               title: "last 5m: 40 tokens; previous 1h: 0 tokens; complete usage for 1 request",
               usage_state: :complete,
               recent_requests: 1,
               known_request_count: 1,
               unknown_request_count: 0,
               recent_tokens: 40
             }

    assert summaries[partial_identity.id]
           |> Map.take([
             :label,
             :title,
             :usage_state,
             :recent_requests,
             :known_request_count,
             :unknown_request_count,
             :recent_tokens
           ]) ==
             %{
               label: "x1",
               title:
                 "last 5m: 20 tokens; previous 1h: 0 tokens; settled usage reported for 1 of 2 requests; 1 usage record missing",
               usage_state: :partial,
               recent_requests: 2,
               known_request_count: 1,
               unknown_request_count: 1,
               recent_tokens: 20
             }

    assert summaries[unknown_identity.id]
           |> Map.take([
             :label,
             :title,
             :usage_state,
             :level,
             :recent_requests,
             :known_request_count,
             :unknown_request_count,
             :recent_tokens
           ]) ==
             %{
               label: "usage unavailable",
               title: "last 5m: 1 request; 1 usage record missing",
               usage_state: :unknown,
               level: nil,
               recent_requests: 1,
               known_request_count: 0,
               unknown_request_count: 1,
               recent_tokens: 0
             }
  end

  test "token burn includes the exact five-minute bounds and excludes adjacent settlements" do
    now = ~U[2026-07-22 12:00:00.000000Z]
    {pool, identity, assignment, api_key} = token_burn_fixture()
    model = model_fixture(pool, %{exposed_model_id: "gpt-example-token-burn-boundary"})

    seed_token_burn_settlement!(
      pool,
      api_key,
      assignment,
      identity,
      now,
      -300,
      %{model_id: model.id, total_tokens: 20, settled_cost_micros: 200}
    )

    seed_token_burn_settlement!(
      pool,
      api_key,
      assignment,
      identity,
      now,
      0,
      %{
        model_id: model.id,
        usage_status: "usage_unknown",
        total_tokens: 999_999,
        settled_cost_micros: 999_999
      }
    )

    seed_token_burn_settlement!(
      pool,
      api_key,
      assignment,
      identity,
      now,
      -301,
      %{model_id: model.id, total_tokens: 123, settled_cost_micros: 1_230}
    )

    seed_token_burn_settlement!(
      pool,
      api_key,
      assignment,
      identity,
      now,
      1,
      %{
        model_id: model.id,
        usage_status: "usage_unknown",
        total_tokens: 456_789,
        settled_cost_micros: 4_567_890
      }
    )

    started_at = DateTime.add(now, -5 * 60, :second)

    assert Reporting.token_totals_by_upstream_identity_pool_and_model_ids(
             [identity.id],
             started_at,
             now
           )[identity.id] == [
             %{
               pool_id: pool.id,
               model_id: model.id,
               total_tokens: 20,
               request_count: 2,
               known_request_count: 1,
               unknown_request_count: 1,
               settled_cost_micros: 200
             }
           ]

    assert TokenBurnProjection.summaries([identity], now: now)[identity.id]
           |> Map.take([
             :usage_state,
             :recent_tokens,
             :recent_requests,
             :known_request_count,
             :unknown_request_count,
             :recent_pools
           ]) == %{
             usage_state: :partial,
             recent_tokens: 20,
             recent_requests: 2,
             known_request_count: 1,
             unknown_request_count: 1,
             recent_pools: %{
               pool.id => %{
                 tokens: 20,
                 request_count: 2,
                 known_request_count: 1,
                 unknown_request_count: 1
               }
             }
           }
  end

  test "assignments without active provenance receive the explicit empty state", %{scope: scope} do
    pool = pool_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(pool)

    model_fixture(pool, %{
      exposed_model_id: "gpt-example-stale",
      status: "stale",
      metadata: %{"source_assignment_models" => %{assignment.id => %{}}}
    })

    [account] = UpstreamAccountsReadModel.list_visible_accounts(scope, [pool])
    [snapshot] = account.assignments

    assert model_state(snapshot) == %{
             models: [],
             model_count: 0,
             advertised_state: :not_advertised,
             model_freshness: :not_advertised
           }
  end

  test "pure observed and preserved assignments expose exact safe snapshot states", %{
    scope: scope
  } do
    observed_pool = pool_fixture()
    preserved_pool = pool_fixture()
    %{assignment: observed_assignment} = upstream_assignment_fixture(observed_pool)
    %{assignment: preserved_assignment} = upstream_assignment_fixture(preserved_pool)

    observed_model =
      model_fixture(observed_pool, %{
        exposed_model_id: "gpt-example-observed",
        metadata: %{
          "source_assignment_models" => %{
            observed_assignment.id => %{"supports_responses" => true}
          }
        }
      })

    model_fixture(preserved_pool, %{
      exposed_model_id: "gpt-example-preserved",
      metadata: %{
        "source_assignment_models" => %{
          preserved_assignment.id => %{"supports_responses" => false}
        },
        "source_assignment_missing_sync_run_ids" => %{
          preserved_assignment.id => Ecto.UUID.generate()
        }
      }
    })

    accounts =
      UpstreamAccountsReadModel.list_visible_accounts(scope, [preserved_pool, observed_pool])

    snapshots =
      accounts
      |> Enum.flat_map(& &1.assignments)
      |> Map.new(&{&1.id, &1})

    observed = Map.fetch!(snapshots, observed_assignment.id)
    preserved = Map.fetch!(snapshots, preserved_assignment.id)

    assert model_state(observed) == %{
             models: [
               %{
                 pool_id: observed_pool.id,
                 assignment_id: observed_assignment.id,
                 exposed_model_id: "gpt-example-observed",
                 capabilities: %{
                   responses: true,
                   streaming: :unknown,
                   tools: :unknown,
                   reasoning: :unknown
                 },
                 model_info: %{
                   description: nil,
                   description_state: :missing,
                   visibility: :unknown,
                   api_support: :unknown,
                   catalog_updated_at: observed_model.last_seen_at
                 },
                 provenance: :observed
               }
             ],
             model_count: 1,
             advertised_state: :advertised,
             model_freshness: :observed
           }

    assert model_state(preserved) == %{
             models: [
               %{
                 pool_id: preserved_pool.id,
                 assignment_id: preserved_assignment.id,
                 exposed_model_id: "gpt-example-preserved",
                 capabilities: %{
                   responses: false,
                   streaming: :unknown,
                   tools: :unknown,
                   reasoning: :unknown
                 },
                 model_info: %{
                   description: nil,
                   description_state: :missing,
                   visibility: :unknown,
                   api_support: :unknown
                 },
                 provenance: :preserved
               }
             ],
             model_count: 1,
             advertised_state: :advertised,
             model_freshness: :preserved
           }
  end

  test "supplied hidden Pool cannot attach a hidden assignment on the same visible identity", %{
    scope: owner_scope
  } do
    visible_pool = pool_fixture(%{name: "Assigned Pool"})
    hidden_pool = pool_fixture(%{name: "Hidden Pool"})

    %{identity: identity, assignment: visible_assignment} =
      upstream_assignment_fixture(visible_pool)

    hidden_model = "gpt-example-hidden-#{System.unique_integer([:positive])}"
    hidden_route = "hidden-route-#{System.unique_integer([:positive])}"
    hidden_reason = "ignore-previous-instructions-#{System.unique_integer([:positive])}"

    hidden_assignment =
      %PoolUpstreamAssignment{
        pool_id: hidden_pool.id,
        upstream_identity_id: identity.id,
        assignment_label: "Hidden assignment",
        status: "active",
        health_status: "active",
        eligibility_status: "eligible",
        metadata: %{},
        created_at: timestamp(0),
        updated_at: timestamp(0)
      }
      |> Repo.insert!()

    model_fixture(visible_pool, %{
      exposed_model_id: "gpt-example-visible",
      metadata: %{"source_assignment_models" => %{visible_assignment.id => %{}}}
    })

    model_fixture(hidden_pool, %{
      exposed_model_id: hidden_model,
      metadata: %{
        "source_assignment_models" => %{
          hidden_assignment.id => %{"provider" => %{"private" => hidden_reason}}
        }
      }
    })

    insert_circuit_state!(
      hidden_pool,
      hidden_assignment,
      hidden_model,
      hidden_route,
      status: "open",
      next_probe_at: DateTime.add(timestamp(0), 120, :second),
      opened_at: timestamp(0),
      reason_code: hidden_reason
    )

    %{user: admin} =
      operator_fixture(owner_scope, %{
        "email" => unique_user_email(),
        "role" => "instance_admin",
        "password_change_required" => "false"
      })

    operator_pool_assignment_fixture(admin, visible_pool, created_by_user_id: owner_scope.user.id)

    admin_scope = Scope.for_user(admin)

    {accounts, query_events} =
      capture_repo_queries(
        fn ->
          UpstreamAccountsReadModel.list_visible_accounts(
            admin_scope,
            [visible_pool, hidden_pool]
          )
        end,
        visible_assignment: visible_assignment.id,
        hidden_assignment: hidden_assignment.id
      )

    assert [%{assignments: [snapshot]}] = accounts
    assert snapshot.pool_id == visible_pool.id
    assert Enum.map(snapshot.models, & &1.exposed_model_id) == ["gpt-example-visible"]

    assert [
             %{
               parameter_membership: %{
                 visible_assignment: true,
                 hidden_assignment: false
               }
             }
           ] = source_events(query_events, "routing_circuit_states")

    projection = inspect(accounts)
    refute projection =~ hidden_pool.id
    refute projection =~ hidden_assignment.id
    assert_sentinels_absent(projection, [hidden_model, hidden_route, hidden_reason])
  end

  @tag :todo4_projection
  test "restricted account projection loads one raw quota view, folds once, and excludes hidden Pools",
       %{scope: owner_scope} do
    visible_pool = pool_fixture(%{name: "Projection-visible Pool"})
    hidden_pool = pool_fixture(%{name: "Projection-hidden Pool"})
    %{identity: visible_identity} = upstream_assignment_fixture(visible_pool)
    %{identity: hidden_identity} = upstream_assignment_fixture(hidden_pool)

    hidden_sentinel = "hidden-quota-projection-#{System.unique_integer([:positive])}"
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    for identity <- [visible_identity, hidden_identity] do
      identity
      |> Ecto.Changeset.change(%{
        metadata: %{
          "saved_reset_redemption" => %{
            "phase" => "consumed_pending_probe",
            "consumed_at" => DateTime.add(observed_at, -60, :second) |> DateTime.to_iso8601(),
            "deadline_at" => DateTime.add(observed_at, 14, :minute) |> DateTime.to_iso8601()
          }
        }
      })
      |> Repo.update!()
    end

    assert {:ok, [_visible_window]} =
             Windows.upsert_quota_windows(visible_identity, [
               quota_projection_window_attrs(observed_at, "visible")
             ])

    assert {:ok, [_hidden_window]} =
             Windows.upsert_quota_windows(hidden_identity, [
               quota_projection_window_attrs(observed_at, hidden_sentinel)
             ])

    %{user: admin} =
      operator_fixture(owner_scope, %{
        "email" => unique_user_email(),
        "role" => "instance_admin",
        "password_change_required" => "false"
      })

    operator_pool_assignment_fixture(admin, visible_pool, created_by_user_id: owner_scope.user.id)
    admin_scope = Scope.for_user(admin)

    {fold_count, {accounts, queries}} =
      count_effective_quota_folds(fn ->
        count_repo_sources(fn ->
          UpstreamAccountsReadModel.list_visible_accounts(admin_scope, [visible_pool, hidden_pool])
        end)
      end)

    assert [%{identity: %{id: visible_identity_id}, saved_reset_confirmation: confirmation}] =
             accounts

    assert visible_identity_id == visible_identity.id
    assert confirmation.confirmation_state == :awaiting_confirmation
    assert Map.get(queries, "account_quota_windows", 0) == 1
    assert fold_count == 1

    projection = inspect(accounts)
    refute projection =~ hidden_identity.id
    refute projection =~ hidden_sentinel
  end

  test "identity filter narrows the account snapshot after fleet model inventory", %{scope: scope} do
    target_pool = pool_fixture(%{name: "Target identity Pool"})
    sibling_pool = pool_fixture(%{name: "Sibling identity Pool"})

    %{identity: target_identity, assignment: target_assignment} =
      upstream_assignment_fixture(target_pool)

    %{identity: sibling_identity, assignment: sibling_assignment} =
      upstream_assignment_fixture(sibling_pool)

    target_model = "gpt-example-target-#{System.unique_integer([:positive])}"
    sibling_model = "gpt-example-sibling-#{System.unique_integer([:positive])}"

    model_fixture(target_pool, %{
      exposed_model_id: target_model,
      metadata: %{"source_assignment_models" => %{target_assignment.id => %{}}}
    })

    model_fixture(sibling_pool, %{
      exposed_model_id: sibling_model,
      metadata: %{"source_assignment_models" => %{sibling_assignment.id => %{}}}
    })

    accounts =
      UpstreamAccountsReadModel.list_visible_accounts(
        scope,
        [target_pool, sibling_pool],
        %{identity_id: target_identity.id}
      )

    assert [%{identity: %{id: target_identity_id}, assignments: [snapshot]}] = accounts
    assert target_identity_id == target_identity.id
    assert snapshot.id == target_assignment.id
    assert Enum.map(snapshot.models, & &1.exposed_model_id) == [target_model]

    projection = inspect(accounts)
    refute projection =~ sibling_identity.id
    refute projection =~ sibling_assignment.id
    refute projection =~ sibling_model
  end

  test "account snapshots batch current circuit summaries for served models", %{scope: scope} do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    retired_model = "gpt-example-circuit-retired-#{System.unique_integer([:positive])}"
    retired_route = "retired-route-#{System.unique_integer([:positive])}"
    retired_reason = "retired-reason-#{System.unique_integer([:positive])}"

    blocked_pool = pool_fixture(%{name: "Blocked circuit Pool"})
    recovering_pool = pool_fixture(%{name: "Recovering circuit Pool"})
    clear_pool = pool_fixture(%{name: "Clear circuit Pool"})
    retired_pool = pool_fixture(%{name: "Retired circuit Pool"})

    %{assignment: blocked_assignment} = upstream_assignment_fixture(blocked_pool)
    %{assignment: recovering_assignment} = upstream_assignment_fixture(recovering_pool)
    %{assignment: clear_assignment} = upstream_assignment_fixture(clear_pool)
    %{assignment: retired_assignment} = upstream_assignment_fixture(retired_pool)

    model_fixture(blocked_pool, %{
      exposed_model_id: "gpt-example-circuit-blocked",
      metadata: %{"source_assignment_models" => %{blocked_assignment.id => %{}}}
    })

    model_fixture(recovering_pool, %{
      exposed_model_id: "gpt-example-circuit-recovering",
      metadata: %{"source_assignment_models" => %{recovering_assignment.id => %{}}}
    })

    model_fixture(clear_pool, %{
      exposed_model_id: "gpt-example-circuit-clear",
      metadata: %{"source_assignment_models" => %{clear_assignment.id => %{}}}
    })

    model_fixture(retired_pool, %{
      exposed_model_id: retired_model,
      status: "retired",
      metadata: %{"source_assignment_models" => %{retired_assignment.id => %{}}}
    })

    insert_circuit_state!(
      blocked_pool,
      blocked_assignment,
      "gpt-example-circuit-blocked",
      "proxy_http",
      status: "open",
      next_probe_at: DateTime.add(now, 120, :second),
      opened_at: now
    )

    insert_circuit_state!(
      recovering_pool,
      recovering_assignment,
      "gpt-example-circuit-recovering",
      "proxy_stream",
      status: "open",
      next_probe_at: DateTime.add(now, -1, :second),
      opened_at: DateTime.add(now, -30, :second)
    )

    insert_circuit_state!(
      retired_pool,
      retired_assignment,
      retired_model,
      retired_route,
      status: "open",
      next_probe_at: DateTime.add(now, 120, :second),
      opened_at: now,
      reason_code: retired_reason
    )

    {accounts, queries} =
      count_repo_sources(fn ->
        UpstreamAccountsReadModel.list_visible_accounts(
          scope,
          [blocked_pool, recovering_pool, clear_pool, retired_pool]
        )
      end)

    assignments =
      accounts
      |> Enum.flat_map(& &1.assignments)
      |> Map.new(&{&1.id, &1})

    assert assignments[blocked_assignment.id].circuit_readiness.state == :blocked
    assert assignments[recovering_assignment.id].circuit_readiness.state == :recovering

    assert assignments[clear_assignment.id].circuit_readiness ==
             UpstreamCircuitReadiness.clear()

    assert assignments[retired_assignment.id].circuit_readiness ==
             UpstreamCircuitReadiness.clear()

    assert Map.get(queries, "routing_circuit_states", 0) == 1
    assert_sentinels_absent(inspect(accounts), [retired_model, retired_route, retired_reason])
  end

  test "identity-filtered circuit batch excludes sibling assignment evidence", %{scope: scope} do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    target_pool = pool_fixture(%{name: "Target circuit identity Pool"})
    sibling_pool = pool_fixture(%{name: "Sibling circuit identity Pool"})

    %{identity: target_identity, assignment: target_assignment} =
      upstream_assignment_fixture(target_pool)

    %{identity: sibling_identity, assignment: sibling_assignment} =
      upstream_assignment_fixture(sibling_pool)

    target_model = "gpt-example-target-circuit"
    sibling_model = "gpt-example-sibling-circuit-#{System.unique_integer([:positive])}"
    sibling_route = "sibling-route-#{System.unique_integer([:positive])}"

    model_fixture(target_pool, %{
      exposed_model_id: target_model,
      metadata: %{"source_assignment_models" => %{target_assignment.id => %{}}}
    })

    model_fixture(sibling_pool, %{
      exposed_model_id: sibling_model,
      metadata: %{"source_assignment_models" => %{sibling_assignment.id => %{}}}
    })

    insert_circuit_state!(
      target_pool,
      target_assignment,
      target_model,
      "proxy_http",
      status: "open",
      next_probe_at: DateTime.add(now, 120, :second),
      opened_at: now
    )

    insert_circuit_state!(
      sibling_pool,
      sibling_assignment,
      sibling_model,
      sibling_route,
      status: "open",
      next_probe_at: DateTime.add(now, 120, :second),
      opened_at: now
    )

    {accounts, query_events} =
      capture_repo_queries(
        fn ->
          UpstreamAccountsReadModel.list_visible_accounts(
            scope,
            [target_pool, sibling_pool],
            %{identity_id: target_identity.id}
          )
        end,
        target_assignment: target_assignment.id,
        sibling_assignment: sibling_assignment.id
      )

    assert [%{identity: %{id: target_identity_id}, assignments: [target_snapshot]}] = accounts
    assert target_identity_id == target_identity.id
    assert target_snapshot.id == target_assignment.id
    assert target_snapshot.circuit_readiness.state == :blocked

    assert [
             %{
               parameter_membership: %{
                 target_assignment: true,
                 sibling_assignment: false
               }
             }
           ] = source_events(query_events, "routing_circuit_states")

    projection = inspect(accounts)
    refute projection =~ sibling_identity.id
    refute projection =~ sibling_assignment.id
    assert_sentinels_absent(projection, [sibling_model, sibling_route])
  end

  test "cockpit identity narrowing excludes sibling assignment circuit input", %{scope: scope} do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    target_pool = pool_fixture(%{name: "Cockpit target Pool"})
    sibling_pool = pool_fixture(%{name: "Cockpit sibling Pool"})

    %{identity: target_identity, assignment: target_assignment} =
      upstream_assignment_fixture(target_pool)

    %{assignment: sibling_assignment} = upstream_assignment_fixture(sibling_pool)

    target_model = "gpt-example-cockpit-target"
    sibling_model = "gpt-example-cockpit-sibling-#{System.unique_integer([:positive])}"

    model_fixture(target_pool, %{
      exposed_model_id: target_model,
      metadata: %{"source_assignment_models" => %{target_assignment.id => %{}}}
    })

    model_fixture(sibling_pool, %{
      exposed_model_id: sibling_model,
      metadata: %{"source_assignment_models" => %{sibling_assignment.id => %{}}}
    })

    insert_circuit_state!(
      target_pool,
      target_assignment,
      target_model,
      "proxy_http",
      status: "open",
      next_probe_at: DateTime.add(now, 120, :second),
      opened_at: now
    )

    insert_circuit_state!(
      sibling_pool,
      sibling_assignment,
      sibling_model,
      "proxy_stream",
      status: "open",
      next_probe_at: DateTime.add(now, 120, :second),
      opened_at: now
    )

    {result, query_events} =
      capture_repo_queries(
        fn -> UpstreamCockpitReadModel.load_visible(scope, target_identity.id) end,
        target_assignment: target_assignment.id,
        sibling_assignment: sibling_assignment.id
      )

    assert {:ok, cockpit} = result
    assert [%{id: target_assignment_id}] = cockpit.assignments.items
    assert target_assignment_id == target_assignment.id

    assert [
             %{
               parameter_membership: %{
                 target_assignment: true,
                 sibling_assignment: false
               }
             }
           ] = source_events(query_events, "routing_circuit_states")

    assert_sentinels_absent(inspect(cockpit), [sibling_model])
  end

  test "empty authorized assignment loads issue zero circuit queries", %{
    scope: owner_scope
  } do
    %{user: admin} =
      operator_fixture(owner_scope, %{
        "email" => unique_user_email(),
        "role" => "instance_admin",
        "password_change_required" => "false"
      })

    {admin_accounts, admin_queries} =
      count_repo_sources(fn ->
        UpstreamAccountsReadModel.list_visible_accounts(Scope.for_user(admin), [])
      end)

    {owner_accounts, owner_queries} =
      count_repo_sources(fn ->
        UpstreamAccountsReadModel.list_visible_accounts(owner_scope, [])
      end)

    pool = pool_fixture()
    _fixture = upstream_assignment_fixture(pool)

    {filtered_accounts, filtered_queries} =
      count_repo_sources(fn ->
        UpstreamAccountsReadModel.list_visible_accounts(
          owner_scope,
          [pool],
          %{identity_id: Ecto.UUID.generate()}
        )
      end)

    assert admin_accounts == []
    assert owner_accounts == []
    assert filtered_accounts == []
    assert Map.get(admin_queries, "routing_circuit_states", 0) == 0
    assert Map.get(owner_queries, "routing_circuit_states", 0) == 0
    assert Map.get(filtered_queries, "routing_circuit_states", 0) == 0
  end

  test "size-one account load issues one authorized circuit query with constant reads", %{
    scope: scope
  } do
    pool = pool_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(pool)

    model_fixture(pool, %{
      exposed_model_id: "gpt-example-size-one",
      metadata: %{"source_assignment_models" => %{assignment.id => %{}}}
    })

    {accounts, query_events} =
      capture_repo_queries(
        fn -> UpstreamAccountsReadModel.list_visible_accounts(scope, [pool]) end,
        authorized_assignment: assignment.id
      )

    assert [%{assignments: [%{id: assignment_id}]}] = accounts
    assert assignment_id == assignment.id
    assert source_count(query_events, "models") == 1
    assert source_count(query_events, "ledger_entries") == 2

    assert [
             %{
               parameter_count: 1,
               parameter_membership: %{authorized_assignment: true},
               query_shape_signature: query_shape_signature
             }
           ] = source_events(query_events, "routing_circuit_states")

    assert byte_size(query_shape_signature) == 64
    refute query_shape_signature == String.duplicate("0", 64)
  end

  test "added model reads stay constant as assignment and model counts grow", %{
    scope: scope
  } do
    observations =
      for size <- [1, 50] do
        pool_assignments =
          for index <- 1..size do
            pool = pool_fixture()
            %{assignment: assignment} = upstream_assignment_fixture(pool)
            model_id = "gpt-example-read-model-#{size}-#{index}"

            model_fixture(pool, %{
              exposed_model_id: model_id,
              metadata: %{"source_assignment_models" => %{assignment.id => %{}}}
            })

            {pool, assignment}
          end

        pools = Enum.map(pool_assignments, &elem(&1, 0))

        parameter_probes =
          pool_assignments
          |> Enum.with_index()
          |> Map.new(fn {{_pool, assignment}, index} ->
            {index, assignment.id}
          end)

        {accounts, query_events} =
          capture_repo_queries(
            fn -> UpstreamAccountsReadModel.list_visible_accounts(scope, pools) end,
            parameter_probes
          )

        assert length(accounts) == size
        assert source_count(query_events, "models") == 1
        assert source_count(query_events, "ledger_entries") == 2

        assert [
                 %{
                   parameter_count: 1,
                   parameter_membership: parameter_membership,
                   query_shape_signature: query_shape_signature
                 }
               ] = source_events(query_events, "routing_circuit_states")

        assert map_size(parameter_membership) == size
        assert Enum.all?(parameter_membership, fn {_label, present?} -> present? end)
        assert byte_size(query_shape_signature) == 64
        refute query_shape_signature == String.duplicate("0", 64)

        query_shape_signature
      end

    assert length(Enum.uniq(observations)) == 1
  end

  defp count_repo_sources(fun) do
    {result, query_events} = capture_repo_queries(fun)
    {result, Enum.frequencies_by(query_events, & &1.source)}
  end

  defp count_effective_quota_folds(fun) do
    target = {CodexPooler.Upstreams.Quota.Windows, :effective_quota_windows, 2}

    :erlang.trace_pattern(
      target,
      true,
      [:call_count]
    )

    try do
      result = fun.()
      {:call_count, count} = :erlang.trace_info(target, :call_count)
      {count, result}
    after
      :erlang.trace_pattern(target, false, [:call_count])
    end
  end

  defp capture_repo_queries(fun, parameter_probes \\ []) do
    parent = self()
    handler_id = "upstream-read-model-query-count-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata[:repo] == Repo and is_binary(metadata[:source]) do
            send(parent, {handler_id, repo_query_event(metadata, parameter_probes)})
          end
        end,
        nil
      )

    try do
      result = fun.()
      {result, drain_repo_query_events(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp token_burn_fixture do
    pool = pool_fixture()
    %{identity: identity, assignment: assignment} = upstream_assignment_fixture(pool)
    %{api_key: api_key} = api_key_fixture(pool)
    {pool, identity, assignment, api_key}
  end

  defp seed_token_burn_settlement!(
         pool,
         api_key,
         assignment,
         identity,
         now,
         offset_seconds,
         attrs
       ) do
    occurred_at = DateTime.add(now, offset_seconds, :second)

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        correlation_id: "token-burn-#{System.unique_integer([:positive])}"
      })
      |> Ecto.Changeset.change(%{admitted_at: occurred_at, completed_at: occurred_at})
      |> Repo.update!()

    attempt =
      request
      |> attempt_fixture(assignment)
      |> Ecto.Changeset.change(%{
        started_at: occurred_at,
        completed_at: occurred_at,
        latency_ms: 1_000
      })
      |> Repo.update!()

    request
    |> ledger_entry_fixture(
      Map.merge(
        %{
          attempt_id: attempt.id,
          pool_upstream_assignment_id: assignment.id,
          upstream_identity_id: identity.id
        },
        attrs
      )
    )
    |> Ecto.Changeset.change(%{occurred_at: occurred_at, created_at: occurred_at})
    |> Repo.update!()
  end

  defp drain_repo_query_events(handler_id, events) do
    receive do
      {^handler_id, event} ->
        drain_repo_query_events(handler_id, [event | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp repo_query_event(metadata, parameter_probes) do
    params = List.wrap(metadata[:params])

    %{
      source: metadata.source,
      query_shape_signature: query_shape_signature(metadata[:query]),
      parameter_count: length(params),
      parameter_membership:
        Map.new(parameter_probes, fn {label, value} ->
          {label, parameter_member?(params, value)}
        end)
    }
  end

  defp query_shape_signature(query) when is_binary(query) do
    query
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp query_shape_signature(_query), do: String.duplicate("0", 64)

  defp parameter_member?(params, value) do
    candidates =
      case Ecto.UUID.dump(value) do
        {:ok, dumped_value} -> [value, dumped_value]
        :error -> [value]
      end

    parameter_member_candidates?(params, candidates)
  end

  defp parameter_member_candidates?(params, candidates) do
    Enum.any?(params, fn
      nested when is_list(nested) -> parameter_member_candidates?(nested, candidates)
      param -> Enum.member?(candidates, param)
    end)
  end

  defp source_count(query_events, source) do
    Enum.count(query_events, &(&1.source == source))
  end

  defp source_events(query_events, source) do
    Enum.filter(query_events, &(&1.source == source))
  end

  defp timestamp(offset_seconds) do
    DateTime.utc_now()
    |> DateTime.add(offset_seconds, :second)
    |> DateTime.truncate(:microsecond)
  end

  defp quota_projection_window_attrs(observed_at, label) do
    %{
      quota_key: "account",
      quota_scope: "account",
      quota_family: "account",
      window_kind: "secondary",
      window_minutes: 10_080,
      used_percent: Decimal.new("100"),
      reset_at: DateTime.add(observed_at, 6, :day),
      source: "codex_usage_api",
      source_precision: "observed",
      freshness_state: "fresh",
      last_sync_at: observed_at,
      observed_at: observed_at,
      display_label: label
    }
  end

  defp insert_circuit_state!(pool, assignment, model_identifier, route_class, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    defaults = [
      status: "closed",
      failure_count: 3,
      success_count: 0,
      opened_at: nil,
      half_opened_at: nil,
      closed_at: nil,
      next_probe_at: nil,
      last_failure_at: nil,
      last_success_at: nil,
      metadata: %{},
      created_at: DateTime.add(now, -1, :second),
      updated_at: DateTime.add(now, -1, :second)
    ]

    attrs = Keyword.merge(defaults, attrs)

    %RoutingCircuitState{
      pool_id: pool.id,
      api_key_id: nil,
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: assignment.upstream_identity_id,
      model_identifier: model_identifier,
      route_class: route_class,
      status: Keyword.fetch!(attrs, :status),
      reason_code: Keyword.get(attrs, :reason_code, "persisted_reason_must_not_escape"),
      failure_count: Keyword.fetch!(attrs, :failure_count),
      success_count: Keyword.fetch!(attrs, :success_count),
      opened_at: Keyword.fetch!(attrs, :opened_at),
      half_opened_at: Keyword.fetch!(attrs, :half_opened_at),
      closed_at: Keyword.fetch!(attrs, :closed_at),
      next_probe_at: Keyword.fetch!(attrs, :next_probe_at),
      last_failure_at: Keyword.fetch!(attrs, :last_failure_at),
      last_success_at: Keyword.fetch!(attrs, :last_success_at),
      metadata: Keyword.fetch!(attrs, :metadata),
      created_at: Keyword.fetch!(attrs, :created_at),
      updated_at: Keyword.fetch!(attrs, :updated_at)
    }
    |> Repo.insert!()
  end

  defp model_state(snapshot) do
    Map.take(snapshot, [
      :models,
      :model_count,
      :advertised_state,
      :model_freshness
    ])
  end

  defp assert_sentinels_absent(projection, sentinels) do
    assert Enum.all?(sentinels, &(not String.contains?(projection, &1))),
           "synthetic hidden sentinels must stay outside the projection"
  end
end
