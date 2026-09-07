defmodule CodexPooler.Metrics.AccountProjectionTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Metrics.{AccountProjection, AccountPrometheus, AccountSnapshot, AccountValues}
  alias CodexPooler.Quotas.{Evidence, SourceObservations}

  alias CodexPooler.Upstreams.Quota.{
    AccountAvailabilityStore,
    AccountQuotaWindow,
    RoutingQuotaSnapshot
  }

  alias CodexPooler.Upstreams.Quota.Windows.Routing
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.QuotaObservations

  @now ~U[2026-09-07 06:00:00Z]
  @account "11111111-1111-4111-8111-111111111111"
  @pool "22222222-2222-4222-8222-222222222222"

  test "all lifecycle states and unassigned identities have one inventory row" do
    statuses =
      ~w(active paused disabled pending refresh_failed reauth_required refreshing refresh_due errored unexpected deleted)

    identities = Enum.map(statuses, &identity(%{id: Ecto.UUID.generate(), status: &1}))
    p = AccountProjection.project(snapshot([], [], identities))
    assert p.complete
    assert p.accounts == length(statuses) - 1
    assert length(samples(p, :account_info)) == p.accounts

    assert Enum.any?(samples(p, :account_state), fn {_, labels, _} ->
             labels[:state] == "unknown"
           end)

    assert samples(p, :account_last_quota_observation_timestamp_seconds) == []
    assert Enum.all?(samples(p, :account_has_quota_observation), &(elem(&1, 2) == 0))
  end

  test "memberships deduplicate independently of account quotas and use closed state domains" do
    for status <-
          ~w(pending active paused refresh_due refreshing refresh_failed reauth_required disabled errored unexpected) do
      member =
        membership(%{
          status: status,
          health_status: "provider-secret",
          eligibility_status: "provider-secret"
        })

      p =
        project([window()], [
          member,
          member,
          membership(%{pool_id: Ecto.UUID.generate()}),
          membership(%{status: "deleted"})
        ])

      assert p.complete
      assert p.memberships == 2
      assert p.groups == 1
      assert p.observations == 1
      assert length(samples(p, :account_pool_membership)) == 2

      refute Enum.any?(samples(p, :account_quota_info), fn {_, labels, _} ->
               Keyword.has_key?(labels, :pool_id)
             end)

      assert Enum.any?(samples(p, :account_pool_state), fn {_, labels, _} ->
               labels[:status] == if(status == "unexpected", do: "unknown", else: status) and
                 labels[:health] == "unknown" and labels[:eligibility] == "unknown"
             end)
    end
  end

  test "missing, malformed, nonfinite and out-of-range usage never becomes zero" do
    for invalid <- [
          nil,
          "42",
          Decimal.new("NaN"),
          Decimal.new("Infinity"),
          Decimal.new(-1),
          Decimal.new(101)
        ] do
      p = project([window(%{used_percent: invalid})])
      assert p.complete
      assert samples(p, :account_quota_observation_used_percent) == []
      assert samples(p, :account_quota_observation_remaining_percent) == []
      assert [{_, _, 0}] = samples(p, :account_quota_observation_used_known)
    end

    for {used, remaining} <- [{0, 100}, {100, 0}] do
      p = project([window(%{used_percent: Decimal.new(used)})])
      assert [{_, _, value}] = samples(p, :account_quota_observation_remaining_percent)
      assert Decimal.equal?(value, remaining)
    end
  end

  test "unknown-time evidence retains values and resets without positive readiness" do
    for time <- [nil, "invalid-time"] do
      missing =
        window(%{
          observed_at: time,
          used_percent: Decimal.new(90),
          source: "codex_response_headers"
        })

      p = project([window(), missing])
      assert p.complete
      assert p.observations == 2
      assert length(samples(p, :account_quota_observation_timestamp_seconds)) == 1
      assert length(samples(p, :account_quota_observation_reset_timestamp_seconds)) == 2

      assert Enum.any?(samples(p, :account_quota_observation_freshness), fn {_, labels, _} ->
               labels[:state] == "unknown"
             end)

      assert [{_, [account_id: @account, provider: _, state: "unknown"], 1}] =
               samples(p, :account_quota_readiness)

      assert [{_, labels, 0}] =
               Enum.filter(samples(p, :account_quota_observation_routing_selected), fn {_, labels,
                                                                                        _} ->
                 labels[:source] == "codex_response_headers"
               end)

      assert labels[:observation_id] == AccountValues.observation_id(missing)
      legacy = as_window(%{missing | observed_at: nil})
      key = SourceObservations.group_key(legacy)
      assert key == QuotaObservations.group_key(legacy)
    end
  end

  test "TTL, elapsed/resetless and future evidence keep distinct freshness and visibility" do
    for {age, state} <- [
          {Evidence.freshness_ttl_seconds(), "fresh"},
          {Evidence.freshness_ttl_seconds() + 1, "stale"}
        ] do
      p = project([window(%{observed_at: DateTime.add(@now, -age)})])
      assert [{_, labels, 1}] = samples(p, :account_quota_observation_freshness)
      assert labels[:state] == state
    end

    p =
      project([
        window(%{reset_at: DateTime.add(@now, -1)}),
        window(%{observed_at: DateTime.add(@now, 1), source: "codex_response_headers"})
      ])

    assert p.observations == 1
    assert [{_, _, 1}] = samples(p, :account_quota_observation_elapsed)
    assert length(samples(p, :account_quota_observation_reset_timestamp_seconds)) == 1

    assert samples(
             project([window(%{reset_at: nil})]),
             :account_quota_observation_reset_timestamp_seconds
           ) == []
  end

  test "retained differences preserve original values and routing provenance without classification" do
    for {older_used, newer_used} <- [{5, 6}, {6, 5}, {6, 6}], gap <- [60, 61] do
      old =
        window(%{
          source: "codex_response_headers",
          observed_at: DateTime.add(@now, -30),
          used_percent: Decimal.new(older_used)
        })

      fresh =
        window(%{
          used_percent: Decimal.new(newer_used),
          reset_at: DateTime.add(old.reset_at, gap)
        })

      p = project([old, fresh])
      assert p.complete
      assert p.observations == 2

      used =
        Map.new(samples(p, :account_quota_observation_used_percent), fn {_, labels, value} ->
          {labels[:source], value}
        end)

      resets =
        Map.new(samples(p, :account_quota_observation_reset_timestamp_seconds), fn {_, labels,
                                                                                    value} ->
          {labels[:source], value}
        end)

      assert used == %{
               "codex_response_headers" => old.used_percent,
               "codex_usage_api" => fresh.used_percent
             }

      assert resets == %{
               "codex_response_headers" => AccountValues.seconds(old.reset_at),
               "codex_usage_api" => AccountValues.seconds(fresh.reset_at)
             }

      assert [{_, _, 1}] = samples(p, :account_quota_routing_selection_present)

      selected =
        RoutingQuotaSnapshot.from_identity(
          struct!(UpstreamIdentity, identity()),
          Enum.map([old, fresh], &as_window/1),
          @now
        )
        |> RoutingQuotaSnapshot.effective_windows()
        |> MapSet.new(& &1.source)

      for {_, labels, value} <- samples(p, :account_quota_observation_routing_selected) do
        assert value == if(MapSet.member?(selected, labels[:source]), do: 1, else: 0)
      end

      body = AccountPrometheus.render({:ok, p}, 0.01)
      refute body =~ "conflict"
      refute body =~ "uncertain"
    end
  end

  test "meter identity preserves the upstream evidence dialog digest across report updates" do
    # Existing source-dialog identity, captured before extracting its grouping helper.
    expected = "2f27296639a30fd4e234f582a14299449afa05c7837250141b3c6bb11c6ef3ea"

    for row <- [
          window(),
          window(%{window_kind: "primary", source: "codex_response_headers"}),
          window(%{observed_at: nil, reset_at: nil, used_percent: Decimal.new(90)})
        ] do
      assert SourceObservations.group_key(as_window(row)) == expected
      assert QuotaObservations.group_key(as_window(row)) == expected
      assert [{_, labels, 1}] = samples(project([row]), :account_quota_info)
      assert labels[:meter_id] == expected
    end
  end

  test "persistence digest exactly separates indexed raw fields from canonical groups" do
    original = window(%{model: "Model", index_model: "model", raw_limit_name: nil})

    equivalent = %{
      original
      | model: "MODEL",
        raw_limit_name: "",
        id: Ecto.UUID.generate(),
        observed_at: nil,
        reset_at: nil,
        used_percent: nil
    }

    assert AccountValues.observation_id(original) == AccountValues.observation_id(equivalent)

    for different <- [
          %{original | raw_limit_name: "X"},
          %{original | raw_limit_name: "x"},
          %{original | source: "Codex_usage_api"},
          %{original | window_kind: "primary"}
        ] do
      refute AccountValues.observation_id(original) == AccountValues.observation_id(different)
    end

    refute AccountValues.observation_id(%{original | raw_limit_name: "X"}) ==
             AccountValues.observation_id(%{original | raw_limit_name: "x"})

    assert SourceObservations.group_key(as_window(original)) ==
             SourceObservations.group_key(as_window(%{original | window_kind: "primary"}))
  end

  test "separate durations, model, Spark, Reserve and opaque meters never flatten" do
    windows = [
      window(),
      window(%{window_minutes: 300, window_kind: "primary"}),
      window(%{window_minutes: 43_200, window_kind: "primary"}),
      window(%{
        quota_scope: "model",
        quota_key: "private-model",
        model: "private-model",
        index_model: "private-model"
      }),
      window(%{
        quota_scope: "model",
        quota_key: "codex_spark",
        quota_family: "codex_spark",
        model: "gpt-5.3-codex-spark",
        index_model: "gpt-5.3-codex-spark"
      }),
      window(%{
        quota_scope: "feature",
        quota_key: "reserve",
        quota_family: "reserve",
        limit_name: "GPT-Reserve",
        raw_metered_feature: "base_model_inference"
      }),
      window(%{
        quota_scope: "feature",
        quota_key: "unknown",
        raw_metered_feature: "private-meter-a"
      }),
      window(%{
        quota_scope: "feature",
        quota_key: "unknown",
        raw_metered_feature: "private-meter-b"
      })
    ]

    p = project(windows)
    assert p.complete
    assert p.groups == 8

    assert Enum.sort(
             Enum.uniq(
               Enum.map(samples(p, :account_quota_info), fn {_, labels, _} -> labels[:bucket] end)
             )
           ) == ~w(account other reserve spark)

    body = AccountPrometheus.render({:ok, p}, 0.01)

    for sentinel <-
          ~w(private-model private-meter-a private-meter-b base_model_inference GPT-Reserve) do
      refute body =~ sentinel
    end

    assert length(
             String.split(body, "\n")
             |> Enum.filter(&String.starts_with?(&1, "codex_pooler_"))
           ) <= 8 + 11 + 3 * 8 + 9 * 8
  end

  test "availability keeps same-epoch blocked state but expires available observations" do
    for {state, age, epoch, expected} <- [
          {:available, 0, 1, "available"},
          {:available, 901, 1, "unknown"},
          {:blocked, 90_000, 1, "blocked"},
          {:blocked, 0, 2, "unknown"},
          {:available, -1, 1, "unknown"}
        ] do
      metadata = %{
        "credential_epoch" => 1,
        "quota_account_availability" =>
          AccountAvailabilityStore.encode!(state, DateTime.add(@now, -age), epoch)
      }

      p = AccountProjection.project(snapshot([], [], [identity(%{metadata: metadata})]))
      assert p.complete
      assert [{_, labels, 1}] = samples(p, :account_provider_availability_state)
      assert labels[:state] == expected

      if epoch != 1 or age < 0,
        do: assert(samples(p, :account_provider_availability_observed_timestamp_seconds) == [])
    end

    metadata = %{
      "credential_epoch" => 1,
      "quota_account_availability" => AccountAvailabilityStore.encode!(:available, @now, 1)
    }

    p = AccountProjection.project(snapshot([], [], [identity(%{metadata: metadata})]))
    assert [{_, labels, 1}] = samples(p, :account_quota_readiness)
    assert labels[:state] == "provider_available_no_windows"
  end

  test "overflow omits the whole account section and malformed data isolates its account" do
    overflows = [
      [window(%{row_count: 513})],
      Enum.map(1..65, &window(%{quota_key: "meter-#{&1}", quota_scope: "feature"})),
      Enum.map(1..9, &window(%{raw_limit_name: "raw-#{&1}"}))
    ]

    for rows <- overflows do
      p = project(rows, [membership()])
      refute p.complete
      assert [{_, _, 1}] = samples(p, :account_projection_overflow)
      assert samples(p, :account_pool_membership) == []
      assert samples(p, :account_quota_info) == []
    end

    refute project([], [membership(%{row_count: 65})]).complete
    bad = identity(%{id: Ecto.UUID.generate(), metadata: %{}})

    p =
      AccountProjection.project(
        snapshot(
          [window(), Map.put(window(%{upstream_identity_id: bad.id}), :unexpected_field, true)],
          [],
          [identity(), bad]
        )
      )

    assert p.accounts == 2
    assert length(samples(p, :account_info)) == 2
    refute p.complete
    assert p.groups == 1
  end

  test "default routing telemetry is preserved and metrics evaluation emits none" do
    event = [:codex_pooler, :quota, :cycle, :decision]
    ref = make_ref()

    :telemetry.attach(
      ref,
      event,
      fn _, _, metadata, pid -> send(pid, {:decision, metadata}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(ref) end)

    old =
      window(%{
        window_kind: "primary",
        window_minutes: 300,
        observed_at: DateTime.add(@now, -1800),
        last_sync_at: DateTime.add(@now, -1800)
      })

    fresh = window()
    values = Enum.map([old, fresh], &as_window/1)
    normal = Routing.reject_superseded_primary_windows(values, @now)
    assert_receive {:decision, %{decision: :superseded_primary_rejected}}

    assert normal ==
             Routing.reject_superseded_primary_windows(values, @now, emit_telemetry: false)

    refute_receive {:decision, _}
    p = project([old, fresh])
    assert p.complete
    refute_receive {:decision, _}

    snapshot =
      RoutingQuotaSnapshot.from_identity(struct!(UpstreamIdentity, identity()), values, @now)

    assert RoutingQuotaSnapshot.effective_windows(snapshot) ==
             RoutingQuotaSnapshot.effective_windows(snapshot, emit_telemetry: false)

    assert_receive {:decision, _}
  end

  test "next scrape drops removed data and failures expose health without fabricated inventory" do
    first = AccountSnapshot.scrape(fn -> {:ok, snapshot([window()], [membership()])} end)
    assert first =~ @account
    second = AccountSnapshot.scrape(fn -> {:ok, snapshot([], [], [])} end)
    refute second =~ @account
    failure = AccountSnapshot.scrape(fn -> raise "private-sentinel" end)
    assert failure =~ "codex_pooler_account_metrics_collection_success 0"
    refute failure =~ "private-sentinel"
    refute failure =~ "codex_pooler_account_metrics_accounts 0"
  end

  defp samples(projection, metric) do
    Enum.filter(projection.samples, fn {name, _labels, value} ->
      name == metric and value != nil
    end)
  end

  defp project(windows, memberships \\ []),
    do: AccountProjection.project(snapshot(windows, memberships))

  defp snapshot(windows, memberships, identities \\ [identity()]),
    do: %{as_of: @now, identities: identities, memberships: memberships, windows: windows}

  defp identity(attrs \\ %{}),
    do:
      Map.merge(
        %{
          id: @account,
          status: "active",
          disabled_at: nil,
          credential_provenance: "codex_chatgpt_oauth",
          metadata: %{"credential_epoch" => 1}
        },
        attrs
      )

  defp membership(attrs \\ %{}),
    do:
      Map.merge(
        %{
          upstream_identity_id: @account,
          pool_id: @pool,
          status: "active",
          health_status: "active",
          eligibility_status: "eligible",
          reconciliation_status: nil,
          reconciliation_finished_at: nil,
          last_successful_refresh_at: nil
        },
        attrs
      )

  defp as_window(row),
    do:
      struct!(
        AccountQuotaWindow,
        Map.drop(row, [:index_model, :index_upstream_model, :row_count])
      )

  defp window(attrs \\ %{}) do
    base = %AccountQuotaWindow{
      id: Ecto.UUID.generate(),
      upstream_identity_id: @account,
      quota_key: "account",
      quota_scope: "account",
      quota_family: "account",
      window_kind: "secondary",
      window_minutes: 10_080,
      source: "codex_usage_api",
      source_precision: "observed",
      freshness_state: "fresh",
      observed_at: @now,
      last_sync_at: @now,
      updated_at: @now,
      reset_at: DateTime.add(@now, 86_400),
      used_percent: Decimal.new(6),
      merge_precedence: 60,
      metadata: %{}
    }

    base
    |> Map.from_struct()
    |> Map.drop([:__meta__])
    |> Map.merge(%{index_model: "", index_upstream_model: ""})
    |> Map.merge(attrs)
  end
end
