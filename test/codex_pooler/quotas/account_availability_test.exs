defmodule CodexPooler.Quotas.AccountAvailabilityTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Quotas.AccountAvailability
  alias CodexPooler.Quotas.Evidence.CodexParsers

  @observed_at ~U[2026-08-25 10:00:00Z]
  @known_reached_types ~w(
    rate_limit_reached
    workspace_owner_credits_depleted
    workspace_member_credits_depleted
    workspace_owner_usage_limit_reached
    workspace_member_usage_limit_reached
  )

  test "the value contract accepts only consistent semantic triples" do
    assert {:ok,
            %AccountAvailability{
              state: :available,
              basis: :affirmative,
              account_windows: :absent
            }} = AccountAvailability.new(:available, :affirmative, :absent)

    assert {:error, :invalid_observation} =
             AccountAvailability.new(:available, :conflict, :absent)

    assert {:error, :invalid_observation} =
             AccountAvailability.new(:absent, :affirmative, :absent)
  end

  describe "windowless provider availability" do
    test "affirmative raw rate flags are plan-independent direct-wire evidence" do
      for plan_type <- ["plus", "enterprise", "future_plan"] do
        assert_result(
          %{
            "plan_type" => plan_type,
            "rate_limit" => status(true, false)
          },
          [],
          %AccountAvailability{
            state: :available,
            basis: :affirmative,
            account_windows: :absent
          }
        )
      end
    end

    test "usable credits are affirmative and false/false credits are no proof" do
      for credits <- [
            %{"has_credits" => true, "unlimited" => false},
            %{"has_credits" => false, "unlimited" => true},
            %{"has_credits" => true, "unlimited" => true}
          ] do
        assert_result(
          %{"plan_type" => "plus", "rate_limit" => nil, "credits" => credits},
          [],
          %AccountAvailability{
            state: :available,
            basis: :affirmative,
            account_windows: :absent
          }
        )
      end

      assert_result(
        %{
          "plan_type" => "plus",
          "rate_limit" => nil,
          "credits" => %{"has_credits" => false, "unlimited" => false}
        },
        [],
        %AccountAvailability{state: :unknown, basis: :no_proof, account_windows: :absent}
      )

      assert_result(
        %{
          "plan_type" => "plus",
          "rate_limit" => status(true, false),
          "credits" => %{"has_credits" => false, "unlimited" => false}
        },
        [],
        %AccountAvailability{
          state: :available,
          basis: :affirmative,
          account_windows: :absent
        }
      )
    end

    test "plan name never creates availability" do
      for plan_type <- ["business", "self_serve_business_usage_based"] do
        assert_result(%{"plan_type" => plan_type}, [], nil)
      end
    end

    test "a nonempty plan is required only for a no-window observation" do
      for plan_type <- [nil, "", "   ", 123] do
        assert_result(
          %{"plan_type" => plan_type, "rate_limit" => status(true, false)},
          [],
          nil
        )
      end

      payload = %{
        "rate_limit" => status(true, false, valid_window()),
        "plan_type" => nil
      }

      assert {:ok, %{windows: [window], account_availability: observation}} = parse(payload)
      assert window.quota_scope == "account"
      assert window.reset_at == ~U[2026-08-25 11:00:00Z]
      assert observation.state == :available
      assert observation.account_windows == :present
    end
  end

  describe "blockers and conflicts" do
    test "complementary blocked flags and reached spend control block" do
      for payload <- [
            %{"plan_type" => "plus", "rate_limit" => status(false, true)},
            %{
              "plan_type" => "plus",
              "rate_limit" => status(true, false),
              "spend_control" => %{"reached" => true}
            }
          ] do
        assert_result(
          payload,
          [],
          %AccountAvailability{state: :blocked, basis: :blocker, account_windows: :absent}
        )
      end
    end

    test "every known reached type blocks" do
      for reached_type <- @known_reached_types do
        assert_result(
          %{
            "plan_type" => "enterprise",
            "rate_limit" => status(true, false),
            "rate_limit_reached_type" => %{"type" => reached_type}
          },
          [],
          %AccountAvailability{state: :blocked, basis: :blocker, account_windows: :absent}
        )
      end
    end

    test "unknown and malformed reached types conflict" do
      for reached_type <- [
            %{"type" => "future_reached_type"},
            %{"type" => ""},
            %{"type" => 7},
            %{},
            "rate_limit_reached",
            7
          ] do
        assert_result(
          %{
            "plan_type" => "plus",
            "rate_limit" => status(true, false),
            "rate_limit_reached_type" => reached_type
          },
          [],
          %AccountAvailability{state: :unknown, basis: :conflict, account_windows: :absent}
        )
      end

      assert_result(
        %{
          "plan_type" => "plus",
          "rate_limit" => status(true, false),
          "rate_limit_reached_type" => nil
        },
        [],
        %AccountAvailability{
          state: :available,
          basis: :affirmative,
          account_windows: :absent
        }
      )
    end

    test "malformed explicit status objects and contradictory booleans fail closed" do
      for payload <- [
            %{"plan_type" => "plus", "rate_limit" => %{}},
            %{"plan_type" => "plus", "rate_limit" => status(true, true)},
            %{"plan_type" => "plus", "rate_limit" => status(false, false)},
            %{
              "plan_type" => "plus",
              "rate_limit" => %{"allowed" => true, "limit_reached" => "false"}
            },
            %{"plan_type" => "plus", "credits" => %{"has_credits" => true}},
            %{"plan_type" => "plus", "credits" => "bad"},
            %{"plan_type" => "plus", "spend_control" => %{"reached" => "true"}},
            %{"plan_type" => "plus", "spend_control" => "bad"}
          ] do
        assert_result(
          payload,
          [],
          %AccountAvailability{state: :unknown, basis: :conflict, account_windows: :absent}
        )
      end

      assert_result(
        %{"plan_type" => "plus", "rate_limit" => "bad"},
        [],
        %AccountAvailability{state: :unknown, basis: :conflict, account_windows: :unknown}
      )
    end

    test "blocker precedence dominates conflict and affirmative evidence" do
      assert_result(
        %{
          "plan_type" => "plus",
          "rate_limit" => status(true, true),
          "credits" => %{"has_credits" => true, "unlimited" => false},
          "spend_control" => %{"reached" => true}
        },
        [],
        %AccountAvailability{state: :blocked, basis: :blocker, account_windows: :absent}
      )
    end
  end

  describe "canonical account window selection" do
    test "canonical values win independently of malformed legacy aliases and map order" do
      canonical = valid_window(20)

      for slot <- ["primary", "secondary"], reverse? <- [false, true] do
        entries = [{"#{slot}_window", canonical}, {slot, "malformed"}]
        rate_limit = entries |> maybe_reverse(reverse?) |> Map.new() |> with_flags()

        assert {:ok, %{windows: [window], account_availability: observation}} =
                 parse(%{"plan_type" => "plus", "rate_limit" => rate_limit})

        assert Decimal.equal?(window.used_percent, Decimal.new("20.0"))
        assert observation.account_windows == :present
      end
    end

    test "malformed canonical aliases never fall back to valid legacy aliases" do
      for slot <- ["primary", "secondary"], reverse? <- [false, true] do
        entries = [{"#{slot}_window", "malformed"}, {slot, valid_window()}]
        rate_limit = entries |> maybe_reverse(reverse?) |> Map.new() |> with_flags()

        assert_result(
          %{"plan_type" => "plus", "rate_limit" => rate_limit},
          [],
          %AccountAvailability{state: :unknown, basis: :conflict, account_windows: :unknown}
        )
      end
    end

    test "duplicate valid aliases use the canonical value" do
      for slot <- ["primary", "secondary"] do
        rate_limit =
          status(true, false)
          |> Map.put("#{slot}_window", valid_window(17))
          |> Map.put(slot, valid_window(88))

        assert {:ok, %{windows: [window], account_availability: observation}} =
                 parse(%{"plan_type" => "plus", "rate_limit" => rate_limit})

        assert Decimal.equal?(window.used_percent, Decimal.new("17.0"))
        assert observation.account_windows == :present
      end
    end

    test "omitted or null canonical aliases allow the legacy value per slot" do
      for slot <- ["primary", "secondary"], canonical <- [:omitted, nil] do
        rate_limit = status(true, false) |> Map.put(slot, valid_window(33))

        rate_limit =
          if canonical == :omitted,
            do: Map.delete(rate_limit, "#{slot}_window"),
            else: Map.put(rate_limit, "#{slot}_window", nil)

        assert {:ok, %{windows: [window], account_availability: observation}} =
                 parse(%{"plan_type" => "plus", "rate_limit" => rate_limit})

        assert Decimal.equal?(window.used_percent, Decimal.new("33.0"))
        assert observation.account_windows == :present
      end
    end

    test "one malformed selected slot makes account window presence unknown" do
      rate_limit =
        status(true, false, valid_window())
        |> Map.put("secondary_window", %{"used_percent" => "bad"})

      assert {:ok, %{windows: [window], account_availability: observation}} =
               parse(%{"plan_type" => "plus", "rate_limit" => rate_limit})

      assert window.quota_scope == "account"

      assert observation == %AccountAvailability{
               state: :unknown,
               basis: :conflict,
               account_windows: :unknown
             }
    end

    test "selected windows require the complete pinned integer shape" do
      for invalid_window <- invalid_pinned_windows() do
        rate_limit = status(true, false) |> Map.put("primary_window", invalid_window)

        assert_result(
          %{"plan_type" => "plus", "rate_limit" => rate_limit},
          [],
          %AccountAvailability{state: :unknown, basis: :conflict, account_windows: :unknown}
        )
      end
    end
  end

  describe "whole-payload additional integrity" do
    test "omitted, null, and empty additional collections are neutral" do
      for additional <- [:omitted, nil, []] do
        payload = %{"plan_type" => "plus", "rate_limit" => status(true, false)}

        payload =
          if additional == :omitted,
            do: payload,
            else: Map.put(payload, "additional_rate_limits", additional)

        assert_result(
          payload,
          [],
          %AccountAvailability{state: :available, basis: :affirmative, account_windows: :absent}
        )
      end
    end

    test "schema-valid additional entries with omitted or null status are neutral" do
      for status_value <- [:omitted, nil] do
        entry = additional(nil)
        entry = if status_value == :omitted, do: Map.delete(entry, "rate_limit"), else: entry

        assert_result(
          %{
            "plan_type" => "plus",
            "rate_limit" => status(true, false),
            "additional_rate_limits" => [entry]
          },
          [],
          %AccountAvailability{state: :available, basis: :affirmative, account_windows: :absent}
        )
      end
    end

    test "malformed collections, entries, identities, statuses, and selected windows conflict" do
      malformed = [
        %{"additional_rate_limits" => %{}},
        %{"additional_rate_limits" => ["bad"]},
        %{"additional_rate_limits" => [%{"limit_name" => "name", "metered_feature" => 1}]},
        %{"additional_rate_limits" => [%{"limit_name" => 1, "metered_feature" => "meter"}]},
        %{"additional_rate_limits" => [%{"limit_name" => "", "metered_feature" => "meter"}]},
        %{"additional_rate_limits" => [%{"limit_name" => "name", "metered_feature" => ""}]},
        %{
          "additional_rate_limits" => [
            additional(%{"allowed" => true, "limit_reached" => false, "primary_window" => "bad"})
          ]
        },
        %{"additional_rate_limits" => [additional("bad")]},
        %{"additional_rate_limits" => [additional(status(true, true))]}
      ]

      for addition <- malformed do
        payload =
          Map.merge(%{"plan_type" => "plus", "rate_limit" => status(true, false)}, addition)

        assert_result(
          payload,
          [],
          %AccountAvailability{state: :unknown, basis: :conflict, account_windows: :absent}
        )
      end
    end

    test "additional selected windows require the complete pinned integer shape" do
      for invalid_window <- invalid_pinned_windows() do
        payload = %{
          "plan_type" => "plus",
          "rate_limit" => status(true, false),
          "additional_rate_limits" => [
            additional(status(true, false, invalid_window))
          ]
        }

        assert_result(
          payload,
          [],
          %AccountAvailability{state: :unknown, basis: :conflict, account_windows: :absent}
        )
      end
    end

    test "explicit additional blockers conflict with and without a valid low-pressure window" do
      for additional_status <- [status(false, true), status(false, true, valid_window(4))] do
        payload = %{
          "plan_type" => "plus",
          "rate_limit" => status(true, false),
          "additional_rate_limits" => [additional(additional_status)]
        }

        assert {:ok, %{account_availability: observation} = result} = parse(payload)
        refute observation.state == :available
        assert observation.basis == :conflict
        refute Enum.any?(result.windows, &(&1.quota_scope == "account"))
      end
    end

    test "ordinary account windows retain their unchanged authority over additional ambiguity" do
      payload = %{
        "plan_type" => "plus",
        "rate_limit" => status(true, false, valid_window()),
        "additional_rate_limits" => "malformed"
      }

      assert {:ok, %{windows: [window], account_availability: observation}} = parse(payload)
      assert window.quota_scope == "account"
      assert observation.basis == :conflict
      assert observation.account_windows == :present

      assert {:ok, [compatibility_window]} =
               CodexParsers.parse_codex_usage_payload(payload, @observed_at)

      assert compatibility_window == window
    end
  end

  test "observations never retain raw provider fields or synthesize Evidence" do
    payload = %{
      "plan_type" => "plus",
      "provider_account" => "sensitive-account",
      "rate_limit" => status(true, false),
      "credits" => %{
        "has_credits" => true,
        "unlimited" => false,
        "balance" => "999",
        "message" => "sensitive-message"
      }
    }

    assert {:ok, %{windows: [], account_availability: observation}} = parse(payload)

    assert Map.from_struct(observation) == %{
             state: :available,
             basis: :affirmative,
             account_windows: :absent
           }

    inspected = inspect(observation)
    refute inspected =~ "sensitive"
    refute inspected =~ "999"
  end

  test "pinned client projection omits direct-wire availability flags" do
    client_source = pinned_codex_source!("codex-rs/backend-client/src/client.rs")

    schema_source =
      pinned_codex_source!(
        "codex-rs/codex-backend-openapi-models/src/models/rate_limit_status_details.rs"
      )

    projection =
      client_source
      |> String.split("fn make_rate_limit_snapshot(", parts: 2)
      |> List.last()
      |> String.split("fn map_rate_limit_reached_type(", parts: 2)
      |> List.first()

    assert schema_source =~ "pub allowed: bool"
    assert schema_source =~ "pub limit_reached: bool"
    refute projection =~ ".allowed"
    refute projection =~ ".limit_reached"

    assert_result(
      %{"plan_type" => "plus", "rate_limit" => status(true, false)},
      [],
      %AccountAvailability{state: :available, basis: :affirmative, account_windows: :absent}
    )
  end

  defp parse(payload), do: CodexParsers.parse_codex_usage_result(payload, @observed_at)

  defp assert_result(payload, windows, observation) do
    assert {:ok, %{windows: ^windows, account_availability: ^observation}} = parse(payload)
  end

  defp status(allowed, limit_reached, primary_window \\ nil) do
    %{
      "allowed" => allowed,
      "limit_reached" => limit_reached,
      "primary_window" => primary_window,
      "secondary_window" => nil
    }
  end

  defp with_flags(rate_limit),
    do: Map.merge(rate_limit, %{"allowed" => true, "limit_reached" => false})

  defp valid_window(used_percent \\ 25) do
    %{
      "used_percent" => used_percent,
      "limit_window_seconds" => 18_000,
      "reset_after_seconds" => 3_600,
      "reset_at" => 1_787_655_600
    }
  end

  defp invalid_pinned_windows do
    valid = valid_window()

    for field <- ~w(used_percent limit_window_seconds reset_after_seconds reset_at),
        mutation <- [:missing, :wrong_type] do
      case mutation do
        :missing -> Map.delete(valid, field)
        :wrong_type -> Map.put(valid, field, "invalid")
      end
    end
  end

  defp pinned_codex_source!(path) do
    {source, 0} =
      System.cmd(
        "git",
        [
          "-C",
          "references/codex",
          "show",
          "316795b3cf2a45e90d121d9f46499d4658b2645c:#{path}"
        ],
        env: [{"GIT_MASTER", "1"}],
        stderr_to_stdout: true
      )

    source
  end

  defp additional(rate_limit) do
    %{
      "limit_name" => "Sample model limit",
      "metered_feature" => "sample_model",
      "rate_limit" => rate_limit
    }
  end

  defp maybe_reverse(entries, true), do: Enum.reverse(entries)
  defp maybe_reverse(entries, false), do: entries
end
