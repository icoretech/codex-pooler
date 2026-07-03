defmodule CodexPooler.Alerts.SavedResetFirstSeenEvaluatorDedupeTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Alerts
  alias CodexPooler.Alerts.Schemas.AlertRule

  @tag :saved_reset_banked_first_seen
  test "saved reset first-seen predicates use stable v2 upstream dedupe key" do
    timestamp = ~U[2026-01-02 03:04:05Z]
    baseline = ~U[2026-01-02 01:00:00Z]
    pool = pool_fixture()
    expires_at = ~U[2026-01-09 00:00:00Z] |> DateTime.to_iso8601()

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        identity_metadata:
          saved_reset_metadata([
            %{
              "expires_at" => expires_at,
              "first_seen_at" => ~U[2026-01-02 02:04:05Z] |> DateTime.to_iso8601()
            }
          ])
      })

    rule = saved_reset_banked_first_seen_rule(pool, created_at: baseline)

    assert [%{action: :match, match_attrs: match}] = Alerts.evaluate_rule(rule, at: timestamp)

    assert match.dedupe_key == saved_reset_v2_dedupe_key(identity.id),
           "v2 dedupe gap: saved-reset first-seen dedupe must be stable per upstream identity"

    refute match.dedupe_key =~ "reset_expires_at",
           "v2 dedupe gap: saved-reset first-seen dedupe must not include reset_expires_at"

    refute match.dedupe_key =~ expires_at,
           "v2 dedupe gap: saved-reset first-seen dedupe must not include expiration instants"
  end

  @tag :saved_reset_banked_first_seen
  test "saved reset first-seen predicates clear stable v2 upstream dedupe key when no alertable reset exists" do
    timestamp = ~U[2026-01-02 03:04:05Z]
    baseline = ~U[2026-01-02 01:00:00Z]
    pool = pool_fixture()

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        identity_metadata: saved_reset_metadata([])
      })

    rule = saved_reset_banked_first_seen_rule(pool, created_at: baseline)

    candidates = Alerts.evaluate_rule(rule, at: timestamp)

    assert length(candidates) == 1,
           "clear-candidate gap: expected one clear candidate for the stable v2 saved-reset dedupe key"

    assert [%{action: :clear, clear_attrs: clear_attrs}] = candidates
    assert clear_attrs.dedupe_key == saved_reset_v2_dedupe_key(identity.id)
  end

  @tag :saved_reset_banked_first_seen
  test "saved reset first-seen predicates ignore malformed expiration rows and inactive assignments" do
    timestamp = ~U[2026-01-02 03:04:05Z]
    pool = pool_fixture()
    valid_expires_at = ~U[2026-01-09 00:00:00Z] |> DateTime.to_iso8601()
    valid_first_seen_at = ~U[2026-01-02 02:04:05Z] |> DateTime.to_iso8601()

    upstream_assignment_fixture(pool, %{
      identity_metadata: %{
        "saved_resets" => %{
          "status" => "reported",
          "available_count" => 3,
          "available_expirations" => [
            %{"first_seen_at" => valid_first_seen_at},
            %{"expires_at" => "not-a-date", "first_seen_at" => valid_first_seen_at},
            %{"expires_at" => valid_expires_at},
            %{"expires_at" => valid_expires_at, "first_seen_at" => "not-a-date"}
          ]
        }
      }
    })

    upstream_assignment_fixture(pool, %{
      assignment_status: "disabled",
      identity_metadata: %{
        "saved_resets" => %{
          "status" => "reported",
          "available_count" => 1,
          "available_expirations" => [
            %{"expires_at" => valid_expires_at, "first_seen_at" => valid_first_seen_at}
          ]
        }
      }
    })

    rule = saved_reset_banked_first_seen_rule(pool, created_at: ~U[2026-01-02 01:00:00Z])

    candidates = Alerts.evaluate_rule(rule, at: timestamp)

    assert length(candidates) == 1,
           "clear-candidate gap: malformed saved-reset rows should clear the stable v2 dedupe key instead of staying silent"

    assert [%{action: :clear}] = candidates
  end

  defp saved_reset_banked_first_seen_rule(pool, attrs) do
    attrs = Map.new(attrs)
    baseline = Map.get(attrs, :created_at, DateTime.utc_now())

    %AlertRule{
      id: Ecto.UUID.generate(),
      pool_id: pool.id,
      scope_type: "upstream_identity",
      rule_kind: "upstream_saved_reset_banked_first_seen",
      severity: "info",
      state: "active",
      created_at: baseline,
      updated_at: Map.get(attrs, :updated_at, baseline),
      metadata: Map.get(attrs, :metadata, %{})
    }
  end

  defp saved_reset_metadata(expirations) do
    %{
      "saved_resets" => %{
        "status" => "reported",
        "available_count" => length(expirations),
        "source" => "codex_reset_credits_api",
        "path_style" => "chatgpt_api",
        "available_expirations" => expirations
      }
    }
  end

  defp saved_reset_v2_dedupe_key(upstream_identity_id) do
    Enum.join(
      [
        "alerts",
        "v2",
        "upstream_saved_reset_banked_first_seen",
        "upstream_identity",
        upstream_identity_id || "none"
      ],
      ":"
    )
  end
end
