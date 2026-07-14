defmodule CodexPooler.Gateway.Routing.ServingSignalsTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Catalog
  alias CodexPooler.Gateway.Persistence.RoutingCircuitState
  alias CodexPooler.Gateway.Routing.ServingSignals
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment

  import CodexPooler.PoolerFixtures

  test "projects newest Pool-level route signals without widening authorized tuples" do
    pool = pool_fixture()
    hidden_pool = pool_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    %{assignment: sibling} = upstream_assignment_fixture(pool)
    %{assignment: hidden} = upstream_assignment_fixture(hidden_pool)
    model_id = "gpt-example-serving"
    %{api_key: api_key} = api_key_fixture(pool)
    old = timestamp(-120)
    recent = timestamp(-60)
    future = timestamp(300)

    insert_state(pool.id, assignment.id, model_id, "proxy_http", %{
      status: "closed",
      reason_code: "upstream_model_unavailable",
      failure_count: 1,
      updated_at: old,
      created_at: old
    })

    insert_state(pool.id, assignment.id, model_id, "proxy_http", %{
      status: "open",
      reason_code: "upstream_model_unavailable",
      failure_count: 2,
      next_probe_at: future,
      updated_at: recent,
      created_at: recent
    })

    insert_state(pool.id, assignment.id, model_id, "proxy_stream", %{
      status: "closed",
      reason_code: nil,
      failure_count: 0,
      last_success_at: recent,
      updated_at: recent,
      created_at: recent
    })

    insert_state(pool.id, assignment.id, model_id, "proxy_websocket", %{
      status: "open",
      reason_code: "unrelated_failure",
      failure_count: 9,
      updated_at: recent,
      created_at: recent,
      metadata: %{"private" => "circuit-private-value"}
    })

    insert_state(pool.id, sibling.id, model_id, "proxy_http", %{
      status: "open",
      reason_code: "upstream_model_unavailable",
      failure_count: 3
    })

    insert_state(hidden_pool.id, hidden.id, model_id, "proxy_http", %{
      status: "open",
      reason_code: "upstream_model_unavailable",
      failure_count: 4
    })

    insert_state(pool.id, assignment.id, model_id, "proxy_stream", %{
      api_key_id: api_key.id,
      status: "open",
      reason_code: "upstream_model_unavailable",
      failure_count: 10,
      updated_at: timestamp(0),
      created_at: timestamp(0)
    })

    rows = ServingSignals.list_summaries([{pool.id, assignment.id, model_id}])

    assert Enum.map(rows, & &1.route_class) ==
             ~w(proxy_http proxy_stream proxy_websocket)

    assert Enum.find(rows, &(&1.route_class == "proxy_http")) == %{
             pool_id: pool.id,
             assignment_id: assignment.id,
             exposed_model_id: model_id,
             route_class: "proxy_http",
             serving_state: :temporarily_unavailable,
             status: "open",
             reason_code: "upstream_model_unavailable",
             failure_count: 2,
             last_failure_at: nil,
             last_success_at: nil,
             next_probe_at: future
           }

    assert %{serving_state: :available_observed, status: "closed", reason_code: nil} =
             Enum.find(rows, &(&1.route_class == "proxy_stream"))

    assert %{serving_state: :unverified, status: nil, reason_code: nil, failure_count: 0} =
             Enum.find(rows, &(&1.route_class == "proxy_websocket"))

    refute inspect(rows) =~ "circuit-private-value"
    assert ServingSignals.list_summaries([]) == []
    assert ServingSignals.list_summaries([{"bad", assignment.id, model_id}, pool.id]) == []
  end

  test "labels closed rejection, due probes, and half-open probes separately" do
    pool = pool_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    model_id = "gpt-example-route-labels"

    insert_state(pool.id, assignment.id, model_id, "proxy_http", %{
      status: "closed",
      reason_code: "upstream_model_unavailable",
      failure_count: 1
    })

    insert_state(pool.id, assignment.id, model_id, "proxy_stream", %{
      status: "open",
      reason_code: "upstream_model_unavailable",
      failure_count: 2,
      next_probe_at: timestamp(-1)
    })

    insert_state(pool.id, assignment.id, model_id, "proxy_websocket", %{
      status: "half_open",
      reason_code: "upstream_model_unavailable",
      failure_count: 2
    })

    rows = ServingSignals.list_summaries([{pool.id, assignment.id, model_id}])

    assert Enum.map(rows, &{&1.route_class, &1.serving_state}) == [
             {"proxy_http", :serving_rejection_observed},
             {"proxy_stream", :probe_due},
             {"proxy_websocket", :probe_in_progress}
           ]
  end

  test "uses created_at as the database tie-break when updated_at matches" do
    pool = pool_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    model_id = "gpt-example-created-tie-break"
    same_updated_at = timestamp(-30)

    insert_state(pool.id, assignment.id, model_id, "proxy_http", %{
      status: "closed",
      reason_code: "upstream_model_unavailable",
      failure_count: 1,
      updated_at: same_updated_at,
      created_at: timestamp(-120)
    })

    insert_state(pool.id, assignment.id, model_id, "proxy_http", %{
      status: "open",
      reason_code: "upstream_model_unavailable",
      failure_count: 7,
      next_probe_at: timestamp(300),
      updated_at: same_updated_at,
      created_at: timestamp(-60)
    })

    assert [http, _stream, _websocket] =
             ServingSignals.list_summaries([{pool.id, assignment.id, model_id}])

    assert %{status: "open", failure_count: 7, serving_state: :temporarily_unavailable} = http
  end

  test "composed Catalog inventory excludes stale, suppressed, retired, and unauthorized circuits" do
    pool = pool_fixture()
    hidden_pool = pool_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    %{assignment: hidden_assignment} = upstream_assignment_fixture(hidden_pool)

    active_model =
      model_fixture(pool, %{
        exposed_model_id: "gpt-example-composed-active",
        metadata: %{
          "source_assignment_models" => %{assignment.id => %{"supports_responses" => true}}
        }
      })

    for status <- ~w(stale suppressed retired) do
      model_fixture(pool, %{
        exposed_model_id: "gpt-example-composed-#{status}",
        status: status,
        metadata: %{"source_assignment_models" => %{assignment.id => %{}}}
      })

      insert_state(pool.id, assignment.id, "gpt-example-composed-#{status}", "proxy_http", %{
        status: "open",
        reason_code: "upstream_model_unavailable",
        failure_count: 9
      })
    end

    insert_state(
      hidden_pool.id,
      hidden_assignment.id,
      active_model.exposed_model_id,
      "proxy_http",
      %{
        status: "open",
        reason_code: "upstream_model_unavailable",
        failure_count: 8
      }
    )

    insert_state(pool.id, assignment.id, active_model.exposed_model_id, "proxy_http", %{
      status: "closed",
      reason_code: "upstream_model_unavailable",
      failure_count: 1
    })

    catalog_rows = Catalog.list_assignment_model_summaries([{pool.id, assignment.id}])

    authorized_models =
      Enum.map(catalog_rows, &{&1.pool_id, &1.assignment_id, &1.exposed_model_id})

    rows = ServingSignals.list_summaries(authorized_models)

    assert Enum.map(catalog_rows, & &1.exposed_model_id) == [active_model.exposed_model_id]
    assert length(rows) == 3
    assert Enum.all?(rows, &(&1.pool_id == pool.id and &1.assignment_id == assignment.id))
    assert Enum.all?(rows, &(&1.exposed_model_id == active_model.exposed_model_id))
  end

  test "composed inventory uses one models and at most one circuit query for one and fifty Pools" do
    for size <- [1, 50] do
      authorized =
        for index <- 1..size do
          pool = pool_fixture()
          %{assignment: assignment} = upstream_assignment_fixture(pool)
          model_id = "gpt-example-bounded-#{size}-#{index}"

          model_fixture(pool, %{
            exposed_model_id: model_id,
            metadata: %{
              "source_assignment_models" => %{
                assignment.id => %{"supports_responses" => true}
              }
            }
          })

          insert_state(pool.id, assignment.id, model_id, "proxy_http", %{
            status: "closed",
            reason_code: "upstream_model_unavailable",
            failure_count: index
          })

          {pool.id, assignment.id}
        end

      {rows, queries} =
        count_repo_sources(fn ->
          authorized
          |> Catalog.list_assignment_model_summaries()
          |> Enum.map(&{&1.pool_id, &1.assignment_id, &1.exposed_model_id})
          |> ServingSignals.list_summaries()
        end)

      assert length(rows) == size * 3
      assert Map.get(queries, "models", 0) == 1
      assert Map.get(queries, "routing_circuit_states", 0) == 1
      assert Enum.sum(Map.values(queries)) == 2
    end
  end

  defp insert_state(pool_id, assignment_id, model_id, route_class, attrs) do
    now = timestamp(-30)
    assignment = Repo.get!(PoolUpstreamAssignment, assignment_id)

    %RoutingCircuitState{}
    |> RoutingCircuitState.changeset(%{
      pool_id: pool_id,
      api_key_id: Map.get(attrs, :api_key_id),
      pool_upstream_assignment_id: assignment_id,
      upstream_identity_id: assignment.upstream_identity_id,
      model_identifier: model_id,
      route_class: route_class,
      status: Map.fetch!(attrs, :status),
      reason_code: Map.get(attrs, :reason_code),
      failure_count: Map.get(attrs, :failure_count, 0),
      success_count: Map.get(attrs, :success_count, 0),
      next_probe_at: Map.get(attrs, :next_probe_at),
      last_failure_at: Map.get(attrs, :last_failure_at),
      last_success_at: Map.get(attrs, :last_success_at),
      metadata: Map.get(attrs, :metadata, %{}),
      created_at: Map.get(attrs, :created_at, now),
      updated_at: Map.get(attrs, :updated_at, now)
    })
    |> Repo.insert!()
  end

  defp count_repo_sources(fun) do
    parent = self()
    handler_id = "serving-signals-query-count-#{System.unique_integer([:positive])}"

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
end
