defmodule CodexPooler.Gateway.WebsocketTest do
  use CodexPooler.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import CodexPooler.PoolerFixtures
  import CodexPoolerWeb.Runtime.BackendCodexTestSupport

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway, as: RuntimeGateway
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{BridgeSessionAlias, CodexSession}
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Pools
  alias CodexPooler.Repo

  @websocket_frame_timeout 1_000
  @supported_compression_model "gpt-4o"

  describe "retarget_websocket_owner_runtime/4" do
    setup do
      previous = Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)
      Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

      on_exit(fn ->
        cleanup_local_owner_sessions()

        case previous do
          nil -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
          value -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
        end
      end)

      key = active_api_key_fixture()
      {:ok, auth} = Access.authenticate_authorization_header(key.authorization)

      %{api_key: key.api_key, auth: auth}
    end

    test "returns the current runtime unchanged when the frame has no previous response alias", %{
      auth: auth
    } do
      {:ok, runtime} = owner_runtime(auth, "owner-runtime-no-alias")

      assert {:ok, ^runtime} =
               Gateway.retarget_websocket_owner_runtime(auth, runtime, %{
                 "type" => "response.create"
               })
    end

    test "returns the current runtime unchanged when the frame alias targets the same session", %{
      api_key: api_key,
      auth: auth
    } do
      {:ok, runtime} = owner_runtime(auth, "owner-runtime-same-session")
      previous_response_id = previous_response_id("same")
      register_previous_response_alias!(runtime.codex_session, api_key, previous_response_id)

      assert {:ok, ^runtime} =
               Gateway.retarget_websocket_owner_runtime(auth, runtime, %{
                 "type" => "response.create",
                 "previous_response_id" => previous_response_id
               })
    end

    test "attaches the authorized different-session owner runtime before returning it", %{
      api_key: api_key,
      auth: auth
    } do
      {:ok, current_runtime} = owner_runtime(auth, "owner-runtime-current")

      {:ok, target_session} =
        Gateway.start_codex_session(auth, owner_opts("owner-runtime-target"))

      target_session = Repo.get!(CodexSession, target_session.id)
      previous_response_id = previous_response_id("target")
      register_previous_response_alias!(target_session, api_key, previous_response_id)

      assert {:ok, retargeted_runtime} =
               Gateway.retarget_websocket_owner_runtime(auth, current_runtime, %{
                 "type" => "response.create",
                 "previous_response_id" => previous_response_id
               })

      assert retargeted_runtime.codex_session.id == target_session.id
      assert retargeted_runtime.codex_session.id != current_runtime.codex_session.id
      assert retargeted_runtime.websocket_owner_lease_token == target_session.owner_lease_token
      assert is_map(retargeted_runtime.websocket_owner_downstream)
      assert retargeted_runtime.websocket_owner_downstream.pid == self()
      assert is_boolean(retargeted_runtime.websocket_owner_active_turn_reconnect?)
      assert {:ok, _owner_pid} = WebsocketOwnerSession.lookup(target_session.id)
      assert {:ok, _owner_pid} = WebsocketOwnerSession.lookup(current_runtime.codex_session.id)
    end

    test "uses backend frame turn-state to attach a different-session owner runtime", %{
      auth: auth
    } do
      {:ok, current_runtime} = owner_runtime(auth, "owner-runtime-turn-state-current")
      target_turn_state = owner_turn_state("owner-runtime-turn-state-target")

      {:ok, target_session} =
        Gateway.start_codex_session(auth, %{accepted_turn_state: target_turn_state})

      target_session = Repo.get!(CodexSession, target_session.id)

      assert {:ok, retargeted_runtime} =
               Gateway.retarget_websocket_owner_runtime(auth, current_runtime, %{
                 "type" => "response.create",
                 "client_metadata" => %{"x-codex-turn-state" => target_turn_state}
               })

      assert retargeted_runtime.codex_session.id == target_session.id
      assert retargeted_runtime.codex_session.id != current_runtime.codex_session.id
      assert retargeted_runtime.websocket_owner_lease_token == target_session.owner_lease_token
      assert is_map(retargeted_runtime.websocket_owner_downstream)
      assert retargeted_runtime.websocket_owner_downstream.pid == self()
      assert is_boolean(retargeted_runtime.websocket_owner_active_turn_reconnect?)
      assert {:ok, _owner_pid} = WebsocketOwnerSession.lookup(target_session.id)
      assert {:ok, _owner_pid} = WebsocketOwnerSession.lookup(current_runtime.codex_session.id)
    end

    test "keeps the current owner runtime when backend frame turn-state is unknown", %{
      auth: auth
    } do
      {:ok, runtime} = owner_runtime(auth, "owner-runtime-unknown-turn-state")
      owner_pid = owner_pid!(runtime.codex_session.id)
      owner_state_before = :sys.get_state(owner_pid)

      assert {:ok, ^runtime} =
               Gateway.retarget_websocket_owner_runtime(auth, runtime, %{
                 "type" => "response.create",
                 "client_metadata" => %{
                   "x-codex-turn-state" => owner_turn_state("unknown")
                 }
               })

      assert :sys.get_state(owner_pid) == owner_state_before
      assert {:ok, ^owner_pid} = WebsocketOwnerSession.lookup(runtime.codex_session.id)
    end

    test "previous response aliases take precedence over backend frame turn-state", %{
      api_key: api_key,
      auth: auth
    } do
      {:ok, current_runtime} = owner_runtime(auth, "owner-runtime-precedence-current")
      target_turn_state = owner_turn_state("owner-runtime-precedence-target")

      {:ok, target_session} =
        Gateway.start_codex_session(auth, %{accepted_turn_state: target_turn_state})

      target_session = Repo.get!(CodexSession, target_session.id)
      owner_pid = owner_pid!(current_runtime.codex_session.id)
      owner_state_before = :sys.get_state(owner_pid)

      assert {:error, :owner_unavailable} =
               Gateway.retarget_websocket_owner_runtime(auth, current_runtime, %{
                 "type" => "response.create",
                 "previous_response_id" => previous_response_id("guessed-precedence"),
                 "client_metadata" => %{"x-codex-turn-state" => target_turn_state}
               })

      assert :sys.get_state(owner_pid) == owner_state_before
      assert {:ok, ^owner_pid} = WebsocketOwnerSession.lookup(current_runtime.codex_session.id)
      assert {:error, :owner_unavailable} = WebsocketOwnerSession.lookup(target_session.id)

      previous_response_id = previous_response_id("valid-precedence")

      register_previous_response_alias!(
        current_runtime.codex_session,
        api_key,
        previous_response_id
      )

      assert {:ok, ^current_runtime} =
               Gateway.retarget_websocket_owner_runtime(auth, current_runtime, %{
                 "type" => "response.create",
                 "previous_response_id" => previous_response_id,
                 "client_metadata" => %{"x-codex-turn-state" => target_turn_state}
               })
    end

    test "refuses guessed aliases with a sanitized owner error and preserves current runtime", %{
      auth: auth
    } do
      {:ok, runtime} = owner_runtime(auth, "owner-runtime-refusal")
      owner_pid = owner_pid!(runtime.codex_session.id)
      owner_state_before = :sys.get_state(owner_pid)

      assert {:error, :owner_unavailable} =
               Gateway.retarget_websocket_owner_runtime(auth, runtime, %{
                 "type" => "response.create",
                 "previous_response_id" => previous_response_id("guessed")
               })

      assert ^runtime = runtime
      assert :sys.get_state(owner_pid) == owner_state_before
      assert {:ok, ^owner_pid} = WebsocketOwnerSession.lookup(runtime.codex_session.id)
    end
  end

  describe "websocket response.create request compression" do
    test "disabled pool sends the original backend websocket tool output with safe metadata" do
      upstream =
        start_upstream(
          FakeUpstream.json_response(%{
            "id" => "resp_ws_compression_disabled",
            "object" => "response",
            "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
          })
        )

      setup = gateway_setup(upstream, supported_compression_model_opts())
      {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
      {:ok, session} = Gateway.start_codex_session(auth, accepted_turn_state: "ws-disabled")
      omitted_sentinel = "backend websocket disabled omitted marker"
      original_output = compression_log_fixture(omitted_sentinel)

      assert :ok =
               execute_websocket_response(
                 auth,
                 backend_tool_output_payload(setup, original_output, "call_ws_disabled"),
                 websocket_request_options(session, "ws-compression-disabled"),
                 fn frame -> send(self(), {:websocket_frame, frame}) end
               )

      assert_receive {:websocket_frame, frame}, @websocket_frame_timeout
      assert %{"id" => "resp_ws_compression_disabled"} = Jason.decode!(frame)

      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.method == "WEBSOCKET"
      assert captured.path == "/backend-api/codex/responses"

      assert captured_output_fingerprint(captured) == payload_fingerprint(original_output)

      assert [request] = request_rows(setup.pool.id)
      assert request.transport == "websocket"
      assert request.status == "succeeded"

      assert [attempt] = attempt_rows(request)

      assert %{
               "enabled" => false,
               "attempted" => true,
               "status" => "disabled",
               "reason" => "pool_disabled",
               "route_class" => "proxy_websocket",
               "transport" => "websocket",
               "candidate_count" => 0,
               "compressed_count" => 0,
               "skipped_count" => 0
             } = attempt.response_metadata["payload_compression"]

      refute_payload_compression_leak!(
        attempt.response_metadata["payload_compression"],
        [omitted_sentinel, "call_ws_disabled"]
      )
    end

    test "enabled pool compresses backend websocket tool output before upstream send" do
      upstream =
        start_upstream(
          FakeUpstream.json_response(%{
            "id" => "resp_ws_backend_compressed",
            "object" => "response",
            "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
          })
        )

      setup = gateway_setup(upstream, supported_compression_model_opts())
      enable_request_compression!(setup.pool)
      {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
      {:ok, session} = Gateway.start_codex_session(auth, accepted_turn_state: "ws-backend")
      omitted_sentinel = "backend websocket compressed omitted marker"
      original_output = compression_log_fixture(omitted_sentinel)

      assert :ok =
               execute_websocket_response(
                 auth,
                 backend_tool_output_payload(setup, original_output, "call_ws_backend"),
                 websocket_request_options(session, "ws-backend-compressed"),
                 fn frame -> send(self(), {:websocket_frame, frame}) end
               )

      assert_receive {:websocket_frame, frame}, @websocket_frame_timeout
      assert %{"id" => "resp_ws_backend_compressed"} = Jason.decode!(frame)

      assert [captured] = FakeUpstream.requests(upstream)
      assert_websocket_output_compressed!(captured, omitted_sentinel)

      assert [request] = request_rows(setup.pool.id)
      assert request.transport == "websocket"
      assert request.status == "succeeded"

      assert [attempt] = attempt_rows(request)
      assert_compressed_metadata!(attempt, "proxy_websocket", "websocket", "log_output")

      refute_payload_compression_leak!(
        attempt.response_metadata["payload_compression"],
        [omitted_sentinel, "call_ws_backend"]
      )
    end

    test "enabled pool preserves output-only public websocket tool output before upstream send" do
      upstream =
        start_upstream(
          FakeUpstream.json_response(%{
            "id" => "resp_ws_public_compressed",
            "object" => "response",
            "usage" => %{"input_tokens" => 4, "output_tokens" => 3, "total_tokens" => 7}
          })
        )

      setup = gateway_setup(upstream, supported_compression_model_opts())
      enable_request_compression!(setup.pool)
      {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
      {:ok, session} = Gateway.start_codex_session(auth, accepted_turn_state: "ws-public")
      omitted_sentinel = "public websocket compressed omitted marker"
      original_output = compression_log_fixture(omitted_sentinel)

      assert :ok =
               execute_websocket_response(
                 auth,
                 public_tool_output_payload(setup, original_output, "call_ws_public"),
                 public_websocket_request_options(session, "ws-public-compressed"),
                 fn frame -> send(self(), {:websocket_frame, frame}) end
               )

      assert_receive {:websocket_frame, frame}, @websocket_frame_timeout
      assert %{"id" => "resp_ws_public_compressed"} = Jason.decode!(frame)

      assert [captured] = FakeUpstream.requests(upstream)
      assert captured.method == "WEBSOCKET"
      assert captured.path == "/backend-api/codex/responses"
      assert captured.json["stream"] == true
      assert captured.json["store"] == false

      assert captured.json["input"] |> List.first() |> Map.fetch!("type") ==
               "function_call_output"

      assert captured.json["input"] |> List.first() |> Map.fetch!("output") == original_output

      assert [request] = request_rows(setup.pool.id)
      assert request.endpoint == "/v1/responses"
      assert request.transport == "websocket"
      assert request.status == "succeeded"

      assert get_in(request.request_metadata, ["openai_compatibility", "source_endpoint"]) ==
               "/v1/responses"

      assert [attempt] = attempt_rows(request)

      assert %{
               "enabled" => true,
               "attempted" => true,
               "status" => "skipped",
               "reason" => "protected_tool_outputs",
               "route_class" => "proxy_websocket",
               "transport" => "websocket",
               "candidate_count" => 0,
               "compressed_count" => 0,
               "skipped_count" => 0,
               "protected_tool_output_skipped_count" => 1
             } = attempt.response_metadata["payload_compression"]

      refute_payload_compression_leak!(
        attempt.response_metadata["payload_compression"],
        [omitted_sentinel, "call_ws_public"]
      )
    end
  end

  defp owner_runtime(auth, session_key) do
    Gateway.prepare_websocket_session(auth, owner_opts(session_key))
  end

  defp owner_opts(session_key) do
    %{accepted_turn_state: owner_turn_state(session_key)}
  end

  defp owner_turn_state(session_key) do
    "#{session_key}-#{System.unique_integer([:positive])}"
  end

  defp previous_response_id(label) do
    "resp_owner_runtime_#{label}_#{System.unique_integer([:positive])}"
  end

  defp register_previous_response_alias!(%CodexSession{} = session, api_key, previous_response_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %BridgeSessionAlias{}
    |> BridgeSessionAlias.changeset(%{
      codex_session_id: session.id,
      pool_id: session.pool_id,
      api_key_id: api_key.id,
      alias_kind: "previous_response_id",
      alias_hash: :crypto.hash(:sha256, previous_response_id),
      alias_preview: "synthetic-prev",
      status: "active",
      expires_at: DateTime.add(now, 300, :second),
      last_seen_at: now,
      metadata: %{},
      created_at: now,
      updated_at: now
    })
    |> Repo.insert!()
  end

  defp owner_pid!(codex_session_id) do
    assert {:ok, owner_pid} = WebsocketOwnerSession.lookup(codex_session_id)
    owner_pid
  end

  defp cleanup_local_owner_sessions do
    capture_log(fn ->
      WebsocketOwnerSession.Registry
      |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
      |> Enum.each(fn codex_session_id ->
        try do
          with {:ok, owner_pid} <- WebsocketOwnerSession.lookup(codex_session_id) do
            _result = GenServer.stop(owner_pid, :shutdown, 1_000)
          end
        catch
          :exit, _reason -> :ok
        end
      end)
    end)

    :ok
  end

  defp execute_websocket_response(
         auth,
         raw_payload,
         %RequestOptions{} = request_options,
         push_frame
       )
       when is_binary(raw_payload) and is_function(push_frame, 1) do
    RuntimeGateway.execute_websocket_response(auth, raw_payload, request_options, push_frame)
  end

  defp websocket_request_options(%CodexSession{} = session, request_id) do
    %{
      request_id: request_id,
      client_ip: "127.0.0.1",
      codex_session: session
    }
    |> RequestOptions.for_websocket()
  end

  defp public_websocket_request_options(%CodexSession{} = session, request_id) do
    session
    |> websocket_request_options(request_id)
    |> RequestOptions.put_openai_compatibility(public_openai_responses_stream: true)
    |> RequestOptions.put_continuity(accepted_turn_state: nil)
    |> RequestOptions.mark_openai_compatibility_origin(
      "/v1/responses",
      "/backend-api/codex/responses"
    )
  end

  defp backend_tool_output_payload(setup, output, call_id) do
    %{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "input" => [
        %{
          "type" => "local_shell_call_output",
          "call_id" => call_id,
          "output" => output
        }
      ],
      "stream" => true,
      "generate" => true
    }
    |> Jason.encode!()
  end

  defp public_tool_output_payload(setup, output, tool_call_id) do
    %{
      "type" => "response.create",
      "model" => setup.model.exposed_model_id,
      "input" => [
        %{
          "role" => "tool",
          "tool_call_id" => tool_call_id,
          "content" => output
        }
      ],
      "stream" => true,
      "generate" => true
    }
    |> Jason.encode!()
  end

  defp assert_websocket_output_compressed!(captured, omitted_sentinel) do
    output = captured.json["input"] |> List.first() |> Map.fetch!("output")

    unless is_binary(output) and String.contains?(output, "[compressed log output: omitted") do
      flunk("expected websocket upstream tool output to be compressed")
    end

    if String.contains?(output, omitted_sentinel) do
      flunk("compressed websocket upstream output retained omitted sentinel")
    end
  end

  defp assert_compressed_metadata!(attempt, route_class, transport, strategy) do
    assert %{
             "enabled" => true,
             "attempted" => true,
             "status" => "compressed",
             "route_class" => ^route_class,
             "transport" => ^transport,
             "candidate_count" => 1,
             "compressed_count" => 1,
             "skipped_count" => 0
           } = metadata = attempt.response_metadata["payload_compression"]

    assert strategy in metadata["strategies"]
    assert metadata["original_bytes"] > metadata["compressed_bytes"]
    assert metadata["saved_bytes"] > 0
    assert metadata["original_tokens"] > metadata["compressed_tokens"]
    assert metadata["saved_tokens"] > 0
  end

  defp supported_compression_model_opts do
    [
      exposed_model_id: @supported_compression_model,
      upstream_model_id: @supported_compression_model,
      pricing_ref: @supported_compression_model
    ]
  end

  defp refute_payload_compression_leak!(metadata, forbidden_values) when is_map(metadata) do
    metadata_text = inspect(metadata)

    for value <- forbidden_values do
      if String.contains?(metadata_text, value) do
        flunk("payload compression metadata leaked forbidden websocket request content")
      end
    end
  end

  defp captured_output_fingerprint(captured) do
    captured.json["input"]
    |> List.first()
    |> Map.fetch!("output")
    |> payload_fingerprint()
  end

  defp payload_fingerprint(payload) when is_binary(payload) do
    :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
  end

  defp request_rows(pool_id) do
    Repo.all(from(r in Request, where: r.pool_id == ^pool_id, order_by: [asc: r.admitted_at]))
  end

  defp attempt_rows(%Request{} = request) do
    Repo.all(
      from(a in Attempt, where: a.request_id == ^request.id, order_by: [asc: a.attempt_number])
    )
  end

  defp enable_request_compression!(pool) do
    pool
    |> Pools.ensure_routing_settings()
    |> Ecto.Changeset.change(%{
      request_compression_enabled: true,
      updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })
    |> Repo.update!()
  end

  defp compression_log_fixture(omitted_sentinel) do
    middle =
      1..96
      |> Enum.map(fn
        48 -> "ordinary build line 48 #{omitted_sentinel}"
        index -> "ordinary build line #{index}"
      end)

    [
      "command started",
      "context before first",
      "error: first failure",
      "context after first"
    ]
    |> Kernel.++(middle)
    |> Kernel.++([
      "context before final",
      "fatal: final failure",
      "context after final"
    ])
    |> Enum.join("\n")
  end
end
