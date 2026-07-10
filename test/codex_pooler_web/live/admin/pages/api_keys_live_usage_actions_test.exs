defmodule CodexPoolerWeb.Admin.ApiKeysLiveUsageActionsTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias CodexPooler.Access
  alias CodexPooler.Access.APIKey
  alias CodexPooler.Pools
  alias CodexPooler.Repo

  setup :register_and_log_in_user

  test "edit review shows Pool name and normalized policy limits without usage", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "policy-key", name: "Policy Pool"})

    {:ok, %{api_key: api_key, raw_key: raw_key}} =
      Access.create_api_key(scope, pool, %{
        display_name: "Policy summary key",
        default_policy: %{max_tokens_per_week: 1_000, max_requests_per_minute: 60}
      })

    {:ok, view, _html} = live(conn, ~p"/admin/api-keys")

    assert has_element?(view, "#api-key-row-#{api_key.id}-last-used", "Never used")
    assert has_element?(view, "#api-key-row-#{api_key.id}-expires", "No expiry")
    refute render(view) =~ raw_key

    view |> element("#edit-api-key-#{api_key.id}") |> render_click()
    select_api_key_section(view, :review)

    assert has_element?(view, "#api-key-review-summary", "Policy Pool")
    assert has_element?(view, "#api-key-review-summary", "1,000")
    assert has_element?(view, "#api-key-review-summary", "60")
    refute has_element?(view, "#api-key-usage-summary")
    refute view |> element("#api-key-review-summary") |> render() =~ pool.id
    refute render(view) =~ raw_key
  end

  test "edit review keeps no-cap policy explicit without usage placeholders", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "unused-key", name: "Unused Key"})

    {:ok, %{api_key: api_key, raw_key: raw_key}} =
      Access.create_api_key(scope, pool, %{display_name: "Unused summary key"})

    {:ok, view, _html} = live(conn, ~p"/admin/api-keys")

    view |> element("#edit-api-key-#{api_key.id}") |> render_click()
    select_api_key_section(view, :review)

    assert has_element?(view, "#api-key-review-summary", "No caps configured")
    refute has_element?(view, "#api-key-usage-summary")
    refute render(view) =~ raw_key
  end

  test "expiry validation blocks malformed values and accepts blank or valid datetimes", %{
    conn: conn,
    scope: scope
  } do
    {:ok, pool} = Pools.create_pool(scope, %{slug: "expiry-validation", name: "Expiry Pool"})

    {:ok, %{api_key: api_key}} =
      Access.create_api_key(scope, pool, %{display_name: "Expiry validation key"})

    {:ok, view, _html} = live(conn, ~p"/admin/api-keys")
    view |> element("#edit-api-key-#{api_key.id}") |> render_click()

    view
    |> element("#api-key-form")
    |> render_change(%{"api_key" => %{"expires_at" => "not-a-date"}})

    select_api_key_section(view, :review)

    refute has_element?(view, "#api-key-tab-review[aria-selected='true']")
    assert has_element?(view, "#api-key-tab-basics[aria-selected='true']")
    assert has_element?(view, "#api-key-section-basics", "must be a valid date and time")
    assert has_element?(view, "#api-key-review-errors", "Expiry must be a valid date and time")

    view
    |> element("#api-key-form")
    |> render_submit(%{"api_key" => %{"expires_at" => "not-a-date"}})

    assert has_element?(view, "#api-key[open]")
    assert has_element?(view, "#api-key-review-errors", "Expiry must be a valid date and time")
    assert Repo.get!(APIKey, api_key.id).expires_at == nil

    view
    |> element("#api-key-form")
    |> render_submit(%{"api_key" => %{"expires_at" => ""}})

    refute has_element?(view, "#api-key[open]")
    assert Repo.get!(APIKey, api_key.id).expires_at == nil

    view |> element("#edit-api-key-#{api_key.id}") |> render_click()

    view
    |> element("#api-key-form")
    |> render_change(%{"api_key" => %{"expires_at" => "2099-08-02T12:45"}})

    select_api_key_section(view, :review)
    refute has_element?(view, "#api-key-review-errors")

    view
    |> element("#api-key-form")
    |> render_submit(%{"api_key" => %{"expires_at" => "2099-08-02T12:45"}})

    refute has_element?(view, "#api-key[open]")
    assert Repo.get!(APIKey, api_key.id).expires_at == ~U[2099-08-02 12:45:00.000000Z]
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
end
