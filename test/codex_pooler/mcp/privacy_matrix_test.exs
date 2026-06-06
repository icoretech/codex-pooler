defmodule CodexPooler.MCP.PrivacyMatrixTest do
  use ExUnit.Case, async: true

  alias CodexPooler.MCP.PrivacyMatrix

  @entity_families [
    :operators,
    :invites,
    :request_logs,
    :audit_logs,
    :upstreams,
    :upstream_quotas,
    :upstream_quota_windows,
    :pools,
    :pool_api_keys
  ]

  @required_policy_terms [
    :email,
    :upstream_account_email,
    :user_agent,
    :endpoint,
    :path,
    :query,
    :invite_recipient,
    :actor_summary,
    :ip_address,
    :correlation_id,
    :api_key_prefix,
    :label,
    :raw_mcp_token,
    :mcp_token_hash,
    :raw_pool_api_key,
    :pool_api_key_hash,
    :invite_url,
    :invite_token,
    :temporary_password,
    :session_token,
    :totp_secret,
    :recovery_secret,
    :upstream_auth_json,
    :access_token,
    :refresh_token,
    :upstream_secret,
    :smtp_secret,
    :metrics_hmac,
    :metrics_fingerprint,
    :raw_headers,
    :cookies,
    :upload_url,
    :filename,
    :prompt,
    :request_body,
    :response_body,
    :multipart_body,
    :websocket_frame,
    :raw_idempotency_key,
    :audit_before_blob,
    :audit_after_blob,
    :pii_sentinel,
    :raw_metadata,
    :evidence,
    :raw_evidence,
    :provider_payload,
    :provider_json,
    :quota_windows,
    :active_limit,
    :remaining_value,
    :credits,
    :used_percent,
    :reset_at,
    :observed_at,
    :freshness_status,
    :routing_usable,
    :routing_unusable_reason,
    :source_precision
  ]

  test "matrix enumerates every initial MCP entity family" do
    assert PrivacyMatrix.entity_families() == @entity_families
  end

  test "every entity policy is explicit and uses only allowed policy classes" do
    for entity <- @entity_families do
      policy = PrivacyMatrix.policy_for!(entity)

      assert Map.keys(policy) |> Enum.sort() == [:allowed, :masked, :omitted, :summarized]

      for {_policy_class, fields} <- policy do
        assert is_list(fields)
        assert fields == Enum.uniq(fields)
        assert Enum.all?(fields, &is_atom/1)
      end

      all_fields = Enum.flat_map(policy, fn {_class, fields} -> fields end)
      assert all_fields == Enum.uniq(all_fields)
      assert all_fields != []
    end
  end

  test "matrix explicitly covers requested privacy terms and forbidden sentinel categories" do
    covered_terms = PrivacyMatrix.covered_terms()

    for term <- @required_policy_terms do
      assert term in covered_terms
    end
  end

  test "MCP-safe policy differs from admin UI-safe policy for PII-heavy fields" do
    assert PrivacyMatrix.field_policy!(:operators, :email) == :masked
    assert PrivacyMatrix.field_policy!(:operators, :display_name) == :allowed
    assert PrivacyMatrix.field_policy!(:invites, :invited_email) == :masked
    assert PrivacyMatrix.field_policy!(:invites, :token_hash) == :omitted
    assert PrivacyMatrix.field_policy!(:request_logs, :upstream_account_email) == :masked
    assert PrivacyMatrix.field_policy!(:request_logs, :user_agent) == :summarized
    assert PrivacyMatrix.field_policy!(:request_logs, :endpoint) == :summarized
    assert PrivacyMatrix.field_policy!(:request_logs, :query) == :omitted
    assert PrivacyMatrix.field_policy!(:audit_logs, :actor_summary) == :summarized
    assert PrivacyMatrix.field_policy!(:audit_logs, :ip_address) == :masked
    assert PrivacyMatrix.field_policy!(:pool_api_keys, :key_prefix) == :allowed
    assert PrivacyMatrix.field_policy!(:pool_api_keys, :key_hash) == :omitted
    assert PrivacyMatrix.field_policy!(:upstreams, :account_label) == :allowed
    assert PrivacyMatrix.field_policy!(:upstreams, :workspace_ref) == :allowed
    assert PrivacyMatrix.field_policy!(:upstreams, :workspace_label) == :allowed
    assert PrivacyMatrix.field_policy!(:upstreams, :workspace_id) == :omitted
    assert PrivacyMatrix.field_policy!(:upstreams, :account_email) == :masked
    assert PrivacyMatrix.field_policy!(:upstream_quotas, :workspace_ref) == :allowed
    assert PrivacyMatrix.field_policy!(:upstream_quotas, :workspace_id) == :omitted
    assert PrivacyMatrix.field_policy!(:upstream_quotas, :quota_windows) == :allowed
    assert PrivacyMatrix.field_policy!(:upstream_quotas, :metadata) == :omitted
    assert PrivacyMatrix.field_policy!(:upstream_quota_windows, :active_limit) == :allowed
    assert PrivacyMatrix.field_policy!(:upstream_quota_windows, :provider_payload) == :omitted
  end

  test "policy projection omits unknown and dangerous fields instead of returning raw maps" do
    source = %{
      id: "op_123",
      email: "operator.privacy@example.com",
      display_name: "Sample Operator",
      password_hash: "argon2-password-hash-sentinel",
      session_token: "raw-session-token-sentinel",
      totp_secret: "totp-secret-sentinel",
      recovery_secret: "recovery-secret-sentinel",
      unknown_raw_field: "must not pass through"
    }

    assert PrivacyMatrix.project!(:operators, source) == %{
             id: "op_123",
             email: "op***@example.com",
             display_name: "Sample Operator"
           }
  end

  test "policy projection summarizes request routes and omits query strings" do
    projected =
      PrivacyMatrix.project!(:request_logs, %{
        id: "req_123",
        endpoint: "/backend-api/codex/responses?token=raw-query-secret",
        path: "/backend-api/codex/responses",
        query: "token=raw-query-secret",
        user_agent: "Codex CLI/1.2.3 extra-details",
        client_ip: "203.0.113.42",
        correlation_id: "corr-task5-safe",
        upstream_account_email: "upstream.account@example.com",
        raw_headers: %{"authorization" => "Bearer raw-header-token"},
        request_body: %{"input" => "raw prompt"},
        response_body: "raw response body",
        filename: "private-upload-name.txt"
      })

    assert projected.id == "req_123"
    assert projected.endpoint == "/backend-api/codex/responses"
    assert projected.path == "/backend-api/codex/responses"
    assert projected.user_agent == "Codex CLI/1.2.3"
    assert projected.client_ip == "203.0.113.xxx"
    assert projected.correlation_id == "corr-task5-safe"
    assert projected.upstream_account_email == "up***@example.com"
    refute Map.has_key?(projected, :query)
    refute inspect(projected) =~ "raw-query-secret"
    refute inspect(projected) =~ "raw-header-token"
    refute inspect(projected) =~ "raw prompt"
    refute inspect(projected) =~ "private-upload-name"
  end

  test "quota projections keep DTO fields and omit raw upstream material" do
    account =
      PrivacyMatrix.project!(:upstream_quotas, %{
        id: "up_123",
        label: "Safe label",
        stored_account_id: "acct_safe",
        status: "active",
        plan_family: "team",
        quota_summary: %{window_count: 1, routing_usable: true},
        quota_windows: [%{quota_kind: "account_primary", active_limit: 100}],
        metadata: %{"raw" => "metadata blob"},
        provider_payload: %{"raw" => "provider payload"},
        access_token: "raw-access-token"
      })

    assert account == %{
             id: "up_123",
             label: "Safe label",
             stored_account_id: "acct_safe",
             status: "active",
             plan_family: "team",
             quota_summary: %{window_count: 1, routing_usable: true},
             quota_windows: [%{quota_kind: "account_primary", active_limit: 100}]
           }

    window =
      PrivacyMatrix.project!(:upstream_quota_windows, %{
        quota_kind: "account_primary",
        active_limit: 100,
        remaining_value: 42,
        credits: 42,
        used_percent: 58.0,
        reset_at: "2026-05-22T12:00:00Z",
        observed_at: "2026-05-22T11:50:00Z",
        freshness_status: "fresh",
        routing_usable: true,
        routing_unusable_reason: nil,
        source_precision: "observed",
        evidence: %{"raw" => "evidence"},
        provider_json: %{"raw" => "provider"}
      })

    assert window.active_limit == 100
    assert window.remaining_value == 42
    assert window.credits == 42
    assert window.used_percent == 58.0
    assert window.reset_at == "2026-05-22T12:00:00Z"
    assert window.observed_at == "2026-05-22T11:50:00Z"
    assert window.freshness_status == "fresh"
    assert window.routing_usable == true
    assert window.source_precision == "observed"
    refute Map.has_key?(window, :evidence)
    refute Map.has_key?(window, :provider_json)
  end

  test "projection rejects raw domain structs so future tools must present explicit maps" do
    pool = dynamic_term(%CodexPooler.Pools.Pool{id: "pool_123", name: "Raw Pool"})

    assert_raise ArgumentError, ~r/raw domain structs are not MCP-safe/, fn ->
      PrivacyMatrix.project!(:pools, pool)
    end
  end

  defp dynamic_term(term), do: term |> :erlang.term_to_binary() |> :erlang.binary_to_term()
end
