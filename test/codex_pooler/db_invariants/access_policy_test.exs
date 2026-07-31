defmodule CodexPooler.DBInvariants.AccessPolicyTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Repo

  test "database rejects duplicate pool slugs case-insensitively" do
    user_id = create_user!("owner-duplicate-pool@example.com")

    create_pool!(user_id, "alpha", "Alpha")

    assert_db_error(:unique_violation, fn ->
      create_pool!(user_id, "ALPHA", "Duplicate Alpha")
    end)
  end

  test "database rejects invalid API key paused status values" do
    user_id = create_user!("owner-api-key-status@example.com")
    pool_id = create_pool!(user_id, "api-key-status", "API Key Status")

    assert_db_error(:check_violation, fn ->
      Repo.query!(
        """
        INSERT INTO api_keys (pool_id, display_name, key_prefix, key_hash, status, created_by_user_id)
        VALUES ($1, 'Disabled key', 'sk_disabled', $2, 'disabled', $3)
        """,
        [pool_id, <<"disabled-key">>, user_id]
      )
    end)
  end

  test "database rejects malformed API key policy contract fields" do
    user_id = create_user!("owner-api-key-policy-shape@example.com")
    pool_id = create_pool!(user_id, "api-key-policy-shape", "API Key Policy Shape")

    assert_db_error(:check_violation, fn ->
      Repo.query!(
        """
        INSERT INTO api_keys (
          pool_id, display_name, key_prefix, key_hash, status, created_by_user_id,
          allowed_model_identifiers
        ) VALUES ($1, 'Malformed model policy', 'sk_policy_null_model', $2, 'active', $3, ARRAY['gpt-example', NULL]::text[])
        """,
        [pool_id, <<"policy-null-model">>, user_id]
      )
    end)

    assert_db_error(:check_violation, fn ->
      Repo.query!(
        """
        INSERT INTO api_keys (
          pool_id, display_name, key_prefix, key_hash, status, created_by_user_id,
          metadata
        ) VALUES ($1, 'Malformed metadata policy', 'sk_policy_bad_metadata', $2, 'active', $3, '[]'::jsonb)
        """,
        [pool_id, <<"policy-bad-metadata">>, user_id]
      )
    end)

    assert_db_error(:check_violation, fn ->
      Repo.query!(
        """
        INSERT INTO api_keys (
          pool_id, display_name, key_prefix, key_hash, status, created_by_user_id,
          metadata
        ) VALUES ($1, 'Malformed label policy', 'sk_policy_bad_label', $2, 'active', $3, '{"labels": ["ok", 123], "operator_notes": null}'::jsonb)
        """,
        [pool_id, <<"policy-bad-label">>, user_id]
      )
    end)

    assert_db_error(:check_violation, fn ->
      Repo.query!(
        """
        INSERT INTO api_keys (
          pool_id, display_name, key_prefix, key_hash, status, created_by_user_id,
          enforced_model_identifier
        ) VALUES ($1, 'Malformed enforced model', 'sk_policy_bad_enforced_model', $2, 'active', $3, 'gpt enforced')
        """,
        [pool_id, <<"policy-bad-enforced-model">>, user_id]
      )
    end)

    assert_db_error(:check_violation, fn ->
      Repo.query!(
        """
        INSERT INTO api_keys (
          pool_id, display_name, key_prefix, key_hash, status, created_by_user_id,
          enforced_reasoning_effort
        ) VALUES ($1, 'Malformed reasoning effort', 'sk_policy_bad_reasoning', $2, 'active', $3, 'extreme')
        """,
        [pool_id, <<"policy-bad-reasoning">>, user_id]
      )
    end)

    [[none_reasoning_id]] =
      Repo.query!(
        """
        INSERT INTO api_keys (
          pool_id, display_name, key_prefix, key_hash, status, created_by_user_id,
          enforced_reasoning_effort
        ) VALUES ($1, 'None reasoning effort', 'sk_policy_none_reasoning', $2, 'active', $3, 'none')
        RETURNING id
        """,
        [pool_id, <<"policy-none-reasoning">>, user_id]
      ).rows

    assert count_rows("api_keys", none_reasoning_id) == 1

    [[ultra_reasoning_id]] =
      Repo.query!(
        """
        INSERT INTO api_keys (
          pool_id, display_name, key_prefix, key_hash, status, created_by_user_id,
          enforced_reasoning_effort
        ) VALUES ($1, 'Ultra reasoning effort', 'sk_policy_ultra_reasoning', $2, 'active', $3, 'ultra')
        RETURNING id
        """,
        [pool_id, <<"policy-ultra-reasoning">>, user_id]
      ).rows

    assert count_rows("api_keys", ultra_reasoning_id) == 1

    assert_db_error(:check_violation, fn ->
      Repo.query!(
        """
        INSERT INTO api_keys (
          pool_id, display_name, key_prefix, key_hash, status, created_by_user_id,
          enforced_service_tier
        ) VALUES ($1, 'Malformed service tier', 'sk_policy_bad_tier', $2, 'active', $3, 'vip')
        """,
        [pool_id, <<"policy-bad-tier">>, user_id]
      )
    end)

    assert_db_constraint("api_keys_enforced_service_tier_check", fn ->
      Repo.query!(
        """
        INSERT INTO api_keys (
          pool_id, display_name, key_prefix, key_hash, status, created_by_user_id,
          enforced_service_tier
        ) VALUES ($1, 'Raw fast service tier', 'sk_policy_raw_fast_tier', $2, 'active', $3, 'fast')
        """,
        [pool_id, <<"policy-raw-fast-tier">>, user_id]
      )
    end)

    api_key_id = create_api_key!(pool_id, user_id, "sk_policy_binding_weekly")

    assert_db_error(:check_violation, fn ->
      Repo.query!(
        """
        INSERT INTO api_key_policy_bindings (
          api_key_id, binding_scope, status, max_tokens_per_week
        ) VALUES ($1, 'default', 'active', 0)
        """,
        [api_key_id]
      )
    end)
  end

  test "database accepts empty API key model allow list as deny-all model policy" do
    user_id = create_user!("owner-api-key-empty-policy@example.com")
    pool_id = create_pool!(user_id, "api-key-empty-policy", "API Key Empty Policy")

    [[id]] =
      Repo.query!(
        """
        INSERT INTO api_keys (
          pool_id, display_name, key_prefix, key_hash, status, created_by_user_id,
          allowed_model_identifiers, metadata
        ) VALUES ($1, 'Empty policy', 'sk_empty_policy', $2, 'active', $3, '{}'::text[], '{"labels": [], "operator_notes": null}'::jsonb)
        RETURNING id
        """,
        [pool_id, <<"empty-policy">>, user_id]
      ).rows

    assert count_rows("api_keys", id) == 1

    assert [[[], nil, nil, nil]] =
             Repo.query!(
               """
               SELECT
                 allowed_model_identifiers,
                 enforced_model_identifier,
                 enforced_reasoning_effort,
                 enforced_service_tier
               FROM api_keys
               WHERE id = $1
               """,
               [id]
             ).rows

    [[missing_labels_id]] =
      Repo.query!(
        """
        INSERT INTO api_keys (
          pool_id, display_name, key_prefix, key_hash, status, created_by_user_id,
          metadata
        ) VALUES ($1, 'Missing labels policy', 'sk_missing_labels_policy', $2, 'active', $3, '{"operator_notes": "operator-reviewed"}'::jsonb)
        RETURNING id
        """,
        [pool_id, <<"missing-labels-policy">>, user_id]
      ).rows

    [[string_labels_id]] =
      Repo.query!(
        """
        INSERT INTO api_keys (
          pool_id, display_name, key_prefix, key_hash, status, created_by_user_id,
          metadata
        ) VALUES ($1, 'String labels policy', 'sk_string_labels_policy', $2, 'active', $3, '{"labels": ["production"], "operator_notes": null}'::jsonb)
        RETURNING id
        """,
        [pool_id, <<"string-labels-policy">>, user_id]
      ).rows

    assert count_rows("api_keys", missing_labels_id) == 1
    assert count_rows("api_keys", string_labels_id) == 1

    assert [[nil, nil, nil, nil]] =
             Repo.query!(
               """
               SELECT
                 allowed_model_identifiers,
                 enforced_model_identifier,
                 enforced_reasoning_effort,
                 enforced_service_tier
               FROM api_keys
               WHERE id = $1
               """,
               [missing_labels_id]
             ).rows
  end

  test "database preserves exact reasoning enforcement and accepts every maximum bound" do
    user_id = create_user!("owner-api-key-reasoning-policy@example.com")
    pool_id = create_pool!(user_id, "api-key-reasoning-policy", "API Key Reasoning Policy")

    exact_id =
      insert_reasoning_policy_key!(pool_id, user_id, "exact", "high", nil)

    assert [["high", nil]] = reasoning_policy_values(exact_id)

    for effort <- ~w(none minimal low medium high xhigh max ultra) do
      maximum_id =
        insert_reasoning_policy_key!(pool_id, user_id, "maximum-#{effort}", nil, effort)

      assert [[nil, ^effort]] = reasoning_policy_values(maximum_id)
    end
  end

  test "database rejects invalid maximum reasoning effort and mutually exclusive policies" do
    user_id = create_user!("owner-api-key-reasoning-policy-invalid@example.com")

    pool_id =
      create_pool!(
        user_id,
        "api-key-reasoning-policy-invalid",
        "Invalid API Key Reasoning Policy"
      )

    assert_db_constraint("api_keys_maximum_reasoning_effort_check", fn ->
      insert_reasoning_policy_key!(pool_id, user_id, "invalid-maximum", nil, "extreme")
    end)

    assert_db_constraint("api_keys_reasoning_effort_policy_mutual_exclusion_check", fn ->
      insert_reasoning_policy_key!(pool_id, user_id, "conflicting", "high", "medium")
    end)
  end

  test "database preserves pre-policy API key rows with nullable advanced policy fields" do
    user_id = create_user!("owner-api-key-legacy-preserve@example.com")
    pool_id = create_pool!(user_id, "api-key-legacy-preserve", "API Key Legacy Preserve")

    [[api_key_id]] =
      Repo.query!(
        """
        INSERT INTO api_keys (
          pool_id, display_name, key_prefix, key_hash, status, created_by_user_id
        ) VALUES ($1, 'Legacy preserved key', 'sk_legacy_preserve', $2, 'active', $3)
        RETURNING id
        """,
        [pool_id, <<"legacy-preserve">>, user_id]
      ).rows

    [[binding_id]] =
      Repo.query!(
        """
        INSERT INTO api_key_policy_bindings (
          api_key_id, binding_scope, status, max_requests_per_minute,
          max_tokens_per_day, created_at, updated_at
        ) VALUES ($1, 'default', 'active', 60, 1000, now(), now())
        RETURNING id
        """,
        [api_key_id]
      ).rows

    assert [[nil, nil, nil, nil]] =
             Repo.query!(
               """
               SELECT
                 allowed_model_identifiers,
                 enforced_model_identifier,
                 enforced_reasoning_effort,
                 enforced_service_tier
               FROM api_keys
               WHERE id = $1
               """,
               [api_key_id]
             ).rows

    assert [[nil]] =
             Repo.query!(
               """
               SELECT max_tokens_per_week
               FROM api_key_policy_bindings
               WHERE id = $1
               """,
               [binding_id]
             ).rows
  end

  test "database preserves existing exact-enforced API key rows unchanged" do
    user_id = create_user!("owner-api-key-exact-preserve@example.com")
    pool_id = create_pool!(user_id, "api-key-exact-preserve", "API Key Exact Preserve")

    [[api_key_id]] =
      Repo.query!(
        """
        INSERT INTO api_keys (
          pool_id, display_name, key_prefix, key_hash, status, created_by_user_id,
          enforced_reasoning_effort
        ) VALUES ($1, 'Exact preserved key', 'sk_exact_preserve', $2, 'active', $3, 'high')
        RETURNING id
        """,
        [pool_id, <<"exact-preserve">>, user_id]
      ).rows

    assert [["high"]] =
             Repo.query!(
               "SELECT enforced_reasoning_effort FROM api_keys WHERE id = $1",
               [api_key_id]
             ).rows
  end

  defp create_user!(email) do
    [[id]] =
      Repo.query!(
        """
        INSERT INTO users (email, display_name, password_hash, status)
        VALUES ($1, 'Owner', '$argon2id$v=19$m=65536,t=3,p=2$fixture$fixture', 'active')
        RETURNING id
        """,
        [email]
      ).rows

    id
  end

  defp create_pool!(user_id, slug, name) do
    [[id]] =
      Repo.query!(
        """
        INSERT INTO pools (slug, name, status, created_by_user_id)
        VALUES ($1, $2, 'active', $3)
        RETURNING id
        """,
        [slug, name, user_id]
      ).rows

    id
  end

  defp create_api_key!(pool_id, user_id, prefix) do
    [[id]] =
      Repo.query!(
        """
        INSERT INTO api_keys (pool_id, display_name, key_prefix, key_hash, status, created_by_user_id)
        VALUES ($1, 'Primary key', $2, $3, 'active', $4)
        RETURNING id
        """,
        [pool_id, prefix, prefix <> ":hash", user_id]
      ).rows

    id
  end

  defp insert_reasoning_policy_key!(pool_id, user_id, suffix, enforced, maximum) do
    [[id]] =
      Repo.query!(
        """
        INSERT INTO api_keys (
          pool_id, display_name, key_prefix, key_hash, status, created_by_user_id,
          enforced_reasoning_effort, maximum_reasoning_effort
        ) VALUES ($1, $2, $3, $4, 'active', $5, $6, $7)
        RETURNING id
        """,
        [
          pool_id,
          "Reasoning policy #{suffix}",
          "sk_reasoning_#{suffix}",
          suffix,
          user_id,
          enforced,
          maximum
        ]
      ).rows

    id
  end

  defp reasoning_policy_values(api_key_id) do
    Repo.query!(
      """
      SELECT enforced_reasoning_effort, maximum_reasoning_effort
      FROM api_keys
      WHERE id = $1
      """,
      [api_key_id]
    ).rows
  end

  defp count_rows(table_name, id) do
    [[count]] = Repo.query!("SELECT COUNT(*) FROM #{table_name} WHERE id = $1", [id]).rows
    count
  end

  defp assert_db_error(code, fun) do
    assert_raise Postgrex.Error, fn ->
      try do
        fun.()
      rescue
        error in Postgrex.Error ->
          assert error.postgres.code == code
          reraise error, __STACKTRACE__
      end
    end
  end

  defp assert_db_constraint(constraint, fun) do
    assert_raise Postgrex.Error, fn ->
      try do
        fun.()
      rescue
        error in Postgrex.Error ->
          assert error.postgres.code == :check_violation
          assert error.postgres.constraint == constraint
          reraise error, __STACKTRACE__
      end
    end
  end
end
