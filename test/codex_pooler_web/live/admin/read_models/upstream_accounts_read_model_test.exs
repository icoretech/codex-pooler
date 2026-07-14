defmodule CodexPoolerWeb.Admin.UpstreamAccountsReadModelTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import Phoenix.LiveViewTest

  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel

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

    hidden_sentinel = "hidden-provider-#{System.unique_integer([:positive])}"

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
      exposed_model_id: "gpt-example-hidden",
      metadata: %{
        "source_assignment_models" => %{
          hidden_assignment.id => %{"provider" => %{"private" => hidden_sentinel}}
        }
      }
    })

    %{user: admin} =
      operator_fixture(owner_scope, %{
        "email" => unique_user_email(),
        "role" => "instance_admin",
        "password_change_required" => "false"
      })

    operator_pool_assignment_fixture(admin, visible_pool, created_by_user_id: owner_scope.user.id)

    admin_scope = Scope.for_user(admin)

    accounts =
      UpstreamAccountsReadModel.list_visible_accounts(admin_scope, [visible_pool, hidden_pool])

    assert [%{assignments: [snapshot]}] = accounts
    assert snapshot.pool_id == visible_pool.id
    assert Enum.map(snapshot.models, & &1.exposed_model_id) == ["gpt-example-visible"]

    projection = inspect(accounts)
    refute projection =~ hidden_pool.id
    refute projection =~ hidden_assignment.id
    refute projection =~ "gpt-example-hidden"
    refute projection =~ hidden_sentinel
  end

  test "empty and no-visible-Pool loads do not expose accounts", %{scope: owner_scope} do
    %{user: admin} =
      operator_fixture(owner_scope, %{
        "email" => unique_user_email(),
        "role" => "instance_admin",
        "password_change_required" => "false"
      })

    assert UpstreamAccountsReadModel.list_visible_accounts(Scope.for_user(admin), []) == []
    assert UpstreamAccountsReadModel.list_visible_accounts(owner_scope, []) == []
  end

  test "added model reads stay constant as assignment and model counts grow", %{
    scope: scope
  } do
    for size <- [1, 50] do
      pools =
        for index <- 1..size do
          pool = pool_fixture()
          %{assignment: assignment} = upstream_assignment_fixture(pool)
          model_id = "gpt-example-read-model-#{size}-#{index}"

          model_fixture(pool, %{
            exposed_model_id: model_id,
            metadata: %{"source_assignment_models" => %{assignment.id => %{}}}
          })

          pool
        end

      {accounts, queries} =
        count_repo_sources(fn ->
          UpstreamAccountsReadModel.list_visible_accounts(scope, pools)
        end)

      assert length(accounts) == size
      assert Map.get(queries, "models", 0) == 1
      assert Map.get(queries, "ledger_entries", 0) == 2
    end
  end

  defp count_repo_sources(fun) do
    parent = self()
    handler_id = "upstream-read-model-query-count-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata[:repo] == Repo and is_binary(metadata[:source]) do
            send(parent, {handler_id, metadata.source})
          end
        end,
        nil
      )

    try do
      result = fun.()
      {result, drain_repo_sources(handler_id, %{})}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_repo_sources(handler_id, counts) do
    receive do
      {^handler_id, source} ->
        drain_repo_sources(handler_id, Map.update(counts, source, 1, &(&1 + 1)))
    after
      0 -> counts
    end
  end

  defp timestamp(offset_seconds) do
    DateTime.utc_now()
    |> DateTime.add(offset_seconds, :second)
    |> DateTime.truncate(:microsecond)
  end

  defp model_state(snapshot) do
    Map.take(snapshot, [
      :models,
      :model_count,
      :advertised_state,
      :model_freshness
    ])
  end
end
