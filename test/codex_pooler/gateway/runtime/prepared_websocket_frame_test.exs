defmodule CodexPooler.Gateway.Runtime.PreparedWebsocketFrameTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Accounting.Request
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Runtime.Service
  alias CodexPooler.Gateway.Transports.Streaming.PreparedWebsocketFrame
  alias CodexPooler.Gateway.Transports.Streaming.PreparedWebsocketFrame.Capability
  alias CodexPooler.Gateway.Transports.Streaming.WebsocketCodec
  alias CodexPooler.Gateway.Transports.Websocket.NativeReplayAdmission
  alias CodexPooler.Repo

  test "manually assembled prepared frames cannot enter prepared execution" do
    payload = %{"generate" => false, "model" => "gpt-example"}
    request_options = RequestOptions.for_websocket(%{request_id: "manual-prepared"}, payload)

    manually_assembled = %PreparedWebsocketFrame{
      variant: :prewarm,
      endpoint: "/backend-api/codex/responses",
      payload: payload,
      request_options: request_options
    }

    assert {:error, %{status: 400, code: "invalid_request"}} =
             Service.execute_prepared_websocket_response(%{}, manually_assembled)
  end

  test "prepared prewarm execution reuses the built request options and stays row-free" do
    observer = fn -> send(self(), :request_options_built) end
    payload = %{"generate" => false, "model" => "gpt-example"}

    opts =
      %{request_id: "prepared-prewarm"}
      |> RequestOptions.for_websocket(payload)
      |> then(&%{&1 | extra: Map.put(&1.extra, :websocket_preparation_observer, observer)})

    assert {:ok, %PreparedWebsocketFrame{variant: :prewarm} = prepared} =
             Service.prepare_websocket_response(
               Jason.encode!(payload),
               opts,
               fn _frame -> :ok end
             )

    assert_receive :request_options_built
    refute_received :request_options_built
    row_count = Repo.aggregate(Request, :count)

    assert {:ok, prepared_result} =
             Service.execute_prepared_websocket_response(%{}, prepared)

    assert prepared_result == WebsocketCodec.warmup_result()

    assert {:error, %{status: 409, code: "prepared_frame_consumed"}} =
             Service.execute_prepared_websocket_response(%{}, prepared)

    refute_received :request_options_built
    assert Repo.aggregate(Request, :count) == row_count
  end

  test "prepared frame validation is non-consuming and seals replay digest carriers" do
    payload = %{
      "type" => "response.create",
      "model" => "gpt-example",
      "turn_id" => "replay-validation-turn",
      "input" => []
    }

    session = %{id: Ecto.UUID.generate()}

    opts =
      RequestOptions.for_websocket(
        %{request_id: "prepared-replay-validation", codex_session: session},
        payload
      )

    assert {:ok, %PreparedWebsocketFrame{} = prepared} =
             Service.prepare_websocket_response(Jason.encode!(payload), opts, fn _frame -> :ok end)

    assert is_binary(prepared.replay_claim_digest)
    assert byte_size(prepared.replay_claim_digest) == 32
    assert prepared.request_options.continuity.replay_claim_digest == prepared.replay_claim_digest

    assert :ok = WebsocketCodec.validate_prepared_frame(prepared)
    assert :ok = WebsocketCodec.validate_prepared_frame(prepared)

    mutated = %{
      prepared
      | replay_claim_digest: <<9::256>>,
        request_options:
          RequestOptions.put_continuity(prepared.request_options, replay_claim_digest: <<9::256>>)
    }

    assert {:error, :invalid} = WebsocketCodec.validate_prepared_frame(mutated)

    assert {:ok, nil} = WebsocketCodec.consume_prepared_frame(prepared)
    assert {:error, :consumed} = WebsocketCodec.validate_prepared_frame(prepared)
  end

  test "prepared frame seals captured API epoch and session authorization identity" do
    payload = %{
      "type" => "response.create",
      "model" => "gpt-example",
      "turn_id" => "sealed-authorization-turn",
      "input" => []
    }

    session = %{
      id: Ecto.UUID.generate(),
      pool_id: Ecto.UUID.generate(),
      api_key_id: Ecto.UUID.generate(),
      status: "active"
    }

    opts =
      RequestOptions.for_websocket(
        %{
          request_id: "sealed-authorization",
          codex_session: session,
          api_key_runtime_epoch: 3
        },
        payload
      )

    assert {:ok, prepared} =
             Service.prepare_websocket_response(Jason.encode!(payload), opts, fn _frame -> :ok end)

    changed_epoch =
      update_in(prepared.request_options.runtime.api_key_runtime_epoch, fn _epoch -> 4 end)

    changed_session_id =
      update_in(prepared.request_options.continuity.codex_session.id, fn _id ->
        Ecto.UUID.generate()
      end)

    changed_session_pool =
      update_in(prepared.request_options.continuity.codex_session.pool_id, fn _id ->
        Ecto.UUID.generate()
      end)

    changed_session_key =
      update_in(prepared.request_options.continuity.codex_session.api_key_id, fn _id ->
        Ecto.UUID.generate()
      end)

    changed_session_status =
      put_in(prepared.request_options.continuity.codex_session.status, "closed")

    changed_model = put_in(prepared.payload["model"], "gpt-tampered")

    assert :ok = WebsocketCodec.validate_prepared_frame(prepared)

    for changed <- [
          changed_epoch,
          changed_session_id,
          changed_session_pool,
          changed_session_key,
          changed_session_status,
          changed_model
        ] do
      assert {:error, :invalid} = WebsocketCodec.validate_prepared_frame(changed)
    end
  end

  test "malformed non-capability provenance returns bounded invalid results" do
    payload = %{"generate" => false, "model" => "gpt-example"}
    opts = RequestOptions.for_websocket(%{request_id: "malformed-capability"}, payload)

    assert {:ok, prepared} =
             Service.prepare_websocket_response(Jason.encode!(payload), opts, fn _frame -> :ok end)

    malformed = put_in(prepared.provenance.capability, :not_a_capability)

    assert WebsocketCodec.valid_prepared_frame?(malformed) == false
    assert WebsocketCodec.validate_prepared_frame(malformed) == {:error, :invalid}
    assert WebsocketCodec.consume_prepared_frame(malformed) == {:error, :invalid}

    assert {:error, %{status: 400, code: "invalid_request"}} =
             Service.execute_prepared_websocket_response(%{}, malformed)
  end

  @tag :replay_protocol_v2
  test "replay reseal consumes the source and redeems exactly once with the matching proof kind" do
    payload = %{
      "type" => "response.create",
      "model" => "gpt-example",
      "turn_id" => "replay-reseal",
      "input" => []
    }

    opts = RequestOptions.for_websocket(%{codex_session: %{id: Ecto.UUID.generate()}}, payload)

    assert {:ok, prepared} =
             Service.prepare_websocket_response(Jason.encode!(payload), opts, fn _ -> :ok end)

    binding = replay_binding(prepared)
    assert {:ok, resealed} = WebsocketCodec.attach_native_replay_admission(prepared, binding)
    assert {:error, :consumed} = WebsocketCodec.validate_prepared_frame(prepared)
    assert {:ok, proof} = WebsocketCodec.consume_prepared_frame(resealed)
    assert proof.kind == :native_replay

    assert {:error, :invalid} =
             Capability.redeem_runtime_admission(proof, proof.binding_digest, :native_compaction)

    assert {:ok, _redeemed} = NativeReplayAdmission.redeem(proof, binding)
    assert {:error, :replayed} = NativeReplayAdmission.redeem(proof, binding)

    assert {:error, :already_attached} =
             WebsocketCodec.attach_native_replay_admission(resealed, binding)
  end

  defp replay_binding(prepared) do
    %NativeReplayAdmission.Binding{
      request_id: Ecto.UUID.generate(),
      codex_turn_id: Ecto.UUID.generate(),
      eligible_attempt_id: Ecto.UUID.generate(),
      replay_attempt_id: Ecto.UUID.generate(),
      replay_generation: 1,
      semantic_turn_digest: prepared.semantic_turn_key,
      replay_claim_digest: prepared.replay_claim_digest,
      provisional_binding_digest: <<3::256>>,
      owner_lease_digest: <<4::256>>,
      downstream_epoch: 2,
      owner_process_generation: 1
    }
  end

  test "concurrent prepared execution atomically admits exactly one consumer" do
    payload = %{"generate" => false, "model" => "gpt-example"}
    opts = RequestOptions.for_websocket(%{request_id: "prepared-concurrent"}, payload)

    assert {:ok, %PreparedWebsocketFrame{variant: :prewarm} = prepared} =
             Service.prepare_websocket_response(Jason.encode!(payload), opts, fn _frame -> :ok end)

    caller = self()
    start_ref = make_ref()

    tasks =
      for _index <- 1..2 do
        Task.async(fn ->
          send(caller, {:ready, self()})

          receive do
            {:start, ^start_ref} -> Service.execute_prepared_websocket_response(%{}, prepared)
          end
        end)
      end

    task_pids =
      for _index <- 1..2 do
        receive do
          {:ready, pid} -> pid
        end
      end

    Enum.each(task_pids, &send(&1, {:start, start_ref}))
    results = Enum.map(tasks, &Task.await(&1, 1_000))

    assert Enum.count(results, &match?({:ok, _result}, &1)) == 1

    assert Enum.count(
             results,
             &match?({:error, %{status: 409, code: "prepared_frame_consumed"}}, &1)
           ) == 1
  end

  test "prepared capability substitution invalidates the signed frame" do
    payload = %{"generate" => false, "model" => "gpt-example"}
    opts = RequestOptions.for_websocket(%{request_id: "prepared-substitution"}, payload)

    assert {:ok, %PreparedWebsocketFrame{} = prepared} =
             Service.prepare_websocket_response(Jason.encode!(payload), opts, fn _frame -> :ok end)

    substituted = %{
      prepared
      | provenance: %{prepared.provenance | capability: Capability.issue()}
    }

    assert {:error, %{status: 400, code: "invalid_request"}} =
             Service.execute_prepared_websocket_response(%{}, substituted)
  end

  test "malformed input fails before preparation observation or accounting" do
    observer = fn -> send(self(), :request_options_built) end

    opts =
      RequestOptions.for_websocket(%{})
      |> then(&%{&1 | extra: Map.put(&1.extra, :websocket_preparation_observer, observer)})

    row_count = Repo.aggregate(Request, :count)

    assert {:error, %{status: 400, code: "invalid_request"}} =
             Service.prepare_websocket_response("{invalid", opts, fn _frame -> :ok end)

    refute_received :request_options_built
    assert Repo.aggregate(Request, :count) == row_count
  end

  test "prepared response.processed keeps its control path without rebuilding options" do
    observer = fn -> send(self(), :request_options_built) end
    payload = %{"type" => "response.processed", "response_id" => "resp_prepared"}

    opts =
      %{request_id: "prepared-response-processed"}
      |> RequestOptions.for_websocket(payload)
      |> then(&%{&1 | extra: Map.put(&1.extra, :websocket_preparation_observer, observer)})

    assert {:ok, %PreparedWebsocketFrame{variant: :response_processed} = prepared} =
             Service.prepare_websocket_response(
               Jason.encode!(payload),
               opts,
               fn _frame -> :ok end
             )

    assert_receive :request_options_built
    refute_received :request_options_built
    row_count = Repo.aggregate(Request, :count)

    assert {:error, %{code: "upstream_websocket_forward_failed"}} =
             Service.execute_prepared_websocket_response(%{}, prepared)

    refute_received :request_options_built
    assert Repo.aggregate(Request, :count) == row_count
  end
end
