defmodule CodexPoolerWeb.Admin.UpstreamCalendarControllerTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Accounts
  alias CodexPooler.Pools
  alias CodexPooler.Repo

  setup :register_and_log_in_user

  test "downloads all future events for the selected upstream with private attachment headers", %{conn: conn, scope: scope} do
    {identity, expirations} = bank_fixture(scope, "calendar-export")
    {other, _other_expirations} = bank_fixture(scope, "calendar-other")

    response = get(conn, ~p"/admin/upstreams/#{identity.id}/saved-reset-expirations.ics")
    body = response(response, 200)
    assert get_resp_header(response, "content-type") == ["text/calendar; charset=utf-8"]
    assert [disposition] = get_resp_header(response, "content-disposition")
    assert disposition == ~s(attachment; filename="banked-reset-expirations-#{String.slice(identity.id, 0, 8)}.ics")
    assert get_resp_header(response, "cache-control") == ["private, no-store"]
    assert length(Regex.scan(~r/BEGIN:VEVENT\r\n/, body)) == 2

    for expiration <- expirations do
      assert body =~ "DTSTART:#{Calendar.strftime(expiration, "%Y%m%dT%H%M%SZ")}\r\n"
    end

    unfolded = String.replace(body, "\r\n ", "")
    assert unfolded =~ "Banked reset expires — #{identity.account_label}"
    assert unfolded =~ "URL:#{CodexPoolerWeb.Endpoint.url()}/admin/upstreams/#{identity.id}\r\n"
    refute unfolded =~ other.account_label
    refute unfolded =~ "private-calendar-marker"
    assert Repo.reload!(identity).metadata == identity.metadata
  end

  test "requires a browser session and current password", %{scope: scope} do
    {identity, _expirations} = bank_fixture(scope, "calendar-auth")
    path = ~p"/admin/upstreams/#{identity.id}/saved-reset-expirations.ics"

    assert build_conn() |> get(path) |> redirected_to() == ~p"/login"

    %{user: operator, temporary_password: password} = operator_fixture(scope, %{"role" => "instance_admin"})
    operator_pool_assignment_fixture(operator, Repo.get!(Pools.Pool, identity.metadata["fixture_pool_id"]))
    assert {:ok, %{token: token}} = Accounts.login_user(%{"email" => operator.email, "password" => password})
    response = build_conn() |> log_in_user(operator, token) |> get(path)
    assert redirected_to(response) == ~p"/password/change-required"
    assert get_resp_header(response, "content-disposition") == []
  end

  test "scopes exports to visible upstreams and rechecks revoked Pool access", %{scope: scope} do
    {visible, _expirations} = bank_fixture(scope, "calendar-visible")
    {hidden, _expirations} = bank_fixture(scope, "calendar-hidden")
    %{user: operator, temporary_password: password} = operator_fixture(scope, %{"role" => "instance_admin", "password_change_required" => "false"})
    pool = Repo.get!(Pools.Pool, visible.metadata["fixture_pool_id"])
    operator_pool_assignment_fixture(operator, pool)
    assert {:ok, %{token: token}} = Accounts.login_user(%{"email" => operator.email, "password" => password})

    assert build_conn() |> log_in_user(operator, token) |> get(~p"/admin/upstreams/#{visible.id}/saved-reset-expirations.ics") |> response(200) =~ "BEGIN:VCALENDAR"
    assert build_conn() |> log_in_user(operator, token) |> get(~p"/admin/upstreams/#{hidden.id}/saved-reset-expirations.ics") |> response(404) == "Not found"

    assert {:ok, _operator} = Accounts.update_operator(scope, operator, %{"pool_ids" => []})
    assert build_conn() |> log_in_user(operator, token) |> get(~p"/admin/upstreams/#{visible.id}/saved-reset-expirations.ics") |> response(404) == "Not found"
  end

  test "returns no calendar for invalid, missing, deleted or empty upstreams", %{conn: conn, scope: scope} do
    {identity, _expirations} = bank_fixture(scope, "calendar-empty")

    for id <- ["invalid", Ecto.UUID.generate()] do
      assert conn |> get(~p"/admin/upstreams/#{id}/saved-reset-expirations.ics") |> response(404) == "Not found"
    end

    Repo.update!(Ecto.Changeset.change(identity, metadata: %{"saved_resets" => %{"status" => "reported", "available_count" => 0}}))
    empty = get(conn, ~p"/admin/upstreams/#{identity.id}/saved-reset-expirations.ics")
    assert response(empty, 404) =~ "No upcoming banked reset expirations"
    assert get_resp_header(empty, "content-disposition") == []

    Repo.update!(Ecto.Changeset.change(identity, status: "deleted"))
    assert conn |> get(~p"/admin/upstreams/#{identity.id}/saved-reset-expirations.ics") |> response(404) == "Not found"
  end

  test "rereads the bank so redeemed expirations are absent from the next download", %{conn: conn, scope: scope} do
    {identity, [first, second]} = bank_fixture(scope, "calendar-current")
    path = ~p"/admin/upstreams/#{identity.id}/saved-reset-expirations.ics"
    assert get(conn, path) |> response(200) =~ Calendar.strftime(first, "%Y%m%dT%H%M%SZ")

    updated = put_in(identity.metadata, ["saved_resets", "available_expires_at"], [DateTime.to_iso8601(second)])
    Repo.update!(Ecto.Changeset.change(identity, metadata: updated))
    body = get(conn, path) |> response(200)
    assert length(Regex.scan(~r/BEGIN:VEVENT\r\n/, body)) == 1
    refute body =~ Calendar.strftime(first, "%Y%m%dT%H%M%SZ")
    assert body =~ Calendar.strftime(second, "%Y%m%dT%H%M%SZ")
  end

  test "an owner can export an unassigned upstream while a scoped operator cannot", %{conn: conn, scope: scope} do
    {identity, _expirations} = bank_fixture(scope, "calendar-unassigned")
    Repo.delete_all(from assignment in CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment, where: assignment.upstream_identity_id == ^identity.id)

    path = ~p"/admin/upstreams/#{identity.id}/saved-reset-expirations.ics"
    assert get(conn, path) |> response(200) =~ "BEGIN:VCALENDAR"

    %{user: operator, temporary_password: password} = operator_fixture(scope, %{"role" => "instance_admin", "password_change_required" => "false"})
    assert {:ok, %{token: token}} = Accounts.login_user(%{"email" => operator.email, "password" => password})
    assert build_conn() |> log_in_user(operator, token) |> get(path) |> response(404) == "Not found"
  end

  defp bank_fixture(scope, slug) do
    {:ok, pool} = Pools.create_pool(scope, %{slug: slug, name: "Sample Pool"})
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    expirations = [DateTime.add(now, 7, :day), DateTime.add(now, 8, :day)]

    %{identity: identity} =
      upstream_assignment_fixture(pool, %{
        account_label: "Sample #{slug}",
        identity_metadata: %{
          "fixture_pool_id" => pool.id,
          "private" => "private-calendar-marker",
          "saved_resets" => %{"status" => "reported", "available_count" => 2, "available_expires_at" => Enum.map(expirations ++ [DateTime.add(now, -1, :day)], &DateTime.to_iso8601/1)}
        }
      })

    {identity, expirations}
  end
end
