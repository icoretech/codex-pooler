defmodule CodexPoolerWeb.Admin.UpstreamsUsagePollPauseLiveTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CodexPooler.PoolerFixtures

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Reconciliation.PoolReconciliation
  alias CodexPooler.Upstreams.Reconciliation.UsagePollCooldown
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  # A provider `Retry-After` of several days on a usage read (findings#259).
  @multi_day_seconds 3 * 86_400

  setup :register_and_log_in_user

  test "a multi-day Retry-After recorded by reconciliation is shown on the account card", %{conn: conn} do
    %{identity: identity, fake: fake} = account = throttled_account!("259-visible")

    assert {:ok, _result} = reconcile!(account)
    assert {:ok, _result} = reconcile!(account)
    # The pause holds: the second cycle never reached the provider.
    assert length(FakeUpstream.requests(fake)) == 1

    %UpstreamIdentity{metadata: metadata} = Repo.get!(UpstreamIdentity, identity.id)
    [%{not_before: not_before}] = UsagePollCooldown.active_pauses(metadata, 1, DateTime.utc_now())
    assert DateTime.diff(not_before, DateTime.utc_now(), :second) > @multi_day_seconds - 120

    {:ok, view, html} = live(conn, ~p"/admin/upstreams")
    prefix = "upstream-account-#{identity.id}"

    assert has_element?(
             view,
             "##{prefix}-usage-poll-pause[data-role='upstream-usage-poll-pause'][data-paused-until='#{DateTime.to_iso8601(not_before)}'][data-status-code='429']"
           )

    assert has_element?(view, "##{prefix}-usage-poll-pause-title", "Usage polling paused until")
    assert has_element?(view, "##{prefix}-usage-poll-pause-remaining", "in 2d 23h")
    assert has_element?(view, "##{prefix}-usage-poll-pause-origin", "HTTP 429 with Retry-After")
    refute has_element?(view, "##{prefix}-usage-poll-pause-origin-count")

    # Display only: the provider's interval is honoured, so the notice offers
    # no way to end it early (findings#259 decision).
    refute has_element?(view, "##{prefix}-usage-poll-pause button")
    refute has_element?(view, "##{prefix}-usage-poll-pause [phx-click]")

    # The origin is stored as a digest and the usage host is operator config;
    # neither the record nor the host it came from is projected.
    refute html =~ UsagePollCooldown.metadata_key()
    refute html =~ FakeUpstream.url(fake)
    refute html =~ "credential_epoch"
  end

  test "an account whose usage polling is not paused shows no pause", %{conn: conn} do
    %{identity: identity} = active_upstream_assignment_fixture(pool_fixture(), %{account_label: "Unpaused Sample Account"})

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    assert has_element?(view, "#upstream-account-#{identity.id}")
    refute has_element?(view, "#upstream-account-#{identity.id}-usage-poll-pause")
  end

  test "a pause for a replaced credential or one already over is not shown", %{conn: conn} do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    origin = UsagePollCooldown.origin_key("https://usage.example.test/backend-api/wham/usage")

    %{identity: stale_epoch} = active_upstream_assignment_fixture(pool_fixture(), %{account_label: "Replaced Credential Sample"})
    %{identity: elapsed} = active_upstream_assignment_fixture(pool_fixture(), %{account_label: "Elapsed Pause Sample"})

    assert {:ok, _deadline} = UsagePollCooldown.record(stale_epoch.id, 1, origin, 429, DateTime.add(now, @multi_day_seconds, :second), now)
    put_metadata!(stale_epoch.id, "credential_epoch", 2)

    earlier = DateTime.add(now, -120, :second)
    assert {:ok, _deadline} = UsagePollCooldown.record(elapsed.id, 1, origin, 503, DateTime.add(earlier, 60, :second), earlier)

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")

    for identity <- [stale_epoch, elapsed] do
      assert has_element?(view, "#upstream-account-#{identity.id}")
      refute has_element?(view, "#upstream-account-#{identity.id}-usage-poll-pause")
    end
  end

  test "pauses on two usage hosts show the latest deadline and count both", %{conn: conn} do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    %{identity: identity} = active_upstream_assignment_fixture(pool_fixture(), %{account_label: "Two Host Sample"})
    shorter = DateTime.add(now, 3_600, :second)
    longer = DateTime.add(now, @multi_day_seconds, :second)

    for {host, status, deadline} <- [{"usage-a.example.test", 429, shorter}, {"usage-b.example.test", 503, longer}] do
      origin = UsagePollCooldown.origin_key("https://#{host}/backend-api/wham/usage")
      assert {:ok, _deadline} = UsagePollCooldown.record(identity.id, 1, origin, status, deadline, now)
    end

    {:ok, view, _html} = live(conn, ~p"/admin/upstreams")
    prefix = "upstream-account-#{identity.id}"

    assert has_element?(view, "##{prefix}-usage-poll-pause[data-paused-until='#{DateTime.to_iso8601(longer)}'][data-status-code='503']")
    assert has_element?(view, "##{prefix}-usage-poll-pause-origin", "HTTP 503 with Retry-After")
    assert has_element?(view, "##{prefix}-usage-poll-pause-origin-count", "Paused on 2 usage hosts")
  end

  defp throttled_account!(suffix) do
    {:ok, fake} =
      FakeUpstream.start_link(
        {:path_json,
         %{
           "/backend-api/wham/usage" => {:json_headers, 429, %{}, [{"retry-after", Integer.to_string(@multi_day_seconds)}]},
           "/backend-api/codex/usage" => {200, %{}}
         }}
      )

    on_exit(fn -> FakeUpstream.stop(fake) end)

    pool = pool_fixture()

    %{identity: identity, assignment: assignment} =
      active_upstream_assignment_fixture(pool, %{
        account_label: "Throttled Sample #{suffix}",
        chatgpt_account_id: "acct_usage_poll_pause_#{System.unique_integer([:positive])}",
        metadata: %{"usage_base_url" => FakeUpstream.url(fake)}
      })

    %{identity: identity, pool: pool, assignment: assignment, fake: fake}
  end

  defp reconcile!(%{pool: pool, assignment: assignment}), do: PoolReconciliation.reconcile_pool_account(pool, assignment, [])

  defp put_metadata!(identity_id, key, value) do
    identity = Repo.get!(UpstreamIdentity, identity_id)

    identity
    |> Ecto.Changeset.change(metadata: Map.put(identity.metadata || %{}, key, value))
    |> Repo.update!()
  end
end
