defmodule CodexPooler.Accounting.APIKeyPolicyReservationTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Access
  alias CodexPooler.Access.APIKeyPolicyBinding
  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.LedgerEntry
  alias CodexPooler.Accounting.RequestLifecycle.LedgerEntries
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Runtime.Dispatch.AccountingReservation
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  import CodexPooler.AccountingTestSupport
  import CodexPooler.PoolerFixtures

  describe "api key policy reservation enforcement" do
    test "weekly token limit uses conservative reservation instead of tiny output cap" do
      setup = accounting_setup()

      update_default_policy!(setup.api_key, %{
        max_tokens_per_week: 100,
        max_requests_per_minute: 60,
        max_tokens_per_day: 1_000
      })

      consumed_request = request_fixture(setup.auth, %{model_id: setup.model.id})

      ledger_entry_fixture(consumed_request, %{
        pricing_snapshot_id: setup.pricing.id,
        total_tokens: 90,
        input_tokens: 90,
        output_tokens: 0,
        estimated_cost_micros: 900,
        settled_cost_micros: 900
      })

      assert {:error, error} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{"model" => setup.model.exposed_model_id, "max_output_tokens" => 10},
                 %{correlation_id: "corr-weekly-token-denied"}
               )

      assert error.code == :api_key_policy_limit_exceeded
      assert error.message =~ "max_tokens_per_week"

      assert Repo.aggregate(
               from(e in LedgerEntry,
                 where:
                   e.api_key_id == ^setup.api_key.id and e.entry_kind == "reservation" and
                     e.amount_status == "recorded"
               ),
               :count
             ) == 0

      refute Repo.get_by(CodexPooler.Accounting.Request,
               correlation_id: "corr-weekly-token-denied"
             )
    end

    test "missing output cap reserves conservative default output pressure" do
      setup = accounting_setup()

      update_default_policy!(setup.api_key, %{
        max_requests_per_minute: 60,
        max_tokens_per_day: 10_000,
        max_tokens_per_week: 10_000
      })

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{"model" => setup.model.exposed_model_id},
                 %{correlation_id: "corr-missing-output-cap"}
               )

      assert reserved.estimate.output_tokens == 512
      assert reserved.estimate.total_tokens == 512
      assert reserved.reservation.output_tokens == 512
      assert reserved.request.request_metadata["reservation"]["output_tokens"] == 512
    end

    test "continuation payload reserves opaque context conservatively" do
      setup = accounting_setup()

      update_default_policy!(setup.api_key, %{
        max_requests_per_minute: 60,
        max_tokens_per_day: 10_000,
        max_tokens_per_week: 10_000
      })

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{
                   "model" => setup.model.exposed_model_id,
                   "previous_response_id" => "resp_synthetic_continuation",
                   "max_output_tokens" => 10
                 },
                 %{correlation_id: "corr-continuation-conservative"}
               )

      assert reserved.estimate.output_tokens == 2_048
      assert reserved.estimate.total_tokens > 2_048
      assert reserved.reservation.output_tokens == 2_048
    end

    test "unknown final usage settles from conservative reservation" do
      setup = accounting_setup()

      update_default_policy!(setup.api_key, %{
        max_requests_per_minute: 60,
        max_tokens_per_day: 10_000,
        max_tokens_per_week: 10_000
      })

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{"model" => setup.model.exposed_model_id, "max_output_tokens" => 10},
                 %{correlation_id: "corr-unknown-conservative"}
               )

      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

      assert {:ok, result} =
               Accounting.finalize_failure(reserved.request, attempt, %{
                 last_error_code: "stream_interrupted",
                 usage: %{status: "usage_unknown"}
               })

      assert reserved.estimate.output_tokens == 512
      assert result.settlement.usage_status == "usage_unknown"
      assert result.settlement.output_tokens == reserved.reservation.output_tokens
      assert result.settlement.total_tokens == reserved.reservation.total_tokens
      assert result.settlement.details["estimated_from_reserve"] == true
    end

    test "known final usage remains consumed after settlement releases the reservation" do
      setup = accounting_setup()
      as_of = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      update_default_policy!(setup.api_key, %{
        max_requests_per_minute: 60,
        max_tokens_per_day: 10_000,
        max_tokens_per_week: 10_000
      })

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{"model" => setup.model.exposed_model_id, "max_output_tokens" => 10},
                 %{correlation_id: "corr-known-consumed-contract"}
               )

      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

      assert {:ok, result} =
               Accounting.finalize_success(
                 reserved.request,
                 attempt,
                 %{
                   status: "usage_known",
                   input_tokens: 7,
                   cached_input_tokens: 0,
                   output_tokens: 3,
                   reasoning_tokens: 0,
                   total_tokens: 10,
                   recorded_at: as_of
                 },
                 %{now: as_of}
               )

      assert result.settlement.usage_status == "usage_known"

      window_usage =
        setup.api_key.id
        |> LedgerEntries.window_usages(weekly: DateTime.add(as_of, -60, :second))
        |> Map.fetch!(:weekly)

      assert window_usage.effective_request_count == 1
      assert window_usage.effective_total_tokens == 10
      assert Decimal.equal?(window_usage.effective_cost_micros, Decimal.new(130))

      assert [rollup] =
               Accounting.list_daily_rollups(setup.pool,
                 date: DateTime.to_date(as_of),
                 dimension_kind: "api_key"
               )

      assert rollup.request_count == 1
      assert rollup.success_count == 1
      assert rollup.failure_count == 0
      assert rollup.total_tokens == 10
      assert Decimal.equal?(rollup.settled_cost_micros, Decimal.new(130))
    end

    test "usage_unknown final usage keeps counts but consumes zero local tokens and cost" do
      setup = accounting_setup()
      as_of = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      update_default_policy!(setup.api_key, %{
        max_requests_per_minute: 60,
        max_tokens_per_day: 10_000,
        max_tokens_per_week: 10_000
      })

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{"model" => setup.model.exposed_model_id, "max_output_tokens" => 10},
                 %{correlation_id: "corr-unknown-zero-consumption-contract"}
               )

      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

      assert {:ok, result} =
               Accounting.finalize_failure(reserved.request, attempt, %{
                 last_error_code: "stream_interrupted",
                 usage: %{status: "usage_unknown", recorded_at: as_of},
                 now: as_of
               })

      assert result.request.status == "failed"
      assert result.settlement.usage_status == "usage_unknown"
      assert result.settlement.total_tokens == reserved.reservation.total_tokens
      assert result.release.total_tokens == reserved.reservation.total_tokens
      assert result.settlement.details["estimated_from_reserve"] == true

      assert [rollup] =
               Accounting.list_daily_rollups(setup.pool,
                 date: DateTime.to_date(as_of),
                 dimension_kind: "api_key"
               )

      assert rollup.request_count == 1
      assert rollup.failure_count == 1

      window_usage =
        setup.api_key.id
        |> LedgerEntries.window_usages(weekly: DateTime.add(as_of, -60, :second))
        |> Map.fetch!(:weekly)

      assert window_usage.effective_request_count == 1
      assert window_usage.effective_total_tokens == 0
      assert Decimal.equal?(window_usage.effective_cost_micros, Decimal.new(0))
    end

    test "model policy takes precedence over default policy at reservation time" do
      setup = accounting_setup()

      update_default_policy!(setup.api_key, %{
        max_requests_per_minute: 60,
        max_tokens_per_day: 10_000,
        max_tokens_per_week: 10_000
      })

      insert_model_policy!(setup.api_key, setup.model.exposed_model_id, %{
        max_requests_per_minute: 60,
        max_tokens_per_day: 511,
        max_tokens_per_week: 10_000
      })

      assert {:error, error} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{
                   "model" => String.upcase(setup.model.exposed_model_id),
                   "max_output_tokens" => 1
                 },
                 %{correlation_id: "corr-model-policy-precedence"}
               )

      assert error.code == :api_key_policy_limit_exceeded
      assert error.message =~ "max_tokens_per_day"
    end

    test "disabled model policy is ignored and falls back to active default policy" do
      setup = accounting_setup()

      update_default_policy!(setup.api_key, %{
        max_requests_per_minute: 60,
        max_tokens_per_day: 10_000,
        max_tokens_per_week: 10_000
      })

      insert_model_policy!(setup.api_key, setup.model.exposed_model_id, %{
        status: "disabled",
        max_requests_per_minute: 60,
        max_tokens_per_day: 512,
        max_tokens_per_week: 10_000
      })

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{"model" => setup.model.exposed_model_id, "max_output_tokens" => 1},
                 %{correlation_id: "corr-disabled-model-policy-fallback"}
               )

      assert reserved.estimate.output_tokens == 512
      assert reserved.reservation.total_tokens == 512
    end

    test "reservation locks exactly one authoritative effective policy row" do
      setup = accounting_setup()

      update_default_policy!(setup.api_key, %{
        max_requests_per_minute: 60,
        max_tokens_per_day: 10_000,
        max_tokens_per_week: 10_000,
        max_output_tokens_per_request: 1_024
      })

      insert_model_policy!(setup.api_key, setup.model.exposed_model_id, %{
        max_requests_per_minute: 60,
        max_tokens_per_day: 10_000,
        max_tokens_per_week: 10_000,
        max_output_tokens_per_request: 768
      })

      {{:ok, reserved}, queries} =
        capture_repo_queries(fn ->
          Accounting.reserve(
            setup.auth,
            setup.model,
            %{"model" => String.upcase(setup.model.exposed_model_id), "max_output_tokens" => 1},
            %{correlation_id: "corr-single-policy-lock"}
          )
        end)

      policy_selects = table_commands(queries, "api_key_policy_bindings", "SELECT")

      assert length(policy_selects) == 1
      assert Enum.all?(policy_selects, &String.contains?(&1.query, "FOR UPDATE"))
      assert reserved.estimate.output_tokens == 768
      assert reserved.reservation.output_tokens == 768
    end

    test "reservation window enforcement aggregates ledger usage in the database" do
      setup = accounting_setup()
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      update_default_policy!(setup.api_key, %{
        max_requests_per_minute: 60,
        max_tokens_per_day: 100_000,
        max_tokens_per_week: 500_000
      })

      for index <- 1..5 do
        setup.auth
        |> request_fixture(%{
          model_id: setup.model.id,
          correlation_id: "corr-aggregate-window-existing-#{index}"
        })
        |> ledger_entry_fixture(%{
          total_tokens: 100,
          estimated_cost_micros: 100,
          settled_cost_micros: 100,
          occurred_at: DateTime.add(now, -index, :hour)
        })
      end

      {{:ok, _reserved}, queries} =
        capture_repo_queries(fn ->
          Accounting.reserve(
            setup.auth,
            setup.model,
            %{"model" => setup.model.exposed_model_id, "max_output_tokens" => 1},
            %{correlation_id: "corr-aggregate-window-reservation"}
          )
        end)

      ledger_usage_queries =
        queries
        |> Enum.filter(fn query ->
          query.command == "SELECT" and String.contains?(query.query, "ledger_entries") and
            String.contains?(query.query, "amount_status")
        end)

      assert ledger_usage_queries != []
      assert Enum.all?(ledger_usage_queries, &(String.downcase(&1.query) =~ "sum("))
      refute Enum.any?(ledger_usage_queries, &String.contains?(&1.query, ~s(l0."id")))
    end

    test "reservation snapshot inputs do not read policy bindings before reservation" do
      setup = accounting_setup()
      {:ok, policy} = Access.normalize_api_key_policy(setup.api_key)
      payload = %{"model" => setup.model.exposed_model_id, "input" => "snapshot estimate only"}

      request_options =
        RequestOptions.build(
          %{
            requested_model: setup.model.exposed_model_id,
            effective_model: setup.model.exposed_model_id,
            api_key_policy: policy
          },
          "/backend-api/codex/responses",
          payload
        )

      {snapshot_inputs, queries} =
        capture_repo_queries(fn ->
          AccountingReservation.reservation_snapshot_inputs(
            setup.auth,
            setup.model,
            payload,
            "/backend-api/codex/responses",
            request_options
          )
        end)

      assert command_count(queries, "api_key_policy_bindings", "SELECT") == 0
      assert snapshot_inputs.estimated_output_tokens == 512

      assert snapshot_inputs.estimated_total_tokens ==
               snapshot_inputs.estimated_input_tokens + snapshot_inputs.estimated_output_tokens
    end

    test "concurrent token reservations near limit cannot oversubscribe with tiny caps" do
      setup = accounting_setup()
      parent = self()

      update_default_policy!(setup.api_key, %{
        max_requests_per_minute: 60,
        max_tokens_per_day: 512,
        max_tokens_per_week: 10_000
      })

      tasks =
        for index <- 1..2 do
          Task.async(fn ->
            Sandbox.allow(Repo, parent, self())

            Accounting.reserve(
              setup.auth,
              setup.model,
              %{"model" => setup.model.exposed_model_id, "max_output_tokens" => 1},
              %{correlation_id: "corr-concurrent-token-limit-#{index}"}
            )
          end)
        end

      results = Task.await_many(tasks, 15_000)

      assert Enum.count(results, &match?({:ok, _reserved}, &1)) == 1

      assert Enum.count(
               results,
               &match?({:error, %{code: :api_key_policy_limit_exceeded}}, &1)
             ) == 1

      assert Repo.aggregate(
               from(e in LedgerEntry,
                 where:
                   e.api_key_id == ^setup.api_key.id and e.entry_kind == "reservation" and
                     e.amount_status == "recorded"
               ),
               :count
             ) == 1

      window_usage =
        setup.api_key.id
        |> LedgerEntries.window_usages(daily: DateTime.add(DateTime.utc_now(), -1, :day))
        |> Map.fetch!(:daily)

      assert window_usage.effective_total_tokens == 512
    end

    test "concurrent request limits serialize so two over-limit reservations cannot both succeed" do
      setup = accounting_setup()
      parent = self()

      update_default_policy!(setup.api_key, %{
        max_requests_per_minute: 1,
        max_tokens_per_day: 1_000,
        max_tokens_per_week: 10_000
      })

      tasks =
        for index <- 1..2 do
          Task.async(fn ->
            Sandbox.allow(Repo, parent, self())

            Accounting.reserve(
              setup.auth,
              setup.model,
              %{"model" => setup.model.exposed_model_id, "max_output_tokens" => 1},
              %{correlation_id: "corr-concurrent-limit-#{index}"}
            )
          end)
        end

      results = Task.await_many(tasks, 15_000)

      assert Enum.count(results, &match?({:ok, _reserved}, &1)) == 1

      assert Enum.count(
               results,
               &match?({:error, %{code: :api_key_policy_limit_exceeded}}, &1)
             ) == 1

      assert Repo.aggregate(
               from(e in LedgerEntry,
                 where:
                   e.api_key_id == ^setup.api_key.id and e.entry_kind == "reservation" and
                     e.amount_status == "recorded"
               ),
               :count
             ) == 1
    end

    test "concurrent model policy reservations serialize through the same lock-time policy row" do
      setup = accounting_setup()
      parent = self()

      update_default_policy!(setup.api_key, %{
        max_requests_per_minute: 60,
        max_tokens_per_day: 10_000,
        max_tokens_per_week: 10_000
      })

      insert_model_policy!(setup.api_key, setup.model.exposed_model_id, %{
        max_requests_per_minute: 60,
        max_tokens_per_day: 512,
        max_tokens_per_week: 10_000
      })

      tasks =
        for index <- 1..2 do
          Task.async(fn ->
            Sandbox.allow(Repo, parent, self())

            Accounting.reserve(
              setup.auth,
              setup.model,
              %{"model" => String.upcase(setup.model.exposed_model_id), "max_output_tokens" => 1},
              %{correlation_id: "corr-concurrent-model-policy-#{index}"}
            )
          end)
        end

      results = Task.await_many(tasks, 15_000)

      assert Enum.count(results, &match?({:ok, _reserved}, &1)) == 1

      assert [error] =
               Enum.flat_map(results, fn
                 {:error, error} -> [error]
                 {:ok, _reserved} -> []
               end)

      assert error.code == :api_key_policy_limit_exceeded
      assert error.message =~ "max_tokens_per_day"

      assert Repo.aggregate(
               from(e in LedgerEntry,
                 where:
                   e.api_key_id == ^setup.api_key.id and e.entry_kind == "reservation" and
                     e.amount_status == "recorded"
               ),
               :count
             ) == 1
    end
  end

  defp insert_model_policy!(api_key, model_identifier, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %APIKeyPolicyBinding{
      api_key_id: api_key.id,
      binding_scope: "model",
      model_identifier: model_identifier,
      status: Map.get(attrs, :status, "active"),
      max_requests_per_minute: Map.get(attrs, :max_requests_per_minute),
      max_tokens_per_day: Map.get(attrs, :max_tokens_per_day),
      max_tokens_per_week: Map.get(attrs, :max_tokens_per_week),
      max_input_tokens_per_request: Map.get(attrs, :max_input_tokens_per_request),
      max_output_tokens_per_request: Map.get(attrs, :max_output_tokens_per_request),
      created_at: now,
      updated_at: now
    }
    |> Repo.insert!()
  end

  defp capture_repo_queries(fun) do
    parent = self()
    handler_id = "api-key-policy-reservation-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata[:repo] == Repo do
            send(
              parent,
              {handler_id, metadata[:source], command_name(metadata[:query]), metadata[:query]}
            )
          end
        end,
        nil
      )

    try do
      result = fun.()
      {result, drain_repo_queries(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_repo_queries(handler_id, queries) do
    receive do
      {^handler_id, source, command, query} ->
        drain_repo_queries(handler_id, [
          %{source: source, command: command, query: query} | queries
        ])
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp table_commands(queries, source, command) do
    Enum.filter(queries, &(&1.source == source and &1.command == command))
  end

  defp command_count(queries, source, command),
    do: length(table_commands(queries, source, command))

  defp command_name(query) when is_binary(query) do
    query
    |> String.trim_leading()
    |> String.split(~r/\s+/, parts: 2)
    |> List.first()
    |> String.upcase()
  end

  defp command_name(_query), do: nil
end
