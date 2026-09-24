defmodule CodexPoolerWeb.Runtime.UsageLimitRouteHealthTest do
  # A provider usage-limit `429` is a quota answer about the refusing account,
  # not an upstream failure (findings#206 row 206-594):
  #
  # - its headers record the account's windows as the provider's denial (the
  #   refusal code, read from the drained body, reaches the header parser, as
  #   on the websocket);
  # - when that evidence excludes the account (an exhausted window with a
  #   reset still ahead, or a workspace-level denial with its reset), the
  #   refusal completes the route neutrally: no demotion and no circuit
  #   failure, so an open circuit never hides the quota state and the account
  #   returns with its window instead of after a circuit probe;
  # - a usage-limit `429` whose headers carry no window records nothing new
  #   (a window, duration or percentage is never inferred from the body's
  #   reset) and keeps today's circuit rule, the only thing that stops the
  #   Pool from dispatching to the account again; so does a plain throttle.
  #
  # One BEAM node, FakeUpstream, native HTTP SSE and JSON, Full and Lite, owner
  # forwarding on and off (an HTTP turn never uses a websocket owner).
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport
  import CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport, only: [model_serving_scope: 0, set_model_serving_mode!: 3]

  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Persistence.{BridgeDemotion, RoutingCircuitState}
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Reconciliation.PoolReconciliation

  @moduletag capture_log: true

  @turn_endpoint "/backend-api/codex/responses"
  @lite_header "x-openai-internal-codex-responses-lite"

  for mode <- ["full", "lite"], forwarding <- [:forwarded, :direct], stream? <- [true, false] do
    @mode mode
    @forwarding forwarding
    @stream stream?

    test "#{mode} #{forwarding} stream=#{stream?}: a usage limit whose headers exhaust a window is quota evidence, not a circuit failure", %{conn: conn} do
      put_owner_forwarding!(@forwarding)
      resets_at = DateTime.to_unix(DateTime.utc_now()) + 3_600
      upstream = start_upstream(usage_limit_429(resets_at, exhausted_window_headers(resets_at) ++ [{"x-codex-rate-limit-reached-type", "rate_limit_reached"}]))
      pool = pool!(upstream, @mode)

      first = post_native(conn, pool, @stream)
      assert first.status == 429

      assert [%AccountQuotaWindow{} = window] = header_windows(pool)
      assert Decimal.equal?(window.used_percent, Decimal.new(100))
      assert window.metadata["rate_limit_reached"] == true
      assert route_health(pool) == %{circuit_failures: 0, demotions: 0}

      # The next request is refused before dispatch by the recorded window.
      second = post_native(build_conn(), pool, @stream)
      assert second.status == 429
      assert %{"error" => %{"type" => "usage_limit_reached", "code" => "quota_exhausted"}} = CodexPooler.JSON.decode!(second.resp_body)
      assert FakeUpstream.count(upstream) == 1
    end
  end

  for stream? <- [true, false] do
    @stream stream?

    test "stream=#{stream?}: a workspace denial below 100% is excluded by the denial, not by the circuit", %{conn: conn} do
      resets_at = DateTime.to_unix(DateTime.utc_now()) + 3_600
      headers = window_headers(resets_at, "97") ++ [{"x-codex-rate-limit-reached-type", "workspace_member_credits_depleted"}]
      upstream = start_upstream(usage_limit_429(resets_at, headers))
      pool = pool!(upstream, "lite")

      assert post_native(conn, pool, @stream).status == 429
      assert route_health(pool) == %{circuit_failures: 0, demotions: 0}
      assert post_native(build_conn(), pool, @stream).status == 429
      assert FakeUpstream.count(upstream) == 1
    end

    test "stream=#{stream?}: a refusal named only by its reached-type header is a usage limit too", %{conn: conn} do
      resets_at = DateTime.to_unix(DateTime.utc_now()) + 3_600
      headers = exhausted_window_headers(resets_at) ++ [{"x-codex-rate-limit-reached-type", "workspace_member_usage_limit_reached"}]
      upstream = start_upstream({:json_headers, 429, %{"error" => %{"code" => "rate_limit_exceeded", "message" => "synthetic"}}, headers})
      pool = pool!(upstream, "lite")

      assert post_native(conn, pool, @stream).status == 429
      assert [%AccountQuotaWindow{} = window] = header_windows(pool)
      assert window.metadata["rate_limit_reached"] == true
      assert route_health(pool) == %{circuit_failures: 0, demotions: 0}
    end

    test "stream=#{stream?}: a usage limit without window headers keeps the circuit rule", %{conn: conn} do
      resets_at = DateTime.to_unix(DateTime.utc_now()) + 3_600
      upstream = start_upstream(usage_limit_429(resets_at, [{"x-codex-rate-limit-reached-type", "workspace_member_usage_limit_reached"}]))
      pool = pool!(upstream, "lite")

      assert post_native(conn, pool, @stream).status == 429
      assert header_windows(pool) == []
      assert route_health(pool).circuit_failures == 1
    end

    test "stream=#{stream?}: a plain throttle keeps the circuit rule", %{conn: conn} do
      resets_at = DateTime.to_unix(DateTime.utc_now()) + 3_600
      upstream = start_upstream({:json_headers, 429, %{"error" => %{"code" => "rate_limit_exceeded", "message" => "synthetic"}}, window_headers(resets_at, "40")})
      pool = pool!(upstream, "lite")

      assert post_native(conn, pool, @stream).status == 429
      assert route_health(pool).circuit_failures == 1
    end
  end

  # Findings#206 row 206-594, reopened: an account whose fresh Usage API
  # reading still says `allowed` (5%) refuses with a usage limit whose
  # headers put a window at 100% until a reset ahead. Whatever the reached
  # type, the refusal excludes the account until that reset; the workspace
  # types did through the account-denial filter, `rate_limit_reached` did not.
  for rtype <- ["rate_limit_reached", "workspace_member_usage_limit_reached"], mode <- ["full", "lite"], stream? <- [true, false] do
    @rtype rtype
    @mode mode
    @stream stream?

    test "#{rtype} #{mode} stream=#{stream?}: a usage limit on an allowed account excludes it until the reset", %{conn: conn} do
      resets_at = DateTime.to_unix(DateTime.utc_now()) + 90
      refusal = usage_limit_429(resets_at, exhausted_window_headers(resets_at) ++ [{"x-codex-rate-limit-reached-type", @rtype}])
      {upstream, pool} = usage_allowed_pool!(refusal, @mode)

      assert post_native(conn, pool, @stream).status == 429

      for _turn <- 1..3 do
        second = post_native(build_conn(), pool, @stream)
        assert second.status == 429
        assert %{"error" => %{"type" => "usage_limit_reached", "code" => "quota_exhausted"}} = CodexPooler.JSON.decode!(second.resp_body)
      end

      assert model_posts(upstream) == 1
      assert route_health(pool) == %{circuit_failures: 0, demotions: 0}
    end
  end

  # The same refusal whose headers keep the window below 100% (the provider
  # refused the account before the percentage reached it): the refusal's
  # reached type decided whether it excluded anything, workspace types only.
  for rtype <- ["rate_limit_reached", "workspace_member_usage_limit_reached"], stream? <- [true, false] do
    @rtype rtype
    @stream stream?

    test "#{rtype} stream=#{stream?}: a usage limit below 100% excludes the account until the reset", %{conn: conn} do
      resets_at = DateTime.to_unix(DateTime.utc_now()) + 90
      refusal = usage_limit_429(resets_at, window_headers(resets_at, "97") ++ [{"x-codex-rate-limit-reached-type", @rtype}])
      {upstream, pool} = usage_allowed_pool!(refusal, "lite")

      assert post_native(conn, pool, @stream).status == 429

      for _turn <- 1..3 do
        next = post_native(build_conn(), pool, @stream)
        assert next.status == 429
        assert %{"error" => %{"type" => "usage_limit_reached", "code" => "quota_exhausted", "resets_in_seconds" => seconds}} = CodexPooler.JSON.decode!(next.resp_body)
        assert seconds in 80..90
      end

      assert model_posts(upstream) == 1
    end
  end

  test "a plain throttle below 100% with a reached-type header name keeps routing", %{conn: conn} do
    resets_at = DateTime.to_unix(DateTime.utc_now()) + 90
    headers = window_headers(resets_at, "40") ++ [{"x-codex-rate-limit-reached-type", "rate_limit_reached"}]
    throttle = {:json_headers, 429, %{"error" => %{"code" => "rate_limit_exceeded", "message" => "synthetic"}}, headers}
    {upstream, pool} = usage_allowed_pool!(throttle, "full")

    assert post_native(conn, pool, false).status == 429
    assert post_native(build_conn(), pool, false).status == 429
    assert model_posts(upstream) == 2
  end

  test "a plain throttle on an allowed account is not excluded", %{conn: conn} do
    resets_at = DateTime.to_unix(DateTime.utc_now()) + 90
    throttle = {:json_headers, 429, %{"error" => %{"code" => "rate_limit_exceeded", "message" => "synthetic"}}, window_headers(resets_at, "40")}
    {upstream, pool} = usage_allowed_pool!(throttle, "lite")

    assert post_native(conn, pool, true).status == 429
    assert post_native(build_conn(), pool, true).status == 429
    assert model_posts(upstream) == 2
  end

  # The account's usage reading, recorded through the real reconciliation
  # path: `allowed`, both windows at 5% with a later reset.
  defp usage_allowed_pool!(refusal, mode) do
    usage = %{
      "plan_type" => "pro",
      "rate_limit" => %{
        "allowed" => true,
        "limit_reached" => false,
        "primary_window" => %{"used_percent" => 5, "limit_window_seconds" => 18_000, "reset_after_seconds" => 9_000, "reset_at" => DateTime.to_unix(DateTime.utc_now()) + 9_000},
        "secondary_window" => %{"used_percent" => 5, "limit_window_seconds" => 604_800, "reset_after_seconds" => 300_000, "reset_at" => DateTime.to_unix(DateTime.utc_now()) + 300_000}
      },
      "credits" => %{"has_credits" => false, "unlimited" => false, "balance" => "0"}
    }

    routes = %{"/api/codex/usage" => {200, usage}, "/backend-api/codex/usage" => {200, usage}, "/wham/usage" => {200, usage}, "/backend-api/wham/usage" => {200, usage}, @turn_endpoint => refusal}
    upstream = start_upstream({:path_json, routes})
    setup = gateway_setup(upstream, quota?: false, compact?: true)
    identity = setup.identity |> Ecto.Changeset.change(metadata: Map.put(setup.identity.metadata, "usage_base_url", FakeUpstream.url(upstream))) |> Repo.update!()
    assert {:ok, identity} = PoolReconciliation.refresh_quota_from_usage(identity, setup.assignment)
    _revision = set_model_serving_mode!(model_serving_scope(), setup, mode)
    {upstream, Map.merge(%{setup | identity: identity}, %{mode: mode, started_at: DateTime.utc_now()})}
  end

  defp model_posts(upstream), do: Enum.count(FakeUpstream.requests(upstream), &(&1.path == @turn_endpoint))

  defp usage_limit_429(resets_at, headers) do
    error = %{"type" => "usage_limit_reached", "message" => "synthetic provider usage limit text", "resets_at" => resets_at, "resets_in_seconds" => resets_at - DateTime.to_unix(DateTime.utc_now())}
    {:json_headers, 429, %{"error" => error}, headers}
  end

  defp exhausted_window_headers(resets_at), do: window_headers(resets_at, "100")

  defp window_headers(resets_at, used_percent) do
    [
      {"x-codex-primary-used-percent", used_percent},
      {"x-codex-primary-window-minutes", "300"},
      {"x-codex-primary-reset-at", Integer.to_string(resets_at)}
    ]
  end

  # The windows the refusal recorded, not the setup's primed evidence.
  defp header_windows(pool) do
    Repo.all(from(w in AccountQuotaWindow, where: w.upstream_identity_id == ^pool.identity.id and w.observed_at > ^pool.started_at))
  end

  defp route_health(pool) do
    circuits = Repo.all(from(c in RoutingCircuitState, where: c.pool_upstream_assignment_id == ^pool.assignment.id))
    demotions = Repo.aggregate(from(d in BridgeDemotion, where: d.pool_upstream_assignment_id == ^pool.assignment.id), :count)
    %{circuit_failures: circuits |> Enum.map(&(&1.failure_count || 0)) |> Enum.sum(), demotions: demotions}
  end

  defp pool!(upstream, mode) do
    setup = gateway_setup(upstream, compact?: true)
    _revision = set_model_serving_mode!(model_serving_scope(), setup, mode)
    Map.merge(setup, %{mode: mode, started_at: DateTime.utc_now()})
  end

  defp post_native(conn, pool, stream?) do
    conn
    |> put_req_header("authorization", pool.authorization)
    |> put_req_header("content-type", "application/json")
    |> then(&if pool.mode == "lite", do: put_req_header(&1, @lite_header, "true"), else: &1)
    |> post(
      @turn_endpoint,
      CodexPooler.JSON.encode!(%{
        "model" => pool.model.exposed_model_id,
        "instructions" => "synthetic instructions",
        "input" => native_text_input("synthetic usage limit route health prompt"),
        "tools" => [],
        "store" => false,
        "stream" => stream?
      })
    )
  end

  defp put_owner_forwarding!(forwarding) do
    CodexPooler.TestAppEnv.restore_on_exit(:websocket_owner_forwarding_enabled, nil)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, forwarding == :forwarded)
  end
end
