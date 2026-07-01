defmodule CodexPoolerWeb.Admin.ApiKeysLivePolicyTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Access
  alias CodexPooler.Access.APIKey
  alias CodexPooler.Access.APIKeyPolicyBinding
  alias CodexPooler.Catalog.SyncRun
  alias CodexPooler.Pools
  alias CodexPooler.Repo

  setup :register_and_log_in_user

  @tag :create_once_secret
  test "creates an API key and shows the raw secret exactly once", %{conn: conn, scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "one-time-key", name: "One-time Key"})
    upstream_assignment_fixture(pool)

    {:ok, view, _html} = live(conn, ~p"/admin/api-keys")
    open_create_dialog(view)

    html =
      view
      |> element("#api-key-form")
      |> render_submit(%{
        "api_key" =>
          %{
            "display_name" => "One-time reveal key",
            "pool_id" => pool.id
          }
          |> api_key_payload()
      })

    assert has_element?(view, "#api-key-created-secret-dialog[open]")
    assert has_element?(view, "#api-key-created-secret", "Copy this API key before closing")
    assert has_element?(view, "#api-key-created-secret-value")
    assert has_element?(view, "#api-key-copy-created-secret")
    raw_key = extract_raw_key!(html)
    api_key = Repo.one!(APIKey)

    assert has_element?(view, "#api-key-row-#{api_key.id}", "One-time reveal key")
    assert render(view) =~ api_key.key_prefix

    view
    |> element("#edit-api-key-#{api_key.id}")
    |> render_click()

    refute render(view) =~ raw_key

    {:ok, _remounted_view, remounted_html} = live(conn, ~p"/admin/api-keys")
    refute remounted_html =~ raw_key
    assert remounted_html =~ api_key.key_prefix
  end

  @tag :policy_form
  test "policy form persists and edits model restrictions", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "policy-key", name: "Policy Key"})

    {:ok, view, _html} = live(conn, ~p"/admin/api-keys")
    open_create_dialog(view)

    view
    |> element("#api-key-form")
    |> render_submit(%{
      "api_key" =>
        %{
          "display_name" => "Restricted key",
          "pool_id" => pool.id,
          "model_mode" => "selected_models",
          "allowed_model_identifiers" => ["GPT-Allowed"],
          "manual_model_identifiers_text" => "custom/manual-test-model",
          "enforced_model_identifier" => "custom/manual-test-model",
          "enforced_reasoning_effort" => "none",
          "enforced_service_tier" => "priority",
          "default_max_tokens_per_week" => "100000",
          "operator_notes" => "limited rollout"
        }
        |> api_key_payload()
    })

    api_key = Repo.one!(APIKey)

    assert has_element?(
             view,
             "#api-key-row-#{api_key.id}-models",
             "gpt-allowed, custom/manual-test-model"
           )

    assert has_element?(view, "#api-key-row-#{api_key.id}-notes-content", "limited rollout")

    persisted = Repo.get!(APIKey, api_key.id)
    assert {:ok, policy} = Access.normalize_api_key_policy(persisted)
    assert policy.allowed_model_identifiers == ["gpt-allowed", "custom/manual-test-model"]
    assert policy.enforced_model_identifier == "custom/manual-test-model"
    assert policy.enforced_reasoning_effort == "none"
    assert policy.enforced_service_tier == "priority"

    assert %APIKeyPolicyBinding{max_tokens_per_week: 100_000} =
             Repo.get_by!(APIKeyPolicyBinding, api_key_id: api_key.id, binding_scope: "default")

    assert {:ok, ^policy} =
             Access.authorize_api_key_policy(policy, %{
               model: "GPT-ALLOWED"
             })

    view |> element("#edit-api-key-#{api_key.id}") |> render_click()
    assert has_element?(view, "#api-key[open]")
    assert has_element?(view, "#api_key_id[value='#{api_key.id}']")
    assert render(view) =~ "limited rollout"

    view
    |> element("#api-key-form")
    |> render_submit(%{
      "api_key" =>
        %{
          "id" => api_key.id,
          "display_name" => "Unrestricted edited key",
          "pool_id" => pool.id,
          "status" => "paused",
          "model_mode" => "all_models",
          "operator_notes" => ""
        }
        |> api_key_payload()
    })

    edited = Repo.get!(APIKey, api_key.id)
    assert edited.display_name == "Unrestricted edited key"
    assert edited.status == "paused"
    assert edited.allowed_model_identifiers == nil
    assert {:error, :api_key_disabled} = Access.normalize_api_key_policy(edited)
  end

  test "edit sections preserve unavailable saved model chips", %{conn: conn, scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "stale-key", name: "Stale Key"})

    {:ok, %{api_key: api_key}} =
      Access.create_api_key(scope, pool, %{
        display_name: "Stale model key",
        model_mode: "selected_models",
        allowed_model_identifiers: ["legacy-removed-model"]
      })

    {:ok, view, _html} = live(conn, ~p"/admin/api-keys")
    view |> element("#edit-api-key-#{api_key.id}") |> render_click()
    select_api_key_section(view, :models)

    assert has_element?(view, "#api-key-stale-model-legacy-removed-model", "legacy-removed-model")

    view
    |> element("#api-key-form")
    |> render_submit(%{
      "api_key" =>
        api_key_payload(%{
          "id" => api_key.id,
          "display_name" => "Stale model key",
          "pool_id" => pool.id,
          "model_mode" => "selected_models",
          "allowed_model_identifiers" => ["legacy-removed-model"]
        })
    })

    assert Repo.get!(APIKey, api_key.id).allowed_model_identifiers == ["legacy-removed-model"]
  end

  test "model policy warnings identify and filter unavailable model references", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "model-policy", name: "Model Policy"})
    insert_visible_model!(pool, "gpt-current")

    {:ok, %{api_key: selected_key, raw_key: selected_raw_key}} =
      Access.create_api_key(scope, pool, %{
        display_name: "Selected stale key",
        model_mode: "selected_models",
        allowed_model_identifiers: ["gpt-current", "legacy-removed-model"]
      })

    {:ok, %{api_key: enforced_key, raw_key: enforced_raw_key}} =
      Access.create_api_key(scope, pool, %{
        display_name: "Enforced stale key",
        enforced_model_identifier: "legacy-enforced-model"
      })

    {:ok, %{api_key: current_key, raw_key: current_raw_key}} =
      Access.create_api_key(scope, pool, %{
        display_name: "Current model key",
        model_mode: "selected_models",
        allowed_model_identifiers: ["gpt-current"]
      })

    {:ok, view, _html} = live(conn, ~p"/admin/api-keys")

    assert has_element?(view, "#api-key-model-policy-attention", "2 affected keys")

    assert has_element?(
             view,
             "#api-key-row-#{selected_key.id}-model-policy-warning",
             "1 selected model is unavailable"
           )

    assert has_element?(
             view,
             "#api-key-row-#{enforced_key.id}-model-policy-warning",
             "Enforced model legacy-enforced-model is unavailable"
           )

    refute has_element?(view, "#api-key-row-#{current_key.id}-model-policy-warning")

    view
    |> element("#api-key-filter-unavailable-model-policies")
    |> render_click()

    assert_patch(view, ~p"/admin/api-keys?model_policy=unavailable")
    assert has_element?(view, "#api-key-active-model-policy-filter", "2 affected keys")
    assert has_element?(view, "#api-key-row-#{selected_key.id}", "Selected stale key")
    assert has_element?(view, "#api-key-row-#{enforced_key.id}", "Enforced stale key")
    refute has_element?(view, "#api-key-row-#{current_key.id}")

    view
    |> element("#api-key-clear-model-policy-filter")
    |> render_click()

    assert_patch(view, ~p"/admin/api-keys")
    assert has_element?(view, "#api-key-row-#{current_key.id}", "Current model key")

    html = render(view)
    refute html =~ selected_raw_key
    refute html =~ enforced_raw_key
    refute html =~ current_raw_key
  end

  test "model editor warns when the enforced model is no longer routable", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "enforced-stale", name: "Enforced Stale"})
    insert_visible_model!(pool, "gpt-current")

    {:ok, %{api_key: api_key}} =
      Access.create_api_key(scope, pool, %{
        display_name: "Stale enforced editor key",
        enforced_model_identifier: "legacy-enforced-model"
      })

    {:ok, view, _html} = live(conn, ~p"/admin/api-keys")
    view |> element("#edit-api-key-#{api_key.id}") |> render_click()
    select_api_key_section(view, :models)

    assert has_element?(view, "#api-key-enforced-model-warning", "Enforced model unavailable")

    assert has_element?(
             view,
             "#api-key-enforced-model-warning",
             "runtime requests will fail until this is changed"
           )
  end

  test "catalog refresh while editor is open updates selector state without dropping form fields",
       %{
         conn: conn,
         scope: scope
       } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "catalog-refresh", name: "Catalog Refresh"})
    {:ok, view, _html} = live(conn, ~p"/admin/api-keys")
    open_create_dialog(view)

    params =
      api_key_payload(%{
        "display_name" => "Refresh-safe key",
        "pool_id" => pool.id,
        "model_mode" => "selected_models",
        "manual_model_identifiers_text" => "gpt-refresh-visible",
        "operator_notes" => "preserve during refresh"
      })

    view |> element("#api-key-form") |> render_change(%{"api_key" => params})
    select_api_key_section(view, :models)

    assert_api_key_section(view, :models)
    assert has_element?(view, "#api-key-manual-model-chips", "gpt-refresh-visible")

    insert_sync_run!(pool)
    %{assignment: assignment} = upstream_assignment_fixture(pool)

    model_fixture(pool, %{
      exposed_model_id: "gpt-refresh-visible",
      display_name: "GPT Refresh Visible",
      metadata: %{"source_assignment_ids" => [assignment.id]}
    })

    view
    |> element("#api-key-form")
    |> render_change(%{
      "api_key" => Map.put(params, "operator_notes", "preserved after refresh")
    })

    assert has_element?(view, "#api-key-model-option-gpt-refresh-visible", "GPT Refresh Visible")
    assert render(view) =~ "preserved after refresh"

    select_api_key_section(view, :review)
    assert has_element?(view, "#api-key-review-summary", "Refresh-safe key")
    assert has_element?(view, "#api-key-review-summary", "1 selected model")
  end

  test "sectioned editor accepts uppercase selected model when enforced model matches", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "uppercase-model", name: "Uppercase Model"})
    upstream_assignment_fixture(pool)

    {:ok, view, _html} = live(conn, ~p"/admin/api-keys")
    open_create_dialog(view)

    view
    |> element("#api-key-form")
    |> render_change(%{
      "api_key" =>
        api_key_payload(%{
          "display_name" => "Uppercase enforced key",
          "pool_id" => pool.id,
          "model_mode" => "selected_models",
          "manual_model_identifiers_text" => "GPT-ALLOWED",
          "enforced_model_identifier" => "GPT-ALLOWED"
        })
    })

    select_api_key_section(view, :review)

    assert_api_key_section(view, :review)
    assert has_element?(view, "#api-key-review-summary", "Uppercase enforced key")
    assert has_element?(view, "#api-key-review-summary", "1 selected model")
    refute has_element?(view, "#api-key-review-errors", "Enforced model must be allowed")

    view
    |> element("#api-key-form")
    |> render_submit(%{"api_key" => %{"operator_notes" => "submitted from review"}})

    api_key = Repo.one!(APIKey)
    assert has_element?(view, "#api-key-created-secret-dialog[open]")
    assert has_element?(view, "#api-key-row-#{api_key.id}", "Uppercase enforced key")

    assert {:ok, policy} = api_key |> Repo.reload!() |> Access.normalize_api_key_policy()
    assert policy.allowed_model_identifiers == ["gpt-allowed"]
    assert policy.enforced_model_identifier == "gpt-allowed"
  end

  test "external API key changes live-update the mounted list", %{conn: conn, scope: scope} do
    {:ok, pool} =
      Pools.create_pool(scope, %{slug: "external-key-update", name: "External Key Update"})

    {:ok, view, _html} = live(conn, ~p"/admin/api-keys")

    assert {:ok, %{api_key: api_key}} =
             publish_from_task(fn ->
               Access.create_api_key(scope, pool, %{display_name: "Externally created key"})
             end)

    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#api-key-row-#{api_key.id}", "Externally created key")
  end

  defp extract_raw_key!(html) do
    case Regex.run(~r/sk-cxp-[A-Za-z0-9_-]+-[A-Za-z0-9_-]+/, html) do
      [raw_key] -> raw_key
      _match -> flunk("raw API key was not rendered in the one-time secret panel")
    end
  end

  defp open_create_dialog(view) do
    view |> element("#api-key-page-create-action") |> render_click()
  end

  defp select_api_key_section(view, section) do
    view |> element("#api-key-tab-#{section}") |> render_click()
  end

  defp assert_api_key_section(view, section) do
    assert has_element?(view, "#api-key-tab-#{section}[aria-selected='true']")
    assert has_element?(view, "#api-key-section-#{section}[role='tabpanel']")
  end

  defp publish_from_task(fun) when is_function(fun, 0) do
    fun
    |> Task.async()
    |> Task.await(5_000)
  end

  defp insert_sync_run!(pool) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %SyncRun{}
    |> SyncRun.changeset(%{
      pool_id: pool.id,
      trigger_kind: "manual",
      status: "succeeded",
      started_at: now,
      finished_at: now,
      discovered_model_count: 1,
      upserted_model_count: 1,
      stale_marked_count: 0,
      retired_count: 0,
      stats: %{}
    })
    |> Repo.insert!()
  end

  defp insert_visible_model!(pool, exposed_model_id) do
    insert_sync_run!(pool)
    %{assignment: assignment} = upstream_assignment_fixture(pool)

    model_fixture(pool, %{
      exposed_model_id: exposed_model_id,
      display_name: exposed_model_id,
      metadata: %{"source_assignment_ids" => [assignment.id]}
    })
  end

  defp api_key_payload(attrs) do
    Map.merge(
      %{
        "id" => "",
        "display_name" => "",
        "pool_id" => "",
        "status" => "active",
        "expires_at" => "",
        "model_mode" => "all_models",
        "allowed_model_identifiers" => [],
        "manual_model_identifiers_text" => "",
        "enforced_model_identifier" => "",
        "enforced_reasoning_effort" => "",
        "enforced_service_tier" => "",
        "default_max_requests_per_minute" => "",
        "default_max_tokens_per_day" => "",
        "default_max_tokens_per_week" => "",
        "default_max_input_tokens_per_request" => "",
        "default_max_output_tokens_per_request" => "",
        "model_policy_model_identifier" => "",
        "model_max_requests_per_minute" => "",
        "model_max_tokens_per_day" => "",
        "model_max_tokens_per_week" => "",
        "model_max_input_tokens_per_request" => "",
        "model_max_output_tokens_per_request" => "",
        "operator_notes" => ""
      },
      attrs
    )
  end
end
