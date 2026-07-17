defmodule CodexPooler.Alerts.Evaluation.SavedResetFirstSeenEvaluatorTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Alerts
  alias CodexPooler.Alerts.Delivery.WebhookPayload
  alias CodexPooler.Alerts.Schemas.AlertRule

  @tag :saved_reset_banked_first_seen
  test "saved reset first-seen predicates suppress historical entries before rule baseline" do
    timestamp = ~U[2026-01-02 03:04:05Z]
    baseline = ~U[2026-01-02 03:00:00Z]
    pool = pool_fixture()

    upstream_assignment_fixture(pool, %{
      identity_metadata:
        saved_reset_metadata([
          saved_reset_expiration(~U[2026-01-09 00:00:00Z], ~U[2026-01-02 02:04:05Z])
        ])
    })

    rule =
      saved_reset_banked_first_seen_rule(pool,
        created_at: baseline,
        metadata: %{"saved_reset_first_seen_baseline_at" => DateTime.to_iso8601(baseline)}
      )

    candidates = Alerts.evaluate_rule(rule, at: timestamp)
    match_candidates = Enum.filter(candidates, &match?(%{action: :match}, &1))

    assert match_candidates == [],
           "historical suppression gap: expected 0 saved-reset match candidates when first_seen_at predates the rule baseline"

    assert [%{action: :clear, clear_attrs: clear_attrs}] = candidates
    assert clear_attrs.dedupe_key =~ "alerts:v2:upstream_saved_reset_banked_first_seen"
  end

  @tag :saved_reset_banked_first_seen
  test "saved reset first-seen predicates aggregate multiple new expirations for one upstream identity" do
    timestamp = ~U[2026-01-02 03:04:05Z]
    baseline = ~U[2026-01-02 01:00:00Z]
    pool = pool_fixture()

    %{identity: identity, assignment: assignment} =
      upstream_assignment_fixture(pool, %{
        identity_metadata:
          saved_reset_metadata([
            saved_reset_expiration(~U[2026-01-09 00:00:00Z], ~U[2026-01-02 02:04:05Z]),
            saved_reset_expiration(~U[2026-01-10 00:00:00Z], ~U[2026-01-02 02:34:05Z])
          ])
      })

    rule = saved_reset_banked_first_seen_rule(pool, created_at: baseline)

    match_candidates =
      rule
      |> Alerts.evaluate_rule(at: timestamp)
      |> Enum.filter(&match?(%{action: :match}, &1))

    assert length(match_candidates) == 1,
           "aggregate one-candidate gap: expected exactly 1 saved-reset match candidate per upstream identity"

    [%{match_attrs: match}] = match_candidates

    assert match.scope_type == "upstream_identity"
    assert match.pool_id == nil
    assert match.upstream_identity_id == identity.id
    assert match.safe_evidence_snapshot["available_count"] == 2
    assert match.safe_evidence_snapshot["new_reset_count"] == 2

    assert match.safe_evidence_snapshot["earliest_reset_first_seen_at"] ==
             DateTime.to_iso8601(~U[2026-01-02 02:04:05Z])

    assert match.safe_evidence_snapshot["latest_reset_first_seen_at"] ==
             DateTime.to_iso8601(~U[2026-01-02 02:34:05Z])

    assert match.safe_evidence_snapshot["next_reset_expires_at"] ==
             DateTime.to_iso8601(~U[2026-01-09 00:00:00Z])

    assert match.safe_evidence_snapshot["latest_reset_expires_at"] ==
             DateTime.to_iso8601(~U[2026-01-10 00:00:00Z])

    assert match.safe_evidence_snapshot["source"] == "codex_reset_credits_api"
    assert match.safe_evidence_snapshot["path_style"] == "chatgpt_api"
    assert match.safe_evidence_snapshot["pool_upstream_assignment_id"] == assignment.id
    assert match.safe_evidence_snapshot["upstream_identity_id"] == identity.id

    for forbidden <- saved_reset_forbidden_fragments() do
      refute inspect(match.safe_evidence_snapshot) =~ forbidden
    end
  end

  @tag :saved_reset_banked_first_seen
  test "saved reset first-seen predicates aggregate whole-second and fractional timestamps chronologically" do
    timestamp = ~U[2026-01-02 03:04:05Z]
    baseline = ~U[2026-01-02 01:00:00Z]
    pool = pool_fixture()

    upstream_assignment_fixture(pool, %{
      identity_metadata:
        saved_reset_metadata([
          %{
            "expires_at" => "2026-01-09T00:00:00.5Z",
            "first_seen_at" => "2026-01-02T02:04:05.1Z"
          },
          %{
            "expires_at" => "2026-01-09T00:00:00Z",
            "first_seen_at" => "2026-01-02T02:04:05Z"
          }
        ])
    })

    rule = saved_reset_banked_first_seen_rule(pool, created_at: baseline)

    assert [%{action: :match, match_attrs: match}] = Alerts.evaluate_rule(rule, at: timestamp)

    assert match.safe_evidence_snapshot["earliest_reset_first_seen_at"] ==
             "2026-01-02T02:04:05Z"

    assert match.safe_evidence_snapshot["latest_reset_first_seen_at"] ==
             "2026-01-02T02:04:05.1Z"

    assert match.safe_evidence_snapshot["next_reset_expires_at"] ==
             "2026-01-09T00:00:00Z"

    assert match.safe_evidence_snapshot["latest_reset_expires_at"] ==
             "2026-01-09T00:00:00.5Z"
  end

  @tag :saved_reset_banked_first_seen
  test "saved reset first-seen predicates aggregate only entries newly seen after baseline" do
    timestamp = ~U[2026-01-02 03:04:05Z]
    baseline = ~U[2026-01-02 02:00:00Z]
    pool = pool_fixture()

    upstream_assignment_fixture(pool, %{
      identity_metadata:
        saved_reset_metadata([
          saved_reset_expiration(~U[2026-01-08 00:00:00Z], ~U[2026-01-02 01:04:05Z]),
          saved_reset_expiration(~U[2026-01-09 00:00:00Z], ~U[2026-01-02 01:34:05Z]),
          saved_reset_expiration(~U[2026-01-10 00:00:00Z], ~U[2026-01-02 02:04:05Z])
        ])
    })

    rule = saved_reset_banked_first_seen_rule(pool, created_at: baseline)

    assert [%{action: :match, match_attrs: match}] = Alerts.evaluate_rule(rule, at: timestamp)
    assert match.safe_evidence_snapshot["available_count"] == 3
    assert match.safe_evidence_snapshot["new_reset_count"] == 1

    assert match.safe_evidence_snapshot["earliest_reset_first_seen_at"] ==
             DateTime.to_iso8601(~U[2026-01-02 02:04:05Z])

    assert match.safe_evidence_snapshot["next_reset_expires_at"] ==
             DateTime.to_iso8601(~U[2026-01-10 00:00:00Z])
  end

  @tag :saved_reset_banked_first_seen
  test "delivery allowlist keeps every evidence field the evaluator emits" do
    timestamp = ~U[2026-01-02 03:04:05Z]
    baseline = ~U[2026-01-02 01:00:00Z]
    pool = pool_fixture()

    upstream_assignment_fixture(pool, %{
      identity_metadata:
        saved_reset_metadata([
          saved_reset_expiration(~U[2026-01-09 00:00:00Z], ~U[2026-01-02 02:04:05Z])
        ])
    })

    rule = saved_reset_banked_first_seen_rule(pool, created_at: baseline)

    [%{match_attrs: match}] =
      rule
      |> Alerts.evaluate_rule(at: timestamp)
      |> Enum.filter(&match?(%{action: :match}, &1))

    summary = WebhookPayload.safe_evidence_summary(match.safe_evidence_snapshot)

    delivered_keys = ~w(
      available_count
      earliest_reset_first_seen_at
      latest_reset_expires_at
      latest_reset_first_seen_at
      new_reset_count
      next_reset_expires_at
      path_style
      reason_code
      source
    )

    for key <- delivered_keys do
      assert Map.has_key?(summary, key),
             "delivery allowlist drift: evaluator evidence key #{key} was dropped from the webhook summary"
    end

    internal_keys = ~w(pool_id upstream_identity_id pool_upstream_assignment_id)

    assert Enum.sort(Map.keys(match.safe_evidence_snapshot)) ==
             Enum.sort(delivered_keys ++ internal_keys),
           "evaluator evidence keys changed: classify each new key as delivered (add to the webhook and email allowlists) or internal, then update this contract"
  end

  defp saved_reset_banked_first_seen_rule(pool, attrs) do
    attrs = Map.new(attrs)
    baseline = Map.get(attrs, :created_at, DateTime.utc_now() |> DateTime.truncate(:microsecond))

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

  defp saved_reset_forbidden_fragments do
    ~w(
      provider_credit_id
      provider_payload
      payload
      token
      secret
      request_body
      response_body
      auth_json
      cookie
      bearer
    )
  end

  defp saved_reset_metadata(expirations) do
    %{
      "saved_resets" => %{
        "status" => "reported",
        "available_count" => length(expirations),
        "source" => "codex_reset_credits_api",
        "path_style" => "chatgpt_api",
        "available_expirations" => expirations,
        "provider_credit_id" => "credit-secret-123",
        "provider_payload" => %{"token" => "raw-secret-token"}
      }
    }
  end

  defp saved_reset_expiration(expires_at, first_seen_at) do
    %{
      "expires_at" => DateTime.to_iso8601(expires_at),
      "first_seen_at" => DateTime.to_iso8601(first_seen_at)
    }
  end
end
