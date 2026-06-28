defmodule CodexPooler.Gateway.Routing.RouteFilteringTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Catalog
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Routing.CandidateEligibility
  alias CodexPooler.Gateway.Routing.CandidateEligibility.FilterInput
  alias CodexPooler.Gateway.Routing.RouteFiltering
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  describe "filter_candidates/2" do
    test "allows missing quota evidence when the route marks quota optional" do
      %{pool: pool, api_key: api_key} = active_api_key_fixture()
      first = upstream_assignment_fixture(pool)
      second = upstream_assignment_fixture(pool)

      model =
        model_fixture(pool, %{
          exposed_model_id: "gpt-route-filtering-#{System.unique_integer([:positive])}",
          metadata: %{
            "source_assignment_ids" => [first.assignment.id, second.assignment.id]
          }
        })

      payload = %{"model" => model.exposed_model_id, "input" => "route filtering"}
      request_options = RequestOptions.build(%{}, "/backend-api/codex/responses", payload)
      candidates = [{first.assignment, first.identity}, {second.assignment, second.identity}]

      filter_input =
        FilterInput.new(%{
          auth: %{pool: pool, api_key: api_key},
          model: model,
          endpoint: "/backend-api/codex/responses",
          payload: payload,
          request_options: request_options,
          candidates: candidates
        })

      assert {:ok, filtered_candidates, filtered_options} =
               RouteFiltering.filter_candidates(filter_input, quota_mode: :optional)

      assert Enum.map(filtered_candidates, fn {assignment, _identity} -> assignment.id end) == [
               first.assignment.id,
               second.assignment.id
             ]

      assert filtered_options.routing.quota_decision == nil
    end

    test "keeps missing quota evidence blocking when quota is required" do
      %{pool: pool, api_key: api_key} = active_api_key_fixture()
      upstream = upstream_assignment_fixture(pool)

      model =
        model_fixture(pool, %{
          exposed_model_id: "gpt-route-filtering-required-#{System.unique_integer([:positive])}",
          metadata: %{"source_assignment_ids" => [upstream.assignment.id]}
        })

      payload = %{"model" => model.exposed_model_id, "input" => "route filtering"}
      request_options = RequestOptions.build(%{}, "/backend-api/codex/responses", payload)

      filter_input =
        FilterInput.new(%{
          auth: %{pool: pool, api_key: api_key},
          model: model,
          endpoint: "/backend-api/codex/responses",
          payload: payload,
          request_options: request_options,
          candidates: [{upstream.assignment, upstream.identity}]
        })

      assert {:error,
              %{
                code: "quota_evidence_unavailable",
                quota_refresh_attempted: false
              }} = RouteFiltering.filter_candidates(filter_input)
    end

    test "routes to preserved catalog source when another same-pool source has exhausted quota" do
      %{pool: pool, api_key: api_key} = active_api_key_fixture()
      source_a = active_upstream_assignment_fixture(pool, %{account_label: "Synthetic source A"})
      source_b = active_upstream_assignment_fixture(pool, %{account_label: "Synthetic source B"})
      model_id = "gpt-preserved-runtime-#{System.unique_integer([:positive])}"

      assert {:ok, %{models: [_model]}} =
               sync_catalog_step(pool, %{
                 source_a.assignment.id => [
                   runtime_sync_model(model_id, %{"source_marker" => "a"})
                 ],
                 source_b.assignment.id => [
                   runtime_sync_model(model_id, %{"source_marker" => "b"})
                 ]
               })

      assert {:ok, %{models: [_model]}} =
               sync_catalog_step(pool, %{
                 source_a.assignment.id => [],
                 source_b.assignment.id => [
                   runtime_sync_model(model_id, %{"source_marker" => "b-current"})
                 ]
               })

      context = CandidateEligibility.visible_model_context(pool, model_id)
      assert context.visible_model.exposed_model_id == model_id

      assert candidate_ids(context.candidate_snapshots) == [
               source_a.assignment.id,
               source_b.assignment.id
             ]

      assert get_in(context.visible_model.metadata, [
               "source_assignment_models",
               source_a.assignment.id,
               "source_marker"
             ]) == "a"

      assert get_in(context.visible_model.metadata, [
               "source_assignment_models",
               source_b.assignment.id,
               "source_marker"
             ]) == "b-current"

      upsert_primary_quota!(source_a.identity, Decimal.new("100"))
      upsert_primary_quota!(source_b.identity, Decimal.new("15"))

      filter_input =
        filter_input(pool, api_key, context.visible_model, context.candidate_snapshots)

      assert {:ok, filtered_candidates, filtered_options} =
               RouteFiltering.filter_candidates(filter_input)

      assert candidate_ids(filtered_candidates) == [source_b.assignment.id]
      assert filtered_options.routing.quota_decision["routing_state"] == "precise"

      upsert_primary_quota!(source_b.identity, Decimal.new("100"))

      assert {:error, %{code: "quota_exhausted"}} =
               RouteFiltering.filter_candidates(filter_input)
    end

    test "does not redeem saved reset when auto policy is disabled by default" do
      {:ok, upstream} =
        FakeUpstream.start_link({:path_json, %{"/api/codex/usage" => {200, usage_payload(0)}}})

      %{pool: pool, api_key: api_key} = active_api_key_fixture()

      %{identity: identity, assignment: assignment} =
        active_upstream_assignment_fixture(pool, %{metadata: saved_reset_metadata(upstream, 1)})

      upsert_weekly_exhausted_quota!(identity)
      filter_input = filter_input(pool, api_key, assignment, identity, "auto-disabled")

      assert {:error, %{code: "quota_exhausted"}} = RouteFiltering.filter_candidates(filter_input)
      assert [] = FakeUpstream.requests(upstream)
    end

    test "auto redemption ignores stale in-progress redemption until manual recovery" do
      {:ok, upstream} =
        FakeUpstream.start_link(
          {:path_json,
           %{
             "/api/codex/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}},
             "/api/codex/usage" => {200, usage_payload(0)}
           }}
        )

      started_at = DateTime.utc_now() |> DateTime.add(-5, :minute) |> DateTime.to_iso8601()
      %{pool: pool, api_key: api_key} = active_api_key_fixture()

      %{identity: identity, assignment: assignment} =
        active_upstream_assignment_fixture(pool, %{
          metadata:
            upstream
            |> saved_reset_metadata(1)
            |> Map.put("saved_reset_redemption", %{
              "status" => "redeeming",
              "attempt_id" => Ecto.UUID.generate(),
              "generation" => 1,
              "trigger_kind" => "gateway_auto",
              "started_at" => started_at,
              "finished_at" => nil,
              "result" => nil
            })
        })

      identity = enable_saved_reset_auto_redeem!(identity)
      upsert_weekly_exhausted_quota!(identity)
      filter_input = filter_input(pool, api_key, assignment, identity, "auto-stale-redemption")

      assert {:error, %{code: "quota_exhausted"}} = RouteFiltering.filter_candidates(filter_input)
      assert [] = FakeUpstream.requests(upstream)
    end

    test "auto redeems saved reset and refilters when weekly account quota is exhausted" do
      {:ok, upstream} =
        FakeUpstream.start_link(
          {:path_json,
           %{
             "/api/codex/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}},
             "/api/codex/usage" => {200, usage_payload(0)}
           }}
        )

      %{pool: pool, api_key: api_key} = active_api_key_fixture()

      %{identity: identity, assignment: assignment} =
        active_upstream_assignment_fixture(pool, %{metadata: saved_reset_metadata(upstream, 1)})

      identity = enable_saved_reset_auto_redeem!(identity)
      upsert_weekly_exhausted_quota!(identity)
      filter_input = filter_input(pool, api_key, assignment, identity, "auto-enabled")

      assert {:ok, [{%{id: assignment_id}, %{id: identity_id}}], filtered_options} =
               RouteFiltering.filter_candidates(filter_input)

      assert assignment_id == assignment.id
      assert identity_id == identity.id
      assert filtered_options.routing.quota_decision["routing_state"] == "precise"

      assert [consume_request, usage_request] = FakeUpstream.requests(upstream)
      assert consume_request.method == "POST"
      assert consume_request.path == "/api/codex/rate-limit-reset-credits/consume"
      assert is_binary(consume_request.json["redeem_request_id"])
      assert usage_request.path == "/api/codex/usage"

      persisted = Repo.reload!(identity)
      assert get_in(persisted.metadata, ["saved_reset_redemption", "result", "code"]) == "reset"
      metadata_json = Jason.encode!(persisted.metadata)
      refute metadata_json =~ consume_request.json["redeem_request_id"]
      refute metadata_json =~ "credit_id"
    end

    test "auto redeems saved reset before exhaustion when every candidate is near weekly limit" do
      {:ok, upstream} =
        FakeUpstream.start_link(
          {:path_json,
           %{
             "/api/codex/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}},
             "/api/codex/usage" => {200, usage_payload(0)}
           }}
        )

      %{pool: pool, api_key: api_key} = active_api_key_fixture()

      first =
        active_upstream_assignment_fixture(pool, %{metadata: saved_reset_metadata(upstream, 2)})

      second = active_upstream_assignment_fixture(pool)

      first_identity =
        enable_saved_reset_auto_redeem!(first.identity, %{
          saved_reset_auto_redeem_trigger_mode: "threshold",
          saved_reset_auto_redeem_quota_threshold_percent: 95
        })

      upsert_weekly_pressure_quota!(first_identity, Decimal.new("96"))
      upsert_weekly_pressure_quota!(second.identity, Decimal.new("97"))

      filter_input =
        filter_input(
          pool,
          api_key,
          [{first.assignment, first_identity}, {second.assignment, second.identity}],
          "threshold-enabled"
        )

      assert {:ok, filtered_candidates, _filtered_options} =
               RouteFiltering.filter_candidates(filter_input)

      assert Enum.map(filtered_candidates, fn {assignment, _identity} -> assignment.id end) == [
               first.assignment.id,
               second.assignment.id
             ]

      assert [consume_request, usage_request] = FakeUpstream.requests(upstream)
      assert consume_request.method == "POST"
      assert consume_request.path == "/api/codex/rate-limit-reset-credits/consume"
      assert usage_request.path == "/api/codex/usage"
    end

    test "auto redeems saved reset before exhaustion when a usable reset expires soon" do
      {:ok, upstream} =
        FakeUpstream.start_link(
          {:path_json,
           %{
             "/api/codex/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}},
             "/api/codex/usage" => {200, usage_payload(0)}
           }}
        )

      %{pool: pool, api_key: api_key} = active_api_key_fixture()

      %{identity: identity, assignment: assignment} =
        active_upstream_assignment_fixture(pool, %{
          metadata: saved_reset_metadata(upstream, 1, expiring_saved_reset_attrs())
        })

      identity = enable_saved_reset_auto_redeem!(identity)
      upsert_weekly_pressure_quota!(identity, Decimal.new("25"))
      filter_input = filter_input(pool, api_key, assignment, identity, "expiring-reset")

      assert {:ok, [{%{id: assignment_id}, %{id: identity_id}}], _filtered_options} =
               RouteFiltering.filter_candidates(filter_input)

      assert assignment_id == assignment.id
      assert identity_id == identity.id

      assert [consume_request, usage_request] = FakeUpstream.requests(upstream)
      assert consume_request.method == "POST"
      assert consume_request.path == "/api/codex/rate-limit-reset-credits/consume"
      assert usage_request.path == "/api/codex/usage"
    end

    test "expiring saved reset auto redemption waits when no weekly usage would be recovered" do
      {:ok, upstream} =
        FakeUpstream.start_link(
          {:path_json,
           %{
             "/api/codex/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}},
             "/api/codex/usage" => {200, usage_payload(1)}
           }}
        )

      %{pool: pool, api_key: api_key} = active_api_key_fixture()

      %{identity: identity, assignment: assignment} =
        active_upstream_assignment_fixture(pool, %{
          metadata: saved_reset_metadata(upstream, 1, expiring_saved_reset_attrs())
        })

      identity = enable_saved_reset_auto_redeem!(identity)
      upsert_weekly_pressure_quota!(identity, Decimal.new("0"))
      filter_input = filter_input(pool, api_key, assignment, identity, "expiring-unused")

      assert {:ok, _filtered_candidates, _filtered_options} =
               RouteFiltering.filter_candidates(filter_input)

      assert [] = FakeUpstream.requests(upstream)
    end

    test "early auto redemption waits when another candidate is not near the weekly limit" do
      {:ok, upstream} =
        FakeUpstream.start_link(
          {:path_json,
           %{
             "/api/codex/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}},
             "/api/codex/usage" => {200, usage_payload(0)}
           }}
        )

      %{pool: pool, api_key: api_key} = active_api_key_fixture()

      first =
        active_upstream_assignment_fixture(pool, %{metadata: saved_reset_metadata(upstream, 2)})

      second = active_upstream_assignment_fixture(pool)

      first_identity =
        enable_saved_reset_auto_redeem!(first.identity, %{
          saved_reset_auto_redeem_trigger_mode: "threshold",
          saved_reset_auto_redeem_quota_threshold_percent: 95
        })

      upsert_weekly_pressure_quota!(first_identity, Decimal.new("96"))
      upsert_weekly_pressure_quota!(second.identity, Decimal.new("80"))

      filter_input =
        filter_input(
          pool,
          api_key,
          [{first.assignment, first_identity}, {second.assignment, second.identity}],
          "threshold-waits-for-pool"
        )

      assert {:ok, _filtered_candidates, _filtered_options} =
               RouteFiltering.filter_candidates(filter_input)

      assert [] = FakeUpstream.requests(upstream)
    end

    test "early auto redemption ignores stale weekly quota pressure" do
      {:ok, upstream} =
        FakeUpstream.start_link({:path_json, %{"/api/codex/usage" => {200, usage_payload(2)}}})

      %{pool: pool, api_key: api_key} = active_api_key_fixture()

      upstream_assignment =
        active_upstream_assignment_fixture(pool, %{metadata: saved_reset_metadata(upstream, 2)})

      identity =
        enable_saved_reset_auto_redeem!(upstream_assignment.identity, %{
          saved_reset_auto_redeem_trigger_mode: "threshold",
          saved_reset_auto_redeem_quota_threshold_percent: 95
        })

      upsert_weekly_pressure_quota!(identity, Decimal.new("96"), freshness_state: "stale")

      filter_input =
        filter_input(pool, api_key, upstream_assignment.assignment, identity, "threshold-stale")

      assert {:ok, _filtered_candidates, _filtered_options} =
               RouteFiltering.filter_candidates(filter_input)

      assert [] = FakeUpstream.requests(upstream)
    end

    test "early auto redemption ignores inferred weekly quota pressure" do
      {:ok, upstream} =
        FakeUpstream.start_link({:path_json, %{"/api/codex/usage" => {200, usage_payload(2)}}})

      %{pool: pool, api_key: api_key} = active_api_key_fixture()

      upstream_assignment =
        active_upstream_assignment_fixture(pool, %{metadata: saved_reset_metadata(upstream, 2)})

      identity =
        enable_saved_reset_auto_redeem!(upstream_assignment.identity, %{
          saved_reset_auto_redeem_trigger_mode: "threshold",
          saved_reset_auto_redeem_quota_threshold_percent: 95
        })

      upsert_weekly_pressure_quota!(identity, Decimal.new("96"), source_precision: "inferred")

      filter_input =
        filter_input(
          pool,
          api_key,
          upstream_assignment.assignment,
          identity,
          "threshold-inferred"
        )

      assert {:ok, _filtered_candidates, _filtered_options} =
               RouteFiltering.filter_candidates(filter_input)

      assert [] = FakeUpstream.requests(upstream)
    end

    test "auto redemption requires weekly-account-only quota exhaustion" do
      {:ok, upstream} =
        FakeUpstream.start_link(
          {:path_json,
           %{
             "/api/codex/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}},
             "/api/codex/usage" => {200, usage_payload(0)}
           }}
        )

      %{pool: pool, api_key: api_key} = active_api_key_fixture()

      %{identity: identity, assignment: assignment} =
        active_upstream_assignment_fixture(pool, %{metadata: saved_reset_metadata(upstream, 1)})

      identity = enable_saved_reset_auto_redeem!(identity)
      upsert_primary_exhausted_quota!(identity)
      filter_input = filter_input(pool, api_key, assignment, identity, "primary-exhausted")

      assert {:error, %{code: "quota_exhausted"}} = RouteFiltering.filter_candidates(filter_input)
      assert [] = FakeUpstream.requests(upstream)
    end
  end

  defp filter_input(pool, api_key, assignment, identity, suffix) do
    filter_input(pool, api_key, [{assignment, identity}], suffix)
  end

  defp candidate_ids(candidates),
    do: Enum.map(candidates, fn {assignment, _identity} -> assignment.id end)

  defp filter_input(pool, api_key, model, candidates) when is_list(candidates) do
    payload = %{"model" => model.exposed_model_id, "input" => "route filtering"}
    request_options = RequestOptions.build(%{}, "/backend-api/codex/responses", payload)

    FilterInput.new(%{
      auth: %{pool: pool, api_key: api_key},
      model: model,
      endpoint: "/backend-api/codex/responses",
      payload: payload,
      request_options: request_options,
      candidates: candidates
    })
  end

  defp filter_input(pool, api_key, candidates, suffix) when is_list(candidates) do
    model =
      model_fixture(pool, %{
        exposed_model_id: "gpt-route-filtering-#{suffix}-#{System.unique_integer([:positive])}",
        metadata: %{
          "source_assignment_ids" =>
            Enum.map(candidates, fn {assignment, _identity} -> assignment.id end)
        }
      })

    payload = %{"model" => model.exposed_model_id, "input" => "route filtering"}
    request_options = RequestOptions.build(%{}, "/backend-api/codex/responses", payload)

    FilterInput.new(%{
      auth: %{pool: pool, api_key: api_key},
      model: model,
      endpoint: "/backend-api/codex/responses",
      payload: payload,
      request_options: request_options,
      candidates: candidates
    })
  end

  defp sync_catalog_step(pool, assignment_models) when is_map(assignment_models) do
    Catalog.sync_pool_catalog(pool,
      fetcher: fn %{assignment: assignment} ->
        {:ok, Map.fetch!(assignment_models, assignment.id)}
      end
    )
  end

  defp runtime_sync_model(model_id, attrs) when is_binary(model_id) and is_map(attrs) do
    Map.merge(
      %{
        "id" => model_id,
        "display_name" => "Synthetic Preserved Runtime",
        "owned_by" => "synthetic",
        "capabilities" => %{"responses" => true, "streaming" => true}
      },
      attrs
    )
  end

  defp saved_reset_metadata(upstream, available_count, saved_reset_attrs \\ %{}) do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

    saved_resets =
      Map.merge(
        %{
          "status" => "reported",
          "available_count" => available_count,
          "source" => "codex_usage_api",
          "path_style" => "codex_api",
          "observed_at" => observed_at,
          "usage_path" => "/api/codex/usage",
          "reason" => nil
        },
        saved_reset_attrs
      )

    %{
      "usage_base_url" => FakeUpstream.url(upstream),
      "saved_resets" => saved_resets
    }
  end

  defp expiring_saved_reset_attrs do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    expires_at = timestamp |> DateTime.add(1, :hour) |> DateTime.to_iso8601()
    observed_at = DateTime.to_iso8601(timestamp)

    %{
      "available_expires_at" => [expires_at],
      "next_expires_at" => expires_at,
      "expires_observed_at" => observed_at,
      "expires_refresh_attempted_at" => observed_at
    }
  end

  defp enable_saved_reset_auto_redeem!(%UpstreamIdentity{} = identity, attrs \\ %{}) do
    identity
    |> UpstreamIdentity.changeset(
      Map.merge(
        %{
          saved_reset_auto_redeem_enabled: true,
          saved_reset_auto_redeem_min_blocked_minutes: 60,
          saved_reset_auto_redeem_keep_credits: 0,
          updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
        },
        attrs
      )
    )
    |> Repo.update!()
  end

  defp upsert_weekly_exhausted_quota!(identity) do
    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [weekly_exhausted_quota_attrs()])
  end

  defp upsert_primary_exhausted_quota!(identity) do
    upsert_primary_quota!(identity, Decimal.new("100"))
  end

  defp upsert_primary_quota!(identity, used_percent) do
    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [primary_quota_attrs(used_percent)])
  end

  defp upsert_weekly_pressure_quota!(identity, used_percent, attrs \\ []) do
    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               weekly_pressure_quota_attrs(used_percent, attrs)
             ])
  end

  defp weekly_exhausted_quota_attrs do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{
      quota_key: "account",
      window_kind: "secondary",
      window_minutes: 10_080,
      used_percent: Decimal.new("100"),
      reset_at: DateTime.add(now, 2, :hour),
      observed_at: now,
      last_sync_at: now,
      source: "codex_usage_api",
      source_precision: "observed",
      quota_scope: "account",
      quota_family: "account",
      freshness_state: "fresh"
    }
  end

  defp primary_quota_attrs(used_percent) do
    weekly_exhausted_quota_attrs()
    |> Map.merge(%{
      window_kind: "primary",
      window_minutes: 300,
      used_percent: used_percent
    })
  end

  defp weekly_pressure_quota_attrs(used_percent, attrs) do
    weekly_exhausted_quota_attrs()
    |> Map.merge(%{used_percent: used_percent})
    |> Map.merge(Map.new(attrs))
  end

  defp usage_payload(available_count) do
    %{
      "plan_type" => "pro",
      "rate_limit_reset_credits" => %{"available_count" => available_count},
      "rate_limit" => %{
        "primary_window" => %{
          "used_percent" => 10,
          "limit_window_seconds" => 18_000,
          "reset_after_seconds" => 900
        }
      }
    }
  end
end
