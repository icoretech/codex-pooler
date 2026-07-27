defmodule CodexPooler.Upstreams.Quota.Windows.EvidenceStoreModelWeeklyRestartTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures
  import ExUnit.CaptureLog

  alias CodexPooler.Quotas.{Evidence, ModelWeeklyResetSemantics}
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.WindowSelector
  alias CodexPooler.Upstreams.Quota.Windows
  alias CodexPooler.Upstreams.Quota.Windows.CycleConfirmation
  alias CodexPooler.Upstreams.Quota.Windows.EvidenceStore
  alias CodexPooler.Upstreams.Quota.Windows.Routing

  @window_seconds 10_080 * 60

  defp identity! do
    %{identity: identity} = active_upstream_assignment_fixture(pool_fixture(), %{})
    identity
  end

  defp model_weekly(observed_at, used_percent, opts \\ []) do
    reset_at = Keyword.get(opts, :reset_at, DateTime.add(observed_at, @window_seconds, :second))
    metadata = Keyword.get(opts, :metadata, %{"reset_after_seconds" => @window_seconds})

    %{
      quota_key: "codex_spark",
      window_kind: "secondary",
      window_minutes: 10_080,
      used_percent: Decimal.new(used_percent),
      reset_at: reset_at,
      observed_at: observed_at,
      last_sync_at: observed_at,
      source: "codex_usage_api",
      source_precision: "observed",
      quota_scope: "model",
      quota_family: "codex_model",
      model: "gpt-5.3-codex-spark",
      freshness_state: "fresh",
      metadata: metadata
    }
  end

  defp model_weekly_row(identity) do
    Repo.one(
      from w in AccountQuotaWindow,
        where:
          w.upstream_identity_id == ^identity.id and w.quota_key == "codex_spark" and
            w.window_kind == "secondary" and w.source == "codex_usage_api"
    )
  end

  defp identity_rows(identity) do
    Repo.all(
      from w in AccountQuotaWindow,
        where: w.upstream_identity_id == ^identity.id,
        order_by: [asc: w.id]
    )
  end

  defp persist_literal_window!(id, attrs) do
    changeset =
      %AccountQuotaWindow{id: id}
      |> AccountQuotaWindow.changeset(attrs)

    assert changeset.valid?, inspect(errors_on(changeset))
    Repo.insert!(changeset)
  end

  defp sorted_full_row_maps(identity) do
    schema_fields = AccountQuotaWindow.__schema__(:fields)

    identity
    |> identity_rows()
    |> Enum.map(fn row ->
      row_map = Map.take(row, schema_fields)
      assert Map.keys(row_map) |> Enum.sort() == Enum.sort(schema_fields)
      row_map
    end)
    |> Enum.sort_by(& &1.id)
  end

  defp full_row_snapshot(identity) do
    row_maps = sorted_full_row_maps(identity)
    %{row_maps: row_maps, bytes: :erlang.term_to_binary(row_maps)}
  end

  defp assert_full_row_snapshot_unchanged!(identity, baseline) do
    current = full_row_snapshot(identity)

    assert current.row_maps == baseline.row_maps
    assert current.bytes == baseline.bytes
    current
  end

  defp alias_model_weekly(observed_at, used_percent, opts \\ []) do
    observed_at
    |> model_weekly(used_percent, opts)
    |> Map.merge(%{
      raw_limit_id: "provider-spark-weekly",
      raw_limit_name: "GPT-5.3-Codex-Spark",
      raw_metered_feature: "provider-spark-weekly"
    })
  end

  defp historical_alias_row!(identity, observed_at, used_percent, opts) do
    attrs =
      observed_at
      |> alias_model_weekly(used_percent, opts)
      |> Map.merge(%{
        upstream_identity_id: identity.id,
        quota_key: "gpt_5_3_codex_spark",
        created_at: observed_at,
        updated_at: observed_at
      })

    %AccountQuotaWindow{}
    |> AccountQuotaWindow.changeset(attrs)
    |> Repo.insert!()
  end

  defp spark_weekly_payload(
         used_percent,
         reset_at,
         reset_after_seconds \\ @window_seconds
       ) do
    %{
      "additional_rate_limits" => [
        %{
          "limit_name" => "GPT-5.3-Codex-Spark",
          "metered_feature" => "codex_bengalfox",
          "model" => "gpt-5.3-codex-spark",
          "rate_limit" => %{
            "primary_window" => %{
              "used_percent" => used_percent,
              "limit_window_seconds" => @window_seconds,
              "reset_after_seconds" => reset_after_seconds,
              "reset_at" => DateTime.to_iso8601(reset_at)
            }
          }
        }
      ]
    }
  end

  defp record_spark_payload!(identity, payload, observed_at) do
    [
      %{
        "rate_limit" => rate_limit
      }
    ] = payload["additional_rate_limits"]

    provider_window = rate_limit["primary_window"] || rate_limit["secondary_window"]
    expected_reset_after_seconds = provider_window["reset_after_seconds"]

    expected_limit_window_seconds =
      case provider_window["limit_window_seconds"] do
        seconds when is_integer(seconds) -> seconds
        _absent_or_invalid -> nil
      end

    assert {:ok, windows} = Windows.codex_usage_quota_windows_from_payload(payload, observed_at)

    assert [spark_weekly] =
             Enum.filter(
               windows,
               &(&1.quota_key == "codex_spark" and &1.window_kind == "secondary")
             )

    assert spark_weekly.quota_scope == "model"
    assert spark_weekly.metadata["reset_after_seconds"] == expected_reset_after_seconds

    assert spark_weekly.metadata["limit_window_seconds"] ==
             expected_limit_window_seconds

    assert {:ok, row} =
             EvidenceStore.record_evidence(identity, spark_weekly, observed_at, observed_at)

    row
  end

  defp spark_secondary_payload(used_percent, reset_at, reset_after_seconds, opts \\ []) do
    secondary_window = %{
      "used_percent" => used_percent,
      "reset_after_seconds" => reset_after_seconds,
      "reset_at" => DateTime.to_iso8601(reset_at)
    }

    secondary_window =
      case Keyword.fetch(opts, :limit_window_seconds) do
        {:ok, limit_window_seconds} ->
          Map.put(secondary_window, "limit_window_seconds", limit_window_seconds)

        :error ->
          secondary_window
      end

    %{
      "additional_rate_limits" => [
        %{
          "limit_name" => "GPT-5.3-Codex-Spark",
          "metered_feature" => "codex_bengalfox",
          "model" => "gpt-5.3-codex-spark",
          "rate_limit" => %{"secondary_window" => secondary_window}
        }
      ]
    }
  end

  defp generic_weekly_payload(limit_name, metered_feature, used_percent, reset_at) do
    %{
      "additional_rate_limits" => [
        %{
          "limit_name" => limit_name,
          "metered_feature" => metered_feature,
          "rate_limit" => %{
            "primary_window" => %{
              "used_percent" => used_percent,
              "limit_window_seconds" => @window_seconds,
              "reset_after_seconds" => @window_seconds,
              "reset_at" => DateTime.to_iso8601(reset_at)
            }
          }
        }
      ]
    }
  end

  defp parsed_additional_weekly!(payload, observed_at) do
    assert {:ok, windows} = Windows.codex_usage_quota_windows_from_payload(payload, observed_at)

    assert [weekly] =
             Enum.filter(
               windows,
               &(&1.window_kind == "secondary" and &1.window_minutes == 10_080 and
                   &1.quota_scope == "model")
             )

    weekly
  end

  defp upstream_model_evidence!(parsed, upstream_model, observed_at) when is_map(parsed) do
    parsed
    |> Map.merge(%{
      quota_scope: "upstream_model",
      model: nil,
      upstream_model: upstream_model
    })
    |> Evidence.new(observed_at)
    |> then(fn {:ok, evidence} -> evidence end)
  end

  defp historical_alias_row!(identity, parsed, observed_at) when is_map(parsed) do
    attrs =
      parsed
      |> Map.merge(%{
        upstream_identity_id: identity.id,
        quota_key: "gpt_5_3_codex_spark",
        created_at: observed_at,
        updated_at: observed_at
      })

    %AccountQuotaWindow{}
    |> AccountQuotaWindow.changeset(attrs)
    |> Repo.insert!()
  end

  defp assert_markerless_anchor(row, as_of) do
    assert row.metadata["reset_state"] == "anchored"
    refute Map.has_key?(row.metadata, "__quota_cycle_confirmation_v1")
    assert CycleConfirmation.valid_marker(row) == :none
    refute CycleConfirmation.selector_valid?(row, as_of)
  end

  defp capture_quota_cycle_events(fun) when is_function(fun, 0) do
    parent = self()
    handler_id = "model-weekly-anchor-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :quota, :cycle, :decision],
        &__MODULE__.handle_quota_cycle_event/4,
        {parent, handler_id}
      )

    try do
      result = fun.()
      {result, drain_quota_cycle_events(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_quota_cycle_events(handler_id, events) do
    receive do
      {^handler_id, measurements, metadata} ->
        drain_quota_cycle_events(handler_id, [{measurements, metadata} | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  def handle_quota_cycle_event(_event, measurements, metadata, {parent, handler_id}) do
    send(parent, {handler_id, measurements, metadata})
  end

  defp parsed_floating_model!(identity, t0) do
    for offset <- [0, 60, 300] do
      observed_at = DateTime.add(t0, offset, :second)

      record_spark_payload!(
        identity,
        spark_weekly_payload(0, DateTime.add(observed_at, @window_seconds, :second)),
        observed_at
      )
    end

    row = model_weekly_row(identity)
    assert row.metadata["reset_state"] == "floating"
    row
  end

  defp fixed_countdown_payload(reset_at, observed_at, opts \\ []) do
    reset_after_seconds = DateTime.diff(reset_at, observed_at, :second)

    spark_weekly_payload(
      Keyword.get(opts, :used_percent, 0),
      reset_at,
      reset_after_seconds
    )
  end

  defp accepted_floating_model!(identity, t0) do
    assert {:ok, _row} =
             EvidenceStore.record_evidence(identity, model_weekly(t0, "0"), t0, t0)

    candidate_at = DateTime.add(t0, 60, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(candidate_at, "0"),
               candidate_at,
               candidate_at
             )

    accepted_at = DateTime.add(candidate_at, 4, :minute)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(accepted_at, "0"),
               accepted_at,
               accepted_at
             )

    row = model_weekly_row(identity)
    assert row.metadata["reset_state"] == "floating"
    row
  end

  defp runtime_model_weekly(observed_at, used_percent, reset_at) do
    observed_at
    |> model_weekly(used_percent, reset_at: reset_at, metadata: %{})
    |> Map.merge(%{
      source: "codex_response_headers",
      raw_limit_id: nil,
      raw_limit_name: nil,
      raw_metered_feature: nil
    })
  end

  defp account_weekly(observed_at, used_percent) do
    observed_at
    |> model_weekly(used_percent)
    |> Map.merge(%{
      quota_key: "account",
      quota_scope: "account",
      quota_family: "account",
      model: nil
    })
  end

  defp assert_qf001_persistence!(insert_order, future_id, future_raw_limit_id) do
    as_of = ~U[2026-07-25 12:00:00.000000Z]
    identity = identity!()

    explicit_floating_attrs = %{
      upstream_identity_id: identity.id,
      quota_key: "codex_spark",
      window_kind: "secondary",
      window_minutes: 10_080,
      active_limit: nil,
      credits: nil,
      reset_at: ~U[2026-08-01 12:00:00.000000Z],
      used_percent: Decimal.new("0"),
      display_label: "GPT-5.3-Codex-Spark",
      limit_name: "gpt-5.3-codex-spark",
      metered_feature: "codex_spark",
      source: "codex_usage_api",
      source_precision: "observed",
      quota_scope: "model",
      quota_family: "codex_model",
      model: "gpt-5.3-codex-spark",
      upstream_model: nil,
      raw_limit_id: "qf001-usage",
      raw_limit_name: "gpt-5.3-codex-spark",
      raw_metered_feature: "codex_spark",
      freshness_state: "fresh",
      last_sync_at: ~U[2026-07-25 11:59:00.000000Z],
      observed_at: ~U[2026-07-25 11:59:00.000000Z],
      merge_precedence: 60,
      metadata: %{"reset_state" => "floating"},
      created_at: ~U[2026-07-25 11:59:00.000000Z],
      updated_at: ~U[2026-07-25 11:59:00.000000Z]
    }

    markerless_header_attrs = %{
      upstream_identity_id: identity.id,
      quota_key: "codex_spark",
      window_kind: "secondary",
      window_minutes: 10_080,
      active_limit: nil,
      credits: nil,
      reset_at: ~U[2026-08-01 12:30:00.000000Z],
      used_percent: Decimal.new("0"),
      display_label: "GPT-5.3-Codex-Spark",
      limit_name: "gpt-5.3-codex-spark",
      metered_feature: "codex_spark",
      source: "codex_response_headers",
      source_precision: "observed",
      quota_scope: "model",
      quota_family: "codex_model",
      model: "gpt-5.3-codex-spark",
      upstream_model: nil,
      raw_limit_id: "qf001-header",
      raw_limit_name: "gpt-5.3-codex-spark",
      raw_metered_feature: "codex_spark",
      freshness_state: "fresh",
      last_sync_at: ~U[2026-07-25 11:59:30.000000Z],
      observed_at: ~U[2026-07-25 11:59:30.000000Z],
      merge_precedence: 80,
      metadata: %{},
      created_at: ~U[2026-07-25 11:59:30.000000Z],
      updated_at: ~U[2026-07-25 11:59:30.000000Z]
    }

    future_boundary_attrs = %{
      upstream_identity_id: identity.id,
      quota_key: "codex_spark",
      window_kind: "secondary",
      window_minutes: 10_080,
      active_limit: nil,
      credits: nil,
      reset_at: ~U[2026-08-02 12:00:00.000001Z],
      used_percent: Decimal.new("100"),
      display_label: "GPT-5.3-Codex-Spark",
      limit_name: "gpt-5.3-codex-spark",
      metered_feature: "codex_spark",
      source: "codex_usage_api",
      source_precision: "observed",
      quota_scope: "model",
      quota_family: "codex_model",
      model: "gpt-5.3-codex-spark",
      upstream_model: nil,
      raw_limit_id: future_raw_limit_id,
      raw_limit_name: "gpt-5.3-codex-spark",
      raw_metered_feature: "codex_spark",
      freshness_state: "fresh",
      last_sync_at: ~U[2026-07-25 12:00:00.000001Z],
      observed_at: ~U[2026-07-25 12:00:00.000001Z],
      merge_precedence: 100,
      metadata: %{"reset_state" => "anchored"},
      created_at: ~U[2026-07-25 12:00:00.000001Z],
      updated_at: ~U[2026-07-25 12:00:00.000001Z]
    }

    row_specs = %{
      explicit_floating: %{
        id: "10000000-0000-4000-8000-000000000001",
        attrs: explicit_floating_attrs
      },
      markerless_header: %{
        id: "ffffffff-ffff-4fff-bfff-ffffffffffff",
        attrs: markerless_header_attrs
      }
    }

    assert insert_order in [
             [:explicit_floating, :markerless_header],
             [:markerless_header, :explicit_floating]
           ]

    persisted_rows =
      Enum.reduce(insert_order, %{}, fn row_name, rows ->
        %{id: id, attrs: attrs} = Map.fetch!(row_specs, row_name)
        Map.put(rows, row_name, persist_literal_window!(id, attrs))
      end)

    explicit_floating = Map.fetch!(persisted_rows, :explicit_floating)
    markerless_header = Map.fetch!(persisted_rows, :markerless_header)
    future_boundary = persist_literal_window!(future_id, future_boundary_attrs)

    assert Map.take(explicit_floating, Map.keys(explicit_floating_attrs)) ==
             explicit_floating_attrs

    assert Map.take(markerless_header, Map.keys(markerless_header_attrs)) ==
             markerless_header_attrs

    assert Map.take(future_boundary, Map.keys(future_boundary_attrs)) == future_boundary_attrs
    assert explicit_floating.id != markerless_header.id

    assert WindowSelector.logical_key(explicit_floating) ==
             WindowSelector.logical_key(markerless_header)

    assert WindowSelector.logical_key(explicit_floating) ==
             WindowSelector.logical_key(future_boundary)

    assert ModelWeeklyResetSemantics.classify(explicit_floating) == :floating
    assert ModelWeeklyResetSemantics.classify(markerless_header) == :unknown
    assert ModelWeeklyResetSemantics.classify(future_boundary) == :anchored
    assert explicit_floating.metadata == %{"reset_state" => "floating"}
    assert markerless_header.metadata == %{}
    assert future_boundary.metadata == %{"reset_state" => "anchored"}
    assert future_boundary.observed_at == ~U[2026-07-25 12:00:00.000001Z]

    assert [future_winner] =
             WindowSelector.logical_windows(
               [explicit_floating, markerless_header, future_boundary],
               future_boundary.observed_at
             )

    assert future_winner.id == future_boundary.id

    baseline = full_row_snapshot(identity)

    expected_physical_ids =
      [
        "10000000-0000-4000-8000-000000000001",
        future_id,
        "ffffffff-ffff-4fff-bfff-ffffffffffff"
      ]
      |> Enum.sort()

    assert Enum.map(baseline.row_maps, & &1.id) == expected_physical_ids
    assert length(baseline.row_maps) == 3

    assert Enum.find(baseline.row_maps, &(&1.id == explicit_floating.id)).metadata == %{
             "reset_state" => "floating"
           }

    assert Enum.find(baseline.row_maps, &(&1.id == markerless_header.id)).metadata == %{}

    assert Enum.find(baseline.row_maps, &(&1.id == future_boundary.id)).metadata == %{
             "reset_state" => "anchored"
           }

    assert [effective_winner] = Windows.list_quota_windows(identity, as_of)
    assert effective_winner.id == explicit_floating.id
    refute effective_winner.id == future_boundary.id
    after_list = assert_full_row_snapshot_unchanged!(identity, baseline)
    assert length(after_list.row_maps) == 3

    selection = Windows.quota_window_selection_data(identity, at: as_of)

    assert [selection_winner] = selection.routing_windows
    assert selection_winner.id == explicit_floating.id
    refute Enum.any?(selection.routing_windows, &(&1.id == future_boundary.id))
    assert Enum.map(selection.windows, & &1.id) |> Enum.sort() == expected_physical_ids
    after_selection = assert_full_row_snapshot_unchanged!(identity, baseline)
    assert length(after_selection.row_maps) == 3

    assert [both_cycle_winner] = Windows.list_quota_windows(identity, as_of)
    both_cycle_selection = Windows.quota_window_selection_data(identity, at: as_of)

    assert both_cycle_winner.id == explicit_floating.id
    assert [both_cycle_selection_winner] = both_cycle_selection.routing_windows
    assert both_cycle_selection_winner.id == explicit_floating.id
    refute Enum.any?(both_cycle_selection.routing_windows, &(&1.id == future_boundary.id))

    assert Enum.map(both_cycle_selection.windows, & &1.id) |> Enum.sort() ==
             expected_physical_ids

    after_both = assert_full_row_snapshot_unchanged!(identity, baseline)
    assert Enum.map(after_both.row_maps, & &1.id) == expected_physical_ids
    assert length(after_both.row_maps) == 3
  end

  test "QF-001 explicit floating then markerless preserves rows and selects floating" do
    assert_qf001_persistence!(
      [:explicit_floating, :markerless_header],
      "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee1",
      "qf001-future-explicit-first"
    )
  end

  test "QF-001 markerless then explicit floating preserves rows and selects floating" do
    assert_qf001_persistence!(
      [:markerless_header, :explicit_floating],
      "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee2",
      "qf001-future-markerless-first"
    )
  end

  test "persisted controls retain model weekly semantics and canonical alias selection" do
    as_of = ~U[2026-07-25 12:00:00.000000Z]
    identity = identity!()

    markerless_positive =
      persist_literal_window!(Ecto.UUID.generate(), %{
        upstream_identity_id: identity.id,
        quota_key: "codex_bengalfox",
        window_kind: "secondary",
        window_minutes: 10_080,
        active_limit: nil,
        credits: nil,
        reset_at: ~U[2026-08-01 13:00:00.000000Z],
        used_percent: Decimal.new("25"),
        display_label: "Spark model alias",
        limit_name: "spark-model-alias",
        metered_feature: "codex_bengalfox",
        source: "codex_usage_api",
        source_precision: "observed",
        quota_scope: "model",
        quota_family: "legacy-model-family",
        model: "legacy-model-alias",
        upstream_model: nil,
        raw_limit_id: "control-model-positive",
        raw_limit_name: "legacy-model-alias",
        raw_metered_feature: "codex_bengalfox",
        freshness_state: "fresh",
        last_sync_at: ~U[2026-07-25 11:58:00.000000Z],
        observed_at: ~U[2026-07-25 11:58:00.000000Z],
        merge_precedence: 60,
        metadata: %{},
        created_at: ~U[2026-07-25 11:58:00.000000Z],
        updated_at: ~U[2026-07-25 11:58:00.000000Z]
      })

    malformed_unknown =
      persist_literal_window!(Ecto.UUID.generate(), %{
        upstream_identity_id: identity.id,
        quota_key: "gpt_5_3_codex_spark",
        window_kind: "secondary",
        window_minutes: 10_080,
        active_limit: nil,
        credits: nil,
        reset_at: ~U[2026-08-01 13:30:00.000000Z],
        used_percent: Decimal.new("0"),
        display_label: "Spark upstream-model alias",
        limit_name: "spark-upstream-model-alias",
        metered_feature: "gpt_5_3_codex_spark",
        source: "codex_response_headers",
        source_precision: "observed",
        quota_scope: "upstream_model",
        quota_family: "legacy-upstream-model-family",
        model: nil,
        upstream_model: "gpt-5.3-codex-spark",
        raw_limit_id: "control-upstream-model-unknown",
        raw_limit_name: "gpt-5.3-codex-spark",
        raw_metered_feature: "gpt_5_3_codex_spark",
        freshness_state: "fresh",
        last_sync_at: ~U[2026-07-25 11:58:30.000000Z],
        observed_at: ~U[2026-07-25 11:58:30.000000Z],
        merge_precedence: 80,
        metadata: %{"reset_state" => "malformed"},
        created_at: ~U[2026-07-25 11:58:30.000000Z],
        updated_at: ~U[2026-07-25 11:58:30.000000Z]
      })

    assert ModelWeeklyResetSemantics.classify(markerless_positive) == :anchored
    assert ModelWeeklyResetSemantics.classify(malformed_unknown) == :unknown

    assert WindowSelector.logical_key(markerless_positive) ==
             {"model", "codex_model", "gpt-5.3-codex-spark", nil, "codex_spark", "secondary",
              10_080}

    assert WindowSelector.logical_key(malformed_unknown) ==
             {"upstream_model", "codex_model", nil, "gpt-5.3-codex-spark", "codex_spark",
              "secondary", 10_080}

    baseline = full_row_snapshot(identity)
    expected_physical_ids = Enum.sort([markerless_positive.id, malformed_unknown.id])

    assert Enum.map(baseline.row_maps, & &1.id) == expected_physical_ids
    assert length(baseline.row_maps) == 2

    effective = Windows.list_quota_windows(identity, as_of)
    assert Enum.map(effective, & &1.id) |> Enum.sort() == expected_physical_ids
    after_list = assert_full_row_snapshot_unchanged!(identity, baseline)
    assert length(after_list.row_maps) == 2

    selection = Windows.quota_window_selection_data(identity, at: as_of)

    assert Enum.map(selection.routing_windows, & &1.id) |> Enum.sort() ==
             expected_physical_ids

    assert Enum.map(selection.windows, & &1.id) |> Enum.sort() == expected_physical_ids
    after_selection = assert_full_row_snapshot_unchanged!(identity, baseline)
    assert length(after_selection.row_maps) == 2

    both_cycle_effective = Windows.list_quota_windows(identity, as_of)
    both_cycle_selection = Windows.quota_window_selection_data(identity, at: as_of)

    assert Enum.map(both_cycle_effective, & &1.id) |> Enum.sort() == expected_physical_ids

    assert Enum.map(both_cycle_selection.routing_windows, & &1.id) |> Enum.sort() ==
             expected_physical_ids

    assert Enum.map(both_cycle_selection.windows, & &1.id) |> Enum.sort() ==
             expected_physical_ids

    after_both = assert_full_row_snapshot_unchanged!(identity, baseline)
    assert length(after_both.row_maps) == 2
    assert Enum.find(after_both.row_maps, &(&1.id == markerless_positive.id)).metadata == %{}

    assert Enum.find(after_both.row_maps, &(&1.id == malformed_unknown.id)).metadata == %{
             "reset_state" => "malformed"
           }
  end

  test "initial positive account evidence keeps the existing markerless reset-state behavior" do
    observed_at = ~U[2026-07-25 03:00:00Z]
    identity = identity!()

    assert {:ok, row} =
             EvidenceStore.record_evidence(
               identity,
               account_weekly(observed_at, "64"),
               observed_at,
               observed_at
             )

    refute Map.has_key?(row.metadata, "reset_state")
    refute Map.has_key?(row.metadata, "__quota_cycle_confirmation_v1")
    assert CycleConfirmation.valid_marker(row) == :none
    refute CycleConfirmation.selector_valid?(row, observed_at)
  end

  test "parser evidence resolves each model weekly identity to one canonical anchored row" do
    observed_at = ~U[2026-07-25 03:10:00Z]
    reset_at = DateTime.add(observed_at, @window_seconds, :second)

    spark =
      parsed_additional_weekly!(spark_weekly_payload(64, reset_at), observed_at)

    generic =
      parsed_additional_weekly!(
        generic_weekly_payload(
          "Example Weekly Model",
          "example_weekly_meter",
          100,
          reset_at
        ),
        observed_at
      )

    upstream_model =
      generic
      |> upstream_model_evidence!("provider-example-weekly-model", observed_at)

    for {evidence, expected} <- [
          {spark,
           %{
             quota_key: "codex_spark",
             quota_scope: "model",
             model: "gpt-5.3-codex-spark",
             upstream_model: nil
           }},
          {generic,
           %{
             quota_key: "example_weekly_model",
             quota_scope: "model",
             model: "Example Weekly Model",
             upstream_model: nil
           }},
          {upstream_model,
           %{
             quota_key: "example_weekly_model",
             quota_scope: "upstream_model",
             model: nil,
             upstream_model: "provider-example-weekly-model"
           }}
        ] do
      identity = identity!()

      assert {:ok, row} =
               EvidenceStore.record_evidence(identity, evidence, observed_at, observed_at)

      assert [persisted] = identity_rows(identity)
      assert persisted.id == row.id
      assert persisted.quota_key == expected.quota_key
      assert persisted.quota_scope == expected.quota_scope
      assert persisted.model == expected.model
      assert persisted.upstream_model == expected.upstream_model
      assert_markerless_anchor(persisted, observed_at)
    end

    alias_identity = identity!()
    historical_alias = historical_alias_row!(alias_identity, spark, observed_at)
    canonical_at = DateTime.add(observed_at, 60, :second)

    canonical_spark =
      parsed_additional_weekly!(
        spark_weekly_payload(70, reset_at, @window_seconds - 60),
        canonical_at
      )

    assert {:ok, canonical_row} =
             EvidenceStore.record_evidence(
               alias_identity,
               canonical_spark,
               canonical_at,
               canonical_at
             )

    assert canonical_row.id == historical_alias.id
    assert [persisted_alias] = identity_rows(alias_identity)
    assert persisted_alias.id == canonical_row.id
    assert persisted_alias.quota_key == "codex_spark"
    assert persisted_alias.quota_scope == "model"
    assert persisted_alias.model == "gpt-5.3-codex-spark"
    assert_markerless_anchor(persisted_alias, canonical_at)
  end

  test "an accepted floating Spark row rebases only after a persisted moving candidate confirms" do
    t0 = ~U[2026-07-19 12:01:16Z]
    identity = identity!()
    accepted = accepted_floating_model!(identity, t0)
    old_provider_watermark = accepted.metadata["__quota_relative_liveness_v1"]

    candidate_at = ~U[2026-07-21 12:10:00Z]
    candidate_provider_at = DateTime.add(candidate_at, -10, :minute)
    candidate_reset = DateTime.add(candidate_provider_at, @window_seconds, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(candidate_at, "0", reset_at: candidate_reset),
               candidate_at,
               candidate_at
             )

    pending = model_weekly_row(identity)

    assert {:ok, candidate} = EvidenceStore.parse_candidate(pending.metadata)

    assert DateTime.compare(candidate.observed_at, candidate_at) == :eq
    assert DateTime.compare(candidate.reset_at, candidate_reset) == :eq
    assert DateTime.compare(pending.reset_at, accepted.reset_at) == :eq
    assert DateTime.compare(pending.observed_at, accepted.observed_at) == :eq
    assert pending.metadata["__quota_relative_liveness_v1"] == old_provider_watermark
    refute Map.has_key?(pending.metadata, "__quota_cycle_confirmation_v1")

    confirmed_at = DateTime.add(candidate_at, 4, :minute)
    confirmed_provider_at = DateTime.add(candidate_provider_at, 4, :minute)
    confirmed_reset = DateTime.add(confirmed_provider_at, @window_seconds, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(confirmed_at, "0", reset_at: confirmed_reset),
               confirmed_at,
               confirmed_at
             )

    rebased = model_weekly_row(identity)
    assert rebased.metadata["reset_state"] == "floating"
    assert :none = EvidenceStore.parse_candidate(rebased.metadata)
    assert DateTime.compare(rebased.reset_at, confirmed_reset) == :eq
    assert DateTime.compare(rebased.observed_at, confirmed_at) == :eq
    assert DateTime.compare(rebased.last_sync_at, confirmed_at) == :eq
    assert rebased.freshness_state == "fresh"
    refute Map.has_key?(rebased.metadata, "__quota_cycle_confirmation_v1")

    assert rebased.metadata["__quota_relative_liveness_v1"] ==
             DateTime.to_iso8601(confirmed_provider_at)
  end

  test "an old-anchor runtime observation does not erase a floating rebase candidate" do
    t0 = ~U[2026-07-19 12:01:16Z]
    identity = identity!()
    accepted = accepted_floating_model!(identity, t0)
    candidate_at = ~U[2026-07-21 12:10:00Z]
    candidate_provider_at = DateTime.add(candidate_at, -10, :minute)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(candidate_at, "0",
                 reset_at: DateTime.add(candidate_provider_at, @window_seconds, :second)
               ),
               candidate_at,
               candidate_at
             )

    runtime_at = DateTime.add(candidate_at, 60, :second)

    assert {:ok, runtime_row} =
             EvidenceStore.record_evidence(
               identity,
               runtime_model_weekly(runtime_at, "12", accepted.reset_at),
               runtime_at,
               runtime_at
             )

    assert runtime_row.source == "codex_response_headers"
    assert {:ok, candidate} = EvidenceStore.parse_candidate(model_weekly_row(identity).metadata)
    assert DateTime.compare(candidate.observed_at, candidate_at) == :eq

    confirmed_at = DateTime.add(candidate_at, 4, :minute)
    confirmed_provider_at = DateTime.add(candidate_provider_at, 4, :minute)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(confirmed_at, "0",
                 reset_at: DateTime.add(confirmed_provider_at, @window_seconds, :second)
               ),
               confirmed_at,
               confirmed_at
             )

    rebased = model_weekly_row(identity)
    assert rebased.metadata["reset_state"] == "floating"
    assert :none = EvidenceStore.parse_candidate(rebased.metadata)

    assert DateTime.compare(
             rebased.reset_at,
             DateTime.add(confirmed_provider_at, @window_seconds)
           ) ==
             :eq
  end

  test "positive Spark evidence anchors a floating row and clears its rebase candidate" do
    t0 = ~U[2026-07-19 12:01:16Z]
    identity = identity!()
    accepted_floating_model!(identity, t0)
    candidate_at = ~U[2026-07-21 12:10:00Z]
    candidate_provider_at = DateTime.add(candidate_at, -10, :minute)
    candidate_reset = DateTime.add(candidate_provider_at, @window_seconds, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(candidate_at, "0", reset_at: candidate_reset),
               candidate_at,
               candidate_at
             )

    assert {:ok, _candidate} = EvidenceStore.parse_candidate(model_weekly_row(identity).metadata)

    positive_at = DateTime.add(candidate_at, 60, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(positive_at, "2", reset_at: candidate_reset, metadata: %{}),
               positive_at,
               positive_at
             )

    anchored = model_weekly_row(identity)
    assert Decimal.equal?(anchored.used_percent, Decimal.new("2"))
    assert DateTime.compare(anchored.reset_at, candidate_reset) == :eq
    assert DateTime.compare(anchored.observed_at, positive_at) == :eq
    assert anchored.metadata["reset_state"] == "anchored"
    assert :none = EvidenceStore.parse_candidate(anchored.metadata)
    refute Map.has_key?(anchored.metadata, "__quota_cycle_confirmation_v1")
    assert CycleConfirmation.valid_marker(anchored) == :none
    refute CycleConfirmation.selector_valid?(anchored, positive_at)
  end

  test "cached, older, future, and malformed timing cannot rebase a floating Spark row" do
    t0 = ~U[2026-07-19 12:01:16Z]

    for invalid_case <- [:cached, :older, :future, :malformed] do
      identity = identity!()
      accepted = accepted_floating_model!(identity, t0)
      observed_at = ~U[2026-07-21 12:10:00Z]

      invalid_evidence =
        case invalid_case do
          :cached ->
            model_weekly(observed_at, "0", reset_at: accepted.reset_at)

          :older ->
            model_weekly(observed_at, "0",
              reset_at: DateTime.add(accepted.reset_at, -60, :second)
            )

          :future ->
            model_weekly(observed_at, "0",
              reset_at: DateTime.add(observed_at, @window_seconds + 10 * 60, :second)
            )

          :malformed ->
            model_weekly(observed_at, "0", metadata: %{"reset_after_seconds" => "bad"})
        end

      assert {:ok, _row} =
               EvidenceStore.record_evidence(
                 identity,
                 invalid_evidence,
                 observed_at,
                 observed_at
               )

      unchanged = model_weekly_row(identity)
      assert DateTime.compare(unchanged.reset_at, accepted.reset_at) == :eq
      assert DateTime.compare(unchanged.observed_at, accepted.observed_at) == :eq
      assert unchanged.metadata["reset_state"] == "floating"
      assert :none = EvidenceStore.parse_candidate(unchanged.metadata)
    end
  end

  test "sliding model weekly zeros become explicitly floating after confirmation" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    stale_reset = DateTime.add(t0, 3, :day)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(t0, "0", reset_at: stale_reset, metadata: %{}),
               t0,
               t0
             )

    t1 = DateTime.add(t0, 300, :second)
    assert {:ok, _row} = Windows.record_evidence(identity, model_weekly(t1, "0"), t1)

    row = model_weekly_row(identity)
    assert DateTime.compare(row.reset_at, stale_reset) == :eq
    refute row.metadata["reset_state"] == "floating"

    t2 = DateTime.add(t1, 240, :second)
    assert {:ok, _row} = Windows.record_evidence(identity, model_weekly(t2, "0"), t2)

    row = model_weekly_row(identity)
    assert row.metadata["reset_state"] == "floating"
    assert Decimal.equal?(row.used_percent, Decimal.new("0"))
    assert DateTime.compare(row.reset_at, DateTime.add(t2, @window_seconds, :second)) == :eq
    assert DateTime.compare(row.observed_at, t2) == :eq
  end

  test "confirmed floating model weekly zero clears prior-cycle usage" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    stale_reset = DateTime.add(t0, 3, :day)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(t0, "64", reset_at: stale_reset, metadata: %{}),
               t0,
               t0
             )

    t1 = DateTime.add(t0, 300, :second)
    assert {:ok, _row} = Windows.record_evidence(identity, model_weekly(t1, "0"), t1)
    t2 = DateTime.add(t1, 240, :second)
    assert {:ok, _row} = Windows.record_evidence(identity, model_weekly(t2, "0"), t2)

    row = model_weekly_row(identity)
    assert row.metadata["reset_state"] == "floating"
    assert Decimal.equal?(row.used_percent, Decimal.new("0"))
  end

  test "a model restart candidate older than newer positive usage cannot clear it" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()

    assert {:ok, _row} =
             Windows.record_evidence(identity, model_weekly(t0, "64"), t0)

    candidate_at = DateTime.add(t0, 60, :second)

    assert {:ok, _row} =
             Windows.record_evidence(
               identity,
               model_weekly(candidate_at, "0"),
               candidate_at
             )

    newer_positive_at = DateTime.add(t0, 120, :second)

    resetless_positive =
      newer_positive_at
      |> model_weekly("80")
      |> Map.put(:reset_at, nil)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               resetless_positive,
               newer_positive_at,
               newer_positive_at
             )

    positive_row = model_weekly_row(identity)
    refute Map.has_key?(positive_row.metadata, "__quota_confirmed_candidate_v1")
    refute Map.has_key?(positive_row.metadata, "__quota_relative_candidate_liveness_v1")

    confirmation_at = DateTime.add(candidate_at, 240, :second)

    assert {:ok, _row} =
             Windows.record_evidence(
               identity,
               model_weekly(confirmation_at, "0"),
               confirmation_at
             )

    row = model_weekly_row(identity)
    assert Decimal.equal?(row.used_percent, Decimal.new("80"))
    assert DateTime.compare(row.observed_at, newer_positive_at) == :eq
  end

  test "a first model positive without provider timing blocks provider-older restart candidates" do
    positive_at =
      DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)

    identity = identity!()

    positive = model_weekly(positive_at, "70", metadata: %{})

    assert {:ok, _row} =
             EvidenceStore.record_evidence(identity, positive, positive_at, positive_at)

    for {provider_delta, observed_delta} <- [{-300, 60}, {-60, 300}] do
      provider_at = DateTime.add(positive_at, provider_delta, :second)
      observed_at = DateTime.add(positive_at, observed_delta, :second)

      assert {:ok, _row} =
               EvidenceStore.record_evidence(
                 identity,
                 model_weekly(observed_at, "0",
                   reset_at: DateTime.add(provider_at, @window_seconds, :second)
                 ),
                 observed_at,
                 observed_at
               )
    end

    row = model_weekly_row(identity)
    assert Decimal.equal?(row.used_percent, Decimal.new("70"))
    assert DateTime.compare(row.observed_at, positive_at) == :eq
    assert row.metadata["__quota_relative_liveness_v1"] == DateTime.to_iso8601(positive_at)
  end

  test "a markerless legacy model positive blocks provider-older restart candidates" do
    positive_at =
      DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)

    identity = identity!()

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(positive_at, "64"),
               positive_at,
               positive_at
             )

    legacy_row = model_weekly_row(identity)

    legacy_row
    |> Ecto.Changeset.change(metadata: %{})
    |> Repo.update!()

    for {provider_delta, observed_delta} <- [{-300, 60}, {-60, 300}] do
      provider_at = DateTime.add(positive_at, provider_delta, :second)
      observed_at = DateTime.add(positive_at, observed_delta, :second)

      assert {:ok, _row} =
               EvidenceStore.record_evidence(
                 identity,
                 model_weekly(observed_at, "0",
                   reset_at: DateTime.add(provider_at, @window_seconds, :second)
                 ),
                 observed_at,
                 observed_at
               )
    end

    row = model_weekly_row(identity)
    assert Decimal.equal?(row.used_percent, Decimal.new("64"))
    assert DateTime.compare(row.observed_at, positive_at) == :eq
    refute Map.has_key?(row.metadata, "__quota_confirmed_candidate_v1")
  end

  test "a first model weekly row with present invalid relative timing is rejected" do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    for reset_after_seconds <- [
          "invalid",
          @window_seconds + 20 * 60,
          @window_seconds - 10 * 60
        ] do
      identity = identity!()

      attrs =
        model_weekly(observed_at, "64", metadata: %{"reset_after_seconds" => reset_after_seconds})

      assert {:error, %{code: :invalid_relative_weekly_timing}} =
               EvidenceStore.record_evidence(identity, attrs, observed_at, observed_at)

      assert model_weekly_row(identity) == nil
    end
  end

  test "an accepted cached model positive cannot rewind the provider watermark" do
    base = DateTime.utc_now() |> DateTime.add(-14, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    canonical_provider_at = DateTime.add(base, 6, :minute)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(canonical_provider_at, "64"),
               canonical_provider_at,
               canonical_provider_at
             )

    cached_positive_at = DateTime.add(base, 7, :minute)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(cached_positive_at, "80",
                 reset_at: DateTime.add(base, @window_seconds, :second)
               ),
               cached_positive_at,
               cached_positive_at
             )

    assert model_weekly_row(identity).metadata["__quota_relative_liveness_v1"] ==
             DateTime.to_iso8601(canonical_provider_at)

    for {provider_delta, observed_delta} <- [{60, 8 * 60}, {5 * 60, 12 * 60}] do
      provider_at = DateTime.add(base, provider_delta, :second)
      observed_at = DateTime.add(base, observed_delta, :second)

      assert {:ok, _row} =
               EvidenceStore.record_evidence(
                 identity,
                 model_weekly(observed_at, "0",
                   reset_at: DateTime.add(provider_at, @window_seconds, :second)
                 ),
                 observed_at,
                 observed_at
               )
    end

    row = model_weekly_row(identity)
    assert Decimal.equal?(row.used_percent, Decimal.new("80"))
    assert DateTime.compare(row.observed_at, cached_positive_at) == :eq

    assert row.metadata["__quota_relative_liveness_v1"] ==
             DateTime.to_iso8601(canonical_provider_at)
  end

  test "a cached model positive cannot rewind a legacy reset-derived provider watermark" do
    base = DateTime.utc_now() |> DateTime.add(-14, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    legacy_provider_at = DateTime.add(base, 6, :minute)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(legacy_provider_at, "64"),
               legacy_provider_at,
               legacy_provider_at
             )

    legacy_row = model_weekly_row(identity)

    legacy_row
    |> Ecto.Changeset.change(
      metadata: Map.delete(legacy_row.metadata, "__quota_relative_liveness_v1")
    )
    |> Repo.update!()

    cached_positive_at = DateTime.add(base, 7, :minute)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(cached_positive_at, "80",
                 reset_at: DateTime.add(base, @window_seconds, :second)
               ),
               cached_positive_at,
               cached_positive_at
             )

    assert model_weekly_row(identity).metadata["__quota_relative_liveness_v1"] ==
             DateTime.to_iso8601(legacy_provider_at)

    for {provider_delta, observed_delta} <- [{60, 8 * 60}, {5 * 60, 12 * 60}] do
      provider_at = DateTime.add(base, provider_delta, :second)
      observed_at = DateTime.add(base, observed_delta, :second)

      assert {:ok, _row} =
               EvidenceStore.record_evidence(
                 identity,
                 model_weekly(observed_at, "0",
                   reset_at: DateTime.add(provider_at, @window_seconds, :second)
                 ),
                 observed_at,
                 observed_at
               )
    end

    row = model_weekly_row(identity)
    assert Decimal.equal?(row.used_percent, Decimal.new("80"))
    assert DateTime.compare(row.observed_at, cached_positive_at) == :eq

    assert row.metadata["__quota_relative_liveness_v1"] ==
             DateTime.to_iso8601(legacy_provider_at)
  end

  test "two future sliding snapshots cannot confirm a model weekly restart" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    assert {:ok, _row} = Windows.record_evidence(identity, model_weekly(t0, "64"), t0)

    first_replay_at = DateTime.add(t0, 60, :second)
    first_provider_at = DateTime.add(first_replay_at, 10, :minute)
    first_reset = DateTime.add(first_provider_at, @window_seconds, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(first_replay_at, "0", reset_at: first_reset),
               first_replay_at,
               first_replay_at
             )

    second_replay_at = DateTime.add(first_replay_at, 4, :minute)
    second_provider_at = DateTime.add(first_provider_at, 4, :minute)
    second_reset = DateTime.add(second_provider_at, @window_seconds, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(second_replay_at, "0", reset_at: second_reset),
               second_replay_at,
               second_replay_at
             )

    row = model_weekly_row(identity)
    assert Decimal.equal?(row.used_percent, Decimal.new("64"))
    assert DateTime.compare(row.observed_at, t0) == :eq
  end

  test "cached model weekly zero never becomes floating or clears prior usage" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    fixed_reset = DateTime.add(t0, 3, :day)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(t0, "64", reset_at: fixed_reset, metadata: %{}),
               t0,
               t0
             )

    for offset <- [300, 540] do
      observed_at = DateTime.add(t0, offset, :second)

      assert {:ok, _row} =
               Windows.record_evidence(
                 identity,
                 model_weekly(observed_at, "0", reset_at: fixed_reset),
                 observed_at
               )
    end

    row = model_weekly_row(identity)
    refute row.metadata["reset_state"] == "floating"
    assert Decimal.equal?(row.used_percent, Decimal.new("64"))
    assert DateTime.compare(row.reset_at, fixed_reset) == :eq
  end

  test "positive model usage anchors a previously floating weekly window" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()

    assert {:ok, _row} = Windows.record_evidence(identity, model_weekly(t0, "0"), t0)

    t1 = DateTime.add(t0, 60, :second)
    assert {:ok, _row} = Windows.record_evidence(identity, model_weekly(t1, "0"), t1)
    t2 = DateTime.add(t1, 240, :second)
    assert {:ok, _row} = Windows.record_evidence(identity, model_weekly(t2, "0"), t2)
    assert model_weekly_row(identity).metadata["reset_state"] == "floating"

    anchored_reset = DateTime.add(t2, @window_seconds, :second)
    t3 = DateTime.add(t2, 60, :second)

    assert {:ok, _row} =
             Windows.record_evidence(
               identity,
               model_weekly(t3, "2", reset_at: anchored_reset),
               t3
             )

    row = model_weekly_row(identity)
    assert row.metadata["reset_state"] == "anchored"
    assert Decimal.equal?(row.used_percent, Decimal.new("2"))
    assert DateTime.compare(row.reset_at, anchored_reset) == :eq
    refute Map.has_key?(row.metadata, "__quota_cycle_confirmation_v1")
    assert CycleConfirmation.valid_marker(row) == :none
    refute CycleConfirmation.selector_valid?(row, t3)
  end

  test "a sub-window zero-percent countdown anchors a previously floating weekly window" do
    t0 = ~U[2026-07-25 04:00:00Z]
    identity = identity!()

    for offset <- [0, 60, 300] do
      observed_at = DateTime.add(t0, offset, :second)

      record_spark_payload!(
        identity,
        spark_weekly_payload(0, DateTime.add(observed_at, @window_seconds, :second)),
        observed_at
      )
    end

    floating = model_weekly_row(identity)
    assert floating.metadata["reset_state"] == "floating"
    observed_at = DateTime.add(floating.observed_at, 104, :second)
    anchored_reset = floating.reset_at
    reset_after_seconds = DateTime.diff(anchored_reset, observed_at, :second)

    assert reset_after_seconds < @window_seconds

    record_spark_payload!(
      identity,
      spark_weekly_payload(0, anchored_reset, reset_after_seconds),
      observed_at
    )

    row = model_weekly_row(identity)
    assert row.metadata["reset_state"] == "anchored"
    assert Decimal.equal?(row.used_percent, Decimal.new("0"))
    assert DateTime.compare(row.reset_at, anchored_reset) == :eq
    assert DateTime.compare(row.observed_at, observed_at) == :eq
    assert DateTime.compare(row.last_sync_at, observed_at) == :eq
    assert row.metadata["__quota_relative_liveness_v1"] == DateTime.to_iso8601(observed_at)
    assert :none = EvidenceStore.parse_candidate(row.metadata)
    refute Map.has_key?(row.metadata, "__quota_relative_candidate_liveness_v1")
    refute Map.has_key?(row.metadata, "__quota_cycle_confirmation_v1")
    assert CycleConfirmation.valid_marker(row) == :none
    refute CycleConfirmation.selector_valid?(row, observed_at)
  end

  test "a parsed 104-second elapsed countdown replaces the floating snapshot" do
    t0 = ~U[2026-07-25 05:00:00Z]
    identity = identity!()

    for offset <- [0, 60, 300] do
      observed_at = DateTime.add(t0, offset, :second)

      record_spark_payload!(
        identity,
        spark_weekly_payload(0, DateTime.add(observed_at, @window_seconds, :second)),
        observed_at
      )
    end

    floating = model_weekly_row(identity)
    assert floating.metadata["reset_state"] == "floating"

    observed_at = DateTime.add(floating.observed_at, 104, :second)

    previous_level = Logger.level()
    Logger.configure(level: :info)

    {log, events} =
      capture_quota_cycle_events(fn ->
        try do
          capture_log([level: :info], fn ->
            record_spark_payload!(
              identity,
              spark_weekly_payload(0, floating.reset_at, @window_seconds - 104),
              observed_at
            )
          end)
        after
          Logger.configure(level: previous_level)
        end
      end)

    assert log =~ "decision=anchored_confirmed reason=relative_countdown_immediate"
    assert log =~ "scope=model source=provider_usage"

    assert events == [
             {%{count: 1},
              %{scope: "model", decision: :anchored_confirmed, source: "provider_usage"}}
           ]

    row = model_weekly_row(identity)
    assert row.metadata["reset_state"] == "anchored"
    assert Decimal.equal?(row.used_percent, Decimal.new("0"))
    assert DateTime.compare(row.reset_at, floating.reset_at) == :eq
    assert DateTime.compare(row.observed_at, observed_at) == :eq
    assert DateTime.compare(row.last_sync_at, observed_at) == :eq
    assert row.metadata["__quota_relative_liveness_v1"] == DateTime.to_iso8601(observed_at)
    assert :none = EvidenceStore.parse_candidate(row.metadata)
    refute Map.has_key?(row.metadata, "__quota_relative_candidate_liveness_v1")
    refute Map.has_key?(row.metadata, "__quota_cycle_confirmation_v1")
    assert CycleConfirmation.valid_marker(row) == :none
    refute CycleConfirmation.selector_valid?(row, observed_at)
  end

  test "bounded elapsed countdowns anchor only from 61 through 120 seconds" do
    t0 = ~U[2026-07-25 06:00:00Z]

    for {elapsed_seconds, expected_state} <- [
          {60, "floating"},
          {61, "anchored"},
          {120, "anchored"},
          {121, "floating"}
        ] do
      identity = identity!()
      floating = parsed_floating_model!(identity, t0)
      observed_at = DateTime.add(floating.observed_at, elapsed_seconds, :second)

      record_spark_payload!(
        identity,
        spark_weekly_payload(
          0,
          floating.reset_at,
          @window_seconds - elapsed_seconds
        ),
        observed_at
      )

      row = model_weekly_row(identity)
      assert row.metadata["reset_state"] == expected_state
      assert Decimal.equal?(row.used_percent, Decimal.new("0"))
      assert DateTime.compare(row.reset_at, floating.reset_at) == :eq

      if expected_state == "anchored" do
        assert DateTime.compare(row.observed_at, observed_at) == :eq
        assert DateTime.compare(row.last_sync_at, observed_at) == :eq
        assert :none = EvidenceStore.parse_candidate(row.metadata)
        refute Map.has_key?(row.metadata, "__quota_relative_candidate_liveness_v1")
        assert row.metadata["__quota_relative_liveness_v1"] == DateTime.to_iso8601(observed_at)
      end
    end
  end

  test "a full-minus-one countdown remains floating" do
    t0 = ~U[2026-07-25 07:00:00Z]
    identity = identity!()
    floating = parsed_floating_model!(identity, t0)
    observed_at = DateTime.add(floating.observed_at, 1, :second)

    record_spark_payload!(
      identity,
      spark_weekly_payload(0, floating.reset_at, @window_seconds - 1),
      observed_at
    )

    row = model_weekly_row(identity)
    assert row.metadata["reset_state"] == "floating"
    assert Decimal.equal?(row.used_percent, Decimal.new("0"))
    assert DateTime.compare(row.reset_at, floating.reset_at) == :eq
  end

  test "missing malformed and derived-only exact duration cannot immediately anchor" do
    t0 = ~U[2026-07-25 08:00:00Z]

    for {case_name, invalid_payload} <- [
          {:missing, spark_secondary_payload(0, DateTime.add(t0, @window_seconds, :second), nil)},
          {:malformed,
           spark_secondary_payload(
             0,
             DateTime.add(t0, @window_seconds, :second),
             @window_seconds - 104,
             limit_window_seconds: "invalid"
           )},
          {:derived_only,
           spark_secondary_payload(
             0,
             DateTime.add(t0, @window_seconds, :second),
             @window_seconds - 104
           )}
        ] do
      identity = identity!()

      initial =
        record_spark_payload!(
          identity,
          spark_weekly_payload(0, DateTime.add(t0, @window_seconds, :second)),
          t0
        )

      observed_at = DateTime.add(t0, 104, :second)

      invalid_payload =
        put_in(
          invalid_payload,
          ["additional_rate_limits", Access.at(0), "rate_limit", "secondary_window", "reset_at"],
          DateTime.to_iso8601(initial.reset_at)
        )

      record_spark_payload!(identity, invalid_payload, observed_at)

      row = model_weekly_row(identity)

      assert row.metadata["reset_state"] == initial.metadata["reset_state"],
             "case=#{case_name}"

      assert DateTime.compare(row.reset_at, initial.reset_at) == :eq
      assert DateTime.compare(row.observed_at, initial.observed_at) == :eq
      assert DateTime.compare(row.last_sync_at, initial.last_sync_at) == :eq

      assert row.metadata["__quota_relative_liveness_v1"] ==
               initial.metadata["__quota_relative_liveness_v1"]
    end
  end

  test "a bounded future provider instant cannot immediately anchor" do
    t0 = ~U[2026-07-25 09:00:00Z]
    identity = identity!()
    floating = parsed_floating_model!(identity, t0)
    observed_at = DateTime.add(floating.observed_at, 61, :second)
    future_reset = DateTime.add(floating.reset_at, 300, :second)

    record_spark_payload!(
      identity,
      spark_weekly_payload(0, future_reset, @window_seconds - 61),
      observed_at
    )

    row = model_weekly_row(identity)
    assert row.metadata["reset_state"] == "floating"
    assert DateTime.compare(row.reset_at, floating.reset_at) == :eq
    assert DateTime.compare(row.observed_at, floating.observed_at) == :eq

    assert row.metadata["__quota_relative_liveness_v1"] ==
             floating.metadata["__quota_relative_liveness_v1"]
  end

  test "replayed and older provider instants cannot refresh or rewind an immediate anchor" do
    t0 = ~U[2026-07-25 10:00:00Z]
    identity = identity!()
    floating = parsed_floating_model!(identity, t0)
    anchored_at = DateTime.add(floating.observed_at, 61, :second)
    anchored_payload = spark_weekly_payload(0, floating.reset_at, @window_seconds - 61)

    record_spark_payload!(identity, anchored_payload, anchored_at)
    anchored = model_weekly_row(identity)
    assert anchored.metadata["reset_state"] == "anchored"
    assert :none = EvidenceStore.parse_candidate(anchored.metadata)
    refute Map.has_key?(anchored.metadata, "__quota_relative_candidate_liveness_v1")

    assert anchored.metadata["__quota_relative_liveness_v1"] ==
             DateTime.to_iso8601(anchored_at)

    replayed_at = DateTime.add(anchored_at, 60, :second)
    record_spark_payload!(identity, anchored_payload, replayed_at)

    replayed = model_weekly_row(identity)
    assert DateTime.compare(replayed.reset_at, anchored.reset_at) == :eq
    assert DateTime.compare(replayed.observed_at, anchored.observed_at) == :eq

    assert replayed.metadata["__quota_relative_liveness_v1"] ==
             anchored.metadata["__quota_relative_liveness_v1"]

    older_at = DateTime.add(anchored_at, 2, :minute)
    older_provider_at = DateTime.add(anchored_at, -1, :second)
    older_reset = DateTime.add(older_provider_at, @window_seconds - 120, :second)

    record_spark_payload!(
      identity,
      spark_weekly_payload(0, older_reset, @window_seconds - 120),
      older_at
    )

    older = model_weekly_row(identity)
    assert DateTime.compare(older.reset_at, anchored.reset_at) == :eq
    assert DateTime.compare(older.observed_at, anchored.observed_at) == :eq

    assert older.metadata["__quota_relative_liveness_v1"] ==
             anchored.metadata["__quota_relative_liveness_v1"]
  end

  test "reset displacement over 300 seconds cannot use the immediate route" do
    t0 = ~U[2026-07-25 11:00:00Z]
    identity = identity!()

    initial =
      record_spark_payload!(
        identity,
        spark_weekly_payload(0, DateTime.add(t0, @window_seconds, :second)),
        t0
      )

    observed_at = DateTime.add(t0, 400, :second)
    displaced_reset = DateTime.add(initial.reset_at, 339, :second)

    record_spark_payload!(
      identity,
      spark_weekly_payload(0, displaced_reset, @window_seconds - 61),
      observed_at
    )

    row = model_weekly_row(identity)
    assert row.metadata["reset_state"] == initial.metadata["reset_state"]
    assert DateTime.compare(row.reset_at, initial.reset_at) == :eq
    assert DateTime.compare(row.observed_at, initial.observed_at) == :eq
    assert DateTime.compare(row.last_sync_at, initial.last_sync_at) == :eq

    assert row.metadata["__quota_relative_liveness_v1"] ==
             initial.metadata["__quota_relative_liveness_v1"]
  end

  test "one bounded zero preserves positive and exhausted canonical pressure" do
    t0 = ~U[2026-07-25 12:00:00Z]

    for used_percent <- ["64", "100"] do
      identity = identity!()

      record_spark_payload!(
        identity,
        spark_weekly_payload(
          String.to_integer(used_percent),
          DateTime.add(t0, @window_seconds, :second)
        ),
        t0
      )

      canonical = model_weekly_row(identity)
      routing_usable = Routing.usable_window?(canonical, t0)
      observed_at = DateTime.add(t0, 104, :second)

      record_spark_payload!(
        identity,
        spark_weekly_payload(0, canonical.reset_at, @window_seconds - 104),
        observed_at
      )

      row = model_weekly_row(identity)
      assert Decimal.equal?(row.used_percent, Decimal.new(used_percent))
      assert DateTime.compare(row.reset_at, canonical.reset_at) == :eq
      assert DateTime.compare(row.observed_at, canonical.observed_at) == :eq
      assert DateTime.compare(row.last_sync_at, canonical.last_sync_at) == :eq

      assert row.metadata["__quota_relative_liveness_v1"] ==
               canonical.metadata["__quota_relative_liveness_v1"]

      assert Routing.usable_window?(row, observed_at) == routing_usable
    end
  end

  test "a stable far-back countdown retains its candidate and anchors after 180 seconds" do
    t0 = ~U[2026-07-25 13:00:00Z]
    identity = identity!()
    floating = parsed_floating_model!(identity, t0)
    canonical_provider_watermark = floating.metadata["__quota_relative_liveness_v1"]
    candidate_at = DateTime.add(floating.observed_at, 5, :minute)
    fixed_reset = DateTime.add(candidate_at, @window_seconds - 24 * 60 * 60, :second)

    assert DateTime.compare(fixed_reset, floating.reset_at) == :lt

    record_spark_payload!(
      identity,
      fixed_countdown_payload(fixed_reset, candidate_at),
      candidate_at
    )

    pending = model_weekly_row(identity)
    assert {:ok, candidate} = EvidenceStore.parse_candidate(pending.metadata)
    assert DateTime.compare(candidate.observed_at, candidate_at) == :eq
    assert DateTime.compare(candidate.reset_at, fixed_reset) == :eq
    assert DateTime.compare(pending.reset_at, floating.reset_at) == :eq
    assert DateTime.compare(pending.observed_at, floating.observed_at) == :eq
    assert pending.metadata["__quota_relative_liveness_v1"] == canonical_provider_watermark

    assert pending.metadata["__quota_relative_candidate_liveness_v1"] ==
             DateTime.to_iso8601(candidate_at)

    before_confirmation_at = DateTime.add(candidate_at, 2, :minute)
    equivalent_reset = DateTime.add(fixed_reset, 5, :second)

    record_spark_payload!(
      identity,
      fixed_countdown_payload(equivalent_reset, before_confirmation_at),
      before_confirmation_at
    )

    retained = model_weekly_row(identity)
    assert {:ok, retained_candidate} = EvidenceStore.parse_candidate(retained.metadata)
    assert DateTime.compare(retained_candidate.observed_at, candidate_at) == :eq
    assert DateTime.compare(retained_candidate.reset_at, fixed_reset) == :eq
    assert DateTime.compare(retained.reset_at, floating.reset_at) == :eq
    assert DateTime.compare(retained.observed_at, floating.observed_at) == :eq

    assert retained.metadata["__quota_relative_candidate_liveness_v1"] ==
             DateTime.to_iso8601(candidate_at)

    confirmed_at = DateTime.add(candidate_at, 3, :minute)

    previous_level = Logger.level()
    Logger.configure(level: :info)

    {log, events} =
      capture_quota_cycle_events(fn ->
        try do
          capture_log([level: :info], fn ->
            record_spark_payload!(
              identity,
              fixed_countdown_payload(equivalent_reset, confirmed_at),
              confirmed_at
            )
          end)
        after
          Logger.configure(level: previous_level)
        end
      end)

    assert log =~ "decision=anchored_confirmed reason=relative_countdown_confirmed"

    assert events == [
             {%{count: 1},
              %{scope: "model", decision: :anchored_confirmed, source: "provider_usage"}}
           ]

    anchored = model_weekly_row(identity)
    assert anchored.metadata["reset_state"] == "anchored"
    assert Decimal.equal?(anchored.used_percent, Decimal.new("0"))
    assert DateTime.compare(anchored.reset_at, equivalent_reset) == :eq
    assert DateTime.compare(anchored.reset_at, floating.reset_at) == :lt
    assert DateTime.compare(anchored.observed_at, confirmed_at) == :eq
    assert DateTime.compare(anchored.last_sync_at, confirmed_at) == :eq
    assert anchored.metadata["__quota_relative_liveness_v1"] == DateTime.to_iso8601(confirmed_at)
    assert :none = EvidenceStore.parse_candidate(anchored.metadata)
    refute Map.has_key?(anchored.metadata, "__quota_relative_candidate_liveness_v1")
    refute Map.has_key?(anchored.metadata, "__quota_cycle_confirmation_v1")
    assert CycleConfirmation.valid_marker(anchored) == :none
    refute CycleConfirmation.selector_valid?(anchored, confirmed_at)
  end

  test "a confirmed far-back countdown replaces positive and exhausted pressure only after proof" do
    t0 = ~U[2026-07-25 14:00:00Z]

    for used_percent <- [64, 100] do
      identity = identity!()

      canonical =
        record_spark_payload!(
          identity,
          spark_weekly_payload(used_percent, DateTime.add(t0, @window_seconds, :second)),
          t0
        )

      candidate_at = DateTime.add(t0, 10, :minute)
      fixed_reset = DateTime.add(candidate_at, @window_seconds - 24 * 60 * 60, :second)

      record_spark_payload!(
        identity,
        fixed_countdown_payload(fixed_reset, candidate_at),
        candidate_at
      )

      pending = model_weekly_row(identity)
      assert Decimal.equal?(pending.used_percent, Decimal.new(used_percent))
      assert DateTime.compare(pending.reset_at, canonical.reset_at) == :eq
      assert DateTime.compare(pending.observed_at, canonical.observed_at) == :eq
      assert DateTime.compare(pending.last_sync_at, canonical.last_sync_at) == :eq
      assert {:ok, candidate} = EvidenceStore.parse_candidate(pending.metadata)
      assert DateTime.compare(candidate.observed_at, candidate_at) == :eq

      confirmed_at = DateTime.add(candidate_at, 3, :minute)

      record_spark_payload!(
        identity,
        fixed_countdown_payload(fixed_reset, confirmed_at),
        confirmed_at
      )

      anchored = model_weekly_row(identity)
      assert anchored.metadata["reset_state"] == "anchored"
      assert Decimal.equal?(anchored.used_percent, Decimal.new("0"))
      assert DateTime.compare(anchored.reset_at, fixed_reset) == :eq
      assert DateTime.compare(anchored.observed_at, confirmed_at) == :eq
      assert :none = EvidenceStore.parse_candidate(anchored.metadata)
    end
  end

  test "fixed countdown replay cannot advance a candidate and reset mismatch restarts it" do
    t0 = ~U[2026-07-25 15:00:00Z]
    identity = identity!()
    floating = parsed_floating_model!(identity, t0)
    candidate_at = DateTime.add(floating.observed_at, 5, :minute)
    fixed_reset = DateTime.add(candidate_at, @window_seconds - 24 * 60 * 60, :second)
    candidate_payload = fixed_countdown_payload(fixed_reset, candidate_at)

    record_spark_payload!(identity, candidate_payload, candidate_at)
    seeded = model_weekly_row(identity)
    assert {:ok, seeded_candidate} = EvidenceStore.parse_candidate(seeded.metadata)
    seeded_candidate_watermark = seeded.metadata["__quota_relative_candidate_liveness_v1"]

    replayed_at = DateTime.add(candidate_at, 60, :second)
    record_spark_payload!(identity, candidate_payload, replayed_at)

    replayed = model_weekly_row(identity)
    assert {:ok, replayed_candidate} = EvidenceStore.parse_candidate(replayed.metadata)
    assert replayed_candidate == seeded_candidate

    assert replayed.metadata["__quota_relative_candidate_liveness_v1"] ==
             seeded_candidate_watermark

    assert DateTime.compare(replayed.reset_at, floating.reset_at) == :eq
    assert DateTime.compare(replayed.observed_at, floating.observed_at) == :eq

    restarted_at = DateTime.add(candidate_at, 2, :minute)
    mismatched_reset = DateTime.add(fixed_reset, 6, :second)

    record_spark_payload!(
      identity,
      fixed_countdown_payload(mismatched_reset, restarted_at),
      restarted_at
    )

    restarted = model_weekly_row(identity)
    assert {:ok, restarted_candidate} = EvidenceStore.parse_candidate(restarted.metadata)
    assert DateTime.compare(restarted_candidate.observed_at, restarted_at) == :eq
    assert DateTime.compare(restarted_candidate.reset_at, mismatched_reset) == :eq

    assert restarted.metadata["__quota_relative_candidate_liveness_v1"] ==
             DateTime.to_iso8601(restarted_at)

    assert DateTime.compare(restarted.reset_at, floating.reset_at) == :eq
    assert DateTime.compare(restarted.observed_at, floating.observed_at) == :eq
  end

  test "an invalid fixed countdown candidate pairing restarts from newer parser evidence" do
    t0 = ~U[2026-07-25 16:00:00Z]
    identity = identity!()
    floating = parsed_floating_model!(identity, t0)
    candidate_at = DateTime.add(floating.observed_at, 5, :minute)
    fixed_reset = DateTime.add(candidate_at, @window_seconds - 24 * 60 * 60, :second)

    record_spark_payload!(
      identity,
      fixed_countdown_payload(fixed_reset, candidate_at),
      candidate_at
    )

    pending = model_weekly_row(identity)

    pending
    |> Ecto.Changeset.change(
      metadata: Map.delete(pending.metadata, "__quota_relative_candidate_liveness_v1")
    )
    |> Repo.update!()

    restarted_at = DateTime.add(candidate_at, 2, :minute)

    record_spark_payload!(
      identity,
      fixed_countdown_payload(fixed_reset, restarted_at),
      restarted_at
    )

    restarted = model_weekly_row(identity)
    assert {:ok, restarted_candidate} = EvidenceStore.parse_candidate(restarted.metadata)
    assert DateTime.compare(restarted_candidate.observed_at, restarted_at) == :eq
    assert DateTime.compare(restarted_candidate.reset_at, fixed_reset) == :eq

    assert restarted.metadata["__quota_relative_candidate_liveness_v1"] ==
             DateTime.to_iso8601(restarted_at)

    assert DateTime.compare(restarted.reset_at, floating.reset_at) == :eq
    assert DateTime.compare(restarted.observed_at, floating.observed_at) == :eq
  end

  test "full full-minus-one and first-minute countdowns never seed the fixed fallback" do
    t0 = ~U[2026-07-25 17:00:00Z]

    for elapsed_seconds <- [0, 1, 60] do
      identity = identity!()
      floating = parsed_floating_model!(identity, t0)
      observed_at = DateTime.add(floating.observed_at, 5, :minute)
      reset_at = DateTime.add(observed_at, @window_seconds - elapsed_seconds, :second)

      record_spark_payload!(
        identity,
        spark_weekly_payload(0, reset_at, @window_seconds - elapsed_seconds),
        observed_at
      )

      row = model_weekly_row(identity)
      assert row.metadata["reset_state"] == "floating"
      assert :none = EvidenceStore.parse_candidate(row.metadata)
      refute Map.has_key?(row.metadata, "__quota_relative_candidate_liveness_v1")
    end
  end

  test "a future provider instant cannot seed the confirmed fixed fallback" do
    t0 = ~U[2026-07-25 18:00:00Z]
    identity = identity!()
    floating = parsed_floating_model!(identity, t0)
    observed_at = DateTime.add(floating.observed_at, 5, :minute)
    elapsed_seconds = 24 * 60 * 60
    reset_after_seconds = @window_seconds - elapsed_seconds
    future_reset = DateTime.add(observed_at, reset_after_seconds + 300, :second)

    record_spark_payload!(
      identity,
      spark_weekly_payload(0, future_reset, reset_after_seconds),
      observed_at
    )

    unchanged = model_weekly_row(identity)
    assert unchanged.metadata["reset_state"] == "floating"
    assert DateTime.compare(unchanged.reset_at, floating.reset_at) == :eq
    assert DateTime.compare(unchanged.observed_at, floating.observed_at) == :eq
    assert :none = EvidenceStore.parse_candidate(unchanged.metadata)
    refute Map.has_key?(unchanged.metadata, "__quota_relative_candidate_liveness_v1")
  end

  test "a fixed replay cannot keep an accepted floating model weekly zero fresh" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    accepted = accepted_floating_model!(identity, t0)
    accepted_at = accepted.observed_at
    fixed_reset = accepted.reset_at

    for minute <- 1..16 do
      replayed_at = DateTime.add(accepted_at, minute, :minute)

      assert {:ok, _row} =
               EvidenceStore.record_evidence(
                 identity,
                 model_weekly(replayed_at, "0", reset_at: fixed_reset),
                 replayed_at,
                 replayed_at
               )
    end

    row = model_weekly_row(identity)
    assert DateTime.compare(row.observed_at, accepted_at) == :eq

    assert Evidence.current_freshness_state(row, DateTime.add(accepted_at, 16, :minute)) ==
             "stale"
  end

  test "older advancing provider times cannot rewind an accepted floating model row" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    accepted = accepted_floating_model!(identity, t0)
    accepted_at = accepted.observed_at

    first_replay_at = DateTime.add(accepted_at, 1, :minute)
    first_provider_at = DateTime.add(accepted_at, -9, :minute)
    first_reset = DateTime.add(first_provider_at, @window_seconds, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(first_replay_at, "0", reset_at: first_reset),
               first_replay_at,
               first_replay_at
             )

    second_replay_at = DateTime.add(first_replay_at, 4, :minute)
    second_provider_at = DateTime.add(first_provider_at, 4, :minute)
    second_reset = DateTime.add(second_provider_at, @window_seconds, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(second_replay_at, "0", reset_at: second_reset),
               second_replay_at,
               second_replay_at
             )

    row = model_weekly_row(identity)
    assert DateTime.compare(row.observed_at, accepted_at) == :eq
    assert DateTime.compare(row.reset_at, accepted.reset_at) == :eq
  end

  test "advancing model candidates older than canonical provider time cannot rewind it" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    canonical_reset = DateTime.add(t0, @window_seconds, :second)

    assert {:ok, _row} =
             Windows.record_evidence(
               identity,
               model_weekly(t0, "64", reset_at: canonical_reset),
               t0
             )

    first_observed_at = DateTime.add(t0, 60, :second)
    first_provider_at = DateTime.add(t0, -5, :minute)
    first_reset = DateTime.add(first_provider_at, @window_seconds, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(first_observed_at, "0", reset_at: first_reset),
               first_observed_at,
               first_observed_at
             )

    second_observed_at = DateTime.add(first_observed_at, 4, :minute)
    second_provider_at = DateTime.add(first_provider_at, 4, :minute)
    second_reset = DateTime.add(second_provider_at, @window_seconds, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(second_observed_at, "0", reset_at: second_reset),
               second_observed_at,
               second_observed_at
             )

    row = model_weekly_row(identity)
    assert Decimal.equal?(row.used_percent, Decimal.new("64"))
    assert DateTime.compare(row.reset_at, canonical_reset) == :eq
    assert DateTime.compare(row.observed_at, t0) == :eq
    assert row.metadata["reset_after_seconds"] == @window_seconds
    refute Map.has_key?(row.metadata, "__quota_relative_candidate_liveness_v1")
  end

  test "positive model refresh advances the canonical provider watermark" do
    t0 = ~U[2026-07-24 19:00:00Z]
    identity = identity!()
    canonical_reset = DateTime.add(t0, @window_seconds, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(t0, "64", reset_at: canonical_reset),
               t0,
               t0
             )

    canonical_provider_at = DateTime.add(t0, 6, :minute)
    canonical_remaining = DateTime.diff(canonical_reset, canonical_provider_at, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(canonical_provider_at, "70",
                 reset_at: canonical_reset,
                 metadata: %{"reset_after_seconds" => canonical_remaining}
               ),
               canonical_provider_at,
               canonical_provider_at
             )

    first_observed_at = DateTime.add(canonical_provider_at, 60, :second)
    first_provider_at = DateTime.add(t0, 2, :minute)
    first_reset = DateTime.add(first_provider_at, @window_seconds, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(first_observed_at, "0", reset_at: first_reset),
               first_observed_at,
               first_observed_at
             )

    second_observed_at = DateTime.add(first_observed_at, 3, :minute)
    second_provider_at = DateTime.add(first_provider_at, 3, :minute)
    second_reset = DateTime.add(second_provider_at, @window_seconds, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(second_observed_at, "0", reset_at: second_reset),
               second_observed_at,
               second_observed_at
             )

    row = model_weekly_row(identity)
    assert Decimal.equal?(row.used_percent, Decimal.new("70"))
    assert DateTime.compare(row.reset_at, canonical_reset) == :eq
    assert DateTime.compare(row.observed_at, canonical_provider_at) == :eq

    assert row.metadata["__quota_relative_liveness_v1"] ==
             DateTime.to_iso8601(canonical_provider_at)

    refute Map.has_key?(row.metadata, "__quota_relative_candidate_liveness_v1")
    assert_markerless_anchor(row, second_observed_at)
  end

  test "positive model evidence without usable timing installs a conservative barrier" do
    t0 = ~U[2026-07-24 20:00:00Z]
    identity = identity!()
    canonical_reset = DateTime.add(t0, @window_seconds, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(t0, "64", reset_at: canonical_reset),
               t0,
               t0
             )

    positive_at = DateTime.add(t0, 6, :minute)

    positive_without_timing =
      positive_at
      |> model_weekly("70", reset_at: canonical_reset)
      |> Map.put(:metadata, "invalid")

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               positive_without_timing,
               positive_at,
               positive_at
             )

    accepted = model_weekly_row(identity)
    assert Decimal.equal?(accepted.used_percent, Decimal.new("70"))
    assert DateTime.compare(accepted.observed_at, positive_at) == :eq
    assert_markerless_anchor(accepted, positive_at)

    assert accepted.metadata["__quota_relative_liveness_v1"] ==
             DateTime.to_iso8601(positive_at)

    first_observed_at = DateTime.add(positive_at, 60, :second)
    first_provider_at = DateTime.add(t0, 2, :minute)
    first_reset = DateTime.add(first_provider_at, @window_seconds, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(first_observed_at, "0", reset_at: first_reset),
               first_observed_at,
               first_observed_at
             )

    second_observed_at = DateTime.add(first_observed_at, 3, :minute)
    second_provider_at = DateTime.add(first_provider_at, 3, :minute)
    second_reset = DateTime.add(second_provider_at, @window_seconds, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(second_observed_at, "0", reset_at: second_reset),
               second_observed_at,
               second_observed_at
             )

    row = model_weekly_row(identity)
    assert Decimal.equal?(row.used_percent, Decimal.new("70"))
    assert DateTime.compare(row.observed_at, positive_at) == :eq
    assert row.metadata["__quota_relative_liveness_v1"] == DateTime.to_iso8601(positive_at)
    assert_markerless_anchor(row, second_observed_at)
  end

  test "missing timing cannot replace an expired historical model alias" do
    t0 = DateTime.utc_now() |> DateTime.add(-20, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    expired_reset = DateTime.add(t0, 60, :second)
    alias_row = historical_alias_row!(identity, t0, "64", reset_at: expired_reset, metadata: %{})
    observed_at = DateTime.add(t0, 10, :minute)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               alias_model_weekly(observed_at, "0", metadata: %{}),
               observed_at,
               observed_at
             )

    row = Repo.get!(AccountQuotaWindow, alias_row.id)
    assert row.quota_key == "gpt_5_3_codex_spark"
    assert Decimal.equal?(row.used_percent, Decimal.new("64"))
    assert DateTime.compare(row.reset_at, expired_reset) == :eq
    assert DateTime.compare(row.observed_at, t0) == :eq
  end

  test "malformed timing cannot replace an expired historical model alias" do
    t0 = DateTime.utc_now() |> DateTime.add(-20, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    expired_reset = DateTime.add(t0, 60, :second)
    alias_row = historical_alias_row!(identity, t0, "64", reset_at: expired_reset, metadata: %{})
    observed_at = DateTime.add(t0, 10, :minute)

    malformed =
      observed_at
      |> alias_model_weekly("0")
      |> Map.put(:metadata, "invalid")

    assert {:ok, _row} =
             EvidenceStore.record_evidence(identity, malformed, observed_at, observed_at)

    row = Repo.get!(AccountQuotaWindow, alias_row.id)
    assert row.quota_key == "gpt_5_3_codex_spark"
    assert Decimal.equal?(row.used_percent, Decimal.new("64"))
    assert DateTime.compare(row.reset_at, expired_reset) == :eq
    assert DateTime.compare(row.observed_at, t0) == :eq
  end

  test "one valid relative zero cannot replace an expired historical model alias" do
    t0 = DateTime.utc_now() |> DateTime.add(-20, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    expired_reset = DateTime.add(t0, 60, :second)
    alias_row = historical_alias_row!(identity, t0, "64", reset_at: expired_reset, metadata: %{})
    observed_at = DateTime.add(t0, 10, :minute)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               alias_model_weekly(observed_at, "0"),
               observed_at,
               observed_at
             )

    row = Repo.get!(AccountQuotaWindow, alias_row.id)
    assert row.quota_key == "gpt_5_3_codex_spark"
    assert Decimal.equal?(row.used_percent, Decimal.new("64"))
    assert DateTime.compare(row.reset_at, expired_reset) == :eq
    assert DateTime.compare(row.observed_at, t0) == :eq
    assert {:ok, _candidate} = EvidenceStore.parse_candidate(row.metadata)
  end

  test "accepted runtime pressure clears a historical alias restart candidate" do
    t0 = DateTime.utc_now() |> DateTime.add(-20, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    expired_reset = DateTime.add(t0, 60, :second)
    alias_row = historical_alias_row!(identity, t0, "64", reset_at: expired_reset, metadata: %{})
    candidate_at = DateTime.add(t0, 10, :minute)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               alias_model_weekly(candidate_at, "0"),
               candidate_at,
               candidate_at
             )

    candidate = Repo.get!(AccountQuotaWindow, alias_row.id)
    assert {:ok, _candidate} = EvidenceStore.parse_candidate(candidate.metadata)
    assert Map.has_key?(candidate.metadata, "__quota_relative_candidate_liveness_v1")

    runtime_at = DateTime.add(candidate_at, 60, :second)

    runtime_pressure =
      runtime_at
      |> model_weekly("91")
      |> Map.merge(%{
        source: "codex_rate_limit_event",
        raw_limit_id: nil,
        raw_limit_name: nil,
        raw_metered_feature: nil
      })

    assert {:ok, runtime_row} =
             EvidenceStore.record_evidence(identity, runtime_pressure, runtime_at, runtime_at)

    assert runtime_row.source == "codex_rate_limit_event"

    cleared = Repo.get!(AccountQuotaWindow, alias_row.id)
    assert :none = EvidenceStore.parse_candidate(cleared.metadata)
    refute Map.has_key?(cleared.metadata, "__quota_relative_candidate_liveness_v1")

    next_observed_at = DateTime.add(candidate_at, 4, :minute)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               alias_model_weekly(next_observed_at, "0"),
               next_observed_at,
               next_observed_at
             )

    row = Repo.get!(AccountQuotaWindow, alias_row.id)
    assert row.quota_key == "gpt_5_3_codex_spark"
    assert Decimal.equal?(row.used_percent, Decimal.new("64"))
    assert {:ok, restarted_candidate} = EvidenceStore.parse_candidate(row.metadata)
    assert DateTime.compare(restarted_candidate.observed_at, next_observed_at) == :eq
  end

  test "model weekly zero without provider timing cannot clear a non-relative row" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    canonical_reset = DateTime.add(t0, 3, :day)

    assert {:ok, _row} =
             Windows.record_evidence(
               identity,
               model_weekly(t0, "64", reset_at: canonical_reset, metadata: %{}),
               t0
             )

    observed_at = DateTime.add(t0, 5, :minute)
    unproven_reset = DateTime.add(observed_at, @window_seconds, :second)

    assert {:ok, _row} =
             EvidenceStore.record_evidence(
               identity,
               model_weekly(observed_at, "0", reset_at: unproven_reset, metadata: %{}),
               observed_at,
               observed_at
             )

    row = model_weekly_row(identity)
    assert Decimal.equal?(row.used_percent, Decimal.new("64"))
    assert DateTime.compare(row.reset_at, canonical_reset) == :eq
    assert DateTime.compare(row.observed_at, t0) == :eq
  end

  test "malformed model timing cannot replace an expired non-relative row" do
    t0 = DateTime.utc_now() |> DateTime.add(-20, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    expired_reset = DateTime.add(t0, 60, :second)

    assert {:ok, _row} =
             Windows.record_evidence(
               identity,
               model_weekly(t0, "64", reset_at: expired_reset, metadata: %{}),
               t0
             )

    observed_at = DateTime.add(t0, 10, :minute)

    malformed =
      observed_at
      |> model_weekly("0")
      |> Map.put(:metadata, "invalid")

    assert {:ok, _row} =
             EvidenceStore.record_evidence(identity, malformed, observed_at, observed_at)

    row = model_weekly_row(identity)
    assert Decimal.equal?(row.used_percent, Decimal.new("64"))
    assert DateTime.compare(row.reset_at, expired_reset) == :eq
    assert DateTime.compare(row.observed_at, t0) == :eq
  end

  test "malformed timing metadata cannot explicitly correct an accepted floating model row" do
    t0 = DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    accepted = accepted_floating_model!(identity, t0)
    replayed_at = DateTime.add(accepted.observed_at, 60, :second)

    malformed =
      replayed_at
      |> model_weekly("0", reset_at: accepted.reset_at)
      |> Map.put(:metadata, "invalid")

    assert {:ok, _row} =
             EvidenceStore.record_evidence(identity, malformed, replayed_at, replayed_at)

    row = model_weekly_row(identity)
    assert DateTime.compare(row.observed_at, accepted.observed_at) == :eq
    assert DateTime.compare(row.reset_at, accepted.reset_at) == :eq
    assert row.metadata["reset_state"] == "floating"
  end

  test "parsed Spark payload requires a moving absolute reset before marking it floating" do
    t0 = DateTime.utc_now() |> DateTime.add(-20, :minute) |> DateTime.truncate(:microsecond)
    identity = identity!()
    fixed_reset = DateTime.add(t0, @window_seconds, :second)

    record_spark_payload!(identity, spark_weekly_payload(64, fixed_reset), t0)

    cached_zero = spark_weekly_payload(0, fixed_reset)

    for offset <- [300, 540] do
      observed_at = DateTime.add(t0, offset, :second)
      record_spark_payload!(identity, cached_zero, observed_at)
    end

    cached_row = model_weekly_row(identity)
    refute cached_row.metadata["reset_state"] == "floating"
    assert Decimal.equal?(cached_row.used_percent, Decimal.new("64"))
    assert DateTime.compare(cached_row.reset_at, fixed_reset) == :eq

    t3 = DateTime.add(t0, 600, :second)

    record_spark_payload!(
      identity,
      spark_weekly_payload(0, DateTime.add(t3, @window_seconds)),
      t3
    )

    t4 = DateTime.add(t3, 240, :second)
    moving_reset = DateTime.add(t4, @window_seconds)
    record_spark_payload!(identity, spark_weekly_payload(0, moving_reset), t4)

    live_row = model_weekly_row(identity)
    assert live_row.metadata["reset_state"] == "floating"
    assert Decimal.equal?(live_row.used_percent, Decimal.new("0"))
    assert DateTime.compare(live_row.reset_at, moving_reset) == :eq
  end
end
