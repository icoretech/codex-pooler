defmodule CodexPooler.Admin.UpstreamCircuitReadinessTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Admin.UpstreamCircuitReadiness
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Persistence.RoutingCircuitState
  alias CodexPooler.Gateway.Routing.CircuitHealth

  @observed_at ~U[2026-07-20 12:00:00.000000Z]
  @settings %OperationalSettings{
    circuit_open_seconds: 60,
    circuit_half_open_probe_limit: 1
  }

  test "empty authorization performs no query and requested assignments without rows are clear" do
    pool = pool_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    %{assignment: second_assignment} = upstream_assignment_fixture(pool)

    {empty, empty_commands} =
      count_repo_commands(fn ->
        UpstreamCircuitReadiness.by_assignment_id(%{}, @settings, @observed_at)
      end)

    {summaries, commands} =
      count_repo_commands(fn ->
        UpstreamCircuitReadiness.by_assignment_id(
          %{assignment.id => ["gpt-clear"]},
          @settings,
          @observed_at
        )
      end)

    {multiple_summaries, multiple_commands} =
      count_repo_commands(fn ->
        UpstreamCircuitReadiness.by_assignment_id(
          %{
            assignment.id => ["gpt-clear"],
            second_assignment.id => ["gpt-second-clear"]
          },
          @settings,
          @observed_at
        )
      end)

    assert empty == %{}
    assert command_count(empty_commands, "routing_circuit_states", "SELECT") == 0
    assert command_count(commands, "routing_circuit_states", "SELECT") == 1
    assert command_count(multiple_commands, "routing_circuit_states", "SELECT") == 1
    assert summaries == %{assignment.id => UpstreamCircuitReadiness.clear()}

    assert multiple_summaries == %{
             assignment.id => UpstreamCircuitReadiness.clear(),
             second_assignment.id => UpstreamCircuitReadiness.clear()
           }

    assert UpstreamCircuitReadiness.clear() == %{
             state: :closed,
             ready?: true,
             tone: :success,
             label: "Circuit clear",
             detail: "No circuit protection is active",
             blocked_lane_count: 0,
             recovering_lane_count: 0,
             affected_lane_count: 0,
             blocked_reasons: [],
             representative: nil
           }
  end

  test "future open and nil-probe open lanes are blocked and not ready" do
    pool = pool_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(pool)

    insert_state!(pool, assignment, "gpt-future", "proxy_http",
      status: "open",
      next_probe_at: DateTime.add(@observed_at, 1, :second)
    )

    insert_state!(pool, assignment, "gpt-no-probe", "proxy_stream", status: "open")

    summary =
      project(%{assignment.id => ["gpt-future", "gpt-no-probe"]})
      |> Map.fetch!(assignment.id)

    assert summary.state == :blocked
    refute summary.ready?
    assert summary.tone == :error
    assert summary.blocked_lane_count == 2
    assert summary.recovering_lane_count == 0
    assert summary.affected_lane_count == 2
    assert summary.blocked_reasons == ["open_cooldown", "open_no_probe"]

    assert summary.representative == %{
             model_identifier: "gpt-future",
             route_class: "proxy_http"
           }
  end

  test "saved-reset recovery metadata does not change circuit readiness projection" do
    pool = pool_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(pool)

    insert_state!(pool, assignment, "gpt-recovery-marker", "proxy_http",
      status: "open",
      next_probe_at: DateTime.add(@observed_at, 1, :second),
      metadata: %{
        "saved_reset_recovery" => %{
          "version" => 1,
          "attempted" => false,
          "since_success_at" => "never"
        }
      }
    )

    summary = project(%{assignment.id => ["gpt-recovery-marker"]}) |> Map.fetch!(assignment.id)

    assert summary.state == :blocked
    refute summary.ready?
    assert summary.blocked_reasons == ["open_cooldown"]
    refute inspect(summary) =~ "saved_reset_recovery"
  end

  @tag :stale_probe_ready_circuit_verdict
  test "stale probe-ready open lane is clear" do
    pool = pool_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(pool)

    insert_state!(pool, assignment, "gpt-stale-open", "proxy_http",
      status: "open",
      next_probe_at: @observed_at,
      opened_at: DateTime.add(@observed_at, -601, :second),
      last_failure_at: DateTime.add(@observed_at, -601, :second)
    )

    summary = project(%{assignment.id => ["gpt-stale-open"]}) |> Map.fetch!(assignment.id)

    assert summary == UpstreamCircuitReadiness.clear()
  end

  test "probe-eligible open and available or stale half-open lanes are recovering while fresh saturated half-open remains blocked" do
    pool = pool_fixture()
    %{assignment: elapsed_open} = upstream_assignment_fixture(pool)
    %{assignment: available_half_open} = upstream_assignment_fixture(pool)
    %{assignment: stale_half_open} = upstream_assignment_fixture(pool)
    %{assignment: saturated_half_open} = upstream_assignment_fixture(pool)

    insert_state!(pool, elapsed_open, "gpt-open", "proxy_http",
      status: "open",
      next_probe_at: @observed_at,
      opened_at: DateTime.add(@observed_at, -30, :second)
    )

    insert_state!(pool, available_half_open, "gpt-free", "proxy_stream",
      status: "half_open",
      metadata: %{"probe_in_flight_count" => 0},
      updated_at: DateTime.add(@observed_at, -1, :second)
    )

    insert_state!(pool, stale_half_open, "gpt-stale", "proxy_websocket",
      status: "half_open",
      metadata: %{"probe_in_flight_count" => 1},
      updated_at: DateTime.add(@observed_at, -60, :second)
    )

    insert_state!(pool, saturated_half_open, "gpt-busy", "proxy_compact",
      status: "half_open",
      metadata: %{"probe_in_flight_count" => 1},
      updated_at: DateTime.add(@observed_at, -59, :second)
    )

    summaries =
      project(%{
        elapsed_open.id => ["gpt-open"],
        available_half_open.id => ["gpt-free"],
        stale_half_open.id => ["gpt-stale"],
        saturated_half_open.id => ["gpt-busy"]
      })

    for assignment <- [elapsed_open, available_half_open, stale_half_open] do
      assert summaries[assignment.id].state == :recovering
      assert summaries[assignment.id].ready?
      assert summaries[assignment.id].tone == :warning
      assert summaries[assignment.id].recovering_lane_count == 1
    end

    assert summaries[saturated_half_open.id].state == :blocked
    refute summaries[saturated_half_open.id].ready?
    assert summaries[saturated_half_open.id].blocked_reasons == ["probe_saturated"]
  end

  test "closed recovery memory includes both interval boundaries and excludes stale and future evidence" do
    pool = pool_fixture()
    %{assignment: lower} = upstream_assignment_fixture(pool)
    %{assignment: upper} = upstream_assignment_fixture(pool)
    %{assignment: stale} = upstream_assignment_fixture(pool)
    %{assignment: future} = upstream_assignment_fixture(pool)
    %{assignment: latest_source} = upstream_assignment_fixture(pool)

    insert_state!(pool, lower, "gpt-lower", "proxy_http",
      opened_at: DateTime.add(@observed_at, -600, :second)
    )

    insert_state!(pool, upper, "gpt-upper", "proxy_http", last_failure_at: @observed_at)

    insert_state!(pool, stale, "gpt-stale", "proxy_http",
      opened_at: DateTime.add(@observed_at, -601, :second)
    )

    insert_state!(pool, future, "gpt-future", "proxy_http",
      last_failure_at: DateTime.add(@observed_at, 1, :second)
    )

    insert_state!(pool, latest_source, "gpt-latest", "proxy_http",
      opened_at: DateTime.add(@observed_at, -400, :second),
      last_failure_at: DateTime.add(@observed_at, -20, :second)
    )

    summaries =
      project(%{
        lower.id => ["gpt-lower"],
        upper.id => ["gpt-upper"],
        stale.id => ["gpt-stale"],
        future.id => ["gpt-future"],
        latest_source.id => ["gpt-latest"]
      })

    assert summaries[lower.id].state == :recovering
    assert summaries[upper.id].state == :recovering
    assert summaries[latest_source.id].state == :recovering
    assert summaries[stale.id] == UpstreamCircuitReadiness.clear()
    assert summaries[future.id] == UpstreamCircuitReadiness.clear()
  end

  test "recovery memory clamps to five minutes and one hour at boundary settings" do
    pool = pool_fixture()
    %{assignment: lower_clamp} = upstream_assignment_fixture(pool)
    %{assignment: upper_clamp} = upstream_assignment_fixture(pool)

    insert_state!(pool, lower_clamp, "gpt-lower-clamp", "proxy_http",
      opened_at: DateTime.add(@observed_at, -300, :second)
    )

    insert_state!(pool, upper_clamp, "gpt-upper-clamp", "proxy_http",
      opened_at: DateTime.add(@observed_at, -3_600, :second)
    )

    lower =
      UpstreamCircuitReadiness.by_assignment_id(
        %{lower_clamp.id => ["gpt-lower-clamp"]},
        %OperationalSettings{@settings | circuit_open_seconds: 0},
        @observed_at
      )

    upper =
      UpstreamCircuitReadiness.by_assignment_id(
        %{upper_clamp.id => ["gpt-upper-clamp"]},
        %OperationalSettings{@settings | circuit_open_seconds: 10_000},
        @observed_at
      )

    assert lower[lower_clamp.id].state == :recovering
    assert upper[upper_clamp.id].state == :recovering
  end

  test "latest exact row controls current classification while eligible older evidence remains independent" do
    pool = pool_fixture()
    %{assignment: newer_closed} = upstream_assignment_fixture(pool)
    %{assignment: newer_blocked} = upstream_assignment_fixture(pool)

    older_blocked =
      insert_state!(pool, newer_closed, "gpt-history-a", "proxy_http",
        status: "open",
        next_probe_at: DateTime.add(@observed_at, 300, :second),
        opened_at: DateTime.add(@observed_at, -100, :second),
        created_at: DateTime.add(@observed_at, -30, :second),
        updated_at: DateTime.add(@observed_at, -30, :second)
      )

    newer_closed_row =
      insert_state!(pool, newer_closed, "gpt-history-a", "proxy_http",
        status: "closed",
        created_at: DateTime.add(@observed_at, -10, :second),
        updated_at: DateTime.add(@observed_at, -10, :second)
      )

    insert_state!(pool, newer_blocked, "gpt-history-b", "proxy_http",
      status: "closed",
      last_failure_at: DateTime.add(@observed_at, -100, :second),
      created_at: DateTime.add(@observed_at, -30, :second),
      updated_at: DateTime.add(@observed_at, -30, :second)
    )

    newer_blocked_row =
      insert_state!(pool, newer_blocked, "gpt-history-b", "proxy_http",
        status: "open",
        next_probe_at: DateTime.add(@observed_at, 300, :second),
        created_at: DateTime.add(@observed_at, -10, :second),
        updated_at: DateTime.add(@observed_at, -10, :second)
      )

    summaries =
      project(%{
        newer_closed.id => ["gpt-history-a"],
        newer_blocked.id => ["gpt-history-b"]
      })

    refute CircuitHealth.blocked?(older_blocked, @settings, @observed_at) ==
             CircuitHealth.blocked?(newer_closed_row, @settings, @observed_at)

    assert summaries[newer_closed.id].state == :recovering
    assert summaries[newer_closed.id].ready?
    assert CircuitHealth.blocked?(newer_closed_row, @settings, @observed_at) == false

    assert summaries[newer_blocked.id].state == :blocked
    refute summaries[newer_blocked.id].ready?
    assert CircuitHealth.blocked?(newer_blocked_row, @settings, @observed_at) == true
  end

  test "API-key and retired model rows are excluded before assignment and aggregate summaries" do
    pool = pool_fixture()
    %{api_key: api_key} = active_api_key_fixture(pool)
    %{assignment: assignment} = upstream_assignment_fixture(pool)

    insert_state!(pool, assignment, "gpt-served", "proxy_http",
      api_key_id: api_key.id,
      status: "open",
      next_probe_at: DateTime.add(@observed_at, 300, :second)
    )

    insert_state!(pool, assignment, "gpt-retired", "proxy_stream",
      status: "open",
      next_probe_at: nil,
      opened_at: @observed_at,
      metadata: %{"probe_in_flight_count" => 99}
    )

    summary = project(%{assignment.id => ["gpt-served"]}) |> Map.fetch!(assignment.id)

    assert summary == UpstreamCircuitReadiness.clear()
    assert UpstreamCircuitReadiness.aggregate([summary]) == UpstreamCircuitReadiness.clear()
    refute inspect(summary) =~ "gpt-retired"
    refute inspect(summary) =~ "proxy_stream"
  end

  test "normalized duplicate exact rows count once while distinct display lanes count separately" do
    pool = pool_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(pool)

    for {model, route} <- [
          {" GPT-DUP ", "proxy_http"},
          {"gpt-dup", "proxy_http"},
          {"gpt-dup", "proxy_stream"}
        ] do
      insert_state!(pool, assignment, model, route,
        status: "open",
        next_probe_at: DateTime.add(@observed_at, 300, :second)
      )
    end

    summary = project(%{assignment.id => ["gpt-dup"]}) |> Map.fetch!(assignment.id)

    assert summary.state == :blocked
    assert summary.blocked_lane_count == 2
    assert summary.affected_lane_count == 2

    assert summary.representative == %{
             model_identifier: "gpt-dup",
             route_class: "proxy_http"
           }
  end

  test "distinct normalized models sharing the first eighty display graphemes remain separate lanes" do
    pool = pool_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    shared_prefix = String.duplicate("m", 80)
    model_a = shared_prefix <> "a"
    model_b = shared_prefix <> "b"

    for model <- [model_a, model_b] do
      insert_state!(pool, assignment, model, "proxy_http",
        status: "open",
        next_probe_at: DateTime.add(@observed_at, 300, :second)
      )
    end

    summary = project(%{assignment.id => [model_a, model_b]}) |> Map.fetch!(assignment.id)

    assert summary.blocked_lane_count == 2
    assert summary.affected_lane_count == 2

    assert summary.representative == %{
             model_identifier: shared_prefix,
             route_class: "proxy_http"
           }
  end

  test "distinct unknown normalized routes remain separate lanes before fallback display" do
    pool = pool_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(pool)

    for route <- ["unknown-route-b", "unknown-route-a"] do
      insert_state!(pool, assignment, "gpt-unknown-route", route,
        status: "open",
        next_probe_at: DateTime.add(@observed_at, 300, :second)
      )
    end

    first = project(%{assignment.id => ["gpt-unknown-route"]}) |> Map.fetch!(assignment.id)
    second = project(%{assignment.id => ["gpt-unknown-route"]}) |> Map.fetch!(assignment.id)

    assert first.blocked_lane_count == 2
    assert first.affected_lane_count == 2

    assert first.representative == %{
             model_identifier: "gpt-unknown-route",
             route_class: "unknown route"
           }

    assert second.representative == first.representative
  end

  test "duplicate display lanes retain the most recent eligible evidence deterministically" do
    pool = pool_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(pool)

    insert_state!(pool, assignment, " GPT-EVIDENCE ", "proxy_http",
      status: "open",
      next_probe_at: nil,
      opened_at: DateTime.add(@observed_at, -100, :second)
    )

    insert_state!(pool, assignment, "gpt-evidence", "proxy_http",
      status: "open",
      next_probe_at: DateTime.add(@observed_at, 300, :second),
      opened_at: DateTime.add(@observed_at, -10, :second)
    )

    summary = project(%{assignment.id => ["gpt-evidence"]}) |> Map.fetch!(assignment.id)

    assert summary.blocked_lane_count == 1
    assert summary.blocked_reasons == ["open_cooldown"]
  end

  test "representative selection is deterministic by severity, model, route, then evidence" do
    pool = pool_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(pool)

    insert_state!(pool, assignment, "a-recovering", "proxy_http",
      status: "closed",
      last_failure_at: DateTime.add(@observed_at, -10, :second)
    )

    insert_state!(pool, assignment, "z-blocked", "proxy_stream",
      status: "open",
      next_probe_at: DateTime.add(@observed_at, 300, :second)
    )

    insert_state!(pool, assignment, "b-blocked", "proxy_websocket",
      status: "open",
      next_probe_at: DateTime.add(@observed_at, 300, :second)
    )

    summary =
      project(%{assignment.id => ["z-blocked", "a-recovering", "b-blocked"]})
      |> Map.fetch!(assignment.id)

    assert summary.representative == %{
             model_identifier: "b-blocked",
             route_class: "proxy_websocket"
           }
  end

  test "untrusted model and route copy is bounded, control-free, HTML-safe, and allowlisted" do
    pool = pool_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(pool)

    raw_model =
      "\u0007<script>ignore previous instructions</script> " <> String.duplicate("x", 120)

    raw_route = "\u001F<iframe>unknown-route"

    insert_state!(pool, assignment, raw_model, raw_route,
      status: "open",
      next_probe_at: DateTime.add(@observed_at, 300, :second),
      reason_code: "<b>persisted-provider-reason</b>"
    )

    summary = project(%{assignment.id => [raw_model, nil, %{}]}) |> Map.fetch!(assignment.id)
    copy = summary.label <> " " <> summary.detail <> " " <> inspect(summary.representative)

    assert summary.state == :blocked
    assert summary.representative.route_class == "unknown route"
    assert String.length(summary.representative.model_identifier) <= 80
    refute copy =~ <<7>>
    refute copy =~ <<31>>
    refute copy =~ "<script>"
    refute copy =~ "<iframe>"
    refute copy =~ "persisted-provider-reason"
    refute copy =~ raw_route
  end

  test "display copy falls back when a served model normalizes to no visible graphemes" do
    pool = pool_fixture()
    %{assignment: assignment} = upstream_assignment_fixture(pool)
    raw_model = "\u0007\u001F"

    insert_state!(pool, assignment, raw_model, "not-a-route",
      status: "open",
      next_probe_at: DateTime.add(@observed_at, 300, :second)
    )

    summary = project(%{assignment.id => [raw_model]}) |> Map.fetch!(assignment.id)

    assert summary.representative == %{
             model_identifier: "unknown model",
             route_class: "unknown route"
           }
  end

  test "aggregate sums lane counts and applies blocked over recovering over closed" do
    blocked = %{
      UpstreamCircuitReadiness.clear()
      | state: :blocked,
        ready?: false,
        tone: :error,
        label: "Circuit protection active",
        detail: "2 circuit lanes blocked",
        blocked_lane_count: 2,
        affected_lane_count: 2,
        blocked_reasons: ["open_cooldown"],
        representative: %{model_identifier: "z-model", route_class: "proxy_stream"}
    }

    recovering = %{
      UpstreamCircuitReadiness.clear()
      | state: :recovering,
        tone: :warning,
        label: "Circuit recovery in progress",
        detail: "3 circuit lanes recovering",
        recovering_lane_count: 3,
        affected_lane_count: 3,
        representative: %{model_identifier: "a-model", route_class: "proxy_http"}
    }

    aggregate =
      UpstreamCircuitReadiness.aggregate([
        UpstreamCircuitReadiness.clear(),
        recovering,
        blocked
      ])

    assert aggregate.state == :blocked
    refute aggregate.ready?
    assert aggregate.blocked_lane_count == 2
    assert aggregate.recovering_lane_count == 3
    assert aggregate.affected_lane_count == 5
    assert aggregate.blocked_reasons == ["open_cooldown"]
    assert aggregate.representative == blocked.representative

    recovering_only =
      UpstreamCircuitReadiness.aggregate([UpstreamCircuitReadiness.clear(), recovering])

    assert recovering_only.state == :recovering
    assert recovering_only.ready?
  end

  defp project(authorized_models) do
    UpstreamCircuitReadiness.by_assignment_id(authorized_models, @settings, @observed_at)
  end

  defp insert_state!(pool, assignment, model_identifier, route_class, attrs) do
    defaults = [
      api_key_id: nil,
      status: "closed",
      reason_code: "persisted_reason_must_not_escape",
      failure_count: 3,
      success_count: 0,
      opened_at: nil,
      half_opened_at: nil,
      closed_at: nil,
      next_probe_at: nil,
      last_failure_at: nil,
      last_success_at: nil,
      metadata: %{},
      created_at: DateTime.add(@observed_at, -1, :second),
      updated_at: DateTime.add(@observed_at, -1, :second)
    ]

    attrs = Keyword.merge(defaults, attrs)

    %RoutingCircuitState{
      pool_id: pool.id,
      api_key_id: Keyword.fetch!(attrs, :api_key_id),
      pool_upstream_assignment_id: assignment.id,
      upstream_identity_id: assignment.upstream_identity_id,
      model_identifier: model_identifier,
      route_class: route_class,
      status: Keyword.fetch!(attrs, :status),
      reason_code: Keyword.fetch!(attrs, :reason_code),
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

  defp count_repo_commands(fun) do
    parent = self()
    handler_id = "upstream-circuit-readiness-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata[:repo] == Repo do
            send(parent, {handler_id, metadata[:source], command_name(metadata[:query])})
          end
        end,
        nil
      )

    try do
      result = fun.()
      {result, drain_repo_commands(handler_id, %{})}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_repo_commands(handler_id, commands) do
    receive do
      {^handler_id, source, command} ->
        key = {source, command}
        drain_repo_commands(handler_id, Map.update(commands, key, 1, &(&1 + 1)))
    after
      0 -> commands
    end
  end

  defp command_count(commands, source, command), do: Map.get(commands, {source, command}, 0)

  defp command_name(query) when is_binary(query) do
    query
    |> String.trim_leading()
    |> String.split(~r/\s+/, parts: 2)
    |> List.first()
    |> String.upcase()
  end
end
