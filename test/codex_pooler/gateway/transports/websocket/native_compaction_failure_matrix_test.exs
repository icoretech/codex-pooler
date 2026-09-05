defmodule CodexPooler.Gateway.Transports.Websocket.NativeCompactionFailureMatrixTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Gateway.Transports.NativeCompactionFailureScenarios, as: Scenarios
  alias Scenarios.{AccountingLifecycle, Context, Observed, Row}

  test "forwarded timeout preserves its outcome and releases its owner without warnings",
       context do
    row = Enum.find(Scenarios.rows(), &(&1.id == :owner_timeout))

    {observed, logs} =
      ExUnit.CaptureLog.with_log(fn ->
        Scenarios.run!(row, Scenarios.context(context, row))
      end)

    assert_required_observables(observed, row.expected)
    assert logs == ""
  end

  test "registry is complete, unique, callable, and backed by real observations", context do
    rows = Scenarios.rows()

    assert :ok = Scenarios.assert_complete!(rows)
    assert Enum.sort(Enum.map(rows, & &1.id)) == Enum.sort(Scenarios.required_row_ids())
    assert Enum.all?(rows, &match?(%Row{}, &1))

    Enum.each(rows, fn %Row{} = row ->
      observed = Scenarios.run!(row, Scenarios.context(context, row))

      assert %Observed{} = observed
      assert_required_observables(observed, row.expected)
    end)
  end

  test "provider observations are independent from locally changed expectations", context do
    row = Enum.find(Scenarios.rows(), &(&1.id == :routing_denial))
    observed = Scenarios.run!(row, Scenarios.context(context, row))

    changed_expected = %{
      row.expected
      | admission_phase: :unexpected_phase,
        upstream_send_count: row.expected.upstream_send_count + 99,
        owner_fate: :retired
    }

    changed_row = %{row | expected: changed_expected}
    changed_observed = Scenarios.run!(changed_row, Scenarios.context(context, changed_row))

    assert changed_observed == observed
    refute changed_observed == changed_expected
  end

  test "registry rejects missing, duplicate, non-callable, and malformed provider contracts" do
    [row | rest] = Scenarios.rows()

    assert_raise ArgumentError, ~r/registry is incomplete/, fn ->
      Scenarios.assert_complete!(rest)
    end

    assert_raise ArgumentError, ~r/duplicate ids/, fn ->
      Scenarios.assert_complete!([row, row | rest])
    end

    missing_provider = %{row | provider: {__MODULE__.MissingProvider, :run}}

    assert_raise ArgumentError, ~r/provider is not callable/, fn ->
      Scenarios.run!(missing_provider, %Context{
        test_pid: self(),
        scenario_namespace: "missing-provider"
      })
    end

    malformed = %Observed{
      admission_phase: :cleared,
      upstream_send_count: 0,
      accounting_lifecycle: %AccountingLifecycle{
        requests: 0,
        attempts: 0,
        turns: 0,
        reservations: 0,
        settlements: -1
      },
      owner_fate: :survived
    }

    assert_raise ArgumentError, ~r/invalid accounting delta/, fn ->
      Scenarios.validate_observed!(malformed)
    end
  end

  defp assert_required_observables(%Observed{} = observed, %Observed{} = expected) do
    assert observed.admission_phase == expected.admission_phase
    assert observed.upstream_send_count == expected.upstream_send_count
    assert observed.accounting_lifecycle == expected.accounting_lifecycle
    assert observed.owner_fate == expected.owner_fate
  end
end
