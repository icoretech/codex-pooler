defmodule CodexPooler.Gateway.Transports.WebsocketOwnerFullHistoryContractTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Gateway.Payloads.NativeCodexTurnMetadata
  alias CodexPooler.Gateway.Payloads.RequestOptions.TimeoutConfig
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequestV2
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequestV6
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketRequestCallbacks

  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Transports.WebsocketOwnerNodeHarness
  alias CodexPooler.Gateway.Websocket, as: Gateway

  @moduletag capture_log: true

  defmodule OldOwner do
    def connected_app_nodes, do: [:"owner@app.example"]
    def app_node?(_node), do: true

    def call_owner(_node, module, function, args, _timeout) do
      send(self(), {:owner_rpc, function})
      {:error, {:exception, :undef, [{module, function, args, []}]}}
    end
  end

  test "v6 full-history collection is a distinct closed envelope and preserves wire bytes" do
    attrs = attrs()
    assert {:ok, request} = WebsocketOwnerRequestV6.new(attrs)
    assert request.version == 6
    assert request.payload == attrs.payload
    assert inspect(request) == "#WebsocketOwnerRequestV6<version: 6>"
    assert :ok = WebsocketOwnerRequestV6.validate(request)

    assert {:error, {:invalid_field, :version}} =
             WebsocketOwnerRequestV2.new(Map.delete(attrs, :native_compaction_metadata))

    for {field, value} <- [
          version: 2,
          websocket_delivery_mode: :collect_compaction,
          connection_bound_continuation?: true,
          effective_serving_mode: "full"
        ] do
      assert {:error, {:invalid_field, ^field}} =
               WebsocketOwnerRequestV6.new(Map.put(attrs, field, value))
    end

    assert {:error, {:unknown_fields, [:full_history_compaction?]}} =
             WebsocketOwnerRequestV6.new(Map.put(attrs, :full_history_compaction?, true))

    assert {:error, {:invalid_field, :envelope}} =
             WebsocketOwnerRequestV6.validate(attrs)
  end

  test "v6 rejects anchors and malformed full-history payloads before materialization" do
    for payload <- [
          Map.put(payload(), "previous_response_id", "resp_synthetic_anchor"),
          Map.put(payload(), "previous_response_id", ""),
          Map.put(payload(), "previous_response_id", false),
          Map.put(payload(), "input", [%{"type" => "compaction_trigger"}]),
          Map.put(payload(), "input", [%{"type" => "message", "content" => []}]),
          Map.put(payload(), "generate", false),
          Map.put(payload(), "input", [nil, %{"type" => "compaction_trigger"}]),
          Map.put(payload(), "input", [%{}, %{"type" => "compaction_trigger"}]),
          Map.put(payload(), "input", [42, %{"type" => "compaction_trigger"}]),
          Map.put(payload(), "input", [
            %{"type" => "compaction_trigger"},
            %{"type" => "compaction_trigger"}
          ]),
          %{"full_history_compaction?" => true}
        ] do
      assert {:error, {:invalid_field, :payload}} =
               WebsocketOwnerRequestV6.new(Map.put(attrs(), :payload, Jason.encode!(payload)))
    end
  end

  test "native reasoning, compaction and empty tool output history remain eligible" do
    for item <- [
          %{"type" => "reasoning", "summary" => []},
          %{"type" => "compaction", "encrypted_content" => "synthetic"},
          %{"type" => "function_call_output", "call_id" => "call_example", "output" => ""},
          %{"type" => "future_tool_result", "call_id" => "call_example", "result" => []}
        ] do
      body = Map.put(payload(), "input", [item, %{"type" => "compaction_trigger"}])

      assert {:ok, _request} =
               WebsocketOwnerRequestV6.new(Map.put(attrs(), :payload, Jason.encode!(body)))
    end
  end

  test "materialization requires current identity and keeps the v6 collection discriminator" do
    identity = active_upstream_identity_fixture()
    assert {:ok, envelope} = WebsocketOwnerRequestV6.new(attrs(identity.id))
    assert {:ok, request} = WebsocketRequestCallbacks.materialize(envelope, nil)
    assert request.websocket_delivery_mode == :collect_full_history
    assert request.payload == envelope.payload
    assert request.writer == nil
    assert request.native_compaction_metadata == envelope.native_compaction_metadata

    assert {:error, :invalid_writer} =
             WebsocketRequestCallbacks.materialize(envelope, fn _ -> :ok end)

    assert {:error, :upstream_identity_not_found} =
             WebsocketRequestCallbacks.materialize(
               %{envelope | upstream_identity_id: Ecto.UUID.generate()},
               nil
             )
  end

  test "versioned entrypoint rejects untyped requests and missing current owners" do
    downstream = %{pid: self(), epoch: 1, correlation_id: "full-history"}

    assert {:error, :owner_unavailable} =
             WebsocketOwnerForwarder.remote_submit_request_v6(
               Ecto.UUID.generate(),
               downstream,
               attrs()
             )

    assert {:ok, envelope} = WebsocketOwnerRequestV6.new(attrs())

    assert {:error, :owner_unavailable} =
             WebsocketOwnerForwarder.remote_submit_request_v6(
               Ecto.UUID.generate(),
               downstream,
               envelope
             )
  end

  test "missing v6 RPC fails closed for returned errors and every caught failure kind" do
    module = WebsocketOwnerForwarder
    args = [Ecto.UUID.generate(), %{pid: self(), epoch: 1}, :opaque_request]
    reason = {:exception, :undef, [{module, :remote_submit_request_v6, args, []}]}

    for kind <- [:error, :exit, :throw] do
      assert :owner_unavailable =
               module.normalize_remote_failure(
                 kind,
                 reason,
                 module,
                 :remote_submit_request_v6,
                 args
               )
    end
  end

  test "remote dispatch targets only v6 and does not downgrade an old owner" do
    session = session("owner@app.example")
    assert {:ok, envelope} = WebsocketOwnerRequestV6.new(attrs())
    downstream = %{pid: self(), epoch: 1, correlation_id: "v6-old-owner"}

    assert {:error, :owner_unavailable} =
             WebsocketOwnerForwarder.submit_request(
               session,
               session.owner_lease_token,
               downstream,
               envelope,
               node_client: OldOwner,
               app_node_names: ["owner@app.example"]
             )

    assert_received {:owner_rpc, :remote_submit_request_v6}
    refute_received {:owner_rpc, :remote_submit_request_v1}
    refute_received {:owner_rpc, :remote_submit_request_v2}
    refute_received {:owner_rpc, :remote_submit_request_v4}
    refute_received {:owner_rpc, :remote_submit_request_v5}
  end

  test "local v6 owner submission rejects a stale token and downstream epoch before sending" do
    session = session(Atom.to_string(node()))
    identity = active_upstream_identity_fixture()
    assert {:ok, envelope} = WebsocketOwnerRequestV6.new(attrs(identity.id))

    assert {:ok, owner} =
             WebsocketOwnerSession.start_owner(
               codex_session_id: session.id,
               owner_lease_token: session.owner_lease_token,
               owner_instance_id: session.owner_instance_id,
               upstream: WebsocketOwnerNodeHarness.fake_upstream_boundary(self())
             )

    on_exit(fn -> if Process.alive?(owner), do: GenServer.stop(owner, :normal, 15_000) end)
    assert_receive {:websocket_owner_harness_upstream_started, upstream}, 15_000

    assert {:ok, downstream} =
             WebsocketOwnerSession.attach_downstream(owner, %{
               pid: self(),
               epoch: 1,
               correlation_id: "v6-owner"
             })

    assert {:error, :stale_owner} =
             WebsocketOwnerForwarder.submit_request(
               session,
               Ecto.UUID.generate(),
               downstream,
               envelope
             )

    assert {:error, :stale_downstream} =
             WebsocketOwnerForwarder.submit_request(
               session,
               session.owner_lease_token,
               %{downstream | epoch: downstream.epoch + 1},
               envelope
             )

    assert [] == WebsocketOwnerNodeHarness.fake_upstream_frames(upstream)

    assert :ok =
             WebsocketOwnerForwarder.submit_request(
               session,
               session.owner_lease_token,
               downstream,
               envelope
             )

    assert [request] = WebsocketOwnerNodeHarness.fake_upstream_frames(upstream)
    assert request.websocket_delivery_mode == :collect_full_history
    assert request.payload == envelope.payload
  end

  defp session(owner_instance) do
    reset_bootstrap_state_fixture!()
    %{user: owner} = bootstrap_owner_fixture()
    pool = pool_fixture(%{created_by_user_id: owner.id})
    %{api_key: api_key} = active_api_key_fixture(pool, %{created_by_user_id: owner.id})

    assert {:ok, session} =
             Gateway.start_codex_session(%{pool: pool, api_key: api_key}, %{
               accepted_turn_state: "full-history-#{System.unique_integer([:positive])}",
               owner_instance_id: owner_instance
             })

    session
  end

  defp attrs(identity_id \\ Ecto.UUID.generate()) do
    %{
      version: 6,
      url: "https://upstream.example.com/backend-api/codex/responses",
      headers: [],
      payload: Jason.encode!(payload()),
      timeouts: %TimeoutConfig{
        connect_timeout_ms: 1_000,
        pool_timeout_ms: 1_000,
        receive_timeout_ms: 30_000
      },
      mapper: :native_codex_responses,
      upstream_identity_id: identity_id,
      observation: %{request_id: nil, client_request_id: nil, attempt_id: nil, mode: "full"},
      reset_probe: nil,
      native_codex_response_control: nil,
      assignment_advertised?: false,
      connection_bound_continuation?: false,
      forward_error_body?: false,
      submission_notification?: false,
      websocket_delivery_mode: :collect_full_history,
      effective_serving_mode: :full,
      native_compaction_metadata: compaction_metadata()
    }
  end

  test "v6 metadata requires typed compaction identity without arbitrary nested fields" do
    for metadata <- [
          nil,
          Map.from_struct(compaction_metadata()),
          %{compaction_metadata() | request_kind: :turn},
          %{compaction_metadata() | semantic_turn_key: nil},
          Map.put(compaction_metadata(), :callback, fn -> :unsafe end),
          %{
            compaction_metadata()
            | compaction: %{compaction_metadata().compaction | strategy: :unknown}
          }
        ] do
      assert {:error, {:invalid_field, :native_compaction_metadata}} =
               WebsocketOwnerRequestV6.new(
                 Map.put(attrs(), :native_compaction_metadata, metadata)
               )
    end
  end

  defp compaction_metadata do
    %NativeCodexTurnMetadata{
      semantic_turn_key: <<1::256>>,
      window_id_digest: <<2::256>>,
      context_window_id_digest: <<3::256>>,
      window_number: 1,
      request_kind: :compaction,
      compaction: %NativeCodexTurnMetadata.Compaction{
        trigger: :manual,
        reason: :user_requested,
        implementation: :responses_compaction_v2,
        phase: :standalone_turn,
        strategy: :memento
      }
    }
  end

  defp payload do
    %{
      "model" => "example-model",
      "input" => [
        %{"role" => "user", "content" => "synthetic"},
        %{"type" => "compaction_trigger"}
      ]
    }
  end
end
