defmodule CodexPoolerWeb.Runtime.BackendCodexResetProbeTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  test "successful HTTP JSON response confirms the guarded reset probe", %{conn: conn} do
    # Auto redemption consumes the saved reset, but the post-consume usage
    # refresh OMITS the account rate_limit window, so the redemption parks in
    # consumed_pending_probe and the triggering request is force-routed as the
    # one-shot guarded probe. Its non-streaming success must flip the phase to
    # confirmed_by_upstream through the shared finalization side effects.
    upstream =
      start_upstream(
        {:path_json,
         %{
           "/api/codex/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}},
           "/api/codex/usage" =>
             {200,
              %{"plan_type" => "pro", "rate_limit_reset_credits" => %{"available_count" => 0}}},
           "/backend-api/codex/responses" =>
             {200,
              %{
                "id" => "resp_reset_probe_confirmed",
                "object" => "response",
                "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
              }}
         }}
      )

    setup = gateway_setup(upstream, quota?: false)

    identity =
      setup.identity
      |> UpstreamIdentity.changeset(%{
        metadata: saved_reset_metadata(upstream, 1),
        saved_reset_auto_redeem_enabled: true,
        saved_reset_auto_redeem_min_blocked_minutes: 60,
        saved_reset_auto_redeem_keep_credits: 0,
        updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      })
      |> Repo.update!()

    prime_weekly_exhausted_quota!(identity)

    conn =
      conn
      |> auth(setup)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "guarded reset probe",
        "stream" => false
      })

    assert %{"id" => "resp_reset_probe_confirmed"} = json_response(conn, 200)

    requests = FakeUpstream.requests(upstream)

    assert [%{method: "POST", json: %{"redeem_request_id" => _}}] =
             Enum.filter(requests, &(&1.path == "/api/codex/rate-limit-reset-credits/consume"))

    assert %{method: "POST", path: "/backend-api/codex/responses"} = List.last(requests)

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "succeeded"
    assert get_in(request.request_metadata, ["quota_decision", "routing_state"]) == "reset_probe"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.status == "succeeded"

    redemption = Repo.reload!(identity).metadata["saved_reset_redemption"]
    assert redemption["phase"] == "confirmed_by_upstream"
    assert get_in(redemption, ["result", "code"]) == "reset"
  end

  test "guarded reset probe model miss stays on the redeemed assignment", %{conn: conn} do
    probe_upstream =
      start_upstream(
        {:path_json,
         %{
           "/api/codex/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}},
           "/api/codex/usage" =>
             {200,
              %{"plan_type" => "pro", "rate_limit_reset_credits" => %{"available_count" => 0}}},
           "/backend-api/codex/responses" =>
             {404, %{"error" => %{"code" => "model_not_found", "param" => "model"}}}
         }}
      )

    sibling_upstream =
      start_upstream(
        FakeUpstream.json_response(%{
          "id" => "resp_reset_probe_sibling_should_not_run",
          "object" => "response"
        })
      )

    setup = gateway_setup(probe_upstream, quota?: false)
    use_deterministic_rotation!(setup.pool, 2)

    sibling =
      gateway_upstream(setup.pool, sibling_upstream, "upstream-token-reset-probe-sibling",
        compact?: false
      )

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(sibling.identity, [
               weekly_quota_window_attrs(%{
                 used_percent: Decimal.new("97"),
                 source: "codex_usage_api"
               })
             ])

    _model =
      put_model_source_assignments!(setup.model, [setup.assignment, sibling.assignment])

    identity =
      setup.identity
      |> UpstreamIdentity.changeset(%{
        metadata: saved_reset_metadata(probe_upstream, 1),
        saved_reset_auto_redeem_enabled: true,
        saved_reset_auto_redeem_trigger_mode: "threshold",
        saved_reset_auto_redeem_quota_threshold_percent: 95,
        saved_reset_auto_redeem_min_blocked_minutes: 60,
        saved_reset_auto_redeem_keep_credits: 0,
        updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      })
      |> Repo.update!()

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(identity, [
               weekly_quota_window_attrs(%{
                 used_percent: Decimal.new("96"),
                 source: "codex_usage_api"
               })
             ])

    routing_settings = Repo.reload!(CodexPooler.Pools.routing_settings_with_defaults(setup.pool))
    assert routing_settings.routing_strategy == "deterministic_rotation"
    assert routing_settings.bridge_ring_size == 2

    request_id = deterministic_rotation_seed(2, 1)
    assert :erlang.phash2(request_id, 2) == 1

    assert [setup.assignment.id, sibling.assignment.id] ==
             Repo.reload!(setup.model).metadata["source_assignment_ids"]

    conn =
      conn
      |> auth(setup)
      |> put_req_header("x-request-id", request_id)
      |> post("/backend-api/codex/responses", %{
        "model" => setup.model.exposed_model_id,
        "input" => "guarded reset probe model miss",
        "stream" => false
      })

    assert Enum.count(
             FakeUpstream.requests(probe_upstream),
             &(&1.path == "/api/codex/rate-limit-reset-credits/consume")
           ) == 1

    redemption = Repo.reload!(identity).metadata["saved_reset_redemption"]
    assert redemption["phase"] == "consumed_pending_probe"
    assert is_binary(get_in(redemption, ["probe", "token"]))

    assert %{"error" => %{"code" => "model_not_found"}} = json_response(conn, 404)

    assert Enum.count(
             FakeUpstream.requests(probe_upstream),
             &(&1.path == "/backend-api/codex/responses")
           ) == 1

    assert FakeUpstream.count(sibling_upstream) == 0

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    assert request.status == "failed"
    assert request.retry_count == 0
    assert get_in(request.request_metadata, ["quota_decision", "routing_state"]) == "reset_probe"

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.pool_upstream_assignment_id == setup.assignment.id
    assert attempt.status == "failed"

    assert get_in(redemption, ["result", "code"]) == "reset"
  end
end
