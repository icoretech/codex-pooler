defmodule CodexPoolerWeb.Runtime.BackendCodexWebsocketSupport do
  @moduledoc false

  # Helpers shared by more than one family under
  # test/codex_pooler_web/controllers/runtime/backend_codex_websocket/.

  import Ecto.Query
  import ExUnit.Assertions
  import ExUnit.CaptureLog
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Accounting.{Attempt, Request, RequestLogs}
  alias CodexPooler.Accounts.Scope
  alias CodexPooler.Audit.AuditEvent
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway, as: RuntimeGateway
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{CodexSession, CodexTurn}
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Websocket.Adapter
  alias CodexPooler.Pools
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Quota.Windows, as: QuotaWindows
  alias CodexPoolerWeb.CodexResponsesSocket

  # Detection budget for a server-side connection teardown the test only
  # observes, never a scenario timeout.
  @connection_shutdown_timeout_ms 15_000

  def strict_native_request(connection_ordinal, respond) do
    FakeUpstream.expect_request(
      method: "WEBSOCKET",
      path: "/backend-api/codex/responses",
      websocket_connection_ordinal: connection_ordinal,
      json: [valid: true, equals: %{"type" => "response.create"}],
      respond: respond
    )
  end

  def strict_native_response(response_id, connection_ordinal, input_tokens, output_tokens) do
    FakeUpstream.expect_request(
      method: "WEBSOCKET",
      path: "/backend-api/codex/responses",
      websocket_connection_ordinal: connection_ordinal,
      json: [valid: true, equals: %{"type" => "response.create"}],
      respond:
        FakeUpstream.websocket_text_frames([
          CodexPooler.JSON.encode!(%{
            "id" => response_id,
            "object" => "response",
            "usage" => %{
              "input_tokens" => input_tokens,
              "output_tokens" => output_tokens,
              "total_tokens" => input_tokens + output_tokens
            }
          })
        ])
    )
  end

  def with_info_log(fun) do
    previous_logger_level = Logger.level()
    Logger.configure(level: :info)

    try do
      with_log([level: :info], fun)
    after
      Logger.configure(level: previous_logger_level)
    end
  end

  def capture_native_turn_warning(fun) when is_function(fun, 0) do
    ExUnit.CaptureLog.with_log([level: :warning], fun)
  end

  def assert_native_turn_warnings(logs, expected_count) do
    assert length(Regex.scan(~r/websocket native turn failed/, logs)) == expected_count
  end

  def websocket_auth_refresh_payload(setup, marker) do
    CodexPooler.JSON.encode!(%{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "input" => native_text_input("websocket auth refresh fixture #{marker}"),
      "stream" => true,
      "generate" => true
    })
  end

  def synthetic_access_token(residency) do
    header = Base.url_encode64(CodexPooler.JSON.encode!(%{"alg" => "none"}), padding: false)

    payload =
      Base.url_encode64(
        CodexPooler.JSON.encode!(%{
          "https://api.openai.com/auth" => %{
            "chatgpt_compute_residency" => residency
          }
        }),
        padding: false
      )

    "#{header}.#{payload}.signature"
  end

  def header_values(headers, target_name) do
    for {name, value} <- headers, String.downcase(name) == target_name, do: value
  end

  def assert_websocket_values_not_persisted!(setup, forbidden_values, logs) do
    requests = Repo.all(from(r in Request, where: r.pool_id == ^setup.pool.id))
    request_ids = Enum.map(requests, & &1.id)
    attempts = Repo.all(from(a in Attempt, where: a.request_id in ^request_ids))
    sessions = Repo.all(from(s in CodexSession, where: s.pool_id == ^setup.pool.id))
    session_ids = Enum.map(sessions, & &1.id)
    turns = Repo.all(from(t in CodexTurn, where: t.codex_session_id in ^session_ids))
    audit_events = Repo.all(from(e in AuditEvent))
    request_logs = RequestLogs.list(setup.pool.id, limit: 10)

    durable_text =
      inspect({requests, attempts, sessions, turns, audit_events, request_logs.items})

    for value <- forbidden_values do
      refute durable_text =~ value
      refute logs =~ value
    end
  end

  def pin_session_to_assignment!(session, assignment) do
    session
    |> Ecto.Changeset.change(%{pool_upstream_assignment_id: assignment.id})
    |> Repo.update!()
  end

  def codex_rate_limits_payload(used_percent, reset_at) do
    %{
      "type" => "codex.rate_limits",
      "rate_limits" => %{
        "primary" => %{
          "used_percent" => used_percent,
          "window_minutes" => 300,
          "reset_at" => DateTime.to_unix(reset_at)
        }
      }
    }
  end

  def wait_for_rate_limit_event_window(identity, window_kind, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 1_000

    identity
    |> QuotaWindows.list_evidence()
    |> Enum.find(&(&1.source == "codex_rate_limit_event" and &1.window_kind == window_kind))
    |> case do
      nil ->
        if System.monotonic_time(:millisecond) < deadline do
          receive do
          after
            10 -> wait_for_rate_limit_event_window(identity, window_kind, deadline)
          end
        else
          flunk("expected codex.rate_limits quota window for #{window_kind}")
        end

      window ->
        window
    end
  end

  def wait_for_rate_limit_event_tasks(deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 1_000

    case Task.Supervisor.children(CodexPooler.RateLimitEventSupervisor) do
      [] ->
        :ok

      _children ->
        if System.monotonic_time(:millisecond) < deadline do
          receive do
          after
            10 -> wait_for_rate_limit_event_tasks(deadline)
          end
        else
          flunk("expected codex.rate_limits persistence tasks to finish")
        end
    end
  end

  def put_setup_model_source_metadata!(setup, source_metadata) when is_map(source_metadata) do
    source_metadata = Map.put_new(source_metadata, "slug", setup.model.exposed_model_id)

    metadata =
      setup.model.metadata
      |> Map.put("source_assignment_models", %{setup.assignment.id => source_metadata})

    model =
      setup.model
      |> Ecto.Changeset.change(%{metadata: metadata})
      |> Repo.update!()

    %{setup | model: model}
  end

  def model_serving_scope do
    %{user: owner} = CodexPooler.AccountsFixtures.bootstrap_owner_fixture()
    Scope.for_user(owner, ["instance_owner"])
  end

  def set_model_serving_mode!(scope, setup, mode, expected_revision \\ nil) do
    expected_revision =
      expected_revision ||
        case Pools.model_serving_modes_snapshot(scope, setup.pool) do
          {:ok, snapshot} -> snapshot.revision
          {:error, error} -> flunk("failed to read model serving modes: #{inspect(error)}")
        end

    assert {:ok, result} =
             Pools.update_model_serving_modes(
               scope,
               setup.pool,
               [%{exposed_model_id: setup.model.exposed_model_id, mode: mode}],
               expected_revision
             )

    result.revision
  end

  def await_succeeded_pool_requests!(pool_id, expected_count, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 1_000

    requests =
      Repo.all(
        from(request in Request,
          where: request.pool_id == ^pool_id,
          order_by: [asc: request.admitted_at]
        )
      )

    if length(requests) == expected_count and
         Enum.all?(requests, &(&1.status == "succeeded")) do
      requests
    else
      if System.monotonic_time(:millisecond) < deadline do
        receive do
        after
          5 -> await_succeeded_pool_requests!(pool_id, expected_count, deadline)
        end
      else
        flunk(
          "expected #{expected_count} succeeded websocket requests, got #{inspect(Enum.map(requests, & &1.status))}"
        )
      end
    end
  end

  def execute_websocket_response(auth, raw_payload, opts, push_frame) do
    request_options = RequestOptions.for_websocket(opts)

    capture_metadata_control? = Map.get(opts, :capture_metadata_control?, false)

    RuntimeGateway.execute_websocket_response(auth, raw_payload, request_options, fn frame ->
      if capture_metadata_control? || not metadata_control_frame?(frame) do
        push_frame.(frame)
      end
    end)
  end

  def stop_registered_websocket_owner_sessions do
    capture_log(fn ->
      WebsocketOwnerSession.Registry
      |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
      |> Enum.each(&stop_websocket_owner_session/1)
    end)
  end

  def stop_websocket_owner_session(codex_session_id) do
    case WebsocketOwnerSession.lookup(codex_session_id) do
      {:ok, owner_pid} ->
        monitor = Process.monitor(owner_pid)

        try do
          GenServer.stop(owner_pid, :shutdown, @connection_shutdown_timeout_ms)
        catch
          :exit, {:noproc, _details} -> :ok
        end

        assert_receive {:DOWN, ^monitor, :process, ^owner_pid, _reason},
                       @connection_shutdown_timeout_ms

      {:error, :owner_unavailable} ->
        :ok
    end

    assert {:error, :owner_unavailable} = WebsocketOwnerSession.lookup(codex_session_id)
  end

  def metadata_control_frame?(%{"type" => "codex.response.metadata"}), do: true

  def metadata_control_frame?({:text, frame}) when is_binary(frame),
    do: metadata_control_frame?(frame)

  def metadata_control_frame?(frame) when is_binary(frame) do
    match?({:ok, %{"type" => "codex.response.metadata"}}, CodexPooler.JSON.decode(frame))
  end

  def metadata_control_frame?(_frame), do: false

  def capture_stream_outcome_telemetry(fun) do
    handler_id = "native-stream-outcome-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :gateway, :stream, :outcome],
        fn _event, _measurements, metadata, _config ->
          send(parent, {:stream_outcome, metadata})
        end,
        nil
      )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end
  end

  def native_previous_response_retry_event do
    %{
      "type" => "error",
      "status" => 400,
      "error" => %{
        "type" => "invalid_request_error",
        "code" => "previous_response_not_found",
        "message" => "Previous response was not found. Retrying the full request."
      }
    }
  end

  def receive_socket_push(state, timeout_ms) do
    receive do
      {:codex_response_chunk, task_pid, frame} ->
        result = CodexResponsesSocket.handle_info({:codex_response_chunk, task_pid, frame}, state)

        if StreamProtocol.internal_control_event?(frame) do
          receive_socket_push(state, timeout_ms)
        else
          result
        end
    after
      timeout_ms -> flunk("expected websocket response chunk")
    end
  end

  @native_turn_failure_shapes [
    :lifecycle_cut,
    :provider_error_event,
    :response_failed,
    :pre_visible_close,
    :upgrade_rejected
  ]
  @native_turn_terminal_types ~w(response.completed response.failed response.incomplete error)

  def native_turn_failure_shapes, do: @native_turn_failure_shapes

  # One native turn whose single upstream send fails in the named shape. Every
  # shape is one strict entry, so a hidden retry or replay fails `verify!/1`.
  def strict_native_turn_failure(:lifecycle_cut) do
    # provenance: observed findings issue 124 (lifecycle frames then a transport close; ids synthetic)
    FakeUpstream.strict_sequence([
      strict_native_request(
        1,
        FakeUpstream.websocket_text_frames_then_abrupt_close([
          CodexPooler.JSON.encode!(%{
            "type" => "response.created",
            "response" => %{"id" => "resp_single_terminal_cut", "status" => "in_progress"}
          }),
          CodexPooler.JSON.encode!(%{
            "type" => "response.in_progress",
            "response" => %{"id" => "resp_single_terminal_cut", "status" => "in_progress"}
          })
        ])
      )
    ])
  end

  def strict_native_turn_failure(:provider_error_event) do
    # provenance: synthetic_adversarial (lifecycle frame then a provider type:error event)
    FakeUpstream.strict_sequence([
      strict_native_request(
        1,
        FakeUpstream.websocket_text_frames([
          CodexPooler.JSON.encode!(%{
            "type" => "response.created",
            "response" => %{"id" => "resp_single_terminal_error", "status" => "in_progress"}
          }),
          CodexPooler.JSON.encode!(%{
            "type" => "error",
            "status" => 500,
            "error" => %{
              "type" => "server_error",
              "code" => "server_error",
              "message" => "synthetic"
            }
          })
        ])
      )
    ])
  end

  def strict_native_turn_failure(:response_failed) do
    # provenance: synthetic_adversarial (invented response.failed terminal)
    FakeUpstream.strict_sequence([
      strict_native_request(1, FakeUpstream.websocket_terminal_failure("server_error"))
    ])
  end

  def strict_native_turn_failure(:pre_visible_close) do
    # provenance: synthetic_adversarial (peer close before any frame)
    FakeUpstream.strict_sequence([
      strict_native_request(1, FakeUpstream.websocket_close(code: 1011))
    ])
  end

  def strict_native_turn_failure(:upgrade_rejected) do
    # provenance: synthetic_adversarial (handshake rejected before any frame)
    FakeUpstream.strict_sequence([
      FakeUpstream.expect_request(
        method: "GET",
        path: "/backend-api/codex/responses",
        respond:
          FakeUpstream.websocket_upgrade_error(
            %{"error" => %{"code" => "upgrade_rejected"}},
            status: 403
          )
      )
    ])
  end

  # A provider `type:error` event reaches the native client normalized as its
  # single `response.failed` terminal, never as a relayed error frame.
  def native_turn_failure_terminal_type(:provider_error_event), do: "response.failed"
  def native_turn_failure_terminal_type(:response_failed), do: "response.failed"
  def native_turn_failure_terminal_type(_shape), do: "error"

  @doc """
  Drives one native websocket turn through the socket callbacks and returns
  every client-visible frame the socket pushed for it, decoded, in push order.

  The turn is settled once the response task reported done, the socket tracks
  no task, and, for an owner-forwarded socket, the owner's `:complete` arrived.
  Every producer of a frame for the turn has fired by then (the owner relays
  before it replies, the task reports after the reply), so the closing mailbox
  check proves nothing else is pending without waiting on a timer.
  """
  def collect_native_turn_frames!(state, timeout_ms \\ @connection_shutdown_timeout_ms) do
    seen = %{done?: false, complete?: not Adapter.owner?(state)}
    collect_native_turn_frames(state, [], seen, timeout_ms)
  end

  defp collect_native_turn_frames(state, frames, seen, timeout_ms) do
    if seen.done? and seen.complete? and MapSet.size(state.tasks) == 0 do
      refute_received {:codex_response_chunk, _task_pid, _frame}
      refute_received {:websocket_owner_frame, _correlation_id, _epoch, _owner_turn_id, _payload}
      refute_received {:websocket_owner_frame, _correlation_id, _epoch, _payload}
      refute_received {:codex_response_done, _task_pid, _result}
      {state, Enum.reverse(frames)}
    else
      message = receive_native_turn_message(timeout_ms)
      seen = mark_native_turn_message(seen, message)

      case CodexResponsesSocket.handle_info(message, state) do
        {:push, {:text, frame}, state} ->
          collect_native_turn_frames(
            state,
            [CodexPooler.JSON.decode!(frame) | frames],
            seen,
            timeout_ms
          )

        {:ok, state} ->
          collect_native_turn_frames(state, frames, seen, timeout_ms)

        {:stop, _reason, close_detail, _state} ->
          flunk("native turn closed the socket with #{inspect(close_detail)}")
      end
    end
  end

  defp receive_native_turn_message(timeout_ms) do
    receive do
      {:codex_response_chunk, _task_pid, _frame} = message -> message
      {:websocket_owner_frame, _, _, _, _} = message -> message
      {:websocket_owner_frame, _, _, _} = message -> message
      {:websocket_owner_output_commit_probe, _, _, _, _, _, _} = message -> message
      {:websocket_owner_cleanup_witness, _, _, _, _} = message -> message
      {:websocket_response_activity, _task_pid, _token} = message -> message
      {:codex_response_done, _task_pid, _result} = message -> message
      {:websocket_response_delivery_complete, _task_pid, _token} = message -> message
    after
      timeout_ms -> flunk("expected native websocket turn settlement")
    end
  end

  defp mark_native_turn_message(seen, {:codex_response_done, _task_pid, _result}),
    do: %{seen | done?: true}

  defp mark_native_turn_message(seen, {:websocket_owner_frame, _, _, _, :complete}),
    do: %{seen | complete?: true}

  defp mark_native_turn_message(seen, {:websocket_owner_frame, _, _, :complete}),
    do: %{seen | complete?: true}

  defp mark_native_turn_message(seen, _message), do: seen

  @doc """
  Asserts the turn delivered exactly one client-visible terminal frame, of
  `expected_type`, as its last frame. Failure messages carry only frame types,
  statuses, and error codes.
  """
  def assert_single_native_turn_terminal!(frames, expected_type) do
    summary = Enum.map(frames, &{&1["type"], &1["status"], get_in(&1, ["error", "code"])})
    terminals = Enum.filter(frames, &(&1["type"] in @native_turn_terminal_types))

    assert Enum.map(terminals, & &1["type"]) == [expected_type],
           "expected exactly one #{expected_type} terminal for the turn, pushed: #{inspect(summary)}"

    assert List.last(frames)["type"] == expected_type
    List.last(frames)
  end
end
