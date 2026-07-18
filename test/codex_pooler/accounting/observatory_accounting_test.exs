defmodule CodexPooler.Accounting.ObservatoryAccountingTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Access.DashboardSessions.Principal, as: DashboardPrincipal
  alias CodexPooler.Accounting.DailyRollup
  alias CodexPooler.Accounting.Usage.Observatory
  alias CodexPooler.Repo

  @unsafe_request_text "discard-this-request-content"
  @unsafe_error_text "discard-this-raw-error-content"
  @unsafe_metadata_text "discard-this-private-metadata"

  test "ledger facts classify costs without late-rollup double counting or unsafe fields" do
    pool = pool_fixture()
    api_key = dashboard_api_key_fixture(pool)
    %{identity: identity, assignment: assignment} = upstream_assignment_fixture(pool)
    model = model_fixture(pool, %{exposed_model_id: "unsafe model label"})
    upper_bound = ~U[2026-07-17 12:00:00Z]

    settled_request =
      timed_request(pool, api_key, ~U[2026-07-17 11:30:00Z], %{
        model_id: model.id,
        status: "failed",
        response_status_code: 503,
        last_error_code: @unsafe_error_text,
        request_metadata: %{
          "request_text" => @unsafe_request_text,
          "private" => @unsafe_metadata_text
        }
      })

    settled_attempt =
      settled_request
      |> timed_attempt(assignment, ~U[2026-07-17 11:30:00Z], 750)
      |> Ecto.Changeset.change(%{
        error_message: @unsafe_error_text,
        response_metadata: %{"private" => @unsafe_metadata_text}
      })
      |> Repo.update!()

    timed_settlement(
      settled_request,
      settled_attempt,
      assignment,
      identity,
      ~U[2026-07-17 11:30:01Z],
      %{total_tokens: 25, settled_cost_micros: 125}
    )

    estimated_request =
      timed_request(pool, api_key, ~U[2026-07-17 11:31:00Z], %{
        model_id: model.id,
        status: "succeeded"
      })

    estimated_attempt =
      timed_attempt(estimated_request, assignment, ~U[2026-07-17 11:31:00Z], 500)

    timed_settlement(
      estimated_request,
      estimated_attempt,
      assignment,
      identity,
      ~U[2026-07-17 11:31:01Z],
      %{
        usage_status: "usage_unknown",
        total_tokens: 9_999,
        estimated_cost_micros: 250,
        details: %{"pricing_status" => "unavailable", "private" => @unsafe_metadata_text}
      }
    )

    _missing_request =
      timed_request(pool, api_key, ~U[2026-07-17 11:32:00Z], %{
        model_id: model.id,
        status: "in_progress",
        completed_at: nil
      })

    insert_late_rollup!(pool, api_key, upper_bound)

    assert {:ok, projection} =
             Observatory.read(principal(pool, api_key), "1h", as_of: upper_bound)

    assert projection.totals.requests == %{
             total: 3,
             succeeded: 1,
             failed: 1,
             in_progress: 1
           }

    assert projection.totals.tokens.total == 25
    assert projection.totals.cost.settled == %{status: "settled", micros: 125}
    assert projection.totals.cost.estimated == %{status: "estimated", micros: 250}
    assert projection.totals.cost.unavailable_requests == 1
    assert projection.totals.cost.confidence == "partial"

    assert projection.accounting == %{
             status: "partial",
             source: "recorded_ledger",
             recorded_settlements: 2,
             missing_settlements: 1,
             unknown_usage: 1,
             late_rollup_policy: "ledger_authoritative"
           }

    assert [%{label: "Unknown model", request_count: 3, total_tokens: 25}] =
             projection.models

    assert Enum.any?(projection.outcomes, &(&1.cost == %{status: "settled", micros: 125}))
    assert Enum.any?(projection.outcomes, &(&1.cost == %{status: "estimated", micros: 250}))
    assert Enum.any?(projection.outcomes, &(&1.cost == %{status: "unavailable", micros: 0}))
    assert Enum.any?(projection.outcomes, &(&1.code == "request_failed"))

    rendered = inspect(projection, limit: :infinity)
    refute rendered =~ @unsafe_request_text
    refute rendered =~ @unsafe_error_text
    refute rendered =~ @unsafe_metadata_text
    refute rendered =~ "999999999"
  end

  test "counts a request's settled cost even when it settles after the window closes" do
    pool = pool_fixture()
    api_key = dashboard_api_key_fixture(pool)
    %{identity: identity, assignment: assignment} = upstream_assignment_fixture(pool)
    model = model_fixture(pool, %{exposed_model_id: "gpt-window-edge"})
    upper_bound = ~U[2026-07-17 12:00:00Z]

    # Admitted just inside the [11:00, 12:00) window...
    request =
      timed_request(pool, api_key, ~U[2026-07-17 11:59:30Z], %{
        model_id: model.id,
        status: "succeeded"
      })

    attempt = timed_attempt(request, assignment, ~U[2026-07-17 11:59:30Z], 400)

    # ...but its settlement is recorded five minutes later, after the window ends.
    # The scope must still attribute this cost to the in-window request; joining
    # the settlement per request (not by an occurred_at window) is what makes
    # that hold and keeps the read from nested-looping settlements.
    timed_settlement(
      request,
      attempt,
      assignment,
      identity,
      ~U[2026-07-17 12:05:00Z],
      %{total_tokens: 40, settled_cost_micros: 321}
    )

    assert {:ok, projection} =
             Observatory.read(principal(pool, api_key), "1h", as_of: upper_bound)

    assert projection.totals.requests.total == 1
    assert projection.totals.tokens.total == 40
    assert projection.totals.cost.settled == %{status: "settled", micros: 321}

    assert [%{label: "gpt-window-edge", total_tokens: 40, cost_micros: 321}] =
             projection.models
  end

  defp principal(pool, api_key) do
    DashboardPrincipal.new(%{
      api_key_id: api_key.id,
      pool_id: pool.id,
      display_name: api_key.display_name,
      key_prefix: api_key.key_prefix
    })
  end

  defp dashboard_api_key_fixture(pool) do
    %{api_key: api_key} = active_api_key_fixture(pool)

    api_key
    |> APIKey.changeset(%{dashboard_access: true})
    |> Repo.update!()
  end

  defp timed_request(pool, api_key, timestamp, attrs) do
    timestamp = usec(timestamp)

    %{pool: pool, api_key: api_key}
    |> request_fixture(attrs)
    |> Ecto.Changeset.change(%{
      admitted_at: timestamp,
      completed_at: Map.get(attrs, :completed_at, timestamp)
    })
    |> Repo.update!()
  end

  defp timed_attempt(request, assignment, timestamp, latency_ms) do
    timestamp = usec(timestamp)

    request
    |> attempt_fixture(assignment, %{latency_ms: latency_ms})
    |> Ecto.Changeset.change(%{started_at: timestamp, completed_at: timestamp})
    |> Repo.update!()
  end

  defp timed_settlement(request, attempt, assignment, identity, timestamp, attrs) do
    timestamp = usec(timestamp)

    attrs =
      Map.merge(
        %{
          attempt_id: attempt.id,
          pool_upstream_assignment_id: assignment.id,
          upstream_identity_id: identity.id,
          occurred_at: timestamp,
          created_at: timestamp,
          details: %{"pricing_status" => "priced"}
        },
        attrs
      )

    ledger_entry_fixture(request, attrs)
  end

  defp insert_late_rollup!(pool, api_key, timestamp) do
    timestamp = usec(timestamp)

    %DailyRollup{
      rollup_date: DateTime.to_date(timestamp),
      dimension_kind: "api_key",
      pool_id: pool.id,
      api_key_id: api_key.id,
      request_count: 999_999_999,
      success_count: 999_999_999,
      failure_count: 0,
      retry_count: 0,
      input_tokens: 999_999_999,
      cached_input_tokens: 0,
      output_tokens: 0,
      reasoning_tokens: 0,
      total_tokens: 999_999_999,
      estimated_cost_micros: Decimal.new(999_999_999),
      settled_cost_micros: Decimal.new(999_999_999),
      created_at: timestamp,
      updated_at: timestamp
    }
    |> Repo.insert!()
  end

  defp usec(timestamp), do: %{timestamp | microsecond: {elem(timestamp.microsecond, 0), 6}}
end
