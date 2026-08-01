defmodule CodexPooler.Accounting.PricingTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.DailyRollup
  alias CodexPooler.Accounting.{LedgerEntry, RequestLogFact}
  alias CodexPooler.Catalog.{OpenAIPricingImporter, PricingSnapshot}
  alias CodexPooler.Repo

  import CodexPooler.AccountingTestSupport
  import CodexPooler.PoolerFixtures

  describe "gateway accounting pricing" do
    test "missing model pricing allows reservation and finalization as unpriced" do
      setup = accounting_setup()
      Repo.delete!(setup.pricing)

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{"model" => setup.model.exposed_model_id, "max_output_tokens" => 5},
                 %{correlation_id: "corr-missing-pricing"}
               )

      assert is_nil(reserved.pricing_snapshot)
      assert reserved.pricing_status == "unpriced_missing_model"
      assert is_nil(reserved.estimate.estimated_cost_micros)
      assert reserved.request.request_metadata["pricing"]["status"] == "unpriced_missing_model"
      assert reserved.request.request_metadata["reservation"]["estimated_cost_micros"] == nil
      assert reserved.reservation.details["pricing_status"] == "unpriced_missing_model"
      assert is_nil(reserved.reservation.pricing_snapshot_id)
      assert Decimal.equal?(reserved.reservation.estimated_cost_micros, Decimal.new(0))

      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

      assert {:ok, result} =
               Accounting.finalize_success(
                 reserved.request,
                 attempt,
                 %{status: "usage_known", input_tokens: 4, output_tokens: 3, total_tokens: 7},
                 %{response_status_code: 200}
               )

      assert result.settlement.details["pricing_status"] == "unpriced_missing_model"
      assert result.settlement.details["settled_cost_micros"] == nil
      assert is_nil(result.settlement.pricing_snapshot_id)
      assert Decimal.equal?(result.settlement.settled_cost_micros, Decimal.new(0))

      request = Repo.get!(CodexPooler.Accounting.Request, reserved.request.id)
      assert request.request_metadata["pricing"]["status"] == "unpriced_missing_model"
      refute request.last_error_code == "pricing_snapshot_unavailable"

      refute Repo.get_by(CodexPooler.Accounting.Request,
               correlation_id: "corr-missing-pricing-denied"
             )
    end

    test "explicit pricing refs price models from imported snapshots" do
      setup = accounting_setup()

      priced_model =
        model_fixture(setup.pool, %{
          exposed_model_id: "gpt-priced-ref",
          upstream_model_id: "gpt-priced-ref",
          pricing_ref: "gpt-priced-ref"
        })

      pricing =
        pricing_snapshot_fixture(setup.pricing, %{
          model_identifier: "gpt-priced-ref",
          input_token_micros: Decimal.new(100),
          output_token_micros: Decimal.new(200)
        })

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 priced_model,
                 %{"model" => priced_model.exposed_model_id, "max_output_tokens" => 3},
                 %{correlation_id: "corr-codex-openai-pricing-ref"}
               )

      assert reserved.pricing_status == "priced"
      assert reserved.pricing_snapshot.id == pricing.id

      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

      assert {:ok, result} =
               Accounting.finalize_success(
                 reserved.request,
                 attempt,
                 %{status: "usage_known", input_tokens: 2, output_tokens: 3, total_tokens: 5},
                 %{response_status_code: 200}
               )

      assert result.settlement.pricing_snapshot_id == pricing.id
      assert result.settlement.details["pricing_status"] == "priced"
      assert Decimal.equal?(result.settlement.settled_cost_micros, Decimal.new(800))
    end

    test "historical mixed-case identifiers resolve across exact and suffix availability paths" do
      setup = accounting_setup()
      unique = System.unique_integer([:positive])
      timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      cases = [
        %{path: :exact, availability: :priced},
        %{path: :exact, availability: :unavailable},
        %{path: :suffix, availability: :priced},
        %{path: :suffix, availability: :unavailable}
      ]

      Enum.each(cases, fn test_case ->
        base_identifier =
          "gpt-legacy-case-#{test_case.path}-#{test_case.availability}-#{unique}"

        requested_identifier =
          if test_case.path == :suffix, do: base_identifier <> "-spark", else: base_identifier

        model =
          model_fixture(setup.pool, %{
            exposed_model_id: requested_identifier,
            upstream_model_id: requested_identifier,
            pricing_ref: requested_identifier
          })

        pricing_snapshot_fixture(setup.pricing, %{
          model_identifier: base_identifier,
          price_version: "older-canonical-#{test_case.path}-#{test_case.availability}",
          config: pricing_config(%{"service_tier" => "priority"}),
          effective_at: DateTime.add(timestamp, -120, :second),
          captured_at: DateTime.add(timestamp, -120, :second)
        })

        historical_config =
          case test_case.availability do
            :priced ->
              pricing_config(%{"service_tier" => "fast"})

            :unavailable ->
              pricing_config(%{
                "service_tier" => "fast",
                "availability" => "unavailable"
              })
          end

        historical_attrs = %{
          model_identifier: String.upcase(base_identifier),
          price_version: "newer-historical-#{test_case.path}-#{test_case.availability}",
          config: historical_config,
          effective_at: DateTime.add(timestamp, -60, :second),
          captured_at: DateTime.add(timestamp, -60, :second)
        }

        historical_attrs =
          if test_case.availability == :unavailable do
            Map.merge(historical_attrs, %{
              input_token_micros: nil,
              cached_input_token_micros: nil,
              output_token_micros: nil,
              reasoning_token_micros: nil,
              request_base_micros: nil
            })
          else
            historical_attrs
          end

        historical = pricing_snapshot_fixture(setup.pricing, historical_attrs)

        assert {:ok, reserved} =
                 Accounting.reserve(
                   setup.auth,
                   model,
                   %{"model" => requested_identifier, "service_tier" => "priority"},
                   %{
                     correlation_id:
                       "corr-legacy-case-#{test_case.path}-#{test_case.availability}-#{unique}"
                   }
                 )

        case test_case.availability do
          :priced ->
            assert reserved.pricing_status == "priced"
            assert reserved.pricing_snapshot.id == historical.id

          :unavailable ->
            assert reserved.pricing_status == "unpriced_unavailable_price_bucket"
            assert is_nil(reserved.pricing_snapshot)
        end

        if test_case.path == :suffix do
          assert reserved.reservation.details["alias"] == %{
                   "source" => "suffix_inference",
                   "from" => requested_identifier,
                   "to" => String.upcase(base_identifier)
                 }
        else
          refute Map.has_key?(reserved.reservation.details, "alias")
        end
      end)

      missing_tier_identifier = "gpt-legacy-case-missing-tier-#{unique}"

      missing_tier_model =
        model_fixture(setup.pool, %{
          exposed_model_id: missing_tier_identifier,
          upstream_model_id: missing_tier_identifier,
          pricing_ref: missing_tier_identifier
        })

      pricing_snapshot_fixture(setup.pricing, %{
        model_identifier: String.upcase(missing_tier_identifier),
        price_version: "historical-missing-tier",
        config: pricing_config(%{"service_tier" => "standard"}),
        effective_at: DateTime.add(timestamp, -60, :second),
        captured_at: DateTime.add(timestamp, -60, :second)
      })

      assert {:ok, missing_tier_reserved} =
               Accounting.reserve(
                 setup.auth,
                 missing_tier_model,
                 %{"model" => missing_tier_identifier, "service_tier" => "flex"},
                 %{correlation_id: "corr-legacy-case-missing-tier-#{unique}"}
               )

      assert missing_tier_reserved.pricing_status == "unpriced_missing_tier"
    end

    test "models without pricing refs use upstream model pricing" do
      setup = accounting_setup()

      priced_model =
        model_fixture(setup.pool, %{
          exposed_model_id: "gpt-unmapped",
          upstream_model_id: "gpt-unmapped",
          pricing_ref: nil
        })

      pricing_snapshot_fixture(setup.pricing, %{
        model_identifier: "gpt-unmapped"
      })

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 priced_model,
                 %{"model" => priced_model.exposed_model_id, "max_output_tokens" => 1},
                 %{correlation_id: "corr-codex-unmapped-pricing"}
               )

      assert reserved.pricing_status == "priced"
      assert reserved.pricing_snapshot.model_identifier == "gpt-unmapped"
    end

    test "exact pricing wins when both exact and suffix-inferred snapshots exist" do
      setup = accounting_setup()
      unique = System.unique_integer([:positive])
      base_identifier = "gpt-example-codex-#{unique}"
      suffix_identifier = "#{base_identifier}-spark"

      priced_model =
        model_fixture(setup.pool, %{
          exposed_model_id: suffix_identifier,
          upstream_model_id: suffix_identifier,
          pricing_ref: suffix_identifier
        })

      inferred_pricing =
        pricing_snapshot_fixture(setup.pricing, %{
          model_identifier: base_identifier,
          input_token_micros: Decimal.new(1),
          output_token_micros: Decimal.new(2)
        })

      exact_pricing =
        pricing_snapshot_fixture(setup.pricing, %{
          model_identifier: suffix_identifier,
          input_token_micros: Decimal.new(100),
          output_token_micros: Decimal.new(200)
        })

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 priced_model,
                 %{"model" => priced_model.exposed_model_id, "max_output_tokens" => 3},
                 %{correlation_id: "corr-exact-suffix-pricing-#{unique}"}
               )

      assert reserved.pricing_status == "priced"
      assert reserved.pricing_snapshot.id == exact_pricing.id
      refute reserved.pricing_snapshot.id == inferred_pricing.id

      assert reserved.request.request_metadata["pricing"]["snapshot"]["model_identifier"] ==
               suffix_identifier

      refute Map.has_key?(reserved.request.request_metadata["pricing"], "alias")
      refute Map.has_key?(reserved.reservation.details, "alias")
    end

    test "suffix-inferred pricing records alias diagnostics and settles as priced" do
      setup = accounting_setup()
      unique = System.unique_integer([:positive])
      base_identifier = "gpt-example-codex-#{unique}"
      suffix_identifier = "#{base_identifier}-spark"

      inferred_model =
        model_fixture(setup.pool, %{
          exposed_model_id: suffix_identifier,
          upstream_model_id: suffix_identifier,
          pricing_ref: suffix_identifier
        })

      pricing =
        pricing_snapshot_fixture(setup.pricing, %{
          model_identifier: base_identifier,
          input_token_micros: Decimal.new(100),
          output_token_micros: Decimal.new(200)
        })

      expected_alias = %{
        "source" => "suffix_inference",
        "from" => suffix_identifier,
        "to" => base_identifier
      }

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 inferred_model,
                 %{"model" => inferred_model.exposed_model_id, "max_output_tokens" => 3},
                 %{correlation_id: "corr-suffix-inferred-pricing-#{unique}"}
               )

      assert reserved.pricing_status == "priced"
      assert reserved.pricing_snapshot.id == pricing.id
      assert reserved.request.request_metadata["pricing"]["alias"] == expected_alias
      assert reserved.reservation.details["alias"] == expected_alias

      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

      assert {:ok, result} =
               Accounting.finalize_success(
                 reserved.request,
                 attempt,
                 %{status: "usage_known", input_tokens: 2, output_tokens: 3, total_tokens: 5},
                 %{response_status_code: 200}
               )

      assert result.settlement.pricing_snapshot_id == pricing.id
      assert result.settlement.details["pricing_status"] == "priced"
      assert result.settlement.details["alias"] == expected_alias
      assert Decimal.equal?(result.settlement.settled_cost_micros, Decimal.new(800))

      request = Repo.get!(CodexPooler.Accounting.Request, reserved.request.id)
      assert request.request_metadata["pricing"]["status"] == "priced"
      assert request.request_metadata["pricing"]["alias"] == expected_alias
    end

    test "suffix inference does not trim two arbitrary non-date suffixes" do
      setup = accounting_setup()
      unique = System.unique_integer([:positive])
      base_identifier = "gpt-example-codex-#{unique}"
      unsafe_identifier = "#{base_identifier}-super-spark"

      unsafe_model =
        model_fixture(setup.pool, %{
          exposed_model_id: unsafe_identifier,
          upstream_model_id: unsafe_identifier,
          pricing_ref: unsafe_identifier
        })

      pricing_snapshot_fixture(setup.pricing, %{
        model_identifier: base_identifier,
        input_token_micros: Decimal.new(100),
        output_token_micros: Decimal.new(200)
      })

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 unsafe_model,
                 %{"model" => unsafe_model.exposed_model_id, "max_output_tokens" => 3},
                 %{correlation_id: "corr-broad-suffix-unpriced-#{unique}"}
               )

      assert reserved.pricing_status == "unpriced_missing_model"
      assert is_nil(reserved.pricing_snapshot)
      refute Map.has_key?(reserved.request.request_metadata["pricing"], "alias")
      refute Map.has_key?(reserved.reservation.details, "alias")
    end

    test "suffix inference leaves ambiguous nearest-distance candidates unpriced" do
      setup = accounting_setup()
      unique = System.unique_integer([:positive])
      upstream_base_identifier = "gpt-example-upstream-#{unique}"
      exposed_base_identifier = "gpt-example-exposed-#{unique}"
      upstream_identifier = "#{upstream_base_identifier}-spark"
      exposed_identifier = "#{exposed_base_identifier}-spark"

      ambiguous_model =
        model_fixture(setup.pool, %{
          exposed_model_id: exposed_identifier,
          upstream_model_id: upstream_identifier,
          pricing_ref: nil
        })

      pricing_snapshot_fixture(setup.pricing, %{
        model_identifier: upstream_base_identifier,
        input_token_micros: Decimal.new(100),
        output_token_micros: Decimal.new(200)
      })

      pricing_snapshot_fixture(setup.pricing, %{
        model_identifier: exposed_base_identifier,
        input_token_micros: Decimal.new(300),
        output_token_micros: Decimal.new(400)
      })

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 ambiguous_model,
                 %{"model" => ambiguous_model.exposed_model_id, "max_output_tokens" => 3},
                 %{correlation_id: "corr-ambiguous-suffix-unpriced-#{unique}"}
               )

      assert reserved.pricing_status == "unpriced_missing_model"
      assert is_nil(reserved.pricing_snapshot)
      refute Map.has_key?(reserved.request.request_metadata["pricing"], "alias")
      refute Map.has_key?(reserved.reservation.details, "alias")
    end

    test "suffix inference supports date version suffixes explicitly" do
      setup = accounting_setup()
      unique = System.unique_integer([:positive])
      base_identifier = "gpt-example-codex-#{unique}"
      dated_identifier = "#{base_identifier}-2026-03-17"

      dated_model =
        model_fixture(setup.pool, %{
          exposed_model_id: dated_identifier,
          upstream_model_id: dated_identifier,
          pricing_ref: dated_identifier
        })

      pricing =
        pricing_snapshot_fixture(setup.pricing, %{
          model_identifier: base_identifier,
          input_token_micros: Decimal.new(100),
          output_token_micros: Decimal.new(200)
        })

      expected_alias = %{
        "source" => "suffix_inference",
        "from" => dated_identifier,
        "to" => base_identifier
      }

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 dated_model,
                 %{"model" => dated_model.exposed_model_id, "max_output_tokens" => 3},
                 %{correlation_id: "corr-dated-suffix-priced-#{unique}"}
               )

      assert reserved.pricing_status == "priced"
      assert reserved.pricing_snapshot.id == pricing.id
      assert reserved.request.request_metadata["pricing"]["alias"] == expected_alias
      assert reserved.reservation.details["alias"] == expected_alias
    end

    test "missing requested service tier allows reservation with tier-specific status" do
      setup = accounting_setup()

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{
                   "model" => setup.model.exposed_model_id,
                   "service_tier" => "flex",
                   "max_output_tokens" => 2
                 },
                 %{correlation_id: "corr-missing-tier"}
               )

      assert reserved.pricing_status == "unpriced_missing_tier"
      assert reserved.reservation.details["pricing_status"] == "unpriced_missing_tier"
      assert reserved.reservation.details["requested_service_tier"] == "flex"
      assert reserved.reservation.details["service_tier"] == "flex"
      assert is_nil(reserved.pricing_snapshot)
    end

    test "batch service tier is unpriced unless batch usage is explicit" do
      setup = accounting_setup()

      batch_pricing =
        pricing_snapshot_fixture(setup.pricing, %{
          config: pricing_config(%{"service_tier" => "batch"}),
          input_token_micros: Decimal.new(10),
          output_token_micros: Decimal.new(20)
        })

      assert {:ok, unpriced} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{
                   "model" => setup.model.exposed_model_id,
                   "service_tier" => "batch",
                   "max_output_tokens" => 1
                 },
                 %{correlation_id: "corr-batch-not-explicit"}
               )

      assert unpriced.pricing_status == "unpriced_batch_tier"
      assert is_nil(unpriced.pricing_snapshot)
      assert unpriced.reservation.details["service_tier"] == "batch"
      assert unpriced.reservation.details["batch_usage"] == false

      assert {:ok, priced} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{
                   "model" => setup.model.exposed_model_id,
                   "service_tier" => "batch",
                   "max_output_tokens" => 1
                 },
                 %{correlation_id: "corr-batch-explicit", batch_usage: true}
               )

      assert priced.pricing_status == "priced"
      assert priced.pricing_snapshot.id == batch_pricing.id
      assert priced.reservation.details["service_tier"] == "batch"
      assert priced.reservation.details["batch_usage"] == true
    end

    test "batch usage atom-key false takes precedence over string-key true" do
      setup = accounting_setup()

      _batch_pricing =
        pricing_snapshot_fixture(setup.pricing, %{
          config: pricing_config(%{"service_tier" => "batch"}),
          input_token_micros: Decimal.new(10),
          output_token_micros: Decimal.new(20)
        })

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{
                   "model" => setup.model.exposed_model_id,
                   "service_tier" => "batch",
                   "max_output_tokens" => 1,
                   :batch_usage => false,
                   "batch_usage" => true
                 },
                 %{
                   :correlation_id => "corr-batch-explicit-false-precedence",
                   :batch_usage => false,
                   "batch_usage" => true,
                   :request_metadata => %{
                     :batch_usage => false,
                     "batch_usage" => true,
                     :pricing => %{:batch_usage => false, "batch_usage" => true}
                   }
                 }
               )

      assert reserved.pricing_status == "unpriced_batch_tier"
      assert reserved.reservation.details["batch_usage"] == false
    end

    test "enforced service tier drives pricing selection" do
      setup = accounting_setup()

      priority_pricing =
        pricing_snapshot_fixture(setup.pricing, %{
          config: pricing_config(%{"service_tier" => "priority"}),
          input_token_micros: Decimal.new(50),
          output_token_micros: Decimal.new(75)
        })

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{
                   "model" => setup.model.exposed_model_id,
                   "service_tier" => "default",
                   "max_output_tokens" => 1
                 },
                 %{
                   correlation_id: "corr-enforced-tier",
                   api_key_policy: %{enforced_service_tier: "priority"}
                 }
               )

      assert reserved.pricing_snapshot.id == priority_pricing.id
      assert reserved.pricing_status == "priced"
      assert reserved.reservation.details["requested_service_tier"] == "priority"
      assert reserved.reservation.details["service_tier"] == "priority"
    end

    test "new fast tier accounting facts are canonical while provider metadata stays unchanged" do
      setup = accounting_setup()

      priority_pricing =
        pricing_snapshot_fixture(setup.pricing, %{
          config: pricing_config(%{"service_tier" => "priority"}),
          input_token_micros: Decimal.new(50),
          output_token_micros: Decimal.new(75)
        })

      sensitive_prompt = "accounting-fast-tier-prompt-must-not-persist"
      sensitive_token = "Bearer accounting-fast-tier-token-must-not-persist"

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{
                   "model" => setup.model.exposed_model_id,
                   "service_tier" => "fast",
                   "input" => sensitive_prompt,
                   "max_output_tokens" => 1
                 },
                 %{
                   correlation_id: "corr-fast-tier-canonical-facts",
                   request_metadata: %{"authorization" => sensitive_token}
                 }
               )

      assert reserved.pricing_snapshot.id == priority_pricing.id
      assert reserved.pricing_service_tier == "priority"
      assert reserved.request.requested_service_tier == "priority"
      assert reserved.request.service_tier == "priority"
      assert reserved.request.request_metadata["pricing"]["requested_service_tier"] == "priority"
      assert reserved.reservation.details["requested_service_tier"] == "priority"
      assert reserved.reservation.details["service_tier"] == "priority"

      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

      assert {:ok, result} =
               Accounting.finalize_success(
                 reserved.request,
                 attempt,
                 %{
                   status: "usage_known",
                   input_tokens: 2,
                   output_tokens: 1,
                   total_tokens: 3,
                   service_tier: "fast"
                 },
                 %{
                   response_status_code: 200,
                   attempt_metadata: %{"service_tier" => "fast"}
                 }
               )

      request = Repo.get!(CodexPooler.Accounting.Request, reserved.request.id)
      persisted_attempt = Repo.get!(CodexPooler.Accounting.Attempt, attempt.id)

      assert request.requested_service_tier == "priority"
      assert request.actual_service_tier == "priority"
      assert request.service_tier == "priority"
      assert request.request_metadata["pricing"]["requested_service_tier"] == "priority"
      assert request.request_metadata["pricing"]["actual_service_tier"] == "priority"
      assert request.request_metadata["pricing"]["service_tier"] == "priority"
      assert result.settlement.details["requested_service_tier"] == "priority"
      assert result.settlement.details["actual_service_tier"] == "priority"
      assert result.settlement.details["service_tier"] == "priority"
      assert result.release.details["requested_service_tier"] == "priority"
      assert result.release.details["actual_service_tier"] == "priority"
      assert result.release.details["service_tier"] == "priority"
      assert persisted_attempt.response_metadata["service_tier"] == "fast"

      assert %{items: [log], total: 1} =
               Accounting.list_request_logs(setup.pool,
                 filters: [request_id: "corr-fast-tier-canonical-facts"]
               )

      assert log.requested_service_tier == "priority"
      assert log.actual_service_tier == "priority"
      assert log.service_tier == "priority"

      accounting_text =
        inspect([request, reserved.reservation, result.settlement, result.release, log])

      refute accounting_text =~ sensitive_prompt
      refute accounting_text =~ sensitive_token
    end

    test "priority pricing aliases use recency before canonical tie breaking" do
      setup = accounting_setup()
      timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      cases = [
        %{
          suffix: "newer-effective",
          priority_effective_at: DateTime.add(timestamp, -180, :second),
          priority_captured_at: DateTime.add(timestamp, -180, :second),
          fast_effective_at: DateTime.add(timestamp, -120, :second),
          fast_captured_at: DateTime.add(timestamp, -120, :second),
          expected_tier: "fast"
        },
        %{
          suffix: "newer-captured-revision",
          priority_effective_at: DateTime.add(timestamp, -120, :second),
          priority_captured_at: DateTime.add(timestamp, -180, :second),
          fast_effective_at: DateTime.add(timestamp, -120, :second),
          fast_captured_at: DateTime.add(timestamp, -60, :second),
          expected_tier: "fast"
        },
        %{
          suffix: "canonical-tie",
          priority_effective_at: DateTime.add(timestamp, -120, :second),
          priority_captured_at: DateTime.add(timestamp, -60, :second),
          fast_effective_at: DateTime.add(timestamp, -120, :second),
          fast_captured_at: DateTime.add(timestamp, -60, :second),
          expected_tier: "priority"
        }
      ]

      for test_case <- cases do
        identifier = "gpt-priority-alias-#{test_case.suffix}"

        model =
          model_fixture(setup.pool, %{
            exposed_model_id: identifier,
            upstream_model_id: identifier,
            pricing_ref: identifier
          })

        priority =
          pricing_snapshot_fixture(setup.pricing, %{
            model_identifier: identifier,
            price_version: "priority-#{test_case.suffix}",
            config: pricing_config(%{"service_tier" => "priority"}),
            input_token_micros: Decimal.new(100),
            output_token_micros: Decimal.new(200),
            effective_at: test_case.priority_effective_at,
            captured_at: test_case.priority_captured_at
          })

        fast =
          pricing_snapshot_fixture(setup.pricing, %{
            model_identifier: identifier,
            price_version: "fast-#{test_case.suffix}",
            config: pricing_config(%{"service_tier" => "fast"}),
            input_token_micros: Decimal.new(300),
            output_token_micros: Decimal.new(400),
            effective_at: test_case.fast_effective_at,
            captured_at: test_case.fast_captured_at
          })

        expected = if test_case.expected_tier == "priority", do: priority, else: fast

        assert {:ok, reserved} =
                 Accounting.reserve(
                   setup.auth,
                   model,
                   %{"model" => identifier, "service_tier" => "priority"},
                   %{correlation_id: "corr-priority-alias-#{test_case.suffix}"}
                 )

        assert reserved.pricing_snapshot.id == expected.id
        assert reserved.reservation.details["service_tier"] == "priority"
      end
    end

    test "priority pricing aliases order exact and suffix unavailable markers deterministically" do
      setup = accounting_setup()
      timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      exact_identifier = "gpt-priority-unavailable-exact"

      exact_model =
        model_fixture(setup.pool, %{
          exposed_model_id: exact_identifier,
          upstream_model_id: exact_identifier,
          pricing_ref: exact_identifier
        })

      pricing_snapshot_fixture(setup.pricing, %{
        model_identifier: exact_identifier,
        price_version: "exact-older-priority-priced",
        config: pricing_config(%{"service_tier" => "priority"}),
        effective_at: DateTime.add(timestamp, -180, :second),
        captured_at: DateTime.add(timestamp, -180, :second)
      })

      pricing_snapshot_fixture(setup.pricing, %{
        model_identifier: exact_identifier,
        price_version: "exact-newer-fast-unavailable",
        config: pricing_config(%{"service_tier" => "fast", "availability" => "unavailable"}),
        input_token_micros: nil,
        cached_input_token_micros: nil,
        output_token_micros: nil,
        reasoning_token_micros: nil,
        request_base_micros: nil,
        effective_at: DateTime.add(timestamp, -60, :second),
        captured_at: DateTime.add(timestamp, -60, :second)
      })

      assert {:ok, exact_reserved} =
               Accounting.reserve(
                 setup.auth,
                 exact_model,
                 %{"model" => exact_identifier, "service_tier" => "priority"},
                 %{correlation_id: "corr-priority-unavailable-exact"}
               )

      assert exact_reserved.pricing_status == "unpriced_unavailable_price_bucket"
      assert is_nil(exact_reserved.pricing_snapshot)

      suffix_base = "gpt-priority-unavailable-suffix"
      suffix_identifier = suffix_base <> "-spark"

      suffix_model =
        model_fixture(setup.pool, %{
          exposed_model_id: suffix_identifier,
          upstream_model_id: suffix_identifier,
          pricing_ref: suffix_identifier
        })

      pricing_snapshot_fixture(setup.pricing, %{
        model_identifier: suffix_base,
        price_version: "suffix-fast-priced-tie",
        config: pricing_config(%{"service_tier" => "fast"}),
        effective_at: DateTime.add(timestamp, -60, :second),
        captured_at: DateTime.add(timestamp, -60, :second)
      })

      pricing_snapshot_fixture(setup.pricing, %{
        model_identifier: suffix_base,
        price_version: "suffix-priority-unavailable-tie",
        config: pricing_config(%{"service_tier" => "priority", "availability" => "unavailable"}),
        input_token_micros: nil,
        cached_input_token_micros: nil,
        output_token_micros: nil,
        reasoning_token_micros: nil,
        request_base_micros: nil,
        effective_at: DateTime.add(timestamp, -60, :second),
        captured_at: DateTime.add(timestamp, -60, :second)
      })

      assert {:ok, suffix_reserved} =
               Accounting.reserve(
                 setup.auth,
                 suffix_model,
                 %{"model" => suffix_identifier, "service_tier" => "fast"},
                 %{correlation_id: "corr-priority-unavailable-suffix"}
               )

      assert suffix_reserved.pricing_status == "unpriced_unavailable_price_bucket"
      assert is_nil(suffix_reserved.pricing_snapshot)

      assert suffix_reserved.reservation.details["alias"] == %{
               "source" => "suffix_inference",
               "from" => suffix_identifier,
               "to" => suffix_base
             }
    end

    test "suffix-inferred priced aliases use the newest compatible tier spelling" do
      setup = accounting_setup()
      timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      base_identifier = "gpt-priority-priced-suffix"
      suffix_identifier = base_identifier <> "-spark"

      model =
        model_fixture(setup.pool, %{
          exposed_model_id: suffix_identifier,
          upstream_model_id: suffix_identifier,
          pricing_ref: suffix_identifier
        })

      pricing_snapshot_fixture(setup.pricing, %{
        model_identifier: base_identifier,
        price_version: "suffix-older-priority-priced",
        config: pricing_config(%{"service_tier" => "priority"}),
        input_token_micros: Decimal.new(100),
        output_token_micros: Decimal.new(200),
        effective_at: DateTime.add(timestamp, -120, :second),
        captured_at: DateTime.add(timestamp, -120, :second)
      })

      newer_fast =
        pricing_snapshot_fixture(setup.pricing, %{
          model_identifier: base_identifier,
          price_version: "suffix-newer-fast-priced",
          config: pricing_config(%{"service_tier" => "fast"}),
          input_token_micros: Decimal.new(300),
          output_token_micros: Decimal.new(400),
          effective_at: DateTime.add(timestamp, -60, :second),
          captured_at: DateTime.add(timestamp, -60, :second)
        })

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 model,
                 %{"model" => suffix_identifier, "service_tier" => "priority"},
                 %{correlation_id: "corr-priority-priced-suffix"}
               )

      assert reserved.pricing_status == "priced"
      assert reserved.pricing_snapshot.id == newer_fast.id
      assert reserved.reservation.details["service_tier"] == "priority"

      assert reserved.reservation.details["alias"] == %{
               "source" => "suffix_inference",
               "from" => suffix_identifier,
               "to" => base_identifier
             }
    end

    test "new priority revisions do not rewrite historical fast attempt references" do
      setup = accounting_setup()
      timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      legacy_fast =
        pricing_snapshot_fixture(setup.pricing, %{
          price_version: "legacy-fast-attempt-reference",
          config: pricing_config(%{"service_tier" => "fast"}),
          effective_at: DateTime.add(timestamp, -120, :second),
          captured_at: DateTime.add(timestamp, -120, :second)
        })

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{"model" => setup.model.exposed_model_id, "service_tier" => "priority"},
                 %{correlation_id: "corr-legacy-fast-attempt-reference"}
               )

      assert reserved.pricing_snapshot.id == legacy_fast.id
      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)
      assert attempt.pricing_snapshot_id == legacy_fast.id

      newer_priority =
        pricing_snapshot_fixture(setup.pricing, %{
          price_version: "newer-priority-after-fast-attempt",
          config: pricing_config(%{"service_tier" => "priority"}),
          effective_at: DateTime.add(timestamp, -60, :second),
          captured_at: DateTime.add(timestamp, -60, :second)
        })

      assert {:ok, newer_reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{"model" => setup.model.exposed_model_id, "service_tier" => "fast"},
                 %{correlation_id: "corr-new-priority-after-fast-attempt"}
               )

      assert newer_reserved.pricing_snapshot.id == newer_priority.id

      assert Repo.get!(CodexPooler.Accounting.Attempt, attempt.id).pricing_snapshot_id ==
               legacy_fast.id

      assert Repo.get!(PricingSnapshot, legacy_fast.id).config["service_tier"] == "fast"
    end

    test "auto service tier is unpriced until actual response tier is known" do
      setup = accounting_setup()

      priority_pricing =
        pricing_snapshot_fixture(setup.pricing, %{
          config: pricing_config(%{"service_tier" => "priority"}),
          input_token_micros: Decimal.new(100),
          output_token_micros: Decimal.new(200)
        })

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{
                   "model" => setup.model.exposed_model_id,
                   "service_tier" => "auto",
                   "max_output_tokens" => 1
                 },
                 %{correlation_id: "corr-auto-tier"}
               )

      assert reserved.pricing_status == "unpriced_auto_tier"
      assert is_nil(reserved.pricing_snapshot)
      assert reserved.request.request_metadata["pricing"]["status"] == "unpriced_auto_tier"

      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

      assert {:ok, result} =
               Accounting.finalize_success(
                 reserved.request,
                 attempt,
                 %{status: "usage_known", input_tokens: 2, output_tokens: 1, total_tokens: 3},
                 %{response_status_code: 200, attempt_metadata: %{"service_tier" => "priority"}}
               )

      assert result.settlement.pricing_snapshot_id == priority_pricing.id
      assert result.settlement.details["pricing_status"] == "priced"
      assert result.settlement.details["requested_service_tier"] == "auto"
      assert result.settlement.details["actual_service_tier"] == "priority"
      assert result.settlement.details["service_tier"] == "priority"
      assert Decimal.equal?(result.settlement.settled_cost_micros, Decimal.new(400))

      request = Repo.get!(CodexPooler.Accounting.Request, reserved.request.id)
      assert request.request_metadata["pricing"]["status"] == "priced"
      assert request.request_metadata["pricing"]["actual_service_tier"] == "priority"
    end

    test "explicit priority settles at standard pricing when upstream returns default" do
      setup = accounting_setup()

      priority_pricing =
        pricing_snapshot_fixture(setup.pricing, %{
          config: pricing_config(%{"service_tier" => "priority"}),
          input_token_micros: Decimal.new(100),
          output_token_micros: Decimal.new(200)
        })

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{
                   "model" => setup.model.exposed_model_id,
                   "service_tier" => "priority",
                   "max_output_tokens" => 1
                 },
                 %{correlation_id: "corr-priority-downgraded-to-default"}
               )

      assert reserved.pricing_snapshot.id == priority_pricing.id
      assert reserved.reservation.details["service_tier"] == "priority"
      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

      assert {:ok, result} =
               Accounting.finalize_success(
                 reserved.request,
                 attempt,
                 %{status: "usage_known", input_tokens: 2, output_tokens: 1, total_tokens: 3},
                 %{response_status_code: 200, attempt_metadata: %{"service_tier" => "default"}}
               )

      assert result.settlement.pricing_snapshot_id == setup.pricing.id
      assert result.settlement.details["requested_service_tier"] == "priority"
      assert result.settlement.details["actual_service_tier"] == "default"
      assert result.settlement.details["service_tier"] == "standard"
      assert Decimal.equal?(result.settlement.settled_cost_micros, Decimal.new(40))
    end

    test "auto service tier settles from normalized upstream usage tier" do
      setup = accounting_setup()

      flex_pricing =
        pricing_snapshot_fixture(setup.pricing, %{
          config: pricing_config(%{"service_tier" => "flex"}),
          input_token_micros: Decimal.new(25),
          output_token_micros: Decimal.new(50)
        })

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{
                   "model" => setup.model.exposed_model_id,
                   "service_tier" => "auto",
                   "max_output_tokens" => 1
                 },
                 %{correlation_id: "corr-auto-tier-from-usage"}
               )

      assert reserved.pricing_status == "unpriced_auto_tier"

      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

      assert {:ok, result} =
               Accounting.finalize_success(
                 reserved.request,
                 attempt,
                 %{
                   status: "usage_known",
                   input_tokens: 2,
                   output_tokens: 1,
                   total_tokens: 3,
                   service_tier: "flex"
                 },
                 %{response_status_code: 200}
               )

      assert result.settlement.pricing_snapshot_id == flex_pricing.id
      assert result.settlement.details["pricing_status"] == "priced"
      assert result.settlement.details["requested_service_tier"] == "auto"
      assert result.settlement.details["actual_service_tier"] == "flex"
      assert result.settlement.details["service_tier"] == "flex"
      assert Decimal.equal?(result.settlement.settled_cost_micros, Decimal.new(100))
    end

    test "long-context usage settles with the long-context price bucket" do
      setup = accounting_setup()

      long_context_pricing =
        pricing_snapshot_fixture(setup.pricing, %{
          config: pricing_config(%{"price_bucket" => "long_context"}),
          input_token_micros: Decimal.new(20),
          cached_input_token_micros: Decimal.new(2),
          output_token_micros: Decimal.new(30),
          reasoning_token_micros: Decimal.new(30)
        })

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{"model" => setup.model.exposed_model_id},
                 %{correlation_id: "corr-long-context-settlement"}
               )

      assert reserved.pricing_snapshot.id == setup.pricing.id

      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

      assert {:ok, result} =
               Accounting.finalize_success(
                 reserved.request,
                 attempt,
                 %{
                   status: "usage_known",
                   input_tokens: 272_001,
                   output_tokens: 2,
                   total_tokens: 272_003
                 },
                 %{response_status_code: 200}
               )

      assert result.settlement.pricing_snapshot_id == long_context_pricing.id
      assert result.settlement.details["pricing_status"] == "priced"
      assert result.settlement.details["price_bucket"] == "long_context"
      assert Decimal.equal?(result.settlement.settled_cost_micros, Decimal.new(5_440_080))
    end

    test "explicit unavailable default bucket overrides older priced snapshot" do
      setup = accounting_setup()
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      pricing_snapshot_fixture(setup.pricing, %{
        config:
          pricing_config(%{
            "availability" => "unavailable"
          }),
        input_token_micros: nil,
        cached_input_token_micros: nil,
        output_token_micros: nil,
        reasoning_token_micros: nil,
        request_base_micros: nil,
        effective_at: DateTime.add(now, -30, :second),
        captured_at: DateTime.add(now, -30, :second)
      })

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{"model" => setup.model.exposed_model_id},
                 %{correlation_id: "corr-default-unavailable"}
               )

      assert is_nil(reserved.pricing_snapshot)
      assert reserved.pricing_status == "unpriced_unavailable_price_bucket"
      assert reserved.reservation.details["price_bucket"] == "default"
      assert reserved.reservation.details["pricing_status"] == "unpriced_unavailable_price_bucket"
      assert Decimal.equal?(reserved.reservation.estimated_cost_micros, Decimal.new(0))
    end

    test "explicit unavailable long-context bucket settles as unpriced instead of default priced" do
      setup = accounting_setup()
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      pricing_snapshot_fixture(setup.pricing, %{
        config:
          pricing_config(%{
            "price_bucket" => "long_context"
          }),
        input_token_micros: Decimal.new(100),
        output_token_micros: Decimal.new(200),
        effective_at: DateTime.add(now, -120, :second),
        captured_at: DateTime.add(now, -120, :second)
      })

      pricing_snapshot_fixture(setup.pricing, %{
        config:
          pricing_config(%{
            "price_bucket" => "long_context",
            "availability" => "unavailable"
          }),
        input_token_micros: nil,
        cached_input_token_micros: nil,
        output_token_micros: nil,
        reasoning_token_micros: nil,
        request_base_micros: nil,
        effective_at: DateTime.add(now, -30, :second),
        captured_at: DateTime.add(now, -30, :second)
      })

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{"model" => setup.model.exposed_model_id},
                 %{correlation_id: "corr-long-context-unavailable"}
               )

      assert reserved.pricing_snapshot.id == setup.pricing.id

      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

      assert {:ok, result} =
               Accounting.finalize_success(
                 reserved.request,
                 attempt,
                 %{
                   status: "usage_known",
                   input_tokens: 272_001,
                   output_tokens: 2,
                   total_tokens: 272_003
                 },
                 %{response_status_code: 200}
               )

      assert is_nil(result.settlement.pricing_snapshot_id)
      assert result.settlement.details["pricing_status"] == "unpriced_unavailable_price_bucket"
      assert result.settlement.details["price_bucket"] == "long_context"
      assert result.settlement.details["settled_cost_micros"] == nil
      assert Decimal.equal?(result.settlement.settled_cost_micros, Decimal.new(0))
    end

    test "suffix-inferred long-context usage falls back to default canonical pricing" do
      setup = accounting_setup()
      unique = System.unique_integer([:positive])
      base_identifier = "gpt-example-long-context-#{unique}"
      suffix_identifier = "#{base_identifier}-spark"

      suffix_model =
        model_fixture(setup.pool, %{
          exposed_model_id: suffix_identifier,
          upstream_model_id: suffix_identifier,
          pricing_ref: suffix_identifier
        })

      default_pricing =
        pricing_snapshot_fixture(setup.pricing, %{
          model_identifier: base_identifier,
          input_token_micros: Decimal.new(100),
          output_token_micros: Decimal.new(200)
        })

      expected_alias = %{
        "source" => "suffix_inference",
        "from" => suffix_identifier,
        "to" => base_identifier
      }

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 suffix_model,
                 %{"model" => suffix_model.exposed_model_id},
                 %{correlation_id: "corr-suffix-long-context-fallback-#{unique}"}
               )

      assert reserved.pricing_status == "priced"
      assert reserved.pricing_snapshot.id == default_pricing.id
      assert reserved.request.request_metadata["pricing"]["alias"] == expected_alias

      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

      assert {:ok, result} =
               Accounting.finalize_success(
                 reserved.request,
                 attempt,
                 %{
                   status: "usage_known",
                   input_tokens: 272_001,
                   output_tokens: 2,
                   total_tokens: 272_003
                 },
                 %{response_status_code: 200}
               )

      assert result.settlement.pricing_snapshot_id == default_pricing.id
      assert result.settlement.details["pricing_status"] == "priced"
      assert result.settlement.details["price_bucket"] == "default"
      assert result.settlement.details["alias"] == expected_alias
      assert Decimal.equal?(result.settlement.settled_cost_micros, Decimal.new(27_200_500))
    end

    test "suffix-inferred unavailable long-context bucket blocks default canonical fallback" do
      setup = accounting_setup()
      unique = System.unique_integer([:positive])
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      base_identifier = "gpt-example-unavailable-long-context-#{unique}"
      suffix_identifier = "#{base_identifier}-spark"

      suffix_model =
        model_fixture(setup.pool, %{
          exposed_model_id: suffix_identifier,
          upstream_model_id: suffix_identifier,
          pricing_ref: suffix_identifier
        })

      pricing_snapshot_fixture(setup.pricing, %{
        model_identifier: base_identifier,
        input_token_micros: Decimal.new(100),
        output_token_micros: Decimal.new(200)
      })

      pricing_snapshot_fixture(setup.pricing, %{
        model_identifier: base_identifier,
        config:
          pricing_config(%{
            "price_bucket" => "long_context"
          }),
        input_token_micros: Decimal.new(300),
        output_token_micros: Decimal.new(400),
        effective_at: DateTime.add(now, -120, :second),
        captured_at: DateTime.add(now, -120, :second)
      })

      pricing_snapshot_fixture(setup.pricing, %{
        model_identifier: base_identifier,
        config:
          pricing_config(%{
            "price_bucket" => "long_context",
            "availability" => "unavailable"
          }),
        input_token_micros: nil,
        cached_input_token_micros: nil,
        output_token_micros: nil,
        reasoning_token_micros: nil,
        request_base_micros: nil,
        effective_at: DateTime.add(now, -30, :second),
        captured_at: DateTime.add(now, -30, :second)
      })

      expected_alias = %{
        "source" => "suffix_inference",
        "from" => suffix_identifier,
        "to" => base_identifier
      }

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 suffix_model,
                 %{"model" => suffix_model.exposed_model_id},
                 %{correlation_id: "corr-suffix-long-context-unavailable-#{unique}"}
               )

      assert reserved.pricing_status == "priced"

      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

      assert {:ok, result} =
               Accounting.finalize_success(
                 reserved.request,
                 attempt,
                 %{
                   status: "usage_known",
                   input_tokens: 272_001,
                   output_tokens: 2,
                   total_tokens: 272_003
                 },
                 %{response_status_code: 200}
               )

      assert is_nil(result.settlement.pricing_snapshot_id)
      assert result.settlement.details["pricing_status"] == "unpriced_unavailable_price_bucket"
      assert result.settlement.details["price_bucket"] == "long_context"
      assert result.settlement.details["alias"] == expected_alias
      assert Decimal.equal?(result.settlement.settled_cost_micros, Decimal.new(0))
    end

    test "websocket final usage overrides reservation estimate for settled tokens and cost" do
      setup = accounting_setup()

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{
                   "model" => setup.model.exposed_model_id,
                   "input" => "short reservation seed",
                   "max_output_tokens" => 1
                 },
                 %{correlation_id: "corr-websocket-final-usage", transport: "websocket"}
               )

      refute reserved.reservation.input_tokens == 100
      refute reserved.reservation.cached_input_tokens == 40
      refute reserved.reservation.output_tokens == 12
      refute reserved.reservation.total_tokens == 112

      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

      assert {:ok, result} =
               Accounting.finalize_success(
                 reserved.request,
                 attempt,
                 %{
                   status: "usage_known",
                   input_tokens: 100,
                   cached_input_tokens: 40,
                   output_tokens: 12,
                   reasoning_tokens: 3,
                   total_tokens: 112,
                   source: "websocket_upstream_usage"
                 },
                 %{response_status_code: 200}
               )

      assert result.settlement.usage_status == "usage_known"
      assert result.settlement.input_tokens == 100
      assert result.settlement.cached_input_tokens == 40
      assert result.settlement.output_tokens == 12
      assert result.settlement.reasoning_tokens == 3
      assert result.settlement.total_tokens == 112
      assert result.settlement.details["estimated_from_reserve"] == false
      assert result.settlement.details["usage_source"] == "websocket_upstream_usage"
      assert result.settlement.details["pricing_status"] == "priced"
      assert result.settlement.details["price_bucket"] == "default"
      assert Decimal.equal?(result.settlement.settled_cost_micros, Decimal.new(910))

      assert %{items: [log], total: 1} = Accounting.list_request_logs(setup.pool, limit: 1)
      assert log.id == result.request.id
      assert log.transport == "websocket"
      assert log.token_counts.input_tokens == 100
      assert log.token_counts.cached_input_tokens == 40
      assert log.token_counts.output_tokens == 12
      assert log.token_counts.reasoning_tokens == 3
      assert log.token_counts.total_tokens == 112
      assert log.cost.status == "priced"
      assert Decimal.equal?(log.cost.usd, Decimal.new("0.000910"))
    end

    test "cache-write usage preserves nil, zero, and positive counters in ledger and request facts" do
      setup = accounting_setup()

      for {suffix, cache_write_tokens} <- [{"absent", nil}, {"zero", 0}, {"positive", 6}] do
        assert {:ok, reserved} =
                 Accounting.reserve(
                   setup.auth,
                   setup.model,
                   %{"model" => setup.model.exposed_model_id, "max_output_tokens" => 1},
                   %{correlation_id: "corr-cache-write-#{suffix}"}
                 )

        assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

        usage = %{
          status: "usage_known",
          input_tokens: 10,
          cached_input_tokens: 4,
          output_tokens: 2,
          total_tokens: 12
        }

        usage =
          if is_nil(cache_write_tokens),
            do: usage,
            else: Map.put(usage, :cache_write_tokens, cache_write_tokens)

        assert {:ok, result} =
                 Accounting.finalize_success(
                   reserved.request,
                   attempt,
                   usage,
                   %{response_status_code: 200}
                 )

        persisted_entry = Repo.get!(LedgerEntry, result.settlement.id)
        persisted_fact = Repo.get!(RequestLogFact, reserved.request.id)

        assert Map.get(persisted_entry, :cache_write_tokens) == cache_write_tokens
        assert Map.get(persisted_fact, :latest_cache_write_tokens) == cache_write_tokens
      end
    end

    test "invalid cache-write usage becomes unknown and never persists billable counters" do
      setup = accounting_setup()

      for {suffix, invalid_usage} <- [
            {"negative", %{cache_write_tokens: -1}},
            {"noninteger", %{cache_write_tokens: "1.5"}},
            {"over-total", %{cached_input_tokens: 8, cache_write_tokens: 3}}
          ] do
        assert {:ok, reserved} =
                 Accounting.reserve(
                   setup.auth,
                   setup.model,
                   %{"model" => setup.model.exposed_model_id},
                   %{correlation_id: "corr-invalid-cache-write-#{suffix}"}
                 )

        assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

        usage =
          Map.merge(
            %{
              status: "usage_known",
              input_tokens: 10,
              cached_input_tokens: 4,
              output_tokens: 2,
              total_tokens: 12
            },
            invalid_usage
          )

        assert {:ok, result} =
                 Accounting.finalize_success(
                   reserved.request,
                   attempt,
                   usage,
                   %{response_status_code: 200}
                 )

        assert result.settlement.usage_status == "usage_unknown"
        assert is_nil(result.settlement.cache_write_tokens)
        assert Decimal.equal?(result.settlement.settled_cost_micros, Decimal.new(0))
        assert Repo.get!(RequestLogFact, reserved.request.id).latest_cache_write_tokens == nil
      end
    end

    test "cache-write settlement uses the selected tier and bucket local rate" do
      setup = accounting_setup()
      Repo.delete!(setup.pricing)

      generated_at =
        DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:microsecond)

      path =
        write_tmp_pricing_json!(generated_at, setup.model.upstream_model_id, %{
          "input" => Decimal.new(10),
          "cached_input" => Decimal.new(2),
          "cache_write" => Decimal.new(7),
          "output" => Decimal.new(20),
          "reasoning" => Decimal.new(20)
        })

      assert {:ok, _result} = OpenAIPricingImporter.import_file(path)

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{"model" => setup.model.exposed_model_id},
                 %{
                   correlation_id: "corr-cache-write-local-rate",
                   now: DateTime.add(generated_at, 1)
                 }
               )

      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

      assert {:ok, result} =
               Accounting.finalize_success(
                 reserved.request,
                 attempt,
                 %{
                   status: "usage_known",
                   input_tokens: 10,
                   cached_input_tokens: 4,
                   cache_write_tokens: 3,
                   output_tokens: 2,
                   total_tokens: 12
                 },
                 %{response_status_code: 200}
               )

      assert result.settlement.pricing_snapshot_id == reserved.pricing_snapshot.id
      assert result.settlement.details["service_tier"] == "standard"
      assert result.settlement.details["price_bucket"] == "default"

      assert result.settlement.details["price_version"] ==
               "#{DateTime.to_iso8601(generated_at)}:importer-format-2"

      assert Decimal.equal?(result.settlement.settled_cost_micros, Decimal.new(99))
      assert result.settlement.details["cache_write_rate_status"] == "available"

      assert Decimal.equal?(
               Decimal.new(result.settlement.details["cache_write_token_micros"]),
               Decimal.new(7)
             )

      assert Decimal.equal?(
               Decimal.new(result.settlement.details["cache_write_cost_micros"]),
               Decimal.new(21)
             )

      assert result.settlement.details["pricing_importer_revision"] in [2, "2"]
    end

    test "explicit zero cache writes remain priced without a cache-write rate" do
      setup = accounting_setup(%{cache_write_token_micros: nil})

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{"model" => setup.model.exposed_model_id},
                 %{correlation_id: "corr-cache-write-zero-missing-rate"}
               )

      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

      assert {:ok, result} =
               Accounting.finalize_success(
                 reserved.request,
                 attempt,
                 %{
                   status: "usage_known",
                   input_tokens: 10,
                   cached_input_tokens: 4,
                   cache_write_tokens: 0,
                   output_tokens: 0,
                   total_tokens: 10
                 },
                 %{response_status_code: 200}
               )

      assert result.settlement.cache_write_tokens == 0
      assert result.settlement.details["pricing_status"] == "priced"
      assert result.settlement.details["cache_write_rate_status"] == "unavailable"
      assert result.settlement.details["cache_write_cost_micros"] == "0"
      assert Decimal.equal?(result.settlement.settled_cost_micros, Decimal.new(64))
    end

    test "reported cache writes replace ordinary input while absent and zero preserve their semantics" do
      setup =
        accounting_setup(%{
          input_token_micros: Decimal.new(10),
          cached_input_token_micros: Decimal.new(2),
          cache_write_token_micros: Decimal.new(7),
          output_token_micros: Decimal.new(0),
          reasoning_token_micros: Decimal.new(0)
        })

      for {suffix, cache_write, expected_cost, rate_status} <- [
            {"absent", :absent, 68, "not_reported"},
            {"zero", 0, 68, "available"},
            {"all-write", 6, 50, "available"}
          ] do
        assert {:ok, reserved} =
                 Accounting.reserve(
                   setup.auth,
                   setup.model,
                   %{"model" => setup.model.exposed_model_id, "max_output_tokens" => 1},
                   %{correlation_id: "corr-cache-write-partition-#{suffix}"}
                 )

        assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

        usage = %{
          status: "usage_known",
          input_tokens: 10,
          cached_input_tokens: 4,
          output_tokens: 0,
          total_tokens: 10
        }

        usage =
          if cache_write == :absent,
            do: usage,
            else: Map.put(usage, :cache_write_tokens, cache_write)

        assert {:ok, result} =
                 Accounting.finalize_success(
                   reserved.request,
                   attempt,
                   usage,
                   %{response_status_code: 200}
                 )

        assert Decimal.equal?(result.settlement.settled_cost_micros, Decimal.new(expected_cost))
        assert result.settlement.details["cache_write_rate_status"] == rate_status
      end
    end

    test "positive cache writes without an available selected-snapshot rate are unpriced" do
      setup = accounting_setup(%{cache_write_token_micros: nil})

      for availability <- [:missing, :unavailable] do
        if availability == :unavailable do
          setup.pricing
          |> Ecto.Changeset.change(%{
            config: Map.put(setup.pricing.config, "availability", "unavailable")
          })
          |> Repo.update!()
        end

        assert {:ok, reserved} =
                 Accounting.reserve(
                   setup.auth,
                   setup.model,
                   %{"model" => setup.model.exposed_model_id},
                   %{correlation_id: "corr-cache-write-rate-#{availability}"}
                 )

        assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

        assert {:ok, result} =
                 Accounting.finalize_success(
                   reserved.request,
                   attempt,
                   %{
                     status: "usage_known",
                     input_tokens: 10,
                     cached_input_tokens: 4,
                     cache_write_tokens: 3,
                     output_tokens: 2,
                     total_tokens: 12
                   },
                   %{response_status_code: 200}
                 )

        assert String.starts_with?(result.settlement.details["pricing_status"], "unpriced")
        assert result.settlement.details["cache_write_rate_status"] == "unavailable"
        assert is_nil(result.settlement.details["cache_write_cost_micros"])
        assert Decimal.equal?(result.settlement.settled_cost_micros, Decimal.new(0))
      end
    end

    test "websocket final usage can reselect the long-context price bucket" do
      setup = accounting_setup()

      long_context_pricing =
        pricing_snapshot_fixture(setup.pricing, %{
          config: pricing_config(%{"price_bucket" => "long_context"}),
          input_token_micros: Decimal.new(20),
          cached_input_token_micros: Decimal.new(2),
          output_token_micros: Decimal.new(30),
          reasoning_token_micros: Decimal.new(30)
        })

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{
                   "model" => setup.model.exposed_model_id,
                   "input" => "short reservation seed",
                   "max_output_tokens" => 1
                 },
                 %{correlation_id: "corr-websocket-long-context", transport: "websocket"}
               )

      assert reserved.pricing_snapshot.id == setup.pricing.id

      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

      assert {:ok, result} =
               Accounting.finalize_success(
                 reserved.request,
                 attempt,
                 %{
                   status: "usage_known",
                   input_tokens: 272_001,
                   output_tokens: 2,
                   total_tokens: 272_003,
                   source: "websocket_upstream_usage"
                 },
                 %{response_status_code: 200}
               )

      assert result.settlement.pricing_snapshot_id == long_context_pricing.id
      assert result.settlement.usage_status == "usage_known"
      assert result.settlement.input_tokens == 272_001
      assert result.settlement.output_tokens == 2
      assert result.settlement.total_tokens == 272_003
      assert result.settlement.details["pricing_status"] == "priced"
      assert result.settlement.details["price_bucket"] == "long_context"
      assert result.settlement.details["estimated_from_reserve"] == false
      assert Decimal.equal?(result.settlement.settled_cost_micros, Decimal.new(5_440_080))
    end

    test "cache-write settlement uses priority short-context and standard long-context rates" do
      setup = accounting_setup(%{cache_write_token_micros: Decimal.new(7)})

      priority_pricing =
        pricing_snapshot_fixture(setup.pricing, %{
          config: pricing_config(%{"service_tier" => "priority"}),
          cache_write_token_micros: Decimal.new(11)
        })

      long_context_pricing =
        pricing_snapshot_fixture(setup.pricing, %{
          config: pricing_config(%{"price_bucket" => "long_context"}),
          cache_write_token_micros: Decimal.new(13)
        })

      for {suffix, payload, usage, expected_snapshot, expected_rate} <- [
            {"priority-short", %{"service_tier" => "priority"}, %{input_tokens: 10},
             priority_pricing, "11"},
            {"standard-long", %{}, %{input_tokens: 272_001}, long_context_pricing, "13"}
          ] do
        assert {:ok, reserved} =
                 Accounting.reserve(
                   setup.auth,
                   setup.model,
                   Map.merge(%{"model" => setup.model.exposed_model_id}, payload),
                   %{correlation_id: "corr-cache-write-dimension-#{suffix}"}
                 )

        assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

        assert {:ok, result} =
                 Accounting.finalize_success(
                   reserved.request,
                   attempt,
                   Map.merge(usage, %{
                     status: "usage_known",
                     cached_input_tokens: 4,
                     cache_write_tokens: 3,
                     output_tokens: 0,
                     total_tokens: usage.input_tokens
                   }),
                   %{response_status_code: 200}
                 )

        assert result.settlement.pricing_snapshot_id == expected_snapshot.id
        assert result.settlement.details["cache_write_token_micros"] == expected_rate
      end
    end

    test "websocket usage_unknown fallback rows keep reservation tokens but no priced cost" do
      setup = accounting_setup()

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{"model" => setup.model.exposed_model_id, "input" => "unknown usage seed"},
                 %{correlation_id: "corr-websocket-usage-unknown", transport: "websocket"}
               )

      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

      assert {:ok, result} =
               Accounting.finalize_success(
                 reserved.request,
                 attempt,
                 %{status: "usage_unknown", source: "websocket_usage_missing"},
                 %{response_status_code: 200}
               )

      assert result.settlement.usage_status == "usage_unknown"
      assert result.settlement.input_tokens == reserved.reservation.input_tokens
      assert result.settlement.output_tokens == reserved.reservation.output_tokens
      assert result.settlement.total_tokens == reserved.reservation.total_tokens
      assert result.settlement.details["estimated_from_reserve"] == true
      assert result.settlement.details["usage_source"] == "websocket_usage_missing"
      assert result.settlement.details["settled_cost_micros"] == nil
      assert Decimal.equal?(result.settlement.settled_cost_micros, Decimal.new(0))

      assert %{items: [log], total: 1} = Accounting.list_request_logs(setup.pool, limit: 1)
      assert log.id == result.request.id
      assert log.token_counts.usage_status == "usage_unknown"
      assert is_nil(log.token_counts.input_tokens)
      assert is_nil(log.token_counts.output_tokens)
      assert is_nil(log.token_counts.total_tokens)
      assert log.cost.status == "unpriced"
      assert is_nil(log.cost.usd)
    end

    test "fractional imported pricing settles exact total micros" do
      setup = accounting_setup()
      Repo.delete!(setup.pricing)

      generated_at =
        DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:microsecond)

      assert {:ok, _result} =
               OpenAIPricingImporter.import_file(
                 write_tmp_pricing_json!(generated_at, setup.model.upstream_model_id, %{
                   "input" => Decimal.new("0.0125"),
                   "cached_input" => Decimal.new(0),
                   "output" => Decimal.new(0),
                   "reasoning" => Decimal.new(0)
                 })
               )

      imported_snapshot =
        Repo.get_by!(PricingSnapshot, model_identifier: setup.model.upstream_model_id)

      assert Decimal.equal?(imported_snapshot.input_token_micros, Decimal.new("0.0125"))

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{"model" => setup.model.exposed_model_id},
                 %{
                   correlation_id: "corr-fractional-imported",
                   now: DateTime.add(generated_at, 1, :second)
                 }
               )

      assert reserved.pricing_status == "priced"
      assert Decimal.equal?(reserved.pricing_snapshot.input_token_micros, Decimal.new("0.0125"))

      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

      assert {:ok, result} =
               Accounting.finalize_success(
                 reserved.request,
                 attempt,
                 %{
                   status: "usage_known",
                   input_tokens: 1_000_000,
                   output_tokens: 0,
                   total_tokens: 1_000_000
                 },
                 %{response_status_code: 200}
               )

      assert result.settlement.details["pricing_status"] == "priced"
      assert result.settlement.details["settled_cost_micros"] == "12500.000000000"
      assert Decimal.equal?(result.settlement.settled_cost_micros, Decimal.new("12500.000000000"))

      assert Decimal.equal?(
               Repo.one(
                 from r in DailyRollup,
                   where: r.api_key_id == ^setup.api_key.id,
                   select: r.settled_cost_micros
               ),
               Decimal.new("12500.000000000")
             )

      assert %{items: [%{cost: %{status: "priced", usd: cost_usd}}]} =
               Accounting.list_request_logs(setup.pool, limit: 1)

      assert Decimal.equal?(cost_usd, Decimal.new("0.012500"))
    end

    test "decimal cost math remains exact for microunit pricing" do
      setup =
        accounting_setup(%{
          input_token_micros: Decimal.new(333_333),
          cached_input_token_micros: Decimal.new(111_111),
          output_token_micros: Decimal.new(666_667),
          reasoning_token_micros: Decimal.new(999_999),
          request_base_micros: Decimal.new(1)
        })

      assert {:ok, reserved} =
               Accounting.reserve(
                 setup.auth,
                 setup.model,
                 %{"model" => setup.model.exposed_model_id},
                 %{correlation_id: "corr-decimal"}
               )

      assert {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)

      assert {:ok, result} =
               Accounting.finalize_success(
                 reserved.request,
                 attempt,
                 %{
                   status: "usage_known",
                   input_tokens: 3,
                   cached_input_tokens: 1,
                   output_tokens: 2,
                   reasoning_tokens: 1,
                   total_tokens: 5
                 },
                 %{response_status_code: 200}
               )

      assert result.settlement.details["pricing_status"] == "priced"
      assert result.settlement.details["service_tier"] == "standard"
      assert Decimal.equal?(result.settlement.settled_cost_micros, Decimal.new(2_444_444))

      assert Decimal.equal?(
               Repo.one(
                 from r in DailyRollup,
                   where: r.api_key_id == ^setup.api_key.id,
                   select: r.settled_cost_micros
               ),
               Decimal.new(2_444_444)
             )
    end
  end
end
