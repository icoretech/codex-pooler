defmodule CodexPooler.Gateway.NativeCompactionFirstCollectionTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  @moduletag capture_log: true
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Payloads.NativeCodexTurnMetadata
  alias CodexPooler.Gateway.Persistence.BridgeOwnerLease
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission, as: Admission
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession, as: Owner
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerAdmissionControlV1, as: Control
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession, as: Forwarded
  alias CodexPooler.Gateway.Websocket
  alias Owner.Request

  test "late first collection cannot overwrite a replacement pending turn" do
    with_owner(fn owner, upstream ->
      {binding, ordinary} = connect(owner, upstream)
      assert :ok = Owner.arm_compact(owner, binding, now() + 30_000, ordinary)
      stale = %{binding | semantic_turn_key: digest(), window_digest: digest()}
      assert {:error, _} = Owner.authorize_first_compact_collection(owner, stale, make_ref())
      assert Owner.compaction_admission_phase(owner) == :pending_compact

      assert {:ok, capability} =
               Owner.reserve_compaction(owner, :compact, binding, make_ref(), now())

      assert :ok = Owner.mark_compaction_accounting_started(owner, capability, now())
    end)
  end

  for boundary <- [:pending, :reserved, :accounting, :reconnected] do
    test "ordinary result from earlier request preserves replacement #{boundary}" do
      with_owner(fn owner, upstream ->
        {old_binding, old} = connect(owner, upstream)
        if unquote(boundary) == :reconnected, do: assert(:ok = Owner.invalidate_connection(owner))
        {binding, current} = connect(owner, upstream)
        assert :ok = Owner.arm_compact(owner, binding, now() + 30_000, current)

        capability =
          if unquote(boundary) != :pending do
            {:ok, capability} =
              Owner.reserve_compaction(owner, :compact, binding, make_ref(), now())

            capability
          end

        if unquote(boundary) == :accounting,
          do: assert(:ok = Owner.mark_compaction_accounting_started(owner, capability, now()))

        phase = Owner.compaction_admission_phase(owner)
        sends = FakeUpstream.count(upstream)
        assert {:error, _} = Owner.arm_compact(owner, old_binding, now() + 30_000, old)
        assert Owner.compaction_admission_phase(owner) == phase
        assert FakeUpstream.count(upstream) == sends

        if unquote(boundary) == :pending do
          assert {:ok, capability} =
                   Owner.reserve_compaction(owner, :compact, binding, make_ref(), now())

          assert :ok = Owner.mark_compaction_accounting_started(owner, capability, now())
        end
      end)
    end
  end

  test "ordinary receipt binds response digest and cannot be replayed" do
    with_owner(fn owner, upstream ->
      {binding, receipt} = connect(owner, upstream)

      assert {:error, _} =
               Owner.arm_compact(
                 owner,
                 %{binding | previous_response_digest: digest()},
                 now() + 30_000,
                 receipt
               )

      assert {:error, _} =
               Owner.arm_compact(owner, binding, now() + 30_000, %{
                 receipt
                 | attempt_id: Ecto.UUID.generate()
               })

      assert :ok = Owner.arm_compact(owner, binding, now() + 30_000, receipt)
      assert {:error, _} = Owner.arm_compact(owner, binding, now() + 30_000, receipt)
      assert Owner.compaction_admission_phase(owner) == :pending_compact
    end)
  end

  test "direct reservation snapshot exposes only current pending mode and lifecycle" do
    with_owner(fn owner, upstream ->
      assert {:error, :owner_unavailable} = Owner.compaction_reservation_snapshot(owner)

      request = %{
        collection_request(upstream)
        | websocket_delivery_mode: :relay,
          effective_serving_mode: "lite"
      }

      assert {:ok, result} = Owner.request(owner, request)
      receipt = result.ordinary_success_result
      binding = ordinary_binding(receipt)
      assert :ok = Owner.arm_compact(owner, binding, now() + 30_000, receipt)
      assert {:ok, snapshot} = Owner.compaction_reservation_snapshot(owner)
      assert snapshot == Map.put(receipt.lifecycle, :serving_mode, :lite)
      assert Owner.connection_lifecycle_snapshot(owner) == receipt.lifecycle
      sends = FakeUpstream.count(upstream)

      assert {:error, :binding_mismatch} =
               Owner.reserve_compaction(
                 owner,
                 :compact,
                 %{binding | serving_mode: :full},
                 make_ref(),
                 now()
               )

      assert FakeUpstream.count(upstream) == sends

      assert {:ok, capability} =
               Owner.reserve_compaction(owner, :compact, binding, make_ref(), now())

      assert {:error, :owner_unavailable} = Owner.compaction_reservation_snapshot(owner)
      assert :ok = Owner.mark_compaction_accounting_started(owner, capability, now())
      assert :ok = Owner.invalidate_connection(owner)
      assert {:error, :owner_unavailable} = Owner.compaction_reservation_snapshot(owner)
    end)
  end

  test "direct reservation snapshot rejects expired pending authority" do
    with_owner(fn owner, upstream ->
      {binding, receipt} = connect(owner, upstream)
      assert :ok = Owner.arm_compact(owner, binding, now() - 1, receipt)
      assert {:error, :owner_unavailable} = Owner.compaction_reservation_snapshot(owner)
      assert FakeUpstream.count(upstream) == 1
    end)
  end

  test "forwarded delayed ordinary result preserves current pending and reserved admission" do
    with_owner(fn _direct, upstream ->
      {owner, lease} = start_forwarded_owner!()

      try do
        {:ok, downstream} =
          Forwarded.attach_downstream(owner, %{pid: self(), correlation_id: Ecto.UUID.generate()})

        old = forwarded_ordinary(owner, downstream, upstream)
        current = forwarded_ordinary(owner, downstream, upstream)
        binding = ordinary_binding(current)

        assert {:ok, _} =
                 Forwarded.admission_control(
                   owner,
                   control(:record_ordinary_success, downstream,
                     binding: binding,
                     first_compact_collection: current,
                     expires_at_ms: now() + 30_000
                   )
                 )

        stale =
          control(:record_ordinary_success, downstream,
            binding: ordinary_binding(old),
            first_compact_collection: old,
            expires_at_ms: now() + 30_000
          )

        assert {:error, _} = Forwarded.admission_control(owner, stale)

        assert {:ok, %{phase: :pending_compact}} =
                 Forwarded.admission_control(owner, control(:snapshot, downstream))

        assert {:ok, capability} =
                 Forwarded.admission_control(
                   owner,
                   control(:reserve, downstream,
                     binding: binding,
                     phase: :compact,
                     control_ref: make_ref(),
                     now_ms: now()
                   )
                 )

        assert {:error, _} = Forwarded.admission_control(owner, stale)

        assert {:ok, %{phase: :accounting_started_compact}} =
                 Forwarded.admission_control(
                   owner,
                   control(:mark_accounting_started, downstream,
                     capability: capability,
                     now_ms: now()
                   )
                 )
      after
        stop_forwarded_owner!(owner, lease)
      end
    end)
  end

  defp forwarded_ordinary(owner, downstream, upstream) do
    request = %{collection_request(upstream) | websocket_delivery_mode: :relay}
    assert {:ok, result} = Forwarded.submit_request(owner, downstream, request)
    result.ordinary_success_result
  end

  defp ordinary_binding(receipt) do
    %Admission.Binding{
      semantic_turn_key: digest(),
      window_digest: digest(),
      context_digest: digest(),
      window_number: 1,
      serving_mode: receipt.serving_mode,
      previous_response_digest: receipt.response_digest,
      topology: receipt.topology,
      lifecycle_id: receipt.lifecycle.lifecycle_id,
      generation: receipt.lifecycle.generation
    }
  end

  test "first collection acknowledgement preserves its real owner" do
    with_owner(fn owner, upstream ->
      receipt = collect(owner, upstream)
      binding = receipt.binding
      assert {:ok, provenance} = Owner.authorize_first_compact_collection(owner, binding, receipt)
      assert :ok = Owner.record_first_compact_collected(owner, provenance)
      item_digest = receipt.item_digest

      confirmation = %Admission.Confirmation{
        source_phase: :first_full_history_compact,
        source_control_ref: provenance.control_ref,
        binding: %{binding | compaction_item_digest: item_digest}
      }

      assert :ok =
               Owner.acknowledge_compact_finalization(
                 owner,
                 {:success, item_digest, confirmation, now() + 30_000}
               )

      assert Process.alive?(owner)
      assert Owner.compaction_admission_phase(owner) == :pending_final
      assert {:error, _} = Owner.authorize_first_compact_collection(owner, binding, receipt)
      assert Owner.compaction_admission_phase(owner) == :pending_final
    end)
  end

  test "a real collected result is retired by a newer pending turn" do
    with_owner(fn owner, upstream ->
      receipt = collect(owner, upstream)
      {binding, ordinary} = connect(owner, upstream)
      assert :ok = Owner.arm_compact(owner, binding, now() + 30_000, ordinary)

      assert {:error, _} =
               Owner.authorize_first_compact_collection(owner, receipt.binding, receipt)

      assert {:ok, capability} =
               Owner.reserve_compaction(owner, :compact, binding, make_ref(), now())

      assert :ok = Owner.mark_compaction_accounting_started(owner, capability, now())
    end)
  end

  test "a delayed signed proof cannot erase the current collected request" do
    with_owner(fn owner, upstream ->
      old = collect(owner, upstream)
      assert {:ok, old_proof} = Owner.authorize_first_compact_collection(owner, old.binding, old)
      current = collect(owner, upstream)

      assert {:ok, current_proof} =
               Owner.authorize_first_compact_collection(owner, current.binding, current)

      assert {:error, _} = Owner.record_first_compact_collected(owner, old_proof)
      assert :ok = Owner.record_first_compact_collected(owner, current_proof)
      assert Owner.compaction_admission_phase(owner) == :collected_unconfirmed
    end)
  end

  test "result ownership binds request attempt owner model item and connection" do
    with_owner(fn owner, upstream ->
      receipt = collect(owner, upstream)

      altered = [
        %{receipt | owner: self()},
        %{receipt | result_ref: make_ref()},
        %{receipt | request_id: Ecto.UUID.generate()},
        %{receipt | attempt_id: Ecto.UUID.generate()},
        %{receipt | model_digest: digest()},
        %{receipt | item_digest: digest()},
        %{receipt | binding: %{receipt.binding | generation: receipt.binding.generation + 1}},
        %{receipt | binding: %{receipt.binding | semantic_turn_key: digest()}},
        %{receipt | binding: %{receipt.binding | window_digest: digest()}}
      ]

      sends_before = FakeUpstream.count(upstream)

      for invalid <- altered do
        assert {:error, _} =
                 Owner.authorize_first_compact_collection(owner, invalid.binding, invalid)
      end

      assert {:ok, proof} =
               Owner.authorize_first_compact_collection(owner, receipt.binding, receipt)

      assert :ok = Owner.record_first_compact_collected(owner, proof)
      assert FakeUpstream.count(upstream) == sends_before
    end)
  end

  test "an intervening accepted request retires the earlier result" do
    with_owner(fn owner, upstream ->
      receipt = collect(owner, upstream)
      connect(owner, upstream)

      assert {:error, _} =
               Owner.authorize_first_compact_collection(owner, receipt.binding, receipt)

      current = collect(owner, upstream)

      assert {:ok, proof} =
               Owner.authorize_first_compact_collection(owner, current.binding, current)

      assert :ok = Owner.record_first_compact_collected(owner, proof)
    end)
  end

  defp collect(owner, upstream) do
    request = collection_request(upstream)
    assert {:ok, result} = Owner.request(owner, request)
    assert %Admission.FirstCompactResult{} = receipt = Map.get(result, :first_compact_result)
    receipt
  end

  test "forwarded first result authorizes once and acknowledges without closing owner" do
    with_owner(fn _direct, upstream ->
      {owner, lease} = start_forwarded_owner!()

      try do
        {:ok, downstream} =
          Forwarded.attach_downstream(owner, %{pid: self(), correlation_id: Ecto.UUID.generate()})

        assert {:ok, result} =
                 Forwarded.submit_request(owner, downstream, collection_request(upstream))

        assert %Admission.FirstCompactResult{} = receipt = result.first_compact_result
        assert receipt.owner == owner

        authorize =
          control(:authorize_first_compact_collection, downstream,
            binding: receipt.binding,
            control_ref: receipt.result_ref,
            first_compact_collection: receipt
          )

        assert {:ok, proof} = Forwarded.admission_control(owner, authorize)
        assert {:error, _} = Forwarded.admission_control(owner, authorize)

        assert {:ok, _} =
                 Forwarded.admission_control(
                   owner,
                   control(:record_first_compact_collected, downstream,
                     first_compact_collection: proof
                   )
                 )

        confirmation = %Admission.Confirmation{
          source_phase: :first_full_history_compact,
          source_control_ref: proof.control_ref,
          binding: %{receipt.binding | compaction_item_digest: receipt.item_digest}
        }

        assert {:ok, _} =
                 Forwarded.admission_control(
                   owner,
                   control(:finalization_ack, downstream,
                     success?: true,
                     compaction_item_digest: receipt.item_digest,
                     confirmation: confirmation,
                     expires_at_ms: now() + 30_000
                   )
                 )

        assert Process.alive?(owner)

        assert {:ok, %{phase: :pending_final}} =
                 Forwarded.admission_control(owner, control(:snapshot, downstream))
      after
        stop_forwarded_owner!(owner, lease)
      end
    end)
  end

  defp control(action, downstream, extra \\ []) do
    attrs = struct(Control) |> Map.from_struct() |> Map.new(fn {key, _} -> {key, nil} end)

    attrs =
      Map.merge(attrs, %{
        version: 1,
        action: action,
        downstream: Map.take(downstream, [:pid, :epoch, :correlation_id])
      })

    {:ok, control} = Control.new(Map.merge(attrs, Map.new(extra)))
    control
  end

  defp collection_request(upstream) do
    metadata = %NativeCodexTurnMetadata{
      request_kind: :compaction,
      semantic_turn_key: digest(),
      window_id_digest: digest(),
      context_window_id_digest: digest(),
      window_number: 1
    }

    %Request{
      url: FakeUpstream.url(upstream) <> "/backend-api/codex/responses",
      headers: [],
      payload:
        Jason.encode!(%{
          "model" => "sample-model",
          "input" => [
            %{"role" => "user", "content" => "sample"},
            %{"type" => "compaction_trigger"}
          ]
        }),
      timeouts: %{connect_timeout_ms: 5_000, receive_timeout_ms: 5_000},
      request_id: Ecto.UUID.generate(),
      attempt_id: Ecto.UUID.generate(),
      websocket_delivery_mode: :collect_full_history,
      effective_serving_mode: "full",
      native_compaction_metadata: metadata,
      message_mapper: &StreamProtocol.canonicalize_native_codex_responses_json_message/1
    }
  end

  test "stale reservation cannot clear the current pending turn" do
    with_owner(fn owner, upstream ->
      {binding, ordinary} = connect(owner, upstream)
      assert :ok = Owner.arm_compact(owner, binding, now() + 30_000, ordinary)
      stale = %{binding | semantic_turn_key: digest()}
      assert {:error, _} = Owner.reserve_compaction(owner, :compact, stale, make_ref(), now())
      assert Owner.compaction_admission_phase(owner) == :pending_compact

      assert {:ok, capability} =
               Owner.reserve_compaction(owner, :compact, binding, make_ref(), now())

      assert :ok = Owner.mark_compaction_accounting_started(owner, capability, now())
    end)
  end

  defp connect(owner, upstream) do
    request = %Request{
      url: FakeUpstream.url(upstream) <> "/backend-api/codex/responses",
      headers: [],
      payload: ~s({"model":"sample-model"}),
      request_id: Ecto.UUID.generate(),
      attempt_id: Ecto.UUID.generate(),
      effective_serving_mode: "full",
      timeouts: %{connect_timeout_ms: 5_000, receive_timeout_ms: 5_000},
      writer: fn _frame -> :ok end,
      message_mapper: &StreamProtocol.canonicalize_native_codex_responses_json_message/1
    }

    assert {:ok, result} = Owner.request(owner, request)
    lifecycle = Owner.connection_lifecycle_snapshot(owner)

    binding = %Admission.Binding{
      previous_response_digest: result.ordinary_success_result.response_digest,
      semantic_turn_key: digest(),
      window_digest: digest(),
      context_digest: digest(),
      window_number: 1,
      serving_mode: :full,
      topology: %Admission.Topology.Direct{},
      lifecycle_id: lifecycle.lifecycle_id,
      generation: lifecycle.generation
    }

    {binding, result.ordinary_success_result}
  end

  defp start_forwarded_owner! do
    %{raw_key: raw_key} = active_api_key_fixture()
    assert {:ok, auth} = CodexPooler.Access.authenticate_api_key(raw_key)
    assert {:ok, session} = Websocket.start_codex_session(auth, %{})
    lease = Repo.get_by!(BridgeOwnerLease, codex_session_id: session.id)
    assert lease.status == "active"
    assert lease.lease_token == session.owner_lease_token

    assert {:ok, owner} =
             Forwarded.start_owner(
               codex_session_id: session.id,
               owner_instance_id: session.owner_instance_id,
               owner_lease_token: session.owner_lease_token
             )

    {owner, lease}
  end

  defp stop_forwarded_owner!(owner, lease) do
    monitor = Process.monitor(owner)
    if Process.alive?(owner), do: GenServer.stop(owner, :normal, 15_000)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 15_000
    assert %{status: "released", released_at: %DateTime{}} = Repo.reload!(lease)
  end

  defp with_owner(fun) do
    item =
      Jason.encode!(%{
        "type" => "response.output_item.done",
        "item" => %{"type" => "compaction", "encrypted_content" => "synthetic-compact"}
      })

    frame =
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => "resp_ordinary_fixture", "status" => "completed"}
      })

    {:ok, upstream} = FakeUpstream.start_link(FakeUpstream.websocket_text_frames([item, frame]))
    {:ok, owner} = Owner.start_link([])
    Process.unlink(owner)

    try do
      fun.(owner, upstream)
    after
      if Process.alive?(owner), do: GenServer.stop(owner, :normal, 15_000)
      FakeUpstream.stop(upstream)
    end
  end

  defp now, do: System.system_time(:millisecond)
  defp digest, do: :crypto.strong_rand_bytes(32)
end
