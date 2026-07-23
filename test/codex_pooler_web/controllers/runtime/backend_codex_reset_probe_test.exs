defmodule CodexPoolerWeb.Runtime.BackendCodexResetProbeTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias Ecto.Adapters.SQL.Sandbox

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

  test "HTTP reset probe failures retain the one-shot claim without sibling fallback", %{
    conn: conn
  } do
    scenarios = [
      {"quota-shaped 429", quota_exhausted_response(), 429, "upstream_rate_limited", "reblocked"},
      {"generic 429", FakeUpstream.generic_429(), 429, "upstream_rate_limited",
       "consumed_pending_probe"},
      {"5xx", FakeUpstream.generic_5xx(), 503, "upstream_status", "consumed_pending_probe"}
    ]

    for {label, response_mode, response_status, error_code, expected_phase} <- scenarios do
      fixture = reset_probe_fixture(response_mode)

      response =
        conn
        |> recycle()
        |> post_reset_probe(fixture, "#{label} reset probe")

      assert response.status == response_status, label

      assert_failure_accounting!(fixture, response_status, error_code)
      assert_probe_outcome!(fixture, expected_phase)
      assert_no_replacement_probe!(conn, fixture, label)
    end
  end

  test "HTTP reset probe connection close retains the one-shot claim", %{conn: conn} do
    fixture = reset_probe_fixture(FakeUpstream.close_before_headers())

    {response, logs} =
      with_log([level: :warning], fn ->
        post_reset_probe(conn, fixture, "connection close reset probe")
      end)

    assert_upstream_transport_warning!(
      logs,
      fixture.setup,
      "http_json",
      "closed",
      ["connection close reset probe"]
    )

    assert response.status == 502
    assert_failure_accounting!(fixture, 502, "upstream_network_error")
    assert_probe_outcome!(fixture, "consumed_pending_probe")
    assert_no_replacement_probe!(conn, fixture, "connection close")
  end

  test "HTTP reset probe receive timeout retains the one-shot claim", %{conn: conn} do
    release_ref = make_ref()

    fixture =
      reset_probe_fixture(
        FakeUpstream.timeout_before_headers(notify: self(), release_ref: release_ref)
      )

    setup_runtime_settings_override(%{
      OperationalSettings.current()
      | upstream_receive_timeout_ms: 100
    })

    parent = self()

    {response, logs} =
      with_log([level: :warning], fn ->
        task =
          Task.async(fn ->
            Sandbox.allow(Repo, parent, self())
            post_reset_probe(conn, fixture, "receive timeout reset probe")
          end)

        assert_receive {:fake_upstream_timeout_barrier, :before_headers, upstream_pid,
                        ^release_ref},
                       1_000

        response = Task.await(task, 1_000)
        send(upstream_pid, {:fake_upstream_release_timeout, release_ref})
        response
      end)

    assert_upstream_transport_warning!(
      logs,
      fixture.setup,
      "http_json",
      "timeout",
      ["receive timeout reset probe"]
    )

    assert response.status == 502
    assert_failure_accounting!(fixture, 502, "upstream_network_error")
    assert_probe_outcome!(fixture, "consumed_pending_probe")
    assert_no_replacement_probe!(conn, fixture, "receive timeout")
  end

  test "HTTP reset probe success released after its persisted deadline stays unconfirmed", %{
    conn: conn
  } do
    release_ref = make_ref()

    fixture =
      reset_probe_fixture(
        FakeUpstream.barrier_json_response(
          %{
            "id" => "resp_reset_probe_late",
            "object" => "response",
            "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
          },
          notify: self(),
          release_ref: release_ref
        )
      )

    parent = self()

    task =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())
        post_reset_probe(conn, fixture, "late reset probe")
      end)

    assert_receive {:fake_upstream_timeout_barrier, :before_headers, upstream_pid, ^release_ref},
                   1_000

    claimed_redemption = redemption(fixture.identity)
    claimed_probe = claimed_redemption["probe"]
    assert claimed_redemption["phase"] == "consumed_pending_probe"

    fixture.identity
    |> Ecto.Changeset.change(%{
      metadata:
        put_in(
          Repo.reload!(fixture.identity).metadata,
          ["saved_reset_redemption", "deadline_at"],
          DateTime.utc_now()
          |> DateTime.add(-1, :second)
          |> DateTime.truncate(:microsecond)
          |> DateTime.to_iso8601()
        )
    })
    |> Repo.update!()

    send(upstream_pid, {:fake_upstream_release_timeout, release_ref})
    response = Task.await(task, 1_000)

    assert %{"id" => "resp_reset_probe_late"} = json_response(response, 200)

    assert [request] = requests_for(fixture)
    assert request.status == "succeeded"
    assert request.response_status_code == 200

    assert [attempt] = attempts_for(request)
    assert attempt.status == "succeeded"

    persisted_redemption = redemption(fixture.identity)
    assert persisted_redemption["phase"] == "consumed_pending_probe"
    assert persisted_redemption["probe"] == claimed_probe
    assert_private_probe_metadata!(request, attempt, claimed_probe)
    assert_probe_outcome!(fixture, "consumed_pending_probe")
    assert_no_replacement_probe!(conn, fixture, "late success")
  end

  defp reset_probe_fixture(response_mode) do
    probe_upstream =
      start_upstream(
        {:path_json,
         %{
           "/api/codex/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}},
           "/api/codex/usage" =>
             {200,
              %{"plan_type" => "pro", "rate_limit_reset_credits" => %{"available_count" => 0}}},
           "/backend-api/codex/responses" => response_mode
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
      gateway_upstream(setup.pool, sibling_upstream, "upstream-token-reset-probe-matrix-sibling",
        compact?: false
      )

    assert {:ok, [_window]} =
             QuotaWindows.upsert_quota_windows(sibling.identity, [
               weekly_quota_window_attrs(%{
                 used_percent: Decimal.new("97"),
                 source: "codex_usage_api"
               })
             ])

    model = put_model_source_assignments!(setup.model, [setup.assignment, sibling.assignment])

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

    %{
      setup: %{setup | identity: identity, model: model},
      identity: identity,
      probe_upstream: probe_upstream,
      sibling_upstream: sibling_upstream,
      request_id: deterministic_rotation_seed(2, 1)
    }
  end

  defp post_reset_probe(conn, fixture, input) do
    conn
    |> put_req_header("x-request-id", fixture.request_id)
    |> auth(fixture.setup)
    |> post("/backend-api/codex/responses", %{
      "model" => fixture.setup.model.exposed_model_id,
      "input" => input,
      "stream" => false
    })
  end

  defp assert_failure_accounting!(fixture, response_status, error_code) do
    assert [request] = requests_for(fixture)
    assert request.status == "failed"
    assert request.response_status_code == response_status
    assert request.retry_count == 0
    assert request.last_error_code == error_code
    assert get_in(request.request_metadata, ["quota_decision", "routing_state"]) == "reset_probe"

    assert [attempt] = attempts_for(request)
    assert attempt.pool_upstream_assignment_id == fixture.setup.assignment.id
    assert attempt.status == "failed"
    assert attempt.network_error_code == error_code

    assert_private_probe_metadata!(request, attempt, redemption(fixture.identity)["probe"])
  end

  defp assert_probe_outcome!(fixture, expected_phase) do
    persisted_redemption = redemption(fixture.identity)
    assert persisted_redemption["phase"] == expected_phase
    assert persisted_redemption["result"]["code"] == "reset"
    assert is_binary(get_in(persisted_redemption, ["probe", "token"]))

    assert Enum.count(
             FakeUpstream.requests(fixture.probe_upstream),
             &(&1.path == "/api/codex/rate-limit-reset-credits/consume")
           ) == 1

    assert Enum.count(
             FakeUpstream.requests(fixture.probe_upstream),
             &(&1.path == "/backend-api/codex/responses")
           ) == 1

    assert FakeUpstream.count(fixture.sibling_upstream) == 0
  end

  defp assert_no_replacement_probe!(conn, fixture, label) do
    claimed_probe = redemption(fixture.identity)["probe"]
    initial_probe_paths = Enum.map(FakeUpstream.requests(fixture.probe_upstream), & &1.path)
    assert [original_request] = requests_for(fixture)

    fixture.setup.model
    |> put_model_source_assignments!([fixture.setup.assignment])

    FakeUpstream.set_mode(
      fixture.probe_upstream,
      FakeUpstream.json_response(%{
        "id" => "resp_replacement_probe_should_not_run",
        "object" => "response"
      })
    )

    response =
      conn
      |> recycle()
      |> put_req_header("x-request-id", replacement_request_id())
      |> auth(fixture.setup)
      |> post("/backend-api/codex/responses", %{
        "model" => fixture.setup.model.exposed_model_id,
        "input" => "replacement probe must not run",
        "stream" => false
      })

    assert Enum.map(FakeUpstream.requests(fixture.probe_upstream), & &1.path) ==
             initial_probe_paths

    assert response.status == 503, label

    assert [replacement_request] =
             fixture
             |> requests_for()
             |> Enum.reject(&(&1.id == original_request.id))

    assert original_request.status in ["failed", "succeeded"]
    assert replacement_request.status == "rejected"
    assert replacement_request.response_status_code == 503

    assert replacement_request.last_error_code in [
             "quota_evidence_unavailable",
             "quota_exhausted"
           ]

    assert attempts_for(replacement_request) == []
    assert redemption(fixture.identity)["probe"] == claimed_probe
    assert FakeUpstream.count(fixture.sibling_upstream) == 0
  end

  defp replacement_request_id do
    Enum.find_value(1..500, fn index ->
      request_id = "reset-probe-replacement-#{index}"
      if :erlang.phash2(request_id, 2) == 1, do: request_id
    end)
  end

  defp assert_private_probe_metadata!(request, attempt, probe) do
    token = probe["token"]
    metadata = inspect({request.request_metadata, attempt.response_metadata})

    refute metadata =~ token
    refute Map.has_key?(request.request_metadata["quota_decision"], "reset_probe")
    refute Map.has_key?(request.request_metadata["quota_decision"], "probe")
  end

  defp quota_exhausted_response do
    reset_at =
      DateTime.utc_now()
      |> DateTime.add(3, :day)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    FakeUpstream.json_response_with_headers(
      %{
        "error" => %{
          "code" => "rate_limit_exceeded",
          "message" => "synthetic account quota exhausted"
        }
      },
      [
        {"x-codex-secondary-used-percent", "100"},
        {"x-codex-secondary-window-minutes", "10080"},
        {"x-codex-secondary-reset-at", reset_at}
      ],
      429
    )
  end

  defp requests_for(fixture) do
    Repo.all(from(r in Request, where: r.pool_id == ^fixture.setup.pool.id))
  end

  defp attempts_for(request) do
    Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
  end

  defp redemption(identity) do
    Repo.reload!(identity).metadata["saved_reset_redemption"]
  end

  defp setup_runtime_settings_override(%OperationalSettings{} = settings) do
    previous = Application.get_env(:codex_pooler, OperationalSettings, [])

    Application.put_env(
      :codex_pooler,
      OperationalSettings,
      previous
      |> Keyword.put(:settings, settings)
      |> Keyword.put(:use_instance_settings?, false)
    )

    on_exit(fn -> Application.put_env(:codex_pooler, OperationalSettings, previous) end)
  end
end
