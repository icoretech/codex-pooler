defmodule CodexPoolerWeb.Admin.AuthLiveTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import CodexPoolerWeb.CoreComponents
  import CodexPooler.AccountsFixtures

  alias CodexPooler.Accounts.User
  alias CodexPooler.Repo
  alias CodexPoolerWeb.Admin.AvatarComponents
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.PolicyEditorComponents

  @admin_routes [
    {"/admin/request-logs", "#admin-request-logs-live"},
    {"/admin/pools", "#admin-pools-live"},
    {"/admin/stats", "#admin-stats"},
    {"/admin/upstreams", "#admin-upstreams-live"},
    {"/admin/api-keys", "#admin-api-keys-live"},
    {"/admin/invites", "#admin-invites-live"},
    {"/admin/audit-logs", "#admin-audit-logs-live"},
    {"/admin/jobs", "#admin-jobs-page"},
    {"/admin/operators", "#admin-operators-live"},
    {"/admin/settings", "#admin-settings-live"}
  ]

  @admin_nav_selectors [
    "#admin-nav-pools",
    "#admin-nav-upstreams",
    "#admin-nav-api-keys",
    "#admin-nav-stats",
    "#admin-nav-operators",
    "#admin-nav-invites",
    "#admin-nav-request-logs",
    "#admin-nav-audit-logs",
    "#admin-nav-jobs"
  ]

  @admin_footer_nav_selectors [
    "#admin-nav-settings",
    "#admin-sidebar-logout"
  ]

  describe "admin route authentication" do
    test "redirects unauthenticated users to login" do
      for {path, _selector} <- @admin_routes do
        conn = build_conn()

        assert {:error, {:redirect, %{to: "/login"}}} = live(conn, path)
      end
    end

    @tag :forced_password_change
    test "redirects password-change-required operators away from /admin/operators", %{conn: conn} do
      %{user: user, token: token} = bootstrap_owner_fixture(%{"email" => "owner@example.com"})
      user = update_user(user, %{password_change_required: true})

      conn = log_in_user(conn, user, token)

      assert {:error, {:redirect, %{to: "/password/change-required"}}} =
               live(conn, "/admin/operators")
    end

    @tag :admin_navigation
    test "mounts for authenticated local browser users", %{conn: conn} do
      %{conn: conn, user: user} = register_and_log_in_user(%{conn: conn})
      expected_operator_identity = operator_identity(user)

      for {path, selector} <- @admin_routes do
        assert {:ok, view, _html} = live(conn, path)
        assert has_element?(view, selector)
        assert has_element?(view, "#admin-shell-root.overflow-hidden")
        assert has_element?(view, "#admin-shell-scroll-region.relative")

        assert has_element?(
                 view,
                 "#admin-nav.min-h-0.overflow-y-auto.overscroll-contain.scrollbar-none"
               )

        assert has_element?(
                 view,
                 "#topbar-connection-indicator[data-state='connecting'][data-transport='pending']"
               )

        assert has_element?(
                 view,
                 "#admin-websocket-state-button[aria-label='Live updates: syncing']"
               )

        assert has_element?(view, "#topbar-connection-indicator [data-ws-icon]")

        assert has_element?(
                 view,
                 "#topbar-connection-indicator [data-ws-label]",
                 "Live updates: syncing"
               )

        assert has_element?(
                 view,
                 "#admin-websocket-state-popover[data-state='connecting'][data-transport='pending'][phx-hook='WebSocketState']"
               )

        assert has_element?(view, "#admin-websocket-state-popover [data-ws-state]", "Syncing")
        assert has_element?(view, "#admin-websocket-state-popover [data-ws-transport]", "Pending")

        assert has_element?(
                 view,
                 "#admin-websocket-state-popover",
                 "Changes appear automatically while this page is open. No manual refresh needed."
               )

        for forbidden_copy <- [
              "web" <> "socket degraded",
              "Browser connection" <> " degraded",
              "Long" <> "Poll fallback",
              "Browser admin UI only",
              "connected via WebSocket"
            ] do
          refute has_element?(view, "#admin-websocket-state-popover", forbidden_copy)
        end

        refute has_element?(view, "#admin-websocket-state-popover [data-ws-endpoint]")
        refute has_element?(view, "#admin-websocket-state-popover [data-ws-heartbeat]")
        assert has_element?(view, "#admin-sidebar-operator-avatar")
        assert has_element?(view, "#admin-sidebar-operator-label.min-w-0.md\\:w-full")

        assert has_element?(
                 view,
                 "#admin-sidebar-operator-label",
                 "operator"
               )

        assert has_element?(
                 view,
                 "#admin-sidebar-operator-label p.block.w-full.min-w-0.truncate[title='#{expected_operator_identity}']",
                 expected_operator_identity
               )

        assert has_element?(view, "#admin-sidebar-footer")
        assert has_element?(view, "#admin-nav-settings[href='/admin/settings']")
        assert has_element?(view, "#admin-sidebar-logout[href='/logout']")
        refute has_element?(view, "#admin-sidebar-theme-toggle")
        refute has_element?(view, "#admin-sidebar-session-label")

        assert has_element?(
                 view,
                 "a[href='https://github.com/icoretech/codex-pooler'][target='_blank']",
                 to_string(Application.spec(:codex_pooler, :vsn))
               )

        assert has_element?(view, "header a[href='/admin/pools']", "CODEX POOLER")

        refute has_element?(
                 view,
                 "a[href='https://github.com/icoretech/codex-pooler']",
                 "v#{Application.spec(:codex_pooler, :vsn)}"
               )

        for nav_selector <- @admin_nav_selectors do
          assert has_element?(view, nav_selector)
        end

        assert admin_nav_selector_order(render(view)) == @admin_nav_selectors
        assert admin_sidebar_footer_selector_order(render(view)) == @admin_footer_nav_selectors
      end
    end

    test "admin avatar helpers use Gravatar SHA-256 URLs with identicon fallback" do
      assert AvatarComponents.email_identity("Account: User@Example.COM ") == "User@Example.COM"

      assert AvatarComponents.gravatar_url(" User@Example.COM ", size: 64) ==
               "https://www.gravatar.com/avatar/b4c9a289323b21a01c3e940f150eb9b8c542587f1abfd8f0e1cc1ffc5e475514?s=64&d=identicon&r=g"
    end

    test "shared admin component conventions render with caller supplied ids" do
      form = to_form(%{"query" => ""}, as: :filters)
      assigns = %{form: form}

      html =
        rendered_to_string(~H"""
        <AdminComponents.page_header
          id="admin-test-page-header"
          title="Shared conventions"
          description="Stable reusable admin chrome"
        >
          <:actions>
            <AdminComponents.action_button
              id="admin-test-header-action"
              icon="hero-plus"
              label="Create"
              variant={:primary}
            />
          </:actions>
        </AdminComponents.page_header>

        <AdminComponents.filter_form id="admin-test-filter-form" for={@form} phx-submit="filter">
          <.input field={@form[:query]} type="text" label="Search" />
          <:actions>
            <AdminComponents.action_button
              id="admin-test-filter-action"
              icon="hero-funnel"
              label="Filter"
              type="submit"
            />
          </:actions>
        </AdminComponents.filter_form>

        <AdminComponents.metric_strip id="admin-test-metrics">
          <AdminComponents.metric_card
            id="admin-test-metric"
            icon="hero-server-stack"
            label="Rows"
            value="123456789"
            description="Visible records with a longer status"
            tone={:primary}
            compact_mobile
          />
        </AdminComponents.metric_strip>

        <AdminComponents.admin_surface
          id="admin-test-surface"
          title="Inventory"
          description="Reusable table surface"
          count="12 rows"
        >
          <:toolbar>
            <div id="admin-test-surface-toolbar">Toolbar</div>
          </:toolbar>
          <div id="admin-test-surface-body">Body</div>
          <:footer>
            <div id="admin-test-surface-footer">Footer</div>
          </:footer>
        </AdminComponents.admin_surface>

        <AdminComponents.object_inspector
          id="admin-test-inspector"
          title="Selected row"
          subtitle="selected-row"
          status="active"
          status_class="inline-flex items-center rounded-box bg-success/15 px-2 py-1 text-xs font-semibold text-success"
        >
          <:tabs>
            <span id="admin-test-inspector-tab">Overview</span>
          </:tabs>
          <div id="admin-test-inspector-body">Details</div>
          <:quick_links>
            <div id="admin-test-inspector-links">Links</div>
          </:quick_links>
        </AdminComponents.object_inspector>

        <AdminComponents.empty_state
          id="admin-test-empty-state"
          title="No rows yet"
          description="Create or adjust filters to see results."
        />

        <AdminComponents.redacted_status_badge
          id="admin-test-status-badge"
          label="Upstream token"
          status={:unknown}
        />

        <AdminComponents.action_button
          id="admin-test-link-action"
          icon="hero-arrow-right"
          label="Open"
          navigate="/admin/request-logs"
        />
        """)

      assert_html_selector(html, "#admin-test-page-header", "Shared conventions")
      assert_html_selector(html, "#admin-test-header-action", "Create")
      assert_html_selector(html, "#admin-test-filter-form")
      assert_html_selector(html, "#admin-test-filter-action.btn-secondary", "Filter")
      refute_html_selector(html, "#admin-test-filter-action.btn-outline")
      assert_html_selector(html, "#admin-test-metrics")
      assert_html_selector(html, "#admin-test-metric")
      assert_html_selector(html, "#admin-test-surface")
      assert_html_selector(html, "#admin-test-surface-toolbar")
      assert_html_selector(html, "#admin-test-surface-body")
      assert_html_selector(html, "#admin-test-surface-footer")
      assert_html_selector(html, "#admin-test-inspector")
      assert_html_selector(html, "#admin-test-inspector-tab", "Overview")
      assert_html_selector(html, "#admin-test-inspector-body", "Details")
      assert_html_selector(html, "#admin-test-inspector-links", "Links")
      assert_html_selector(html, "#admin-test-empty-state", "No rows yet")
      assert_html_selector(html, "#admin-test-status-badge", "redacted")
      assert_html_selector(html, "#admin-test-link-action", "Open")
    end

    test "shared policy editor dialog shell renders stable operator-facing regions" do
      assigns = %{
        steps: [
          %{id: :basics, label: "Basics", description: "Name and Pool"},
          %{id: :models, label: "Models", description: "Access policy"},
          %{id: :review, label: "Review"}
        ]
      }

      html =
        rendered_to_string(~H"""
        <PolicyEditorComponents.policy_editor_dialog
          id="admin-test-editor"
          eyebrow="API key access"
          title="Create API key"
          description="Choose the policy section to edit."
          steps={@steps}
          current_step={:models}
          step_event="select_policy_section"
          backdrop_event="cancel_policy_editor"
        >
          <div id="admin-test-editor-content">Section body</div>
          <:actions>
            <AdminComponents.action_button
              id="admin-test-editor-cancel"
              icon="hero-x-mark"
              label="Cancel"
              phx-click="cancel_policy_editor"
            />
            <AdminComponents.action_button
              id="admin-test-editor-submit"
              icon="hero-check"
              label="Save policy"
              type="submit"
              form="admin-test-editor-form"
              variant={:primary}
            />
          </:actions>
        </PolicyEditorComponents.policy_editor_dialog>
        """)

      assert_html_selector(html, "#admin-test-editor")
      assert_html_selector(html, "#admin-test-editor-panel")
      assert_html_selector(html, "#admin-test-editor-header", "Create API key")
      assert_html_selector(html, "#admin-test-editor-sections")
      assert_html_selector(html, "#admin-test-editor-tabs[role='tablist']")
      assert_html_selector(html, "#admin-test-editor-body")
      assert_html_selector(html, "#admin-test-editor-footer")
      assert_html_selector(html, "#admin-test-editor-backdrop")
      assert_html_selector(html, "#admin-test-editor-step-basics")
      assert_html_selector(html, "#admin-test-editor-step-models")
      assert_html_selector(html, "#admin-test-editor-step-review")
      assert_html_selector(html, "#admin-test-editor-tab-basics")

      assert_html_selector(
        html,
        "#admin-test-editor-tab-models[aria-controls='admin-test-editor-section-models'][aria-selected='true'][phx-value-step='models']"
      )

      assert_html_selector(html, "#admin-test-editor-tab-review")
      assert_html_selector(html, "#admin-test-editor-content", "Section body")
      assert_html_selector(html, "#admin-test-editor-cancel", "Cancel")
      assert_html_selector(html, "#admin-test-editor-submit", "Save policy")

      assert_html_selector(
        html,
        "#admin-test-editor-header",
        "Choose the policy section to edit."
      )
    end
  end

  defp update_user(%User{} = user, attrs) do
    user
    |> Ecto.Changeset.change(attrs)
    |> Repo.update!()
  end

  defp operator_identity(%User{} = user) do
    display_name = user.display_name && String.trim(user.display_name)

    cond do
      is_binary(display_name) and display_name != "" -> display_name
      is_binary(user.email) and user.email != "" -> user.email
      true -> "operator"
    end
  end

  defp admin_nav_selector_order(html) do
    @admin_nav_selectors
    |> Enum.map(fn "#" <> id -> {html |> :binary.match(~s(id="#{id}")) |> elem(0), "##{id}"} end)
    |> Enum.sort_by(fn {index, _selector} -> index end)
    |> Enum.map(fn {_index, selector} -> selector end)
  end

  defp admin_sidebar_footer_selector_order(html) do
    @admin_footer_nav_selectors
    |> Enum.map(fn "#" <> id -> {html |> :binary.match(~s(id="#{id}")) |> elem(0), "##{id}"} end)
    |> Enum.sort_by(fn {index, _selector} -> index end)
    |> Enum.map(fn {_index, selector} -> selector end)
  end

  defp assert_html_selector(html, selector, text \\ nil) do
    id = selector_id!(selector)
    opening_tag = opening_tag_with_id(html, id)
    assert opening_tag, "expected selector #{selector} to be present"

    for class <- selector_classes(selector) do
      assert opening_tag =~ class, "expected selector #{selector} to include class #{class}"
    end

    for {attr, value} <- selector_attrs(selector) do
      assert opening_tag =~ ~s(#{attr}="#{value}"),
             "expected selector #{selector} to include #{attr}=#{inspect(value)}"
    end

    if text do
      assert html =~ text, "expected selector #{selector} to expose #{inspect(text)}"
    end
  end

  defp refute_html_selector(html, selector) do
    id = selector_id!(selector)

    case opening_tag_with_id(html, id) do
      nil ->
        :ok

      opening_tag ->
        refute Enum.all?(selector_classes(selector), &(opening_tag =~ &1)),
               "expected selector #{selector} to be absent"
    end
  end

  defp selector_id!(selector) do
    case Regex.run(~r/#([A-Za-z0-9_-]+)/, selector, capture: :all_but_first) do
      [id] -> id
      _missing -> raise ArgumentError, "selector #{selector} must include an id"
    end
  end

  defp selector_classes(selector) do
    ~r/\.([A-Za-z0-9_-]+)/
    |> Regex.scan(selector, capture: :all_but_first)
    |> List.flatten()
  end

  defp selector_attrs(selector) do
    ~r/\[([^=\]]+)='([^']+)'\]/
    |> Regex.scan(selector, capture: :all_but_first)
    |> Enum.map(fn [attr, value] -> {attr, value} end)
  end

  defp opening_tag_with_id(html, id) do
    id = Regex.escape(id)

    ~r/<[^>]*id="#{id}"[^>]*>/
    |> Regex.run(html)
    |> case do
      [opening_tag] -> opening_tag
      _missing -> nil
    end
  end
end
