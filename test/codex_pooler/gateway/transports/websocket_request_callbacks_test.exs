defmodule CodexPooler.Gateway.Transports.WebsocketRequestCallbacksTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Gateway.Payloads.RequestOptions.{ResetProbe, TimeoutConfig}
  alias CodexPooler.Gateway.Transports.NativeCodexResponseControl.TurnSnapshot
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.Request
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequest
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequestV3
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketRequestCallbacks
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity

  test "maps every discriminator to the exact current mapper output" do
    messages = [
      Jason.encode!(%{"type" => "response.completed", "response" => %{"id" => "resp_example"}}),
      Jason.encode!(%{
        "type" => "response.failed",
        "response" => %{"error" => %{"code" => "server_error"}}
      })
    ]

    mappings = [
      public_openai_responses: &StreamProtocol.normalize_public_openai_responses_json_message/1,
      native_codex_responses: &StreamProtocol.canonicalize_native_codex_responses_json_message/1,
      codex_responses: &StreamProtocol.canonicalize_codex_responses_json_message/1
    ]

    for {discriminator, current_mapper} <- mappings,
        message <- messages do
      assert {:ok, mapper} = WebsocketRequestCallbacks.mapper(discriminator)
      assert mapper.(message) === current_mapper.(message)
    end

    assert {:error, :invalid_mapper} = WebsocketRequestCallbacks.mapper(:unknown)
  end

  test "materializes callbacks only after loading the current local identity" do
    identity = active_upstream_identity_fixture()
    assert {:ok, envelope} = owner_request(identity.id)

    current_label = "Current identity #{System.unique_integer([:positive])}"

    identity
    |> Ecto.Changeset.change(account_label: current_label)
    |> Repo.update!()

    assert {:ok, %Request{} = request} =
             WebsocketRequestCallbacks.materialize(envelope, fn _text, _terminal -> :written end)

    assert is_function(request.message_mapper, 1)
    assert is_function(request.writer, 2)
    assert is_function(request.frame_observer, 2)
    assert request.submission_observer == nil
    assert request.writer.("{}", :not_terminal) == :written

    assert {:env, environment} = :erlang.fun_info(request.frame_observer, :env)

    assert Enum.any?(environment, fn
             %UpstreamIdentity{account_label: ^current_label} -> true
             _value -> false
           end)

    UpstreamIdentity |> Repo.get!(identity.id) |> Repo.delete!()

    assert {:error, :upstream_identity_not_found} =
             WebsocketRequestCallbacks.materialize(envelope, fn _text -> :written end)
  end

  test "V1 materialization preserves the validated Full and Lite serving-mode witness" do
    identity = active_upstream_identity_fixture()

    for mode <- ["full", "lite"] do
      attrs =
        identity.id
        |> valid_attrs()
        |> put_in([:observation, :mode], mode)

      assert {:ok, envelope} = WebsocketOwnerRequest.new(attrs)

      assert {:ok, %Request{effective_serving_mode: ^mode}} =
               WebsocketRequestCallbacks.materialize(envelope, fn _text -> :written end)
    end

    spoofed =
      identity.id
      |> valid_attrs()
      |> put_in([:observation, :mode], "auto")

    assert {:error, {:invalid_owner_request, {:invalid_field, :observation}}} =
             WebsocketRequestCallbacks.materialize(spoofed, fn _text -> :written end)
  end

  test "V3 materializes one opaque owner capability into the direct request boundary" do
    identity = active_upstream_identity_fixture()
    capability = capability()

    attrs =
      identity.id
      |> valid_attrs()
      |> Map.merge(%{
        version: 3,
        websocket_delivery_mode: :collect_compaction,
        effective_serving_mode: :full,
        owner_admission_capability: capability,
        first_compact_collection: nil
      })

    assert {:ok, envelope} = WebsocketOwnerRequestV3.new(attrs)
    assert {:ok, request} = WebsocketRequestCallbacks.materialize(envelope, nil)

    assert request.native_compaction_capability == capability

    assert request.expected_connection_lifecycle == %{
             lifecycle_id: capability.binding.lifecycle_id,
             generation: capability.binding.generation
           }

    assert request.writer == nil
    assert request.websocket_delivery_mode == :collect_compaction
    assert request.effective_serving_mode == "full"
    refute inspect(request) =~ Base.encode16(capability.token)
  end

  test "rejects malformed envelope before identity lookup" do
    malformed = %{valid_attrs(Ecto.UUID.generate()) | headers: [{"x-test", fn -> :bad end}]}

    assert {:error, {:invalid_owner_request, {:invalid_field, :headers}}} =
             WebsocketRequestCallbacks.materialize(malformed, fn _text -> :written end)
  end

  test "rejects callback-bearing nested snapshot keys before identity lookup" do
    function = fn -> :bad end
    attrs = valid_attrs(Ecto.UUID.generate())

    snapshots = [
      {:timeouts, Map.put(attrs.timeouts, :unexpected_callback, function)},
      {:reset_probe,
       Map.put(%ResetProbe{token: Ecto.UUID.generate()}, :unexpected_callback, function)},
      {:native_codex_response_control,
       Map.put(%TurnSnapshot{models_etag: "etag"}, :unexpected_callback, function)}
    ]

    assert Enum.map(snapshots, fn {field, snapshot} ->
             attrs
             |> Map.put(field, snapshot)
             |> WebsocketRequestCallbacks.materialize(fn _text -> :written end)
           end) ==
             [
               {:error, {:invalid_owner_request, {:invalid_field, :timeouts}}},
               {:error, {:invalid_owner_request, {:invalid_field, :reset_probe}}},
               {:error,
                {:invalid_owner_request, {:invalid_field, :native_codex_response_control}}}
             ]
  end

  test "owner-local writer and frame observer preserve multi-agent round observation semantics" do
    identity = active_upstream_identity_fixture()
    handler_id = "websocket-request-callbacks-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :gateway, :multi_agent_round, :product_stage],
        fn _event, _measurements, metadata, _config -> send(parent, {:observation, metadata}) end,
        nil
      )

    Application.put_env(:codex_pooler, :multi_agent_round_product_observation_enabled, true)

    on_exit(fn ->
      Application.put_env(:codex_pooler, :multi_agent_round_product_observation_enabled, false)
      :telemetry.detach(handler_id)
    end)

    assert {:ok, envelope} = owner_request(identity.id)
    parent = self()

    writer = fn text, terminal ->
      send(parent, {:written, text, terminal})
      :writer_result
    end

    assert {:ok, request} = WebsocketRequestCallbacks.materialize(envelope, writer)

    frame =
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => "resp_abcdefghijklmnop"}
      })

    assert request.frame_observer.(frame, Jason.decode!(frame)) == :ok
    assert request.writer.(frame, :terminal) == :writer_result
    assert_receive {:written, ^frame, :terminal}

    assert_receive {:observation,
                    %{
                      direction: :provider_to_pooler,
                      event_type: "response.completed",
                      route: "backend_websocket"
                    }}

    assert_receive {:observation,
                    %{
                      direction: :pooler_to_codex,
                      event_type: "response.completed",
                      route: "backend_websocket"
                    }}
  end

  defp owner_request(identity_id), do: valid_attrs(identity_id) |> WebsocketOwnerRequest.new()

  defp valid_attrs(identity_id) do
    %{
      version: 1,
      url: "https://upstream.example.com/backend-api/codex/responses",
      headers: [{"authorization", "synthetic-value"}],
      payload: "{}",
      timeouts: %TimeoutConfig{
        connect_timeout_ms: 1_000,
        pool_timeout_ms: 1_000,
        receive_timeout_ms: 30_000
      },
      mapper: :codex_responses,
      upstream_identity_id: identity_id,
      observation: %{
        request_id: Ecto.UUID.generate(),
        client_request_id: "client-request",
        attempt_id: Ecto.UUID.generate(),
        mode: "full"
      },
      reset_probe: nil,
      native_codex_response_control: nil,
      assignment_advertised?: false,
      connection_bound_continuation?: false,
      forward_error_body?: false,
      submission_notification?: false
    }
  end

  defp capability do
    binding = %NativeCompactionAdmission.Binding{
      semantic_turn_key: <<1::256>>,
      window_digest: <<2::256>>,
      context_digest: <<3::256>>,
      window_number: nil,
      previous_response_digest: nil,
      serving_mode: :full,
      topology: %NativeCompactionAdmission.Topology.Forwarded{
        owner_instance_digest: <<4::256>>,
        downstream_epoch: 1,
        owner_lease_digest: <<5::256>>
      },
      lifecycle_id: Ecto.UUID.generate(),
      generation: 1
    }

    {:ok, ordinary} = NativeCompactionAdmission.ordinary_success(binding)
    {:ok, pending} = NativeCompactionAdmission.arm_compact(ordinary, 100)

    {:ok, _reserved, capability} =
      NativeCompactionAdmission.reserve(pending, :compact, binding, make_ref(), 0)

    capability
  end
end
