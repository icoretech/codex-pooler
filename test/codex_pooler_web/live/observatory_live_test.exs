defmodule CodexPoolerWeb.ObservatoryLiveTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Access
  alias CodexPooler.Access.{APIKey, APIKeyDashboardSession}
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Events
  alias CodexPooler.Events.{Event, PostgresBridge}
  alias CodexPooler.Repo
  alias CodexPoolerWeb.ObservatoryAuth
  alias Phoenix.LiveView.Static

  @login_path "/observatory/login"
  @observatory_path "/observatory"
  @admin_path "/admin/pools"
  @logout_path "/observatory/logout"
  @cookie_name "_codex_pooler_observatory_token"
  @login_path_text "/observatory/login"

  test "authenticated Observatory mounts with the minimal safe shell", %{conn: conn} do
    %{conn: conn, api_key: api_key, raw_key: raw_key} = authenticated_conn(conn)
    cookie_value = response_cookie_value(conn)

    {:ok, view, html} = live(conn, @observatory_path)

    assert has_element?(view, "#observatory-shell")
    assert has_element?(view, "#observatory-page")
    assert has_element?(view, "#observatory-principal", api_key.display_name)
    assert has_element?(view, "#observatory-key-prefix", api_key.key_prefix)
    assert has_element?(view, "#observatory-logout-form[action='#{@logout_path}']")
    assert has_element?(view, "#observatory-logout-form[method='post']")
    assert has_element?(view, "#observatory-logout-form input[name='_method'][value='delete']")
    assert has_element?(view, "#observatory-logout-form input[name='_csrf_token']")
    refute html =~ raw_key
    refute html =~ cookie_value
    refute html =~ "current_scope"
    socket_state = :sys.get_state(view.pid)
    refute inspect(socket_state) =~ raw_key
    refute inspect(socket_state) =~ cookie_value
    principal = socket_state.socket.assigns.dashboard_principal

    assert Map.keys(Map.from_struct(principal)) |> Enum.sort() ==
             [:api_key_id, :display_name, :key_prefix, :pool_id]

    assert is_nil(Map.get(principal, :api_key))
    assert is_nil(Map.get(principal, :pool))
    refute html =~ "observatory_handoff"
    refute html =~ "token_hash"
    assert Repo.aggregate(CodexPooler.Access.APIKeyDashboardSession, :count, :id) == 1

    expires_at =
      Repo.get_by!(CodexPooler.Access.APIKeyDashboardSession, api_key_id: api_key.id).expires_at

    send(view.pid, ObservatoryAuth.revalidation_message())
    _ = :sys.get_state(view.pid)

    assert Repo.get_by!(CodexPooler.Access.APIKeyDashboardSession, api_key_id: api_key.id).expires_at ==
             expires_at
  end

  test "signed LiveView session contains only a safe dashboard-session row id", %{conn: conn} do
    %{conn: conn, api_key: api_key} = authenticated_conn(conn)
    cookie_value = response_cookie_value(conn)
    session_row = Repo.get_by!(APIKeyDashboardSession, api_key_id: api_key.id)

    conn = conn |> recycle() |> get(@observatory_path)
    html = html_response(conn, 200)
    live_session_token = live_session_token(html)

    assert {:ok, decoded_payload} =
             Static.verify_token(CodexPoolerWeb.Endpoint, live_session_token)

    assert term_contains_binary?(decoded_payload, cookie_value) == false
    assert term_contains_binary?(decoded_payload, session_row.token_hash) == false
    assert term_contains_binary?(decoded_payload, api_key.key_hash) == false

    assert Map.keys(decoded_payload.session) == ["observatory_handoff"]
    handoff = decoded_payload.session["observatory_handoff"]
    assert Map.keys(handoff) == [:dashboard_session_id]
    assert {:ok, handoff.dashboard_session_id} == Ecto.UUID.cast(handoff.dashboard_session_id)

    assert {:error, :invalid_dashboard_session} =
             Access.authenticate_dashboard_session(handoff.dashboard_session_id)

    conn =
      conn
      |> recycle()
      |> put_req_cookie(@cookie_name, handoff.dashboard_session_id)
      |> get(@observatory_path)

    assert redirected_to(conn) == @login_path_text

    assert {:ok, principal} = Access.authenticate_dashboard_session_handoff(handoff)

    assert Map.keys(Map.from_struct(principal)) |> Enum.sort() ==
             [:api_key_id, :display_name, :key_prefix, :pool_id]
  end

  test "operator session alone cannot mount Observatory", %{conn: conn} do
    %{user: user, token: operator_token} = bootstrap_owner_fixture()
    conn = log_in_user(conn, user, operator_token)

    assert {:error, {:redirect, %{to: @login_path_text}}} = live(conn, @observatory_path)
  end

  test "Observatory cookie alone cannot mount the operator admin surface", %{conn: conn} do
    %{conn: conn} = authenticated_conn(conn)

    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, @admin_path)
  end

  test "raw query input and forged cookies cannot authenticate Observatory", %{conn: conn} do
    assert {:error, {:redirect, %{to: @login_path_text}}} =
             live(conn, @observatory_path <> "?api_key=synthetic-query-marker")

    conn = put_req_cookie(conn, @cookie_name, "synthetic-forged-cookie")

    assert {:error, {:redirect, %{to: @login_path_text}}} = live(conn, @observatory_path)
  end

  test "a stale dashboard session is denied by the request boundary", %{conn: conn} do
    %{conn: conn} = authenticated_conn(conn)
    cookie_value = response_cookie_value(conn)
    assert :ok = Access.delete_dashboard_session(cookie_value)

    assert {:error, {:redirect, %{to: @login_path_text}}} = live(conn, @observatory_path)
  end

  test "on_mount denies a stale handoff without an invalidation event", %{conn: conn} do
    %{conn: conn} = authenticated_conn(conn)
    cookie_value = response_cookie_value(conn)
    handoff = Access.dashboard_session_handoff(cookie_value)
    assert :ok = Access.delete_dashboard_session(cookie_value)

    assert {:halt, %{redirected: {:redirect, %{to: @login_path_text}}}} =
             ObservatoryAuth.on_mount(
               :require_authenticated,
               %{},
               %{"observatory_handoff" => handoff},
               %Phoenix.LiveView.Socket{}
             )
  end

  test "connected Observatory redirects on a cross-node dashboard invalidation event", %{
    conn: conn
  } do
    %{conn: conn, api_key: api_key} = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, @observatory_path)

    event = %Event{
      version: 1,
      id: Ecto.UUID.generate(),
      pool_id: api_key.pool_id,
      topics: ["dashboard_sessions"],
      reason: "dashboard_session_invalidated",
      emitted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
      payload: %{
        "api_key_id" => api_key.id,
        "cause" => "api_key_rotated",
        "pool_id" => api_key.pool_id,
        "status" => "active"
      }
    }

    assert {:ok, payload} = Events.event_to_postgres_payload(event)
    assert :ok = PostgresBridge.relay_payload(payload)
    assert_redirect(view, @login_path_text)
  end

  test "connected Observatory redirects when Access revokes the API key", %{conn: conn} do
    assert_connected_lifecycle_redirect(conn, "api_key_revoked", "revoked", fn scope, api_key ->
      Access.revoke_api_key(scope, api_key)
    end)
  end

  test "connected Observatory redirects when Access disables dashboard access", %{conn: conn} do
    assert_connected_lifecycle_redirect(conn, "api_key_updated", "active", fn scope, api_key ->
      Access.update_api_key_with_policy(scope, api_key, %{"dashboard_access" => false})
    end)
  end

  test "connected Observatory redirects when Access deletes the API key", %{conn: conn} do
    assert_connected_lifecycle_redirect(conn, "api_key_deleted", "active", fn scope, api_key ->
      Access.delete_api_key(scope, api_key)
    end)
  end

  test "connected Observatory revalidates canonical state after a missed invalidation event", %{
    conn: conn
  } do
    %{conn: conn, api_key: api_key} = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, @observatory_path)

    api_key
    |> APIKey.changeset(%{dashboard_access: false})
    |> Repo.update!()

    send(view.pid, ObservatoryAuth.revalidation_message())

    assert_redirect(view, @login_path_text)
  end

  test "route surface has exactly the four Observatory routes and no dashboard routes" do
    routes =
      CodexPoolerWeb.Router
      |> Phoenix.Router.routes()
      |> Enum.map(&{&1.verb, &1.path})

    assert {:get, @login_path} in routes
    assert {:post, @login_path} in routes
    assert {:delete, "/observatory/logout"} in routes
    assert {:get, @observatory_path} in routes

    assert Enum.count(routes, fn {_verb, path} -> String.starts_with?(path, "/observatory") end) ==
             4

    refute Enum.any?(routes, fn {_verb, path} -> String.starts_with?(path, "/dashboard/") end)
  end

  defp authenticated_conn(conn) do
    %{api_key: api_key, raw_key: raw_key} = active_api_key_fixture()

    api_key = enable_dashboard_access!(api_key)
    conn = get(conn, @login_path)

    conn =
      post(conn, @login_path, %{
        "observatory" => %{"api_key" => raw_key},
        "_csrf_token" => csrf_token_from(conn.resp_body)
      })

    %{conn: conn, api_key: api_key, raw_key: raw_key}
  end

  defp enable_dashboard_access!(api_key) do
    api_key
    |> APIKey.changeset(%{dashboard_access: true})
    |> Repo.update!()
  end

  defp assert_connected_lifecycle_redirect(conn, cause, status, mutation) do
    %{conn: conn, api_key: api_key} = authenticated_conn(conn)
    {:ok, view, _html} = live(conn, @observatory_path)
    listener = subscribe_dashboard_events_from_task(api_key.id)
    %{user: owner} = bootstrap_owner_fixture()
    scope = Scope.for_user(owner, ["instance_owner"])

    assert {:ok, _result} = mutation.(scope, api_key)

    assert {Events,
            %Events.Event{
              pool_id: pool_id,
              topics: ["dashboard_sessions"],
              reason: "dashboard_session_invalidated",
              payload: payload
            }} = Task.await(listener, 5_000)

    assert pool_id == api_key.pool_id

    assert payload == %{
             "api_key_id" => api_key.id,
             "cause" => cause,
             "pool_id" => api_key.pool_id,
             "status" => status
           }

    assert_redirect(view, @login_path_text)
  end

  defp subscribe_dashboard_events_from_task(api_key_id) do
    parent = self()

    task =
      Task.async(fn ->
        :ok = Events.subscribe_dashboard_sessions(api_key_id)
        send(parent, {:dashboard_event_listener_ready, self()})

        receive do
          message -> message
        after
          5_000 -> :event_timeout
        end
      end)

    assert_receive {:dashboard_event_listener_ready, listener_pid}
    assert listener_pid == task.pid
    task
  end

  defp response_cookie_value(conn), do: get_resp_cookies(conn)[@cookie_name][:value]

  defp csrf_token_from(html) do
    [_, token] = Regex.run(~r/name="_csrf_token"[^>]*value="([^"]+)"/, html)
    token
  end

  defp live_session_token(html) do
    [_, token] = Regex.run(~r/data-phx-session="([^"]+)"/, html)
    token
  end

  defp term_contains_binary?(term, value) when is_binary(value) do
    :binary.match(:erlang.term_to_binary(term), value) != :nomatch
  end
end
