defmodule CodexPoolerWeb.Runtime.BackendCodexResetProbeStreamTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  defmodule ClosedChunkAdapter do
    def chunk(_payload, _chunk), do: {:error, :closed}
  end

  test "SSE stream completion confirms the guarded reset probe upstream", %{conn: conn} do
    fixture = reset_probe_fixture(completed_stream("resp_reset_probe_stream"))

    conn = post_reset_probe(conn, fixture.setup)

    assert conn.status == 200
    assert conn.resp_body =~ "resp_reset_probe_stream"

    assert_reset_probe_outcome!(fixture, "confirmed_by_upstream", "succeeded", nil)
  end

  test "explicit account quota rejection reblocks the guarded SSE reset probe", %{conn: conn} do
    fixture = reset_probe_fixture(quota_exhausted_response())

    conn = post_reset_probe(conn, fixture.setup)

    assert conn.status == 429

    assert_reset_probe_outcome!(
      fixture,
      "reblocked",
      "failed",
      "upstream_rate_limited"
    )
  end

  for {label, mode, expected_status, expected_error} <- [
        {"generic 429", FakeUpstream.generic_429(), 429, "upstream_rate_limited"},
        {"generic 5xx", FakeUpstream.generic_5xx(), 503, "upstream_status"}
      ] do
    test "#{label} does not confirm or reblock the guarded SSE reset probe", %{conn: conn} do
      fixture = reset_probe_fixture(unquote(Macro.escape(mode)))

      conn = post_reset_probe(conn, fixture.setup)

      assert conn.status == unquote(expected_status)

      assert_reset_probe_outcome!(
        fixture,
        "consumed_pending_probe",
        "failed",
        unquote(expected_error)
      )
    end
  end

  test "close before SSE headers leaves the guarded reset probe claimed", %{conn: conn} do
    fixture = reset_probe_fixture(FakeUpstream.close_before_headers())

    {conn, logs} =
      with_log([level: :warning], fn -> post_reset_probe(conn, fixture.setup) end)

    assert_upstream_transport_warning!(
      logs,
      fixture.setup,
      "http_sse",
      "closed",
      ["reset probe stream fixture"]
    )

    assert conn.status == 502

    assert_reset_probe_outcome!(
      fixture,
      "consumed_pending_probe",
      "failed",
      "upstream_network_error"
    )
  end

  test "timeout before SSE headers leaves the guarded reset probe claimed", %{conn: conn} do
    setup_runtime_timeout(100)
    release_ref = make_ref()

    fixture =
      reset_probe_fixture(
        FakeUpstream.timeout_before_headers(notify: self(), release_ref: release_ref)
      )

    {conn, logs} =
      with_log([level: :warning], fn ->
        conn = post_reset_probe(conn, fixture.setup)

        assert_receive {:fake_upstream_timeout_barrier, :before_headers, upstream_pid,
                        ^release_ref},
                       1_000

        send(upstream_pid, {:fake_upstream_release_timeout, release_ref})
        conn
      end)

    assert_upstream_transport_warning!(
      logs,
      fixture.setup,
      "http_sse",
      "timeout",
      ["reset probe stream fixture"]
    )

    assert conn.status == 502

    assert_reset_probe_outcome!(
      fixture,
      "consumed_pending_probe",
      "failed",
      "upstream_network_error"
    )
  end

  for {label, stage, mode_kind, expected_error} <- [
        {"silent stream after headers", :after_sse_headers, :after_headers,
         "stream_idle_timeout"},
        {"partial stream", :mid_stream, :mid_stream, "stream_idle_timeout"}
      ] do
    test "#{label} timeout leaves the guarded SSE reset probe claimed", %{conn: conn} do
      setup_runtime_timeout(100)
      release_ref = make_ref()

      mode = timeout_mode(unquote(mode_kind), self(), release_ref)
      fixture = reset_probe_fixture(mode)

      conn = post_reset_probe(conn, fixture.setup)

      assert_receive {:fake_upstream_timeout_barrier, unquote(stage), upstream_pid, ^release_ref},
                     1_000

      send(upstream_pid, {:fake_upstream_release_timeout, release_ref})
      assert conn.status == 200

      assert_reset_probe_outcome!(
        fixture,
        "consumed_pending_probe",
        "failed",
        unquote(expected_error)
      )
    end
  end

  test "abrupt upstream close mid-stream leaves the guarded SSE reset probe claimed", %{
    conn: conn
  } do
    fixture =
      reset_probe_fixture(
        FakeUpstream.abrupt_close_mid_stream([
          {"response.output_text.delta",
           %{"type" => "response.output_text.delta", "delta" => "partial"}}
        ])
      )

    conn = post_reset_probe(conn, fixture.setup)

    assert conn.status == 200

    assert_reset_probe_outcome!(
      fixture,
      "consumed_pending_probe",
      "failed",
      "upstream_stream_error"
    )
  end

  test "downstream cancellation leaves the guarded SSE reset probe claimed" do
    fixture =
      reset_probe_fixture(
        FakeUpstream.sse_stream([
          {"response.output_text.delta",
           %{"type" => "response.output_text.delta", "delta" => "visible"}}
        ])
      )

    {:ok, auth} = Access.authenticate_authorization_header(fixture.setup.authorization)

    payload = reset_probe_payload(fixture.setup)

    assert {:ok, %{stream: stream}} =
             Gateway.execute(
               auth,
               "/backend-api/codex/responses",
               payload,
               RequestOptions.build(
                 %{upstream_endpoint: "/backend-api/codex/responses"},
                 "/backend-api/codex/responses",
                 payload
               )
             )

    closed_conn = %{
      Phoenix.ConnTest.build_conn()
      | adapter: {ClosedChunkAdapter, nil},
        state: :chunked
    }

    assert {:ok, _conn} = stream.(closed_conn)

    assert_reset_probe_outcome!(
      fixture,
      "consumed_pending_probe",
      "failed",
      "client_disconnected"
    )
  end

  test "SSE terminal completion released after the deadline cannot confirm the reset probe", %{
    conn: conn
  } do
    release_ref = make_ref()

    fixture =
      reset_probe_fixture(
        FakeUpstream.delayed_terminal_sse_stream(
          [
            {"response.output_text.delta",
             %{"type" => "response.output_text.delta", "delta" => "partial"}}
          ],
          completed_event("resp_reset_probe_late_terminal"),
          notify: self(),
          release_ref: release_ref
        )
      )

    task = Task.async(fn -> post_reset_probe(conn, fixture.setup) end)

    assert_receive {:fake_upstream_timeout_barrier, :before_terminal, upstream_pid, ^release_ref},
                   1_000

    expire_reset_probe!(fixture.identity)
    send(upstream_pid, {:fake_upstream_release_timeout, release_ref})

    conn = Task.await(task, 2_000)
    assert conn.status == 200
    assert conn.resp_body =~ "resp_reset_probe_late_terminal"

    assert_reset_probe_outcome!(
      fixture,
      "consumed_pending_probe",
      "succeeded",
      nil
    )
  end

  defp reset_probe_fixture(dispatch_mode) do
    usage_upstream =
      start_upstream(
        {:path_json,
         %{
           "/api/codex/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}},
           "/api/codex/usage" =>
             {200,
              %{"plan_type" => "pro", "rate_limit_reset_credits" => %{"available_count" => 0}}}
         }}
      )

    dispatch_upstream = start_upstream(dispatch_mode)
    sibling_upstream = start_upstream(completed_stream("resp_reset_probe_sibling_should_not_run"))
    setup = gateway_setup(dispatch_upstream, quota?: false)

    sibling =
      gateway_upstream(
        setup.pool,
        sibling_upstream,
        "upstream-token-reset-probe-stream-sibling",
        compact?: false
      )

    prime_weekly_exhausted_quota!(sibling.identity)
    model = put_model_source_assignments!(setup.model, [setup.assignment, sibling.assignment])

    identity =
      setup.identity
      |> merge_saved_reset_identity_metadata!(usage_upstream)
      |> enable_saved_reset_auto_redeem!()

    prime_weekly_exhausted_quota!(identity)

    %{
      setup: %{setup | identity: identity, model: model},
      identity: identity,
      usage_upstream: usage_upstream,
      dispatch_upstream: dispatch_upstream,
      sibling_upstream: sibling_upstream
    }
  end

  defp post_reset_probe(conn, setup) do
    conn
    |> auth(setup)
    |> post("/backend-api/codex/responses", reset_probe_payload(setup))
  end

  defp reset_probe_payload(setup) do
    %{
      "model" => setup.model.exposed_model_id,
      "stream" => true,
      "input" => "reset probe stream fixture"
    }
  end

  defp assert_reset_probe_outcome!(fixture, phase, attempt_status, error_code) do
    assert_single_reset_consume!(fixture.usage_upstream)
    assert [response_request] = FakeUpstream.requests(fixture.dispatch_upstream)
    assert response_request.path == "/backend-api/codex/responses"
    assert FakeUpstream.count(fixture.sibling_upstream) == 0

    assert [request] =
             Repo.all(from(r in Request, where: r.pool_id == ^fixture.setup.pool.id))

    assert request.transport == "http_sse"
    assert request.status == attempt_status
    assert request.retry_count == 0
    assert get_in(request.request_metadata, ["quota_decision", "routing_state"]) == "reset_probe"
    refute Map.has_key?(request.request_metadata["quota_decision"], "reset_probe")

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.pool_upstream_assignment_id == fixture.setup.assignment.id
    assert attempt.status == attempt_status
    assert request.last_error_code == error_code
    assert attempt.network_error_code == error_code

    redemption = Repo.reload!(fixture.identity).metadata["saved_reset_redemption"]
    assert redemption["phase"] == phase
    assert get_in(redemption, ["result", "code"]) == "reset"
    assert is_binary(get_in(redemption, ["probe", "token"]))
    assert get_in(redemption, ["probe", "version"]) == 2

    metadata_text = inspect({request.request_metadata, attempt.response_metadata})
    refute metadata_text =~ get_in(redemption, ["probe", "token"])
    refute metadata_text =~ "upstream-token-reset-probe-stream-sibling"
  end

  defp assert_single_reset_consume!(usage_upstream) do
    requests = FakeUpstream.requests(usage_upstream)

    assert Enum.count(
             requests,
             &(&1.method == "POST" and
                 &1.path == "/api/codex/rate-limit-reset-credits/consume")
           ) == 1

    assert Enum.all?(
             Enum.reject(
               requests,
               &(&1.method == "POST" and
                   &1.path == "/api/codex/rate-limit-reset-credits/consume")
             ),
             &(&1.method == "GET")
           )
  end

  defp completed_stream(response_id) do
    FakeUpstream.sse_stream([completed_event(response_id)])
  end

  defp completed_event(response_id) do
    {"response.completed",
     %{
       "type" => "response.completed",
       "response" => %{
         "id" => response_id,
         "status" => "completed",
         "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
       }
     }}
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

  defp timeout_mode(:after_headers, notify, release_ref) do
    FakeUpstream.timeout_after_sse_headers(notify: notify, release_ref: release_ref)
  end

  defp timeout_mode(:mid_stream, notify, release_ref) do
    FakeUpstream.timeout_mid_stream(
      ~s(event: response.output_text.delta\ndata: {"delta":"partial"}\n\n),
      notify: notify,
      release_ref: release_ref
    )
  end

  defp setup_runtime_timeout(timeout_ms) do
    previous = Application.get_env(:codex_pooler, OperationalSettings, [])

    Application.put_env(
      :codex_pooler,
      OperationalSettings,
      previous
      |> Keyword.put(:settings, %OperationalSettings{upstream_receive_timeout_ms: timeout_ms})
      |> Keyword.put(:use_instance_settings?, false)
    )

    on_exit(fn -> Application.put_env(:codex_pooler, OperationalSettings, previous) end)
  end

  defp expire_reset_probe!(%UpstreamIdentity{} = identity) do
    metadata = identity |> Repo.reload!() |> Map.fetch!(:metadata)

    redemption =
      metadata
      |> Map.fetch!("saved_reset_redemption")
      |> Map.put(
        "deadline_at",
        DateTime.utc_now()
        |> DateTime.add(-1, :second)
        |> DateTime.truncate(:microsecond)
        |> DateTime.to_iso8601()
      )

    identity
    |> UpstreamIdentity.changeset(%{
      metadata: Map.put(metadata, "saved_reset_redemption", redemption),
      updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })
    |> Repo.update!()
  end

  defp merge_saved_reset_identity_metadata!(%UpstreamIdentity{} = identity, upstream) do
    identity
    |> UpstreamIdentity.changeset(%{
      metadata: Map.merge(identity.metadata || %{}, saved_reset_metadata(upstream, 1)),
      updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })
    |> Repo.update!()
  end

  defp enable_saved_reset_auto_redeem!(%UpstreamIdentity{} = identity) do
    identity
    |> UpstreamIdentity.changeset(%{
      saved_reset_auto_redeem_enabled: true,
      saved_reset_auto_redeem_min_blocked_minutes: 60,
      saved_reset_auto_redeem_keep_credits: 0,
      updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })
    |> Repo.update!()
  end
end
