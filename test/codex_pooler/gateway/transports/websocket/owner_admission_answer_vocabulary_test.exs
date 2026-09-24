defmodule CodexPooler.Gateway.Transports.Websocket.OwnerAdmissionAnswerVocabularyTest do
  use CodexPooler.DataCase, async: false

  @moduletag capture_log: true

  alias CodexPooler.Gateway.Transports.OrdinarySuccessTestSeed
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerAdmissionControlV1
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerContract
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerForwarder
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Transports.WebsocketOwnerNodeHarness

  # Every native compaction admission answer leaves the owner's node through
  # `WebsocketOwnerForwarder.remote_admission_control_v1/2`, for a socket on
  # that node and for one on another node alike. This drives a real owner
  # session through that function into every refusal the admission walk can
  # reach and checks each one comes back as the owner gave it, inside the
  # vocabulary the calling node passes through: a refusal outside it would
  # read `owner_crashed` on a remote owner only (findings#206 row 206-402).
  test "every refusal a real owner answers through the owner-node boundary is passed through unchanged", context do
    codex_session_id = "codex-session-#{System.unique_integer([:positive])}"
    lease_token = "owner-token-#{System.unique_integer([:positive])}"
    instance_id = Atom.to_string(node())
    on_exit(fn -> cleanup_owner_session(codex_session_id) end)

    upstream = WebsocketOwnerNodeHarness.fake_upstream_boundary(self())
    {boundary, seed_url} = OrdinarySuccessTestSeed.boundary(upstream)

    assert {:ok, owner} =
             WebsocketOwnerSession.start_owner(
               codex_session_id: codex_session_id,
               owner_lease_token: lease_token,
               owner_instance_id: instance_id,
               upstream: boundary
             )

    assert_receive {:websocket_owner_harness_upstream_started, _upstream_pid}

    assert {:ok, downstream} =
             WebsocketOwnerSession.attach_downstream(owner, %{pid: self(), correlation_id: "vocabulary-#{context.test}"})

    ids = %{instance_id: instance_id, lease_token: lease_token}
    now = System.system_time(:millisecond)
    expires = now + 30_000
    answer = fn action, attrs -> WebsocketOwnerForwarder.remote_admission_control_v1(codex_session_id, control(action, downstream, attrs)) end

    stale_downstream = %{downstream | epoch: downstream.epoch + 1}

    assert {:error, :stale_downstream} =
             WebsocketOwnerForwarder.remote_admission_control_v1(codex_session_id, control(:snapshot, stale_downstream, []))

    # No admission yet: a reservation falls through to the owner's own refusal.
    unseeded = forwarded_binding(ids, downstream)

    assert {:error, :invalid_transition} =
             answer.(:reserve, binding: unseeded, phase: :compact, control_ref: make_ref(), now_ms: now)

    {binding, receipt} = OrdinarySuccessTestSeed.request(owner, downstream, forwarded_binding(ids, downstream), seed_url)
    foreign_lease = %{binding | topology: WebsocketOwnerAdmissionControlV1.forwarded_topology(instance_id, "foreign-lease", downstream.epoch)}

    assert {:error, :binding_mismatch} =
             answer.(:record_ordinary_success, binding: foreign_lease, first_compact_collection: receipt, expires_at_ms: expires)

    assert {:ok, pending} =
             answer.(:record_ordinary_success, binding: binding, first_compact_collection: receipt, expires_at_ms: expires)

    assert NativeCompactionAdmission.phase(pending) == :pending_compact

    assert {:error, :expired} =
             answer.(:reserve, binding: binding, phase: :compact, control_ref: make_ref(), now_ms: expires + 1)

    assert {:error, :binding_mismatch} =
             answer.(:reserve, binding: %{binding | semantic_turn_key: <<9::256>>}, phase: :compact, control_ref: make_ref(), now_ms: now)

    assert {:error, :invalid_transition} =
             answer.(:reserve, binding: binding, phase: :final, control_ref: make_ref(), now_ms: now)

    assert {:ok, %NativeCompactionAdmission.Capability{} = capability} =
             answer.(:reserve, binding: binding, phase: :compact, control_ref: make_ref(), now_ms: now)

    forged = %{capability | token: :crypto.strong_rand_bytes(byte_size(capability.token))}

    assert {:error, :capability_mismatch} =
             answer.(:mark_accounting_started, capability: forged, now_ms: now)

    assert {:ok, _accounting} = answer.(:mark_accounting_started, capability: capability, now_ms: now)

    assert {:error, :committed} =
             answer.(:cancel, capability: capability, disposition: :pre_accounting, now_ms: now)

    assert {:error, :capability_mismatch} = answer.(:clear, capability: forged)

    driven = [:stale_downstream, :invalid_transition, :binding_mismatch, :expired, :capability_mismatch, :committed]

    for reason <- driven do
      assert NativeCompactionAdmission.refusal_reason?(reason) or WebsocketOwnerContract.owner_error?(reason),
             "#{reason} is outside the vocabulary a remote caller passes through"
    end
  end

  defp forwarded_binding(ids, downstream) do
    %NativeCompactionAdmission.Binding{
      semantic_turn_key: <<1::256>>,
      window_digest: <<2::256>>,
      context_digest: <<3::256>>,
      window_number: 1,
      previous_response_digest: nil,
      serving_mode: :full,
      topology: WebsocketOwnerAdmissionControlV1.forwarded_topology(ids.instance_id, ids.lease_token, downstream.epoch),
      lifecycle_id: Ecto.UUID.generate(),
      generation: 1
    }
  end

  defp control(action, downstream, attrs) do
    defaults = %{
      version: 1,
      action: action,
      downstream: Map.take(downstream, [:pid, :epoch, :correlation_id]),
      binding: nil,
      phase: nil,
      control_ref: nil,
      capability: nil,
      disposition: nil,
      success?: nil,
      compaction_item_digest: nil,
      confirmation: nil,
      first_compact_collection: nil,
      expires_at_ms: nil,
      now_ms: nil
    }

    {:ok, control} = defaults |> Map.merge(Map.new(attrs)) |> WebsocketOwnerAdmissionControlV1.new()
    control
  end

  defp cleanup_owner_session(codex_session_id) do
    case WebsocketOwnerSession.lookup(codex_session_id) do
      {:ok, owner} ->
        owner_ref = Process.monitor(owner)
        _result = GenServer.stop(owner, :normal, 15_000)

        receive do
          {:DOWN, ^owner_ref, :process, ^owner, _reason} -> :ok
        after
          15_000 -> flunk("websocket owner did not terminate during test cleanup")
        end

      {:error, :owner_unavailable} ->
        :ok
    end
  catch
    :exit, _reason -> :ok
  end
end
