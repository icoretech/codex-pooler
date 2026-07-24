defmodule CodexPoolerWeb.Runtime.BackendCodexResetProbeWebsocketTest do
  use CodexPoolerWeb.ConnCase, async: false

  import Ecto.Query
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway, as: RuntimeGateway
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias CodexPoolerWeb.CodexResponsesSocket
  alias Ecto.Adapters.SQL.Sandbox

  @websocket_frame_timeout 1_000

  test "successful websocket response confirms the guarded reset probe" do
    fixture = reset_probe_fixture(completed_stream("resp_ws_reset_probe_confirmed"))

    assert :ok = execute_reset_probe(fixture)
    assert_receive_completed_frame("resp_ws_reset_probe_confirmed")

    assert_reset_probe_outcome!(fixture, "confirmed_by_upstream", "succeeded", nil, 1)
  end

  test "explicit account quota terminal reblocks the guarded websocket reset probe" do
    fixture = reset_probe_fixture(quota_terminal_failure())

    assert :ok = execute_reset_probe(fixture)

    assert_receive {:websocket_frame, terminal_frame}, @websocket_frame_timeout

    assert %{
             "type" => "response.failed",
             "response" => %{"error" => %{"code" => "usage_limit_exceeded"}}
           } = Jason.decode!(terminal_frame)

    assert_reset_probe_outcome!(
      fixture,
      "reblocked",
      "failed",
      "usage_limit_exceeded",
      1
    )
  end

  test "explicit account quota upgrade rejection reblocks the guarded websocket reset probe" do
    fixture = reset_probe_fixture(quota_upgrade_rejection())

    assert {:error, %{code: "upstream_request_failed", status: 502}} =
             execute_reset_probe(fixture)

    assert_reset_probe_outcome!(
      fixture,
      "reblocked",
      "failed",
      "upstream_stream_error",
      0
    )
  end

  for {label, mode} <- [
        {"generic upgrade 429",
         FakeUpstream.websocket_upgrade_error(
           %{"error" => %{"code" => "rate_limit_exceeded"}},
           status: 429
         )},
        {"generic upgrade 5xx",
         FakeUpstream.websocket_upgrade_error(
           %{"error" => %{"code" => "server_error"}},
           status: 503
         )}
      ] do
    test "#{label} leaves the guarded websocket reset probe claimed" do
      fixture = reset_probe_fixture(unquote(Macro.escape(mode)))

      assert {:error, %{code: "upstream_request_failed", status: 502}} =
               execute_reset_probe(fixture)

      assert_reset_probe_outcome!(
        fixture,
        "consumed_pending_probe",
        "failed",
        "upstream_stream_error",
        0
      )
    end
  end

  test "websocket upgrade timeout leaves the guarded reset probe claimed" do
    release_ref = make_ref()

    fixture =
      reset_probe_fixture(
        FakeUpstream.websocket_upgrade_timeout(notify: self(), release_ref: release_ref)
      )

    parent = self()

    task =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())
        execute_reset_probe(fixture, [connect_timeout_ms: 25], parent)
      end)

    assert_receive {:fake_upstream_timeout_barrier, :websocket_upgrade, upstream_pid,
                    ^release_ref},
                   1_000

    assert {:error, %{code: "upstream_request_failed", status: 502}} =
             Task.await(task, 1_000)

    upstream_ref = Process.monitor(upstream_pid)
    send(upstream_pid, {:fake_upstream_release_timeout, release_ref})

    assert_reset_probe_outcome!(
      fixture,
      "consumed_pending_probe",
      "failed",
      "upstream_stream_error",
      0
    )

    assert_receive {:DOWN, ^upstream_ref, :process, ^upstream_pid, _reason}, 1_000
  end

  test "upstream websocket close leaves the guarded reset probe claimed" do
    fixture = reset_probe_fixture(FakeUpstream.websocket_close())

    assert {:error, %{code: "upstream_request_failed", status: 502}} =
             execute_reset_probe(fixture)

    assert_reset_probe_outcome!(
      fixture,
      "consumed_pending_probe",
      "failed",
      "upstream_stream_error",
      1
    )
  end

  test "terminal websocket failure leaves the guarded reset probe claimed" do
    fixture = reset_probe_fixture(FakeUpstream.websocket_terminal_failure())

    assert :ok = execute_reset_probe(fixture)

    assert_receive {:websocket_frame, terminal_frame}, @websocket_frame_timeout
    assert %{"type" => "response.failed"} = Jason.decode!(terminal_frame)

    assert_reset_probe_outcome!(
      fixture,
      "consumed_pending_probe",
      "failed",
      "server_error",
      1
    )
  end

  for auth_code <- ["invalid_api_key", "invalid_authentication"] do
    @auth_code auth_code
    test "websocket terminal auth #{auth_code} does not refresh or redispatch a bound reset probe" do
      auth_code = @auth_code
      refresh_token = "refresh-token-bound-reset-probe-#{auth_code}-do-not-leak"

      fixture =
        reset_probe_fixture(
          {:sequence,
           [
             websocket_terminal_failure(auth_code),
             FakeUpstream.json_response(%{"access_token" => "replacement-token-should-not-run"}),
             FakeUpstream.json_response(%{"id" => "replacement-response-should-not-run"})
           ]}
        )

      assert {:ok, _secret} =
               Upstreams.store_encrypted_secret(fixture.identity, %{
                 secret_kind: "refresh_token",
                 plaintext: refresh_token
               })

      assert :ok = execute_reset_probe(fixture)
      assert_receive_failed_frame(auth_code)

      assert_reset_probe_outcome!(
        fixture,
        "consumed_pending_probe",
        "failed",
        auth_code,
        1
      )

      assert_bound_probe_metadata_omits!(fixture, [
        refresh_token,
        "replacement-token-should-not-run",
        "replacement-response-should-not-run"
      ])
    end
  end

  test "websocket connection limit does not retry or replace a bound reset probe dispatch" do
    fixture =
      reset_probe_fixture(
        {:sequence,
         [
           websocket_terminal_failure("websocket_connection_limit_reached"),
           FakeUpstream.json_response(%{"id" => "connection-limit-retry-should-not-run"})
         ]}
      )

    assert :ok = execute_reset_probe(fixture)
    assert_receive_failed_frame("websocket_connection_limit_reached")

    assert_reset_probe_outcome!(
      fixture,
      "consumed_pending_probe",
      "failed",
      "websocket_connection_limit_reached",
      1
    )

    assert_bound_probe_metadata_omits!(fixture, ["connection-limit-retry-should-not-run"])
  end

  test "upstream model unavailable does not dispatch a sibling for a bound reset probe" do
    fixture =
      reset_probe_fixture(
        {:sequence,
         [
           websocket_terminal_failure("model_not_found"),
           FakeUpstream.json_response(%{"id" => "model-replacement-should-not-run"})
         ]}
      )

    assert :ok = execute_reset_probe(fixture)
    assert_receive_failed_frame("model_not_found")

    assert_reset_probe_outcome!(
      fixture,
      "consumed_pending_probe",
      "failed",
      "upstream_model_unavailable",
      1
    )

    assert_bound_probe_metadata_omits!(fixture, ["model-replacement-should-not-run"])
  end

  test "client websocket disconnect leaves the guarded reset probe claimed" do
    release_ref = make_ref()

    fixture =
      reset_probe_fixture(
        FakeUpstream.barrier_sse_stream(
          [completed_event("resp_ws_reset_probe_cancelled")],
          barrier_after: 0,
          notify: self(),
          release_ref: release_ref
        )
      )

    {:ok, auth} = Access.authenticate_authorization_header(fixture.setup.authorization)

    {:ok, state} =
      CodexResponsesSocket.init(%{
        auth: auth,
        opts: %{
          request_id: "ws-reset-probe-cancelled",
          accepted_turn_state: "ws-reset-probe-cancelled",
          client_ip: "127.0.0.1"
        }
      })

    assert {:ok, state} =
             CodexResponsesSocket.handle_in(
               {reset_probe_payload(fixture.setup), [opcode: :text]},
               state
             )

    assert_receive {:fake_upstream_chunk_barrier, 0, upstream_pid, ^release_ref}, 1_000
    assert [response_task_pid] = MapSet.to_list(state.tasks)
    response_task_monitor = Process.monitor(response_task_pid)

    Process.exit(response_task_pid, :kill)

    assert_receive {:DOWN, ^response_task_monitor, :process, ^response_task_pid, :killed}, 1_000
    assert :ok = CodexResponsesSocket.terminate(:closed, state)
    send(upstream_pid, {:fake_upstream_release_chunk, release_ref})

    assert_reset_probe_outcome!(
      fixture,
      "consumed_pending_probe",
      "failed",
      "client_disconnected",
      1
    )
  end

  test "websocket completion released after the deadline cannot confirm the reset probe" do
    release_ref = make_ref()

    fixture =
      reset_probe_fixture(
        FakeUpstream.delayed_terminal_sse_stream(
          [],
          completed_event("resp_ws_reset_probe_late_terminal"),
          notify: self(),
          release_ref: release_ref
        )
      )

    parent = self()

    task =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())
        execute_reset_probe(fixture, [], parent)
      end)

    assert_receive {:fake_upstream_timeout_barrier, :before_terminal, upstream_pid, ^release_ref},
                   1_000

    expire_reset_probe!(fixture.identity)
    send(upstream_pid, {:fake_upstream_release_timeout, release_ref})

    assert :ok = Task.await(task, 2_000)
    assert_receive_completed_frame("resp_ws_reset_probe_late_terminal")

    assert_reset_probe_outcome!(fixture, "consumed_pending_probe", "succeeded", nil, 1)
  end

  defp reset_probe_fixture(dispatch_mode) do
    usage_upstream = reset_probe_usage_upstream()
    dispatch_upstream = start_upstream(dispatch_mode)

    sibling_upstream =
      start_upstream(completed_stream("resp_ws_reset_probe_sibling_should_not_run"))

    setup = gateway_setup(dispatch_upstream, quota?: false)

    sibling =
      gateway_upstream(
        setup.pool,
        sibling_upstream,
        "upstream-token-reset-probe-websocket-sibling",
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

  defp execute_reset_probe(fixture, options \\ [], recipient \\ self()) do
    {:ok, auth} = Access.authenticate_authorization_header(fixture.setup.authorization)

    request_options =
      %{request_id: "ws-reset-probe-#{System.unique_integer([:positive])}"}
      |> Map.merge(Map.new(options))
      |> RequestOptions.for_websocket()

    RuntimeGateway.execute_websocket_response(
      auth,
      reset_probe_payload(fixture.setup),
      request_options,
      fn frame -> send(recipient, {:websocket_frame, frame}) end
    )
  end

  defp reset_probe_payload(setup) do
    Jason.encode!(%{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "input" => "guarded reset probe over websocket",
      "stream" => true,
      "generate" => true
    })
  end

  defp assert_receive_completed_frame(response_id) do
    assert_receive {:websocket_frame, completed_frame}, @websocket_frame_timeout

    assert %{
             "type" => "response.completed",
             "response" => %{"id" => ^response_id}
           } = Jason.decode!(completed_frame)
  end

  defp assert_receive_failed_frame(error_code) do
    assert_receive {:websocket_frame, failed_frame}, @websocket_frame_timeout

    assert %{
             "type" => failure_type,
             "response" => %{"error" => %{"code" => ^error_code}}
           } = Jason.decode!(failed_frame)

    assert failure_type in ["error", "response.failed"]
    refute_received {:websocket_frame, _unexpected}
  end

  defp assert_reset_probe_outcome!(
         fixture,
         phase,
         request_status,
         error_code,
         dispatch_count
       ) do
    assert_single_reset_consume!(fixture.usage_upstream)
    assert FakeUpstream.count(fixture.dispatch_upstream) == dispatch_count
    assert FakeUpstream.count(fixture.sibling_upstream) == 0

    if dispatch_count == 1 do
      assert [dispatch_request] = FakeUpstream.requests(fixture.dispatch_upstream)
      assert dispatch_request.method == "WEBSOCKET"
      assert dispatch_request.json["type"] == "response.create"
    end

    assert [request] = Repo.all(from(r in Request, where: r.pool_id == ^fixture.setup.pool.id))
    assert request.transport == "websocket"
    assert request.status == request_status
    assert request.retry_count == 0
    assert request.last_error_code == error_code
    assert get_in(request.request_metadata, ["quota_decision", "routing_state"]) == "reset_probe"
    refute Map.has_key?(request.request_metadata["quota_decision"], "reset_probe")

    assert [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    assert attempt.pool_upstream_assignment_id == fixture.setup.assignment.id
    assert attempt.status == request_status
    assert attempt.network_error_code == error_code

    redemption = Repo.reload!(fixture.identity).metadata["saved_reset_redemption"]
    assert redemption["phase"] == phase
    assert get_in(redemption, ["result", "code"]) == "reset"
    assert is_binary(get_in(redemption, ["probe", "token"]))
    assert get_in(redemption, ["probe", "version"]) == 2

    metadata_text = inspect({request.request_metadata, attempt.response_metadata})
    refute metadata_text =~ get_in(redemption, ["probe", "token"])
    refute metadata_text =~ "upstream-token-reset-probe-websocket-sibling"
  end

  defp assert_bound_probe_metadata_omits!(fixture, forbidden_values) do
    [request] = Repo.all(from(r in Request, where: r.pool_id == ^fixture.setup.pool.id))
    [attempt] = Repo.all(from(a in Attempt, where: a.request_id == ^request.id))
    metadata_text = inspect({request.request_metadata, attempt.response_metadata})

    Enum.each(forbidden_values, fn forbidden_value ->
      refute metadata_text =~ forbidden_value
    end)
  end

  defp websocket_terminal_failure(error_code) do
    FakeUpstream.sse_stream(
      [
        {"response.failed",
         %{
           "type" => "response.failed",
           "response" => %{
             "id" => "resp_ws_bound_probe_terminal_failure",
             "status" => "failed",
             "error" => %{"code" => error_code}
           }
         }}
      ],
      done: false
    )
  end

  defp reset_probe_usage_upstream do
    start_upstream(
      {:path_json,
       %{
         "/api/codex/rate-limit-reset-credits/consume" => {200, %{"code" => "reset"}},
         "/api/codex/usage" =>
           {200, %{"plan_type" => "pro", "rate_limit_reset_credits" => %{"available_count" => 0}}}
       }}
    )
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

  defp completed_stream(response_id), do: FakeUpstream.sse_stream([completed_event(response_id)])

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

  defp quota_terminal_failure do
    FakeUpstream.sse_stream(
      [
        {"response.failed",
         %{
           "type" => "response.failed",
           "headers" => quota_headers(),
           "response" => %{
             "id" => "resp_ws_reset_probe_quota_terminal",
             "status" => "failed",
             "error" => %{"code" => "usage_limit_exceeded"}
           }
         }}
      ],
      done: false
    )
  end

  defp quota_upgrade_rejection do
    FakeUpstream.websocket_upgrade_error(
      %{"error" => %{"code" => "rate_limit_exceeded"}},
      status: 429,
      headers: Map.to_list(quota_headers())
    )
  end

  defp quota_headers do
    reset_at =
      DateTime.utc_now()
      |> DateTime.add(3, :day)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    %{
      "x-codex-rate-limit-reached-type" => "workspace_owner_usage_limit_reached",
      "x-codex-secondary-used-percent" => "100",
      "x-codex-secondary-window-minutes" => "10080",
      "x-codex-secondary-reset-at" => reset_at
    }
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
