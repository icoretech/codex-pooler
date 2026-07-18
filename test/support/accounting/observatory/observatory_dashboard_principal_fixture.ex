defmodule CodexPooler.Accounting.ObservatoryDashboardPrincipalFixture do
  @moduledoc false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Access.APIKey
  alias CodexPooler.Access.DashboardSessions.Principal, as: DashboardPrincipal
  alias CodexPooler.Repo

  @as_of ~U[2026-07-17 12:00:00Z]
  @principal_marker "discard-principal-private-metadata"
  @same_pool_marker "discard-same-pool-private-metadata"
  @other_pool_marker "discard-other-pool-private-metadata"

  def as_of, do: @as_of

  def excluded_artifacts do
    [
      @principal_marker,
      @same_pool_marker,
      @other_pool_marker,
      "gpt-observatory-different-key",
      "gpt-observatory-different-pool",
      "900000",
      "800000",
      "1800000",
      "1600000"
    ]
  end

  def isolation_fixture! do
    principal_pool = pool_fixture(%{name: "Shared generic Pool"})
    other_pool = pool_fixture(%{name: "Shared generic Pool"})

    principal_key =
      opted_in_api_key_fixture(principal_pool, %{display_name: "Shared generic key"})

    other_key = opted_in_api_key_fixture(principal_pool, %{display_name: "Shared generic key"})

    principal_model =
      model_fixture(principal_pool, %{
        exposed_model_id: "gpt-observatory-principal",
        display_name: "Shared generic model"
      })

    different_key_model =
      model_fixture(principal_pool, %{
        exposed_model_id: "gpt-observatory-different-key",
        display_name: "Shared generic model"
      })

    different_pool_model =
      model_fixture(other_pool, %{
        exposed_model_id: "gpt-observatory-different-pool",
        display_name: "Shared generic model"
      })

    seed_principal_facts!(principal_pool, principal_key, principal_model)

    %{
      principal: dashboard_principal(principal_key, principal_pool),
      conflicts: [
        %{
          pool: principal_pool,
          api_key: other_key,
          model: different_key_model,
          marker: @same_pool_marker,
          scale: 1,
          shift_seconds: 0
        },
        %{
          pool: other_pool,
          api_key: principal_key,
          model: different_pool_model,
          marker: @other_pool_marker,
          scale: 2,
          shift_seconds: 2
        }
      ]
    }
  end

  def insert_conflicting_facts!(conflicts), do: Enum.each(conflicts, &seed_conflicting_facts!/1)

  def record_usage(pool, api_key, model_name, total_tokens, occurred_at) do
    model = model_fixture(pool, %{exposed_model_id: model_name, display_name: model_name})
    request = timed_request(pool, api_key, model, occurred_at, %{status: "succeeded"})

    settlement(request, occurred_at, %{
      total_tokens: total_tokens,
      details: %{"pricing_status" => "priced"}
    })
  end

  def opted_in_api_key_fixture(pool, attrs \\ %{}) do
    %{api_key: api_key} = api_key_fixture(pool, attrs)
    enable_dashboard_access!(api_key)
  end

  def enable_dashboard_access!(api_key) do
    api_key |> APIKey.changeset(%{dashboard_access: true}) |> Repo.update!()
  end

  def dashboard_principal(api_key, pool) do
    DashboardPrincipal.new(%{
      api_key_id: api_key.id,
      pool_id: pool.id,
      display_name: api_key.display_name,
      key_prefix: api_key.key_prefix
    })
  end

  defp seed_conflicting_facts!(conflict) do
    settled_at = DateTime.add(~U[2026-07-17 11:02:00Z], conflict.shift_seconds)
    estimated_at = DateTime.add(~U[2026-07-17 11:31:00Z], conflict.shift_seconds)
    in_progress_at = DateTime.add(~U[2026-07-17 11:58:00Z], conflict.shift_seconds)

    settled =
      timed_request(conflict.pool, conflict.api_key, conflict.model, settled_at, %{
        status: "succeeded",
        request_metadata: %{"private" => conflict.marker}
      })

    settlement(settled, DateTime.add(settled_at, 1), %{
      total_tokens: 50_000 * conflict.scale,
      settled_cost_micros: 900_000 * conflict.scale,
      details: %{"pricing_status" => "priced", "private" => conflict.marker}
    })

    estimated =
      timed_request(conflict.pool, conflict.api_key, conflict.model, estimated_at, %{
        status: "failed",
        response_status_code: 504,
        last_error_code: "conflicting_timeout",
        request_metadata: %{"private" => conflict.marker}
      })

    settlement(estimated, DateTime.add(estimated_at, 1), %{
      usage_status: "usage_unknown",
      total_tokens: 70_000 * conflict.scale,
      estimated_cost_micros: 800_000 * conflict.scale,
      details: %{"pricing_status" => "unavailable", "private" => conflict.marker}
    })

    timed_request(conflict.pool, conflict.api_key, conflict.model, in_progress_at, %{
      status: "in_progress",
      completed_at: nil,
      request_metadata: %{"private" => conflict.marker}
    })
  end

  defp seed_principal_facts!(pool, api_key, model) do
    settled =
      timed_request(pool, api_key, model, ~U[2026-07-17 11:02:00Z], %{
        status: "failed",
        response_status_code: 503,
        last_error_code: @principal_marker,
        request_metadata: %{"private" => @principal_marker}
      })

    settlement(settled, ~U[2026-07-17 11:02:01Z], %{
      input_tokens: 12,
      cached_input_tokens: 4,
      output_tokens: 8,
      reasoning_tokens: 1,
      total_tokens: 25,
      settled_cost_micros: 125,
      details: %{"pricing_status" => "priced", "private" => @principal_marker}
    })

    estimated =
      timed_request(pool, api_key, model, ~U[2026-07-17 11:31:00Z], %{
        status: "succeeded",
        request_metadata: %{"private" => @principal_marker}
      })

    settlement(estimated, ~U[2026-07-17 11:31:01Z], %{
      usage_status: "usage_unknown",
      total_tokens: 9_999,
      estimated_cost_micros: 250,
      details: %{"pricing_status" => "unavailable", "private" => @principal_marker}
    })

    timed_request(pool, api_key, model, ~U[2026-07-17 11:58:00Z], %{
      status: "in_progress",
      completed_at: nil,
      request_metadata: %{"private" => @principal_marker}
    })
  end

  defp timed_request(pool, api_key, model, timestamp, attrs) do
    timestamp = usec(timestamp)

    %{pool: pool, api_key: api_key}
    |> request_fixture(
      Map.merge(%{model_id: model.id, requested_model: model.exposed_model_id}, attrs)
    )
    |> Ecto.Changeset.change(%{
      admitted_at: timestamp,
      completed_at: Map.get(attrs, :completed_at, timestamp)
    })
    |> Repo.update!()
  end

  defp settlement(request, timestamp, attrs) do
    timestamp = usec(timestamp)

    ledger_entry_fixture(
      request,
      Map.merge(%{occurred_at: timestamp, created_at: timestamp}, attrs)
    )
  end

  defp usec(timestamp), do: %{timestamp | microsecond: {elem(timestamp.microsecond, 0), 6}}
end
