defmodule CodexPooler.Gateway.Transports.WebsocketOwnerRequestTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Payloads.RequestOptions.{ResetProbe, TimeoutConfig}
  alias CodexPooler.Gateway.Transports.NativeCodexResponseControl.TurnSnapshot
  alias CodexPooler.Gateway.Transports.Streaming.RuntimeAdmissionProof
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequest
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequestV2
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequestV3
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerRequestV4

  @allowed_keys MapSet.new([
                  :__struct__,
                  :version,
                  :url,
                  :headers,
                  :payload,
                  :timeouts,
                  :mapper,
                  :upstream_identity_id,
                  :observation,
                  :reset_probe,
                  :native_codex_response_control,
                  :assignment_advertised?,
                  :connection_bound_continuation?,
                  :forward_error_body?,
                  :submission_notification?
                ])

  test "constructs the fixed v1 data-only envelope" do
    assert {:ok, request} = WebsocketOwnerRequest.new(valid_attrs())

    assert request.version == 1
    assert MapSet.new(Map.keys(request)) == @allowed_keys
    refute contains_function?(request)
    assert WebsocketOwnerRequest.validate(request) == :ok
  end

  test "supports every mapper discriminator" do
    for mapper <- [
          :public_openai_responses,
          :native_codex_responses,
          :codex_responses
        ] do
      assert {:ok, %WebsocketOwnerRequest{mapper: ^mapper}} =
               valid_attrs() |> Map.put(:mapper, mapper) |> WebsocketOwnerRequest.new()
    end
  end

  test "rejects unknown fields and versions" do
    assert {:error, {:unknown_fields, [:unexpected]}} =
             valid_attrs() |> Map.put(:unexpected, true) |> WebsocketOwnerRequest.new()

    assert {:error, {:invalid_field, :version}} =
             valid_attrs() |> Map.put(:version, 2) |> WebsocketOwnerRequest.new()

    assert {:ok, request} = WebsocketOwnerRequest.new(valid_attrs())

    assert {:error, {:unknown_fields, [:unexpected]}} =
             request |> Map.put(:unexpected, true) |> WebsocketOwnerRequest.validate()
  end

  test "rejects malformed UUID, header, mapper, timeout, reset, control, and observation values" do
    invalid_values = [
      {:upstream_identity_id, "not-a-uuid"},
      {:headers, [{"authorization\nforged", "value"}]},
      {:headers, [{"authorization", "value\r\nforged"}]},
      {:headers, %{"authorization" => "value"}},
      {:payload, %{arbitrary: "map"}},
      {:mapper, :arbitrary_mapper},
      {:timeouts,
       %TimeoutConfig{connect_timeout_ms: -1, pool_timeout_ms: 1, receive_timeout_ms: 1}},
      {:timeouts, %{connect_timeout_ms: 1, pool_timeout_ms: 1, receive_timeout_ms: 1}},
      {:reset_probe, %ResetProbe{token: "not-a-uuid"}},
      {:reset_probe, %{token: Ecto.UUID.generate()}},
      {:native_codex_response_control, %TurnSnapshot{models_etag: ""}},
      {:native_codex_response_control, %{models_etag: "etag"}},
      {:observation, %{request_id: Ecto.UUID.generate()}},
      {:observation,
       valid_observation() |> Map.put(:client_request_id, String.duplicate("x", 257))},
      {:observation, valid_observation() |> Map.put(:mode, "auto")},
      {:observation, valid_observation() |> Map.put(:unknown, true)},
      {:assignment_advertised?, 1},
      {:connection_bound_continuation?, nil},
      {:forward_error_body?, :disabled},
      {:submission_notification?, "true"}
    ]

    for {field, value} <- invalid_values do
      assert {:error, {:invalid_field, ^field}} =
               valid_attrs() |> Map.put(field, value) |> WebsocketOwnerRequest.new()
    end
  end

  test "rejects a function at every reachable container shape" do
    function = fn -> :not_data end

    mutations = [
      {:url, function},
      {:headers, function},
      {:headers, [{"x-test", function}]},
      {:headers, [function]},
      {:payload, function},
      {:timeouts, function},
      {:timeouts,
       %TimeoutConfig{
         connect_timeout_ms: function,
         pool_timeout_ms: 1,
         receive_timeout_ms: 1
       }},
      {:mapper, function},
      {:upstream_identity_id, function},
      {:observation, function},
      {:observation, valid_observation() |> Map.put(:request_id, function)},
      {:observation, valid_observation() |> Map.put(:client_request_id, function)},
      {:observation, valid_observation() |> Map.put(:attempt_id, function)},
      {:observation, valid_observation() |> Map.put(:mode, function)},
      {:reset_probe, function},
      {:reset_probe, %ResetProbe{token: function}},
      {:native_codex_response_control, function},
      {:native_codex_response_control, %TurnSnapshot{models_etag: function}},
      {:assignment_advertised?, function},
      {:connection_bound_continuation?, function},
      {:forward_error_body?, function},
      {:submission_notification?, function}
    ]

    for {field, value} <- mutations do
      assert {:error, {:invalid_field, ^field}} =
               valid_attrs() |> Map.put(field, value) |> WebsocketOwnerRequest.new()
    end
  end

  test "rejects callback-bearing unknown keys on every nested snapshot" do
    function = fn -> :not_data end
    attrs = valid_attrs()

    mutations = [
      {:timeouts, Map.put(attrs.timeouts, :unexpected_callback, function)},
      {:reset_probe, Map.put(attrs.reset_probe, :unexpected_callback, function)},
      {:native_codex_response_control,
       Map.put(attrs.native_codex_response_control, :unexpected_callback, function)}
    ]

    assert Enum.map(mutations, fn {field, snapshot} ->
             attrs |> Map.put(field, snapshot) |> WebsocketOwnerRequest.new()
           end) ==
             [
               {:error, {:invalid_field, :timeouts}},
               {:error, {:invalid_field, :reset_probe}},
               {:error, {:invalid_field, :native_codex_response_control}}
             ]
  end

  test "inspect is opaque" do
    attrs = valid_attrs()
    assert {:ok, request} = WebsocketOwnerRequest.new(attrs)
    inspected = inspect(request)

    assert inspected == "#WebsocketOwnerRequest<version: 1>"
    refute inspected =~ attrs.url
    refute inspected =~ attrs.payload
    refute inspected =~ elem(hd(attrs.headers), 1)
    refute inspected =~ attrs.upstream_identity_id
  end

  test "constructs a strict function-free v2 collect envelope" do
    attrs =
      valid_attrs()
      |> Map.put(:version, 2)
      |> Map.put(:websocket_delivery_mode, :collect_compaction)
      |> Map.put(:effective_serving_mode, :full)

    assert {:ok, request} = WebsocketOwnerRequestV2.new(attrs)
    assert request.version == 2
    assert request.websocket_delivery_mode == :collect_compaction
    assert request.effective_serving_mode == :full
    refute contains_function?(request)
    assert inspect(request) == "#WebsocketOwnerRequestV2<version: 2>"

    for {field, value} <- [
          {:version, 1},
          {:websocket_delivery_mode, :relay},
          {:effective_serving_mode, :auto},
          {:effective_serving_mode, "full"}
        ] do
      assert {:error, {:invalid_field, ^field}} =
               attrs |> Map.put(field, value) |> WebsocketOwnerRequestV2.new()
    end

    assert {:error, {:unknown_fields, [:unexpected]}} =
             attrs |> Map.put(:unexpected, true) |> WebsocketOwnerRequestV2.new()

    assert {:error, {:invalid_field, :effective_serving_mode}} =
             attrs |> Map.delete(:effective_serving_mode) |> WebsocketOwnerRequestV2.new()

    assert {:error, {:invalid_field, :envelope}} = WebsocketOwnerRequestV2.new(request)
  end

  test "keeps v1 and v2 closed while accepting a separate capability-bearing v3 envelope" do
    v2_attrs =
      valid_attrs()
      |> Map.put(:version, 2)
      |> Map.put(:websocket_delivery_mode, :collect_compaction)
      |> Map.put(:effective_serving_mode, :full)

    capability = capability()

    v3_attrs =
      Map.merge(v2_attrs, %{
        version: 3,
        owner_admission_capability: capability,
        first_compact_collection: nil
      })

    assert {:ok, request} = WebsocketOwnerRequestV3.new(v3_attrs)
    assert request.owner_admission_capability == capability
    assert inspect(request) == "#WebsocketOwnerRequestV3<version: 3, capability: redacted>"

    assert {:ok, relay_request} =
             v3_attrs
             |> Map.put(:websocket_delivery_mode, :relay)
             |> WebsocketOwnerRequestV3.new()

    assert relay_request.websocket_delivery_mode == :relay
    assert relay_request.owner_admission_capability == capability

    assert {:error, {:unknown_fields, [:owner_admission_capability]}} =
             v2_attrs
             |> Map.put(:owner_admission_capability, capability)
             |> WebsocketOwnerRequestV2.new()

    assert {:error, {:unknown_fields, [:owner_admission_capability]}} =
             valid_attrs()
             |> Map.put(:owner_admission_capability, capability)
             |> WebsocketOwnerRequest.new()

    assert {:error, {:invalid_field, :owner_admission_capability}} =
             v3_attrs
             |> Map.put(:owner_admission_capability, nil)
             |> WebsocketOwnerRequestV3.new()
  end

  @tag :replay_protocol_v2
  test "V4 is a closed redacted replay-only data plane envelope" do
    attrs =
      valid_attrs()
      |> Map.merge(%{
        version: 4,
        websocket_delivery_mode: :relay,
        effective_serving_mode: :full,
        native_replay_binding: replay_binding(),
        native_replay_proof: replay_proof(),
        provisional_token: <<9::256>>
      })

    assert {:ok, request} = WebsocketOwnerRequestV4.new(attrs)
    assert inspect(request) == "#WebsocketOwnerRequestV4<version: 4, replay: redacted>"
    refute inspect(request) =~ Base.encode16(attrs.provisional_token)

    assert {:error, {:unknown_fields, [:owner_admission_capability]}} =
             attrs
             |> Map.put(:owner_admission_capability, capability())
             |> WebsocketOwnerRequestV4.new()
  end

  defp valid_attrs do
    upstream_identity_id = Ecto.UUID.generate()

    %{
      version: 1,
      url: "https://upstream.example.com/backend-api/codex/responses",
      headers: [{"authorization", "synthetic-value"}],
      payload: Jason.encode!(%{"model" => "example-model", "input" => []}),
      timeouts: %TimeoutConfig{
        connect_timeout_ms: 1_000,
        pool_timeout_ms: 1_000,
        receive_timeout_ms: 30_000
      },
      mapper: :codex_responses,
      upstream_identity_id: upstream_identity_id,
      observation: valid_observation(),
      reset_probe: %ResetProbe{
        token: Ecto.UUID.generate(),
        version: 2,
        pool_upstream_assignment_id: Ecto.UUID.generate(),
        upstream_identity_id: upstream_identity_id,
        effective_model: "example-model",
        route_class: "proxy_websocket"
      },
      native_codex_response_control: %TurnSnapshot{models_etag: ~s(W/"models-etag")},
      assignment_advertised?: true,
      connection_bound_continuation?: false,
      forward_error_body?: false,
      submission_notification?: true
    }
  end

  defp valid_observation do
    %{
      request_id: Ecto.UUID.generate(),
      client_request_id: "client-request",
      attempt_id: Ecto.UUID.generate(),
      mode: "full"
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

  defp replay_binding do
    %CodexPooler.Gateway.Transports.Websocket.NativeReplayAdmission.Binding{
      request_id: Ecto.UUID.generate(),
      codex_turn_id: Ecto.UUID.generate(),
      eligible_attempt_id: Ecto.UUID.generate(),
      replay_attempt_id: Ecto.UUID.generate(),
      replay_generation: 1,
      semantic_turn_digest: <<1::256>>,
      replay_claim_digest: <<2::256>>,
      provisional_binding_digest: <<3::256>>,
      owner_lease_digest: <<4::256>>,
      downstream_epoch: 2,
      owner_process_generation: 1
    }
  end

  defp replay_proof do
    RuntimeAdmissionProof.new(
      self(),
      make_ref(),
      make_ref(),
      <<7::256>>,
      :native_replay
    )
  end

  defp contains_function?(value) when is_function(value), do: true

  defp contains_function?(%_{} = struct) do
    struct |> Map.from_struct() |> contains_function?()
  end

  defp contains_function?(value) when is_map(value) do
    Enum.any?(value, fn {key, nested} -> contains_function?(key) or contains_function?(nested) end)
  end

  defp contains_function?(value) when is_list(value), do: Enum.any?(value, &contains_function?/1)

  defp contains_function?(value) when is_tuple(value) do
    value |> Tuple.to_list() |> Enum.any?(&contains_function?/1)
  end

  defp contains_function?(_value), do: false
end
