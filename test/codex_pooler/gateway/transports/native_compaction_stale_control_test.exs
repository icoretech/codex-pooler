defmodule CodexPooler.Gateway.NativeCompactionStaleControlTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true
  alias CodexPooler.FakeUpstream
  alias CodexPooler.Gateway.Transports.Streaming.StreamProtocol
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission, as: Admission
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession, as: Owner
  alias Owner.Request

  for action <- [:accounting, :cancel, :ack] do
    test "old generation #{action} preserves current reserved capability" do
      with_owner(fn owner, upstream ->
        {old_binding, old_capability} = reserve(owner, upstream)
        assert :ok = Owner.invalidate_connection(owner)
        {current_binding, current_capability} = reserve(owner, upstream)
        assert current_binding.generation > old_binding.generation
        sends_before = FakeUpstream.count(upstream)
        assert {:error, _} = apply_old(unquote(action), owner, old_binding, old_capability)
        assert Owner.compaction_admission_phase(owner) == :reserved_compact
        assert :ok = Owner.mark_compaction_accounting_started(owner, current_capability, now())
        assert FakeUpstream.count(upstream) == sends_before
      end)
    end
  end

  test "stale cancellation cannot clear current accounting-started admission" do
    with_owner(fn owner, upstream ->
      {_old_binding, old_capability} = reserve(owner, upstream)
      assert :ok = Owner.invalidate_connection(owner)
      {_binding, current_capability} = reserve(owner, upstream)
      assert :ok = Owner.mark_compaction_accounting_started(owner, current_capability, now())
      assert {:error, _} = Owner.cancel_compaction_reservation(owner, old_capability, now())
      assert Owner.compaction_admission_phase(owner) == :accounting_started_compact
    end)
  end

  test "late first-collection authorization cannot replace a current reserved turn" do
    with_owner(fn owner, upstream ->
      {binding, capability} = reserve(owner, upstream)
      stale_binding = %{binding | semantic_turn_key: digest(), window_digest: digest()}

      assert {:error, _} =
               Owner.authorize_first_compact_collection(owner, stale_binding, make_ref())

      assert Owner.compaction_admission_phase(owner) == :reserved_compact
      assert :ok = Owner.mark_compaction_accounting_started(owner, capability, now())
    end)
  end

  test "forged first-collection provenance cannot clear a current reserved turn" do
    with_owner(fn owner, upstream ->
      {binding, capability} = reserve(owner, upstream)
      provenance = Admission.FirstCompactCollection.issue(binding, make_ref())
      assert {:error, _} = Owner.record_first_compact_collected(owner, provenance)
      assert Owner.compaction_admission_phase(owner) == :reserved_compact
      assert :ok = Owner.mark_compaction_accounting_started(owner, capability, now())
    end)
  end

  defp apply_old(:accounting, owner, _binding, capability),
    do: Owner.mark_compaction_accounting_started(owner, capability, now())

  defp apply_old(:cancel, owner, _binding, capability),
    do: Owner.cancel_compaction_reservation(owner, capability, now())

  defp apply_old(:ack, owner, binding, capability) do
    item_digest = digest()

    confirmation = %Admission.Confirmation{
      source_phase: :compact,
      source_control_ref: capability.control_ref,
      binding: %{binding | compaction_item_digest: item_digest}
    }

    Owner.acknowledge_compact_finalization(
      owner,
      {:success, item_digest, confirmation, now() + 30_000}
    )
  end

  defp reserve(owner, upstream) do
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

    assert :ok = Owner.arm_compact(owner, binding, now() + 30_000, result.ordinary_success_result)

    assert {:ok, capability} =
             Owner.reserve_compaction(owner, :compact, binding, make_ref(), now())

    {binding, capability}
  end

  defp with_owner(fun) do
    frame =
      Jason.encode!(%{
        "type" => "response.completed",
        "response" => %{"id" => "resp_ordinary_fixture", "status" => "completed"}
      })

    {:ok, upstream} = FakeUpstream.start_link(FakeUpstream.websocket_text_frames([frame]))
    {:ok, owner} = Owner.start_link([])

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
