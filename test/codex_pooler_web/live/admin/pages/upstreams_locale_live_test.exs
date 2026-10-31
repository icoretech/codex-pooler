defmodule CodexPoolerWeb.Admin.UpstreamsLocaleLiveTest do
  use CodexPoolerWeb.ConnCase, async: false

  import CodexPooler.PoolerFixtures
  import Phoenix.LiveViewTest

  alias CodexPooler.Audit
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Admin.UpstreamsLive.WorkflowError

  setup :register_and_log_in_user

  test "Chinese upstream index and auth JSON dialog use the request locale", %{conn: conn} do
    pool = pool_fixture(%{name: "Locale Pool"})
    {:ok, view, _html} = conn |> put_locale("zh-CN") |> live(~p"/admin/upstreams")

    assert has_element?(view, "#upstream-account-page-header h1", "上游")
    assert has_element?(view, "#upstream-page-import-auth-json-action[aria-label='导入 auth.json']")

    view |> element("#upstream-page-import-auth-json-action") |> render_click()

    assert has_element?(view, "#auth-json-import-dialog[open] h2", "导入 auth.json")
    assert has_element?(view, "#auth-json-import-submit", "导入 auth.json")

    view
    |> element("#auth-json-import-form")
    |> render_submit(%{"auth_json" => %{"pool_id" => pool.id, "content" => ""}})

    assert has_element?(view, "#auth-json-import-errors", "粘贴 auth.json 或上传一个 .json 文件")
  end

  test "Chinese saved-reset labels survive an asynchronous index reload", %{conn: conn} do
    pool = pool_fixture()
    %{identity: identity} = upstream_assignment_fixture(pool, reset_bank_attrs())
    {:ok, view, _html} = conn |> put_locale("zh-CN") |> live(~p"/admin/upstreams")

    meter = "#upstream-account-#{identity.id}-saved-reset-meter-bar"
    assert has_element?(view, "#{meter}[aria-label='2 次已保存的重置'][aria-valuenow='2']")
    metadata = put_in(identity.metadata, ["saved_resets", "available_count"], 3)
    identity |> Ecto.Changeset.change(metadata: metadata) |> Repo.update!()

    send(view.pid, :reload_upstreams_from_events)
    _ = :sys.get_state(view.pid)
    _ = render_async(view)

    assert has_element?(view, "#{meter}[aria-label='3 次已保存的重置'][aria-valuenow='3']")

    view |> element("#upstream-account-#{identity.id}-saved-reset-meter-open") |> render_click()
    assert has_element?(view, "#saved-reset-policy-dialog[open]")
    assert has_element?(view, "#saved-reset-policy-submit", "保存")
  end

  test "Chinese cockpit translates deferred request events and shared labels", %{conn: conn} do
    pool = pool_fixture()
    %{api_key: api_key} = active_api_key_fixture(pool)
    %{identity: identity, assignment: assignment} = upstream_assignment_fixture(pool, reset_bank_attrs())

    request = request_fixture(%{pool: pool, api_key: api_key}, %{status: "failed", response_status_code: nil, last_error_code: nil})
    attempt_fixture(request, assignment, %{status: "failed", upstream_status_code: nil})

    {:ok, view, _html} = conn |> put_locale("zh-CN") |> live(~p"/admin/upstreams/#{identity.id}")
    _ = render_async(view)

    assert has_element?(view, "#upstream-cockpit-status", "启用")
    assert has_element?(view, "#upstream-assignments h2", "路由通道")
    assert has_element?(view, "#upstream-event-summary [data-role='recent-event-title']", "请求失败")
    assert has_element?(view, "#upstream-event-summary [data-role='recent-event-subtitle']", "1 次尝试")
    assert has_element?(view, "#upstream-quota-saved-reset-meter-bar[aria-label='2 次已保存的重置']")
  end

  test "Chinese cockpit translates paused identity and audit outcomes after deferred load", %{conn: conn, user: user} do
    pool = pool_fixture()
    %{identity: identity} = upstream_assignment_fixture(pool, reset_bank_attrs())
    identity = identity |> Ecto.Changeset.change(status: "paused") |> Repo.update!()

    assert {:ok, _event} =
             Audit.record_user_event(user, %{
               pool_id: pool.id,
               action: "upstream_account.rename",
               target_type: "upstream_identity",
               target_id: identity.id,
               outcome: "success"
             })

    {:ok, view, _html} = conn |> put_locale("zh-CN") |> live(~p"/admin/upstreams/#{identity.id}")
    _ = render_async(view)

    assert has_element?(view, "#upstream-cockpit-status", "已暂停")
    assert has_element?(view, "#upstream-event-summary [data-role='recent-event-title']", "上游账号已重命名")
    assert has_element?(view, "#upstream-event-summary [data-role='recent-event-subtitle']", "成功")
  end

  test "known OAuth and lifecycle errors translate without changing domain messages" do
    Gettext.put_locale("zh_CN")
    assert WorkflowError.message(%{code: :expired_flow, message: "OAuth flow has expired"}) == "OAuth 流程已过期"
    assert WorkflowError.message(%{code: :upstream_deletion_busy, message: "upstream deletion is waiting for database work to finish"}) == "上游删除正在等待数据库操作完成"
  end

  defp reset_bank_attrs do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %{
      account_label: "Locale upstream",
      identity_metadata: %{
        "saved_resets" => %{
          "status" => "reported",
          "available_count" => 2,
          "observed_at" => DateTime.to_iso8601(now),
          "source" => "codex_usage_api",
          "available_expirations" => [%{"expires_at" => DateTime.to_iso8601(DateTime.add(now, 7, :day)), "first_seen_at" => DateTime.to_iso8601(now)}]
        }
      },
      assignment_metadata: %{"quota_priming" => %{"status" => "known"}}
    }
  end
end
