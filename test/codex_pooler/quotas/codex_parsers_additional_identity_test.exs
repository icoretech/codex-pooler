defmodule CodexPooler.Quotas.CodexParsersAdditionalIdentityTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Quotas.Evidence.CodexParsers

  @observed_at ~U[2026-08-25 10:00:00Z]

  test "windows-only compatibility accepts legacy selected windows while strict results reject them" do
    legacy_payload = %{
      "plan_type" => "sample_plan",
      "rate_limit" => %{
        "primary_window" => %{
          "used_percent" => 25,
          "limit_window_seconds" => 18_000,
          "reset_after_seconds" => 900
        }
      }
    }

    assert {:ok, [legacy_window]} =
             CodexParsers.parse_codex_usage_payload(legacy_payload, @observed_at)

    assert legacy_window.window_minutes == 300
    assert legacy_window.reset_at == DateTime.add(@observed_at, 900, :second)

    assert {:ok, %{windows: [], account_availability: availability}} =
             CodexParsers.parse_codex_usage_result(legacy_payload, @observed_at)

    assert availability.state == :unknown
    assert availability.basis == :conflict
    assert availability.account_windows == :unknown
  end

  test "same-label additional meters retain the shared legacy window identity" do
    assert {:ok, evidences} =
             CodexParsers.parse_codex_usage_payload(same_label_meter_payload(), @observed_at)

    assert length(evidences) == 2

    assert evidences
           |> MapSet.new(&{&1.quota_key, &1.window_kind, &1.window_minutes})
           |> MapSet.size() == 1
  end

  test "same-label additional meters retain distinct canonical identities" do
    assert {:ok, evidences} =
             CodexParsers.parse_codex_usage_payload(same_label_meter_payload(), @observed_at)

    assert Enum.map(evidences, &{&1.raw_limit_id, &1.raw_metered_feature, &1.used_percent}) == [
             {"meter_alpha", "meter_alpha", Decimal.new("31.0")},
             {"meter_beta", "meter_beta", Decimal.new("71.0")}
           ]
  end

  test "synthetic Reserve-shaped weekly payload preserves its wire identity without a model substitution" do
    payload = %{
      "additional_rate_limits" => [
        %{
          "limit_name" => "gpt-reserve",
          "metered_feature" => "base_model_inference",
          "rate_limit" => %{
            "primary_window" => %{
              "used_percent" => 25,
              "limit_window_seconds" => 604_800,
              "reset_after_seconds" => 604_800,
              "reset_at" => 1_778_000_000
            }
          }
        }
      ]
    }

    assert {:ok, [evidence]} = CodexParsers.parse_codex_usage_payload(payload, @observed_at)

    assert evidence.quota_key == "gpt_reserve"
    assert evidence.quota_scope == "model"
    assert evidence.model == "gpt-reserve"
    assert evidence.raw_limit_name == "gpt-reserve"
    assert evidence.raw_metered_feature == "base_model_inference"
    assert evidence.window_kind == "secondary"
    assert evidence.window_minutes == 10_080
  end

  test "exact duplicate meter identity deterministically retains highest pressure" do
    payload = %{
      "additional_rate_limits" => [
        additional_limit("meter_alpha", 83),
        additional_limit("meter_alpha", 19)
      ]
    }

    assert {:ok, [evidence]} = CodexParsers.parse_codex_usage_payload(payload, @observed_at)
    assert evidence.raw_metered_feature == "meter_alpha"
    assert Decimal.equal?(evidence.used_percent, Decimal.new("83.0"))
  end

  test "blank metered feature falls back to the trimmed raw limit id" do
    limit =
      "   "
      |> additional_limit(44)
      |> Map.put("limit_id", "  provider_meter_fallback  ")

    assert {:ok, [evidence]} =
             CodexParsers.parse_codex_usage_payload(
               %{"additional_rate_limits" => [limit]},
               @observed_at
             )

    assert evidence.raw_metered_feature == "provider_meter_fallback"
    assert evidence.raw_limit_id == "provider_meter_fallback"
    refute evidence.raw_limit_id == evidence.raw_limit_name
  end

  test "display label alone never becomes canonical meter identity" do
    limit = additional_limit("   ", 44)

    assert {:ok, [evidence]} =
             CodexParsers.parse_codex_usage_payload(
               %{"additional_rate_limits" => [limit]},
               @observed_at
             )

    assert evidence.raw_limit_name == "Shared weekly limit"
    assert evidence.raw_metered_feature == nil
    assert evidence.raw_limit_id == nil
  end

  defp same_label_meter_payload do
    %{
      "additional_rate_limits" => [
        additional_limit("meter_alpha", 31),
        additional_limit("meter_beta", 71)
      ]
    }
  end

  defp additional_limit(metered_feature, used_percent) do
    %{
      "limit_name" => "Shared weekly limit",
      "metered_feature" => metered_feature,
      "rate_limit" => %{
        "primary_window" => %{
          "used_percent" => used_percent,
          "limit_window_seconds" => 604_800,
          "reset_after_seconds" => 604_800,
          "reset_at" => 1_778_000_000
        }
      }
    }
  end
end
