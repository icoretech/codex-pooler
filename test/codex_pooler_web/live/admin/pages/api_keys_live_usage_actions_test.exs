defmodule CodexPoolerWeb.Admin.ApiKeysLiveUsageActionsTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Access
  alias CodexPooler.Access.APIKey
  alias CodexPooler.Accounting.DailyRollup
  alias CodexPooler.Pools
  alias CodexPooler.Repo

  setup :register_and_log_in_user

  test "edit review shows seeded API key usage and limits", %{conn: conn, scope: scope} do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "usage-key", name: "Usage Key"})

    {:ok, %{api_key: api_key, raw_key: raw_key}} =
      Access.create_api_key(scope, pool, %{
        display_name: "Usage summary key",
        default_policy: %{max_tokens_per_week: 100, max_requests_per_minute: 60}
      })

    request =
      request_fixture(%{pool: pool, api_key: api_key}, %{
        requested_model: "gpt-usage",
        request_metadata: %{"prompt" => "raw prompt must stay hidden"}
      })

    ledger_entry_fixture(request, %{total_tokens: 90, input_tokens: 60, output_tokens: 30})
    insert_daily_rollup!(pool, api_key, %{request_count: 1, total_tokens: 90})

    {:ok, view, _html} = live(conn, ~p"/admin/api-keys")

    assert has_element?(view, "#api-key-row-#{api_key.id}-usage", "1 requests")
    assert has_element?(view, "#api-key-row-#{api_key.id}-usage", "90 tokens")
    refute render(view) =~ raw_key
    refute render(view) =~ "raw prompt must stay hidden"

    view |> element("#edit-api-key-#{api_key.id}") |> render_click()
    select_api_key_section(view, :review)

    assert has_element?(view, "#api-key-usage-summary", "1 requests · 90 tokens")
    assert has_element?(view, "#api-key-usage-summary-cost", "Cost unpriced")
    assert has_element?(view, "#api-key-usage-summary-limits", "90 / 100 used")
    assert has_element?(view, "#api-key-usage-summary-limits", "10 remaining")
    refute render(view) =~ raw_key
    refute render(view) =~ "raw prompt must stay hidden"
  end

  test "edit review shows empty usage state when no accounting data exists", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "unused-key", name: "Unused Key"})

    {:ok, %{api_key: api_key, raw_key: raw_key}} =
      Access.create_api_key(scope, pool, %{display_name: "Unused summary key"})

    {:ok, view, _html} = live(conn, ~p"/admin/api-keys")

    refute has_element?(view, "#api-key-row-#{api_key.id}-usage-empty")

    view |> element("#edit-api-key-#{api_key.id}") |> render_click()
    select_api_key_section(view, :review)

    assert has_element?(view, "#api-key-usage-summary-empty", "No usage recorded yet")
    refute render(view) =~ raw_key
  end

  test "disable, enable, rotate, revoke, and delete actions use stable row ids", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "key-actions", name: "Key Actions"})

    {:ok, %{api_key: api_key, raw_key: original_raw_key}} =
      Access.create_api_key(scope, pool, %{display_name: "Action key"})

    {:ok, view, _html} = live(conn, ~p"/admin/api-keys")

    view |> element("#disable-api-key-#{api_key.id}") |> render_click()
    assert has_element?(view, "#api-key-row-#{api_key.id}-status", "paused")
    assert Repo.get!(APIKey, api_key.id).status == "paused"

    view |> element("#enable-api-key-#{api_key.id}") |> render_click()
    assert has_element?(view, "#api-key-row-#{api_key.id}-status", "active")

    rotate_html = view |> element("#rotate-api-key-#{api_key.id}") |> render_click()
    rotated_raw_key = extract_raw_key!(rotate_html)
    rotated_api_key = Repo.get!(APIKey, api_key.id)
    assert rotated_raw_key != original_raw_key
    assert has_element?(view, "#api-key-created-secret", "Copy this API key before closing")
    refute render(view) =~ original_raw_key

    view |> element("#revoke-api-key-#{api_key.id}") |> render_click()
    assert has_element?(view, "#api-key-row-#{api_key.id}-status", "revoked")
    assert Repo.get!(APIKey, api_key.id).status == "revoked"
    refute render(view) =~ rotated_raw_key

    view |> element("#delete-api-key-#{api_key.id}") |> render_click()
    assert has_element?(view, "#api-key-delete-dialog[open]")
    assert render(view) =~ rotated_api_key.key_prefix

    view
    |> element("#api-key-delete-form")
    |> render_submit(%{
      "api_key_delete" => %{
        "id" => api_key.id,
        "confirmation_prefix" => "wrong-prefix"
      }
    })

    assert has_element?(view, "#api-key-delete-dialog[open]")
    assert Repo.get(APIKey, api_key.id)

    view
    |> element("#api-key-delete-form")
    |> render_submit(%{
      "api_key_delete" => %{
        "id" => api_key.id,
        "confirmation_prefix" => rotated_api_key.key_prefix
      }
    })

    refute has_element?(view, "#api-key-row-#{api_key.id}")
    refute Repo.get(APIKey, api_key.id)
  end

  defp extract_raw_key!(html) do
    case Regex.run(~r/sk-cxp-[A-Za-z0-9_-]+-[A-Za-z0-9_-]+/, html) do
      [raw_key] -> raw_key
      _match -> flunk("raw API key was not rendered in the one-time secret panel")
    end
  end

  defp select_api_key_section(view, section) do
    view |> element("#api-key-tab-#{section}") |> render_click()
  end

  defp insert_daily_rollup!(pool, api_key, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %DailyRollup{
      rollup_date: Date.utc_today(),
      dimension_kind: "api_key",
      pool_id: pool.id,
      api_key_id: api_key.id,
      request_count: Map.get(attrs, :request_count, 0),
      success_count: Map.get(attrs, :success_count, 1),
      failure_count: Map.get(attrs, :failure_count, 0),
      retry_count: Map.get(attrs, :retry_count, 0),
      input_tokens: Map.get(attrs, :input_tokens, 0),
      cached_input_tokens: Map.get(attrs, :cached_input_tokens, 0),
      output_tokens: Map.get(attrs, :output_tokens, 0),
      reasoning_tokens: Map.get(attrs, :reasoning_tokens, 0),
      total_tokens: Map.get(attrs, :total_tokens, 0),
      estimated_cost_micros: Decimal.new(Map.get(attrs, :estimated_cost_micros, 0)),
      settled_cost_micros: Decimal.new(Map.get(attrs, :settled_cost_micros, 0)),
      created_at: now,
      updated_at: now
    }
    |> Repo.insert!()
  end
end
