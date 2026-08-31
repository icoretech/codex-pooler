defmodule CodexPooler.Gateway.Transports.Streaming.WebsocketCodecTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Payloads.{CompactionTrigger, RequestOptions}
  alias CodexPooler.Gateway.Transports.Streaming.PreparedWebsocketFrame
  alias CodexPooler.Gateway.Transports.Streaming.{StreamProtocol, WebsocketCodec}
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerAdmissionControlV1

  @remote_compaction_v2_fixture_path Path.expand(
                                       "../../../fixtures/codex/rust-v0.150.0-3b3b4f8fb3f6403e72c2d0533ed0d2f309c59717/remote_compaction_v2_request.json",
                                       __DIR__
                                     )
  @external_resource @remote_compaction_v2_fixture_path

  @remote_compaction_v2_incremental_fixture_path Path.expand(
                                                   "../../../fixtures/codex/rust-v0.150.0-3b3b4f8fb3f6403e72c2d0533ed0d2f309c59717/remote_compaction_v2_incremental_request.json",
                                                   __DIR__
                                                 )
  @external_resource @remote_compaction_v2_incremental_fixture_path

  describe "decode_payload/1" do
    test "accepts response.create through the generic object contract" do
      payload = Jason.encode!(%{"type" => "response.create", "model" => "gpt-example"})

      assert {:ok, %{"type" => "response.create", "model" => "gpt-example"}} =
               WebsocketCodec.decode_payload(payload)
    end

    test "rejects invalid JSON and non-object JSON" do
      assert WebsocketCodec.decode_payload("[1,2,3]") == {:error, :not_object}
      assert WebsocketCodec.decode_payload("{invalid") == {:error, :invalid_json}
    end
  end

  describe "prepare_frame/3" do
    test "rejects malformed native input and tools before sealing" do
      for {updates, param} <- [
            {%{"input" => "synthetic scalar input"}, "input"},
            {%{"input" => [], "tools" => "synthetic non-list tools"}, "tools"}
          ] do
        payload =
          Map.merge(
            %{"type" => "response.create", "model" => "gpt-example"},
            updates
          )

        assert {:error, %{status: 400, code: "invalid_request", param: ^param}} =
                 WebsocketCodec.prepare_frame(
                   Jason.encode!(payload),
                   native_responses_options(payload),
                   fn _frame -> :ok end
                 )
      end
    end

    test "native validation claims are exact and survive admission resealing" do
      payload = %{
        "type" => "response.create",
        "model" => "gpt-example",
        "input" => [],
        "turn_id" => Ecto.UUID.generate()
      }

      assert {:ok, prepared} =
               WebsocketCodec.prepare_frame(
                 Jason.encode!(payload),
                 direct_responses_options(payload),
                 fn _frame -> :ok end
               )

      assert prepared.provenance.validation.completed == [
               :strict_schema,
               :input_shape,
               :payload
             ]

      admission = direct_admission(prepared)

      assert {:ok, replacement} =
               WebsocketCodec.attach_native_compaction_admission(prepared, admission)

      assert replacement.provenance.validation.completed ==
               prepared.provenance.validation.completed

      assert replacement.provenance.validation.version == prepared.provenance.validation.version
    end

    test "admission resealing rejects a source frame with mutated validation claims" do
      payload = %{
        "type" => "response.create",
        "model" => "gpt-example",
        "input" => [],
        "turn_id" => Ecto.UUID.generate()
      }

      assert {:ok, prepared} =
               WebsocketCodec.prepare_frame(
                 Jason.encode!(payload),
                 direct_responses_options(payload),
                 fn _frame -> :ok end
               )

      admission = direct_admission(prepared)

      forged =
        put_in(prepared.provenance.validation.completed, [])

      assert {:error, :invalid} =
               WebsocketCodec.attach_native_compaction_admission(forged, admission)

      assert {:ok, nil} = WebsocketCodec.consume_prepared_frame(prepared)
    end

    test "admission attachment cross-checks actual owner topology and serving mode" do
      for {prepared_topology, prepared_mode, capability_topology, capability_mode, expected} <- [
            {:direct, :full, :direct, :full, :ok},
            {:direct, :lite, :direct, :lite, :ok},
            {:forwarded, :full, :forwarded, :full, :ok},
            {:forwarded, :lite, :forwarded, :lite, :ok},
            {:direct, :full, :forwarded, :full, :binding_mismatch},
            {:forwarded, :full, :direct, :full, :binding_mismatch},
            {:direct, :full, :direct, :lite, :binding_mismatch},
            {:forwarded, :lite, :forwarded, :full, :binding_mismatch}
          ] do
        {prepared, owner} = prepared_admission_frame(prepared_topology, prepared_mode)
        admission = admission_for(prepared, owner, capability_topology, capability_mode)

        case expected do
          :ok ->
            assert {:ok, replacement} =
                     WebsocketCodec.attach_native_compaction_admission(prepared, admission)

            assert {:ok, %CodexPooler.Gateway.Transports.Streaming.RuntimeAdmissionProof{}} =
                     WebsocketCodec.consume_prepared_frame(replacement)

          :binding_mismatch ->
            assert {:error, :binding_mismatch} =
                     WebsocketCodec.attach_native_compaction_admission(prepared, admission)

            assert {:error, :consumed} = WebsocketCodec.consume_prepared_frame(prepared)
        end
      end
    end

    test "deferred Lite admission seals before routing resolution and still rejects a resolved Full mismatch" do
      {prepared, owner} = prepared_admission_frame(:forwarded, nil)
      admission = admission_for(prepared, owner, :forwarded, :lite)

      assert {:ok, replacement} =
               WebsocketCodec.attach_native_compaction_admission(prepared, admission)

      assert RequestOptions.model_serving_mode_snapshot(replacement.request_options) == nil

      assert {:ok, %CodexPooler.Gateway.Transports.Streaming.RuntimeAdmissionProof{}} =
               WebsocketCodec.consume_prepared_frame(replacement)

      {resolved_full, resolved_owner} = prepared_admission_frame(:forwarded, :full)
      lite_admission = admission_for(resolved_full, resolved_owner, :forwarded, :lite)

      assert {:error, :binding_mismatch} =
               WebsocketCodec.attach_native_compaction_admission(resolved_full, lite_admission)
    end

    test "post-compaction summary is a native final input variant" do
      payload = %{
        "type" => "response.create",
        "model" => "gpt-example",
        "input" => [
          %{"type" => "message", "content" => "synthetic follow-up"},
          %{"type" => "compaction_summary", "encrypted_content" => "synthetic-summary"}
        ],
        "turn_id" => Ecto.UUID.generate()
      }

      assert {:ok, prepared} =
               WebsocketCodec.prepare_frame(
                 Jason.encode!(payload),
                 direct_responses_options(payload),
                 fn _frame -> :ok end
               )

      assert Enum.any?(
               prepared.payload["input"],
               &match?(%{"type" => "compaction_summary"}, &1)
             )
    end

    test "one typed admission attachment consumes the original and seals one replacement" do
      payload = %{
        "type" => "response.create",
        "model" => "gpt-example",
        "input" => [],
        "turn_id" => Ecto.UUID.generate()
      }

      assert {:ok, prepared} =
               WebsocketCodec.prepare_frame(
                 Jason.encode!(payload),
                 direct_responses_options(payload),
                 fn _frame -> :ok end
               )

      admission = direct_admission(prepared)

      assert {:ok, replacement} =
               WebsocketCodec.attach_native_compaction_admission(prepared, admission)

      assert replacement.request_options.runtime == prepared.request_options.runtime
      assert replacement.request_options.native_compaction_admission == admission
      assert {:error, :consumed} = WebsocketCodec.consume_prepared_frame(prepared)

      assert {:ok, %CodexPooler.Gateway.Transports.Streaming.RuntimeAdmissionProof{}} =
               WebsocketCodec.consume_prepared_frame(replacement)

      assert {:error, :consumed} = WebsocketCodec.consume_prepared_frame(replacement)

      assert {:error, :consumed} =
               WebsocketCodec.attach_native_compaction_admission(prepared, admission)

      assert {:error, :already_attached} =
               WebsocketCodec.attach_native_compaction_admission(replacement, admission)
    end

    test "runtime admission proof redeems once and rejects copied or mismatched bindings" do
      payload = %{
        "type" => "response.create",
        "model" => "gpt-example",
        "input" => [],
        "turn_id" => Ecto.UUID.generate()
      }

      {:ok, prepared} =
        WebsocketCodec.prepare_frame(
          Jason.encode!(payload),
          direct_responses_options(payload),
          fn _frame -> :ok end
        )

      admission = direct_admission(prepared)
      {:ok, replacement} = WebsocketCodec.attach_native_compaction_admission(prepared, admission)
      {:ok, proof} = WebsocketCodec.consume_prepared_frame(replacement)

      {:ok, digest} =
        RequestOptions.native_compaction_admission_digest(
          replacement.request_options,
          replacement.variant
        )

      assert {:error, :invalid} =
               PreparedWebsocketFrame.Capability.redeem_runtime_admission(
                 proof,
                 :crypto.hash(:sha256, "mismatch")
               )

      assert {:error, :replayed} =
               PreparedWebsocketFrame.Capability.redeem_runtime_admission(proof, digest)

      {:ok, prepared2} =
        WebsocketCodec.prepare_frame(
          Jason.encode!(payload),
          direct_responses_options(payload),
          fn _frame -> :ok end
        )

      admission2 = direct_admission(prepared2)

      {:ok, replacement2} =
        WebsocketCodec.attach_native_compaction_admission(prepared2, admission2)

      {:ok, proof2} = WebsocketCodec.consume_prepared_frame(replacement2)

      {:ok, digest2} =
        RequestOptions.native_compaction_admission_digest(
          replacement2.request_options,
          replacement2.variant
        )

      results =
        1..2
        |> Task.async_stream(
          fn _ ->
            PreparedWebsocketFrame.Capability.redeem_runtime_admission(proof2, digest2)
          end,
          max_concurrency: 2,
          ordered: false
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, _uuid}, &1)) == 1
      assert Enum.count(results, &match?({:error, :replayed}, &1)) == 1
    end

    test "admission attachment rejects mismatched binding and consumes the source frame" do
      payload = %{
        "type" => "response.create",
        "model" => "gpt-example",
        "input" => [],
        "turn_id" => Ecto.UUID.generate()
      }

      {:ok, prepared} =
        WebsocketCodec.prepare_frame(
          Jason.encode!(payload),
          direct_responses_options(payload),
          fn _frame -> :ok end
        )

      admission = direct_admission(prepared)
      capability = admission.capability
      mismatched_binding = %{capability.binding | semantic_turn_key: <<9::256>>}
      mismatched_capability = %{capability | binding: mismatched_binding}

      mismatched_admission = %{
        admission
        | capability: mismatched_capability,
          expected_connection_lifecycle: %{
            lifecycle_id: mismatched_binding.lifecycle_id,
            generation: mismatched_binding.generation
          }
      }

      assert {:error, :binding_mismatch} =
               WebsocketCodec.attach_native_compaction_admission(prepared, mismatched_admission)

      assert {:error, :consumed} = WebsocketCodec.consume_prepared_frame(prepared)
    end

    test "returns typed native, public, prewarm, and response.processed variants" do
      session_id = Ecto.UUID.generate()
      turn_id = Ecto.UUID.generate()
      writer = fn _frame -> :ok end

      native = %{
        "type" => "response.create",
        "model" => "gpt-example",
        "input" => [],
        "turn_id" => turn_id
      }

      assert {:ok, %PreparedWebsocketFrame{variant: :native_response_create} = prepared_native} =
               WebsocketCodec.prepare_frame(
                 Jason.encode!(native),
                 native_responses_options(native, session_id),
                 writer
               )

      assert %RequestOptions{} = prepared_native.request_options

      assert prepared_native.provenance.validation.completed == [
               :strict_schema,
               :input_shape,
               :payload
             ]

      assert is_binary(prepared_native.semantic_turn_key)
      assert is_binary(prepared_native.turn_claim_key)

      assert prepared_native.semantic_turn_key ==
               prepared_native.request_options.continuity.semantic_turn_key

      assert prepared_native.turn_claim_key ==
               prepared_native.request_options.continuity.turn_claim_key

      refute Map.has_key?(Map.from_struct(prepared_native), :turn_id)
      refute inspect(prepared_native) =~ turn_id
      refute Map.has_key?(prepared_native.payload, "turn_id")

      canonical_turn_id = "canonical-#{System.unique_integer([:positive])}"

      canonical = %{
        "type" => "response.create",
        "model" => "gpt-example",
        "input" => [],
        "client_metadata" => %{
          "x-codex-turn-metadata" =>
            Jason.encode!(%{"turn_id" => canonical_turn_id, "request_kind" => "turn"})
        }
      }

      assert {:ok, %PreparedWebsocketFrame{} = prepared_canonical} =
               WebsocketCodec.prepare_frame(
                 Jason.encode!(canonical),
                 native_responses_options(canonical, session_id),
                 writer
               )

      refute inspect(prepared_canonical) =~ canonical_turn_id

      assert %{"request_kind" => "turn"} =
               prepared_canonical.payload
               |> get_in(["client_metadata", "x-codex-turn-metadata"])
               |> Jason.decode!()

      public = %{"type" => "response.create", "model" => "gpt-example", "input" => "example"}

      assert {:ok, %PreparedWebsocketFrame{variant: :public_response_create} = prepared_public} =
               WebsocketCodec.prepare_frame(
                 Jason.encode!(public),
                 public_responses_options(public),
                 writer
               )

      assert prepared_public.provenance.validation.completed == []

      prewarm = %{"generate" => false, "model" => "gpt-example"}

      assert {:ok, %PreparedWebsocketFrame{variant: :prewarm}} =
               WebsocketCodec.prepare_frame(
                 Jason.encode!(prewarm),
                 native_responses_options(prewarm),
                 writer
               )

      released_prewarm = %{
        "type" => "response.create",
        "generate" => false,
        "model" => "gpt-example",
        "client_metadata" => %{
          "x-codex-turn-metadata" =>
            Jason.encode!(%{
              "session_id" => "untrusted-session",
              "thread_id" => Ecto.UUID.generate(),
              "turn_id" => "",
              "request_kind" => "prewarm",
              "sandbox_mode" => "read-only"
            })
        }
      }

      assert {:ok, %PreparedWebsocketFrame{variant: :prewarm} = prepared_prewarm} =
               WebsocketCodec.prepare_frame(
                 Jason.encode!(released_prewarm),
                 native_responses_options(released_prewarm),
                 writer
               )

      assert prepared_prewarm.semantic_turn_key == nil
      assert prepared_prewarm.turn_claim_key == nil
      assert prepared_prewarm.request_options.continuity.semantic_turn_key == nil
      assert prepared_prewarm.request_options.continuity.turn_claim_key == nil

      processed = %{"type" => "response.processed", "response_id" => "resp_example"}

      assert {:ok, %PreparedWebsocketFrame{variant: :response_processed}} =
               WebsocketCodec.prepare_frame(
                 Jason.encode!(processed),
                 native_responses_options(processed),
                 writer
               )
    end

    test "defaults an omitted native response type without relaxing the public websocket contract" do
      native = %{"model" => "gpt-example", "input" => []}

      assert {:ok, %PreparedWebsocketFrame{variant: :native_response_create}} =
               WebsocketCodec.prepare_frame(
                 Jason.encode!(native),
                 native_responses_options(native),
                 fn _frame -> :ok end
               )

      public = %{"model" => "gpt-example", "input" => "public input"}

      assert {:error,
              %{
                status: 400,
                code: "invalid_request",
                message: "websocket message type is not supported",
                param: "type"
              }} =
               WebsocketCodec.prepare_frame(
                 Jason.encode!(public),
                 public_responses_options(public),
                 fn _frame -> :ok end
               )
    end

    test "rejects malformed frames before invoking the preparation observer" do
      observer = fn -> send(self(), :prepared_request_options) end

      opts =
        %{"type" => "response.create", "model" => "gpt-example"}
        |> native_responses_options()
        |> then(&%{&1 | extra: Map.put(&1.extra, :websocket_preparation_observer, observer)})

      invalid_frames = [
        {"{invalid", nil},
        {Jason.encode!(["not-object"]), nil},
        {Jason.encode!(%{"type" => "response.create", "model" => 123}), "model"},
        {Jason.encode!(%{
           "type" => "response.create",
           "model" => "gpt-example",
           "turn_id" => "bad/id"
         }), "turn_id"},
        {Jason.encode!(%{"type" => "response.processed"}), nil}
      ]

      for {frame, param} <- invalid_frames do
        assert {:error, %{status: 400, code: "invalid_request", param: ^param}} =
                 WebsocketCodec.prepare_frame(frame, opts, fn _frame -> :ok end)

        refute_received :prepared_request_options
      end
    end

    test "assigns deterministic request claims only to validated ordinary native tool continuations" do
      session_id = "018f60df-713f-7ca8-b9a0-0d12c508a901"
      turn_id = "turn-request-claim"
      anchor = native_request_claim_payload(turn_id, nil, [])

      assert {:ok, anchor_prepared} =
               WebsocketCodec.prepare_frame(
                 Jason.encode!(anchor),
                 native_responses_options(anchor, session_id),
                 fn _frame -> :ok end
               )

      assert anchor_prepared.request_options.continuity.request_claim_key ==
               anchor_prepared.turn_claim_key

      continuation =
        native_request_claim_payload(turn_id, "resp_claim_0001", [
          %{
            "type" => "function_call_output",
            "call_id" => "call_claim_0001",
            "output" => %{"status" => "ok"}
          }
        ])

      assert {:ok, continuation_prepared} =
               WebsocketCodec.prepare_frame(
                 Jason.encode!(continuation),
                 native_responses_options(continuation, session_id),
                 fn _frame -> :ok end
               )

      assert continuation_prepared.semantic_turn_key == anchor_prepared.semantic_turn_key
      assert continuation_prepared.turn_claim_key == anchor_prepared.turn_claim_key

      assert continuation_prepared.request_options.continuity.request_claim_key =~
               ~r/\Acodex-request:[A-Za-z0-9_-]{43}\z/

      refute continuation_prepared.request_options.continuity.request_claim_key ==
               continuation_prepared.turn_claim_key

      released_continuation =
        continuation
        |> Map.delete("previous_response_id")
        |> put_in(
          ["client_metadata", "x-codex-turn-metadata"],
          Jason.encode!(%{
            "turn_id" => turn_id,
            "request_kind" => "turn",
            "window_id" => "window-released-continuation",
            "window_number" => 1,
            "context_window_id" => "00000000-0000-4000-8000-000000000151"
          })
        )

      assert {:ok, released_prepared} =
               WebsocketCodec.prepare_frame(
                 Jason.encode!(released_continuation),
                 native_responses_options(released_continuation, session_id),
                 fn _frame -> :ok end
               )

      assert released_prepared.request_options.continuity.request_claim_key =~
               ~r/\Acodex-request:[A-Za-z0-9_-]{43}\z/

      refute released_prepared.request_options.continuity.request_claim_key ==
               released_prepared.turn_claim_key

      assert {:ok, replay_prepared} =
               WebsocketCodec.prepare_frame(
                 Jason.encode!(continuation),
                 native_responses_options(continuation, session_id),
                 fn _frame -> :ok end
               )

      assert replay_prepared.request_options.continuity.request_claim_key ==
               continuation_prepared.request_options.continuity.request_claim_key

      assert {:ok, direct_prepared} =
               WebsocketCodec.prepare_frame(
                 Jason.encode!(continuation),
                 direct_responses_options(continuation),
                 fn _frame -> :ok end
               )

      assert direct_prepared.request_options.continuity.request_claim_key =~
               ~r/\Acodex-request:[A-Za-z0-9_-]{43}\z/

      admission = direct_admission(direct_prepared)

      assert {:ok, compaction_admitted} =
               WebsocketCodec.attach_native_compaction_admission(
                 direct_prepared,
                 admission
               )

      assert compaction_admitted.request_options.continuity.request_claim_key ==
               compaction_admitted.turn_claim_key
    end

    test "falls back to the logical turn claim for non-tool, public, and native compaction paths" do
      turn_id = "turn-fallback-claim"

      non_tool =
        native_request_claim_payload(turn_id, "resp_non_tool", [
          %{"type" => "message", "role" => "user", "content" => "synthetic"}
        ])

      assert {:ok, non_tool_prepared} =
               WebsocketCodec.prepare_frame(
                 Jason.encode!(non_tool),
                 native_responses_options(non_tool),
                 fn _frame -> :ok end
               )

      assert non_tool_prepared.request_options.continuity.request_claim_key ==
               non_tool_prepared.turn_claim_key

      public =
        native_request_claim_payload(turn_id, "resp_public", [
          %{
            "type" => "function_call_output",
            "call_id" => "call_public",
            "output" => %{"status" => "ok"}
          }
        ])
        |> Map.drop(["turn_id", "client_metadata"])

      assert {:ok, public_prepared} =
               WebsocketCodec.prepare_frame(
                 Jason.encode!(public),
                 public_responses_options(public),
                 fn _frame -> :ok end
               )

      assert is_nil(public_prepared.request_options.continuity.request_claim_key)

      compaction =
        native_compaction_trigger_payload(%{"turn_id" => turn_id})
        |> Map.put("previous_response_id", "resp_compaction")

      assert {:ok, compaction_prepared} =
               WebsocketCodec.prepare_frame(
                 Jason.encode!(compaction),
                 native_responses_options(compaction),
                 fn _frame -> :ok end
               )

      assert compaction_prepared.request_options.continuity.request_claim_key ==
               compaction_prepared.turn_claim_key

      explicit_compaction_metadata =
        native_request_claim_payload(turn_id, nil, [
          %{
            "type" => "function_call_output",
            "call_id" => "call_explicit_compaction",
            "output" => %{"status" => "ok"}
          }
        ])
        |> put_in(
          ["client_metadata", "x-codex-turn-metadata"],
          Jason.encode!(%{
            "turn_id" => turn_id,
            "request_kind" => "compaction",
            "window_id" => "window-explicit-compaction",
            "window_number" => 1,
            "context_window_id" => "00000000-0000-4000-8000-000000000152",
            "compaction" => %{
              "trigger" => "auto",
              "reason" => "context_limit",
              "implementation" => "responses_compaction_v2",
              "phase" => "mid_turn",
              "strategy" => "memento"
            }
          })
        )

      assert {:ok, explicit_compaction_prepared} =
               WebsocketCodec.prepare_frame(
                 Jason.encode!(explicit_compaction_metadata),
                 native_responses_options(explicit_compaction_metadata),
                 fn _frame -> :ok end
               )

      assert explicit_compaction_prepared.request_options.continuity.request_claim_key ==
               explicit_compaction_prepared.turn_claim_key
    end

    test "rejects unsupported compaction placement during preparation" do
      payload = %{
        "type" => "response.create",
        "model" => "gpt-example",
        "input" => [
          %{"type" => "compaction_trigger"},
          %{"type" => "message", "content" => "visible"}
        ]
      }

      assert {:error, %{status: 400, code: "invalid_request"}} =
               WebsocketCodec.prepare_frame(
                 Jason.encode!(payload),
                 native_responses_options(payload),
                 fn _frame -> :ok end
               )
    end
  end

  describe "coerce_request/3" do
    test "uses the current native top-level turn id for websocket correlations" do
      turn_id = Ecto.UUID.generate()
      session_id = Ecto.UUID.generate()

      payload = %{
        "type" => "response.create",
        "model" => "gpt-example",
        "input" => [],
        "turn_id" => turn_id
      }

      assert {:ok, coerced} =
               WebsocketCodec.coerce_request(
                 payload,
                 native_responses_options(payload, session_id),
                 fn _frame -> :ok end
               )

      expected = :crypto.hash(:sha256, session_id <> <<0>> <> turn_id)
      claim_key = "codex-turn:" <> Base.url_encode64(expected, padding: false)

      assert coerced.request_options.continuity.semantic_turn_key == expected
      assert coerced.request_options.continuity.turn_claim_key == claim_key
      assert RequestOptions.server_correlation_id(coerced.request_options) == claim_key
      assert RequestOptions.websocket_request_correlation_id(coerced.request_options) == claim_key
      refute inspect(coerced.request_options) =~ turn_id
    end

    test "rejects malformed higher-priority native identity without fallback" do
      payload = %{
        "type" => "response.create",
        "model" => "gpt-example",
        "input" => [],
        "client_metadata" => %{"turn_id" => "invalid/value"},
        "turn_id" => Ecto.UUID.generate()
      }

      assert {:error,
              %{
                status: 400,
                code: "invalid_request",
                message: "native websocket turn identity is invalid",
                param: "client_metadata.turn_id"
              }} =
               WebsocketCodec.coerce_request(
                 payload,
                 native_responses_options(payload, Ecto.UUID.generate()),
                 fn _frame -> :ok end
               )
    end

    test "does not consume native identity metadata for public websocket requests" do
      payload = %{
        "type" => "response.create",
        "model" => "gpt-example",
        "input" => "public input",
        "client_metadata" => %{"turn_id" => "invalid/value"}
      }

      assert {:ok, coerced} =
               WebsocketCodec.coerce_request(
                 payload,
                 public_responses_options(payload),
                 fn _frame -> :ok end
               )

      assert is_nil(coerced.request_options.continuity.semantic_turn_key)
      assert is_nil(coerced.request_options.continuity.turn_claim_key)
    end

    test "keeps ordinary native Responses websocket creates on passthrough" do
      payload = %{
        "type" => "response.create",
        "model" => "gpt-example",
        "input" => [%{"type" => "message", "content" => "ordinary native input"}],
        "stream" => true
      }

      push_frame = fn _frame -> :ok end

      assert {:ok, coerced} =
               WebsocketCodec.coerce_request(
                 payload,
                 native_responses_options(payload),
                 push_frame
               )

      assert coerced.endpoint == "/backend-api/codex/responses"
      assert coerced.payload == payload
      refute Map.has_key?(coerced, :result_adapter)
      assert coerced.request_options.transport.transport == "websocket"
      assert coerced.request_options.transport.upstream_endpoint == coerced.endpoint
      assert coerced.request_options.transport.route_class == "proxy_websocket"
      assert is_function(coerced.request_options.transport.websocket_writer, 1)
      refute coerced.request_options.payload_context.compaction_trigger_bridge?
    end

    test "bridges valid terminal native compaction triggers through canonical compact HTTP" do
      for {client_metadata, result_transport} <- [
            {v2_client_metadata(), :sse},
            {%{"x-codex-turn-metadata" => Jason.encode!(%{"compaction" => %{}})}, :buffered},
            {remote_compaction_v2_client_metadata(), :sse},
            {nil, :buffered}
          ] do
        payload = native_compaction_trigger_payload(client_metadata)

        assert {:ok, coerced} =
                 WebsocketCodec.coerce_request(
                   payload,
                   native_responses_options(payload),
                   fn _frame -> :ok end
                 )

        assert coerced.endpoint == "/backend-api/codex/responses/compact"

        expected_payload = %{
          "model" => "gpt-example",
          "instructions" => "compact synthetic history",
          "input" => [
            %{"type" => "message", "content" => "visible native input"},
            %{"type" => "compaction_trigger"}
          ],
          "store" => false
        }

        expected_payload =
          if result_transport == :sse,
            do: Map.put(expected_payload, "stream", true),
            else: expected_payload

        assert coerced.payload == expected_payload

        assert is_function(coerced.result_adapter, 1)
        assert coerced.request_options.transport.transport == "http_compact_json"

        assert coerced.request_options.transport.upstream_endpoint ==
                 "/backend-api/codex/responses"

        assert coerced.request_options.transport.route_class == "proxy_compact"
        assert is_nil(coerced.request_options.transport.websocket_writer)
        assert coerced.request_options.payload_context.compaction_trigger_bridge?

        assert coerced.request_options.payload_context.compaction_result_transport ==
                 result_transport

        assert coerced.request_options.payload_context.compaction_result_mode ==
                 :native_websocket
      end
    end

    test "rejects malformed canonical native turn metadata before compaction routing" do
      payload =
        native_compaction_trigger_payload(%{"x-codex-turn-metadata" => "not-json"})

      assert {:error,
              %{
                status: 400,
                code: "invalid_request",
                message: "native websocket turn identity is invalid",
                param: "client_metadata.x-codex-turn-metadata"
              }} =
               WebsocketCodec.coerce_request(
                 payload,
                 native_responses_options(payload),
                 fn _frame -> :ok end
               )
    end

    test "projects the pinned rich Codex compact request identically to the HTTP contract" do
      payload = native_compaction_trigger_payload(remote_compaction_v2_client_metadata())

      assert {:ok, coerced} =
               WebsocketCodec.coerce_request(
                 payload,
                 native_responses_options(payload),
                 fn _frame -> :ok end
               )

      assert {:ok, compact_payload} =
               CompactionTrigger.prepare_bridge("/backend-api/codex/responses", payload)

      http_projection = CompactionTrigger.project_responses_payload(compact_payload, :sse)

      assert coerced.request_options.payload_context.compaction_result_transport == :sse
      assert coerced.payload == http_projection
      assert Jason.encode!(coerced.payload) == Jason.encode!(http_projection)
    end

    test "retains source-derived incremental anchors before compact continuity routing" do
      for scenario <- ["anchored_tool_output_and_trigger", "anchored_trigger_only"] do
        payload = remote_compaction_v2_incremental_subset!(scenario)

        assert {:ok, coerced} =
                 WebsocketCodec.coerce_request(
                   payload,
                   native_responses_options(payload),
                   fn _frame -> :ok end
                 )

        first_projection = CompactionTrigger.project_responses_payload(payload, :sse)
        second_projection = CompactionTrigger.project_responses_payload(first_projection, :sse)
        third_projection = CompactionTrigger.project_responses_payload(second_projection, :sse)

        assert coerced.endpoint == "/backend-api/codex/responses/compact"
        assert coerced.payload == first_projection
        assert second_projection == first_projection
        assert third_projection == first_projection
        assert coerced.payload["previous_response_id"] == payload["previous_response_id"]

        assert coerced.request_options.payload_context.compaction_trigger_bridge?
        assert coerced.request_options.payload_context.compaction_result_transport == :sse
        assert coerced.request_options.transport.route_class == "proxy_compact"
      end
    end

    test "keeps source-derived full-history compaction unanchored" do
      payload = remote_compaction_v2_incremental_subset!("full_history_without_anchor")

      assert {:ok, coerced} =
               WebsocketCodec.coerce_request(
                 payload,
                 native_responses_options(payload),
                 fn _frame -> :ok end
               )

      refute Map.has_key?(coerced.payload, "previous_response_id")
      assert coerced.payload["input"] == payload["input"]
    end

    test "does not widen public admission for anchors without tool output" do
      payload = %{
        "type" => "response.create",
        "model" => "gpt-fixture",
        "previous_response_id" => "resp_fixture_public_0001",
        "input" => [
          %{"type" => "message", "role" => "user", "content" => "visible public input"},
          %{"type" => "compaction_trigger"}
        ]
      }

      assert {:error, error} =
               WebsocketCodec.coerce_request(
                 payload,
                 public_responses_options(payload),
                 fn _frame -> :ok end
               )

      assert error.status == 400
      assert error.code == "invalid_request"
      assert error.param == "previous_response_id"
    end

    test "retains an anchor with an unknown future output suffix" do
      payload = %{
        "type" => "response.create",
        "model" => "gpt-fixture",
        "previous_response_id" => "resp_fixture_future_0001",
        "input" => [
          %{
            "type" => "future_tool_output_v9",
            "call_id" => "call_fixture_future",
            "output" => "fixture future output"
          },
          %{"type" => "compaction_trigger"}
        ],
        "store" => false,
        "stream" => true
      }

      assert {:ok, coerced} =
               WebsocketCodec.coerce_request(
                 payload,
                 native_responses_options(payload),
                 fn _frame -> :ok end
               )

      assert coerced.payload["previous_response_id"] == payload["previous_response_id"]
      assert coerced.payload["input"] == payload["input"]
    end

    test "bridges a singleton native compaction trigger" do
      payload = %{
        "type" => "response.create",
        "model" => "gpt-example",
        "input" => [%{"type" => "compaction_trigger"}],
        "stream" => true
      }

      assert {:ok, coerced} =
               WebsocketCodec.coerce_request(
                 payload,
                 native_responses_options(payload),
                 fn _frame -> :ok end
               )

      assert coerced.endpoint == "/backend-api/codex/responses/compact"
      assert coerced.payload["input"] == [%{"type" => "compaction_trigger"}]
      assert coerced.request_options.payload_context.compaction_result_transport == :buffered
    end

    test "rejects malformed native compaction trigger placement without retaining metadata" do
      marker_sentinel = "raw-native-marker-must-not-survive"

      invalid_inputs = [
        [
          %{"type" => "compaction_trigger"},
          %{"type" => "message", "content" => "visible native input"}
        ],
        [
          %{"type" => "message", "content" => "visible native input"},
          %{"type" => "compaction_trigger"},
          %{"type" => "compaction_trigger"}
        ],
        [
          %{"type" => "reasoning", "encrypted_content" => "hidden-only"},
          %{"type" => "compaction_trigger"}
        ]
      ]

      for input <- invalid_inputs do
        payload = %{
          "type" => "response.create",
          "model" => "gpt-example",
          "input" => input,
          "stream" => true,
          "client_metadata" => %{"x-codex-turn-metadata" => marker_sentinel}
        }

        assert {:error, error} =
                 WebsocketCodec.coerce_request(
                   payload,
                   native_responses_options(payload),
                   fn _frame -> :ok end
                 )

        assert error == %{
                 status: 400,
                 code: "invalid_request",
                 message:
                   "compaction_trigger must be the final input item and must follow visible input",
                 param: "input"
               }

        refute inspect(error) =~ marker_sentinel
      end
    end

    test "emits the exact native websocket compaction result wire" do
      payload = native_compaction_trigger_payload(v2_client_metadata())

      assert {:ok, %{result_adapter: result_adapter}} =
               WebsocketCodec.coerce_request(
                 payload,
                 native_responses_options(payload),
                 fn _frame -> :ok end
               )

      source = %{
        "id" => "resp_native_compaction",
        "object" => "response.compaction",
        "output" => [
          %{
            "type" => "compaction_summary",
            "encrypted_content" => "synthetic-native-encrypted",
            "id" => "cmp_native",
            "internal_chat_message_metadata_passthrough" => %{
              "turn_id" => "turn_native"
            },
            "summary" => "must drop"
          }
        ],
        "usage" => %{"input_tokens" => 8, "output_tokens" => 2, "total_tokens" => 10}
      }

      assert {:ok, adapted} =
               result_adapter.(
                 {:ok, %{status: 200, headers: [], raw_body: Jason.encode!(source)}}
               )

      item = %{
        "type" => "compaction",
        "encrypted_content" => "synthetic-native-encrypted",
        "id" => "cmp_native",
        "internal_chat_message_metadata_passthrough" => %{"turn_id" => "turn_native"}
      }

      assert adapted.websocket_messages == [
               %{"type" => "response.output_item.done", "item" => item},
               %{
                 "type" => "response.completed",
                 "response" => %{
                   "id" => "resp_native_compaction",
                   "status" => "completed",
                   "output" => [item],
                   "usage" => %{
                     "input_tokens" => 8,
                     "output_tokens" => 2,
                     "total_tokens" => 10
                   }
                 }
               }
             ]

      refute Map.has_key?(adapted, :raw_body)
      refute Map.has_key?(adapted, :body)
      refute inspect(adapted.websocket_messages) =~ "object"
      refute inspect(adapted.websocket_messages) =~ "stream_id"
      refute inspect(adapted.websocket_messages) =~ "[DONE]"
      refute inspect(adapted.websocket_messages) =~ "must drop"
    end

    test "omits malformed optional native compaction item metadata" do
      payload = native_compaction_trigger_payload(nil)

      assert {:ok, %{result_adapter: result_adapter}} =
               WebsocketCodec.coerce_request(
                 payload,
                 native_responses_options(payload),
                 fn _frame -> :ok end
               )

      source = %{
        "output" => [
          %{
            "type" => "compaction",
            "encrypted_content" => "synthetic-native-encrypted",
            "id" => 7,
            "internal_chat_message_metadata_passthrough" => %{"turn_id" => false}
          }
        ]
      }

      assert {:ok, %{websocket_messages: [done, completed]}} =
               result_adapter.({:ok, %{status: 200, body: source}})

      assert done == %{
               "type" => "response.output_item.done",
               "item" => %{
                 "type" => "compaction",
                 "encrypted_content" => "synthetic-native-encrypted"
               }
             }

      assert completed["response"]["output"] == [done["item"]]
    end

    test "keeps the public compaction websocket result wrapper compatible" do
      payload = %{
        "type" => "response.create",
        "model" => "gpt-example",
        "input" => [
          %{"type" => "message", "content" => "visible public input"},
          %{"type" => "compaction_trigger"}
        ]
      }

      assert {:ok, %{result_adapter: result_adapter}} =
               WebsocketCodec.coerce_request(
                 payload,
                 public_responses_options(payload),
                 fn _frame -> :ok end
               )

      source = %{
        "id" => "resp_public_compaction",
        "output" => [
          %{
            "type" => "compaction",
            "encrypted_content" => "synthetic-public-encrypted",
            "id" => nil
          }
        ]
      }

      assert {:ok, %{websocket_messages: [_done, completed]}} =
               result_adapter.({:ok, %{status: 200, body: source}})

      assert completed["response"]["object"] == "response"
    end

    test "keeps public Responses websocket creates without stream_id compatible" do
      payload = %{"type" => "response.create", "model" => "gpt-example", "input" => "hello"}

      assert {:ok, coerced} =
               WebsocketCodec.coerce_request(
                 payload,
                 public_responses_options(payload),
                 fn _frame -> :ok end
               )

      assert coerced.endpoint == "/backend-api/codex/responses"
      assert coerced.payload["model"] == "gpt-example"
      assert coerced.payload["generate"]
      refute Map.has_key?(coerced.payload, "stream_id")
    end

    test "coerces padded mixed ultrafast service tiers through the shared Responses adapter" do
      for service_tier <- [" UlTrAfAsT ", "\tulTRafast\n"] do
        payload = %{
          "type" => "response.create",
          "model" => "gpt-example",
          "input" => "hello",
          "service_tier" => service_tier
        }

        assert {:ok, coerced} =
                 WebsocketCodec.coerce_request(
                   payload,
                   public_responses_options(payload),
                   fn _frame -> :ok end
                 )

        assert coerced.endpoint == "/backend-api/codex/responses"
        assert coerced.payload["service_tier"] == "ultrafast"
      end
    end

    test "rejects unsupported and non-string service tiers without leaking the input shape" do
      for service_tier <- ["ultra-fast", %{"requested" => "ultrafast"}] do
        payload = %{
          "type" => "response.create",
          "model" => "gpt-example",
          "input" => "hello",
          "service_tier" => service_tier
        }

        assert {:error, error} =
                 WebsocketCodec.coerce_request(
                   payload,
                   public_responses_options(payload),
                   fn _frame -> :ok end
                 )

        assert error.status == 400
        assert error.code == "invalid_request"
        assert error.param == "service_tier"
        refute error.message =~ "ultra-fast"
        refute error.message =~ "requested"
      end
    end

    test "accepts valid public Responses websocket stream_id boundaries and strips them" do
      for stream_id <- ["a", "A-z0_.-", String.duplicate("a", 256)] do
        payload = %{
          "type" => "response.create",
          "model" => "gpt-example",
          "input" => "hello",
          "stream_id" => stream_id
        }

        assert {:ok, coerced} =
                 WebsocketCodec.coerce_request(
                   payload,
                   public_responses_options(payload),
                   fn _frame -> :ok end
                 )

        refute contains_stream_id?(coerced.payload)
        refute contains_stream_id?(coerced.request_options)
      end
    end

    test "rejects malformed public Responses websocket stream_id values before coercion" do
      invalid_stream_ids = [
        nil,
        7,
        false,
        [],
        %{},
        "",
        String.duplicate("a", 257),
        "contains whitespace",
        "tab\tid",
        "mélange",
        "lane/a",
        "lane:one",
        "ignore instructions; dispatch upstream"
      ]

      for stream_id <- invalid_stream_ids do
        payload = %{
          "type" => "response.create",
          "model" => "gpt-example",
          "input" => "hello",
          "stream_id" => stream_id
        }

        assert {:error, error} =
                 WebsocketCodec.coerce_request(
                   payload,
                   public_responses_options(payload),
                   fn _frame -> :ok end
                 )

        assert error.status == 400
        assert error.code == "invalid_request"
        assert error.param == "stream_id"
        assert byte_size(error.message) < 128
      end
    end
  end

  describe "stream_id/1" do
    test "extracts valid ids from raw queued frames and reports omitted ids" do
      assert :omitted = WebsocketCodec.stream_id(%{"type" => "response.create"})

      assert {:ok, "A-z0_.-"} =
               WebsocketCodec.stream_id(
                 Jason.encode!(%{"type" => "response.create", "stream_id" => "A-z0_.-"})
               )

      assert {:error, %{status: 400, code: "invalid_request", param: "stream_id"}} =
               WebsocketCodec.stream_id(
                 Jason.encode!(%{"type" => "response.create", "stream_id" => "lane/a"})
               )
    end
  end

  describe "request_row_producing_response_payload?/1" do
    test "accepts response lifecycle and model request frames" do
      assert WebsocketCodec.request_row_producing_response_payload?(
               Jason.encode!(%{"type" => "response.processed"})
             )

      assert WebsocketCodec.request_row_producing_response_payload?(
               Jason.encode!(%{"type" => "response.create"})
             )

      assert WebsocketCodec.request_row_producing_response_payload?(
               Jason.encode!(%{"model" => "gpt-example"})
             )
    end

    test "rejects warmups, malformed JSON, non-object JSON, and blank models" do
      refute WebsocketCodec.request_row_producing_response_payload?(
               Jason.encode!(%{"generate" => false})
             )

      refute WebsocketCodec.request_row_producing_response_payload?("{invalid")
      refute WebsocketCodec.request_row_producing_response_payload?(Jason.encode!(["frame"]))

      refute WebsocketCodec.request_row_producing_response_payload?(
               Jason.encode!(%{"model" => ""})
             )

      refute WebsocketCodec.request_row_producing_response_payload?(
               Jason.encode!(%{"model" => "  "})
             )
    end
  end

  describe "continuity_ordered_payload?/1" do
    test "orders response.processed and tool-result continuations" do
      assert WebsocketCodec.continuity_ordered_payload?(
               Jason.encode!(%{"type" => "response.processed"})
             )

      assert WebsocketCodec.continuity_ordered_payload?(
               Jason.encode!(%{
                 "type" => "response.create",
                 "previous_response_id" => "resp_previous",
                 "input" => [
                   %{
                     "type" => "function_call_output",
                     "call_id" => "call_123",
                     "output" => %{"status" => "ok"}
                   }
                 ]
               })
             )

      assert WebsocketCodec.continuity_ordered_payload?(
               Jason.encode!(%{
                 "type" => "response.create",
                 "previous_response_id" => "resp_previous",
                 "input" => [
                   %{
                     "type" => "function_call_output",
                     "name" => "lookup_fixture",
                     "output" => nil
                   }
                 ]
               })
             )
    end

    test "orders anchored terminal compaction triggers with and without tool output" do
      for scenario <- ["anchored_tool_output_and_trigger", "anchored_trigger_only"] do
        payload = remote_compaction_v2_incremental_subset!(scenario)

        assert WebsocketCodec.continuity_ordered_payload?(Jason.encode!(payload))
      end
    end

    test "does not order ordinary, malformed, or unanchored compaction continuations" do
      unordered_payloads = [
        %{
          "type" => "response.create",
          "previous_response_id" => "resp_previous",
          "input" => [%{"type" => "message", "content" => "placeholder"}]
        },
        %{
          "type" => "response.create",
          "previous_response_id" => "   ",
          "input" => [
            %{"type" => "message", "content" => "visible"},
            %{"type" => "compaction_trigger"}
          ]
        },
        %{
          "type" => "response.create",
          "previous_response_id" => 123,
          "input" => [
            %{"type" => "message", "content" => "visible"},
            %{"type" => "compaction_trigger"}
          ]
        },
        %{
          "type" => "response.create",
          "previous_response_id" => "resp_previous",
          "input" => [
            %{"type" => "compaction_trigger"},
            %{"type" => "message", "content" => "visible"}
          ]
        },
        %{
          "type" => "response.create",
          "previous_response_id" => "resp_previous",
          "input" => [
            %{"type" => "message", "content" => "visible"},
            %{"type" => "compaction_trigger"},
            %{"type" => "compaction_trigger"}
          ]
        },
        %{
          "type" => "response.create",
          "input" => [
            %{"type" => "message", "content" => "visible"},
            %{"type" => "compaction_trigger"}
          ]
        }
      ]

      Enum.each(unordered_payloads, fn payload ->
        refute WebsocketCodec.continuity_ordered_payload?(Jason.encode!(payload))
      end)

      refute WebsocketCodec.continuity_ordered_payload?(Jason.encode!(%{"generate" => false}))
      refute WebsocketCodec.continuity_ordered_payload?("{invalid")
    end
  end

  describe "deliver_result/2" do
    test "normalizes websocket stream success tuples to :ok" do
      result = %{websocket_stream: fn -> {:ok, :done} end}

      assert WebsocketCodec.deliver_result(result, &unexpected_push/1) == :ok
    end

    test "preserves structured websocket stream errors" do
      error = %{status: 503, code: "upstream_stream_error", message: "upstream stream failed"}
      result = %{websocket_stream: fn -> {:error, error} end}

      assert WebsocketCodec.deliver_result(result, &unexpected_push/1) == {:error, error}
    end

    test "sanitizes structured websocket errors with invalid code types" do
      error = %{status: 503, code: {:closed, "sensitive detail"}, message: "upstream failed"}
      result = %{websocket_stream: fn -> {:error, error} end}

      assert {:error, sanitized} = WebsocketCodec.deliver_result(result, &unexpected_push/1)
      assert sanitized.status == 502
      assert sanitized.code == "websocket_stream_error"
      assert sanitized.message == "websocket stream failed"
      refute inspect(sanitized) =~ "sensitive detail"
    end

    test "sanitizes unexpected websocket stream results" do
      result = %{websocket_stream: fn -> {:error, {:closed, "sensitive transport detail"}} end}

      assert {:error, error} = WebsocketCodec.deliver_result(result, &unexpected_push/1)
      assert error.status == 502
      assert error.code == "websocket_stream_error"
      assert error.message == "websocket stream failed"
      refute inspect(error) =~ "sensitive transport detail"
    end
  end

  describe "stream_messages/3" do
    test "returns explicit buffer for split SSE frames without process state" do
      request_id = "websocket-buffer-explicit"
      state = StreamProtocol.new_sse_block_state()

      assert {[], state} =
               WebsocketCodec.stream_messages(
                 request_id,
                 "data: {\"type\":\"response.",
                 state
               )

      assert state.buffer == "data: {\"type\":\"response."

      assert {[message], state} =
               WebsocketCodec.stream_messages(
                 request_id,
                 "completed\",\"response\":{\"id\":\"resp_123\"}}\n\n",
                 state
               )

      assert state == StreamProtocol.new_sse_block_state()
      assert Jason.decode!(message)["type"] == "response.completed"
      refute Process.get({:websocket_sse_buffer, request_id})
    end

    test "preserves safety-buffering metadata from upstream SSE frames" do
      request_id = "websocket-safety-buffering"

      sse =
        "event: response.output_text.delta\n" <>
          "data: " <>
          Jason.encode!(%{
            "type" => "response.output_text.delta",
            "delta" => "visible synthetic safety-buffered text",
            "safety_buffering" => %{
              "model" => "safety-buffering-model-sentinel",
              "use_cases" => ["cyber"],
              "reasons" => ["user-risk-sentinel"]
            }
          }) <>
          "\n\n"

      assert {[message], state} =
               WebsocketCodec.stream_messages(
                 request_id,
                 sse,
                 StreamProtocol.new_sse_block_state()
               )

      assert state == StreamProtocol.new_sse_block_state()

      assert %{
               "type" => "response.output_text.delta",
               "safety_buffering" => safety_buffering
             } = Jason.decode!(message)

      assert safety_buffering == %{
               "model" => "safety-buffering-model-sentinel",
               "use_cases" => ["cyber"],
               "reasons" => ["user-risk-sentinel"]
             }
    end

    test "emits standalone-CR SSE once and consumes its optional following LF" do
      request_id = "websocket-standalone-cr"

      payload = %{
        "type" => "response.completed",
        "response" => %{"id" => "resp_websocket_cr", "status" => "completed"}
      }

      state = StreamProtocol.new_sse_block_state()
      source = "data: " <> Jason.encode!(payload) <> "\r\r"

      assert {[message], state} = WebsocketCodec.stream_messages(request_id, source, state)
      assert Jason.decode!(message) == payload
      assert state.skip_leading_lf?

      assert {[], state} = WebsocketCodec.stream_messages(request_id, "\n", state)
      assert state == StreamProtocol.new_sse_block_state()
    end

    test "canonicalizes a decoded SSE terminal identically to a direct JSON message" do
      request_id = "websocket-decoded-sse-terminal"

      frame =
        Jason.encode!(%{
          "type" => "error",
          "error" => %{"code" => "previous_response_not_found"}
        })

      assert {[message], state} =
               WebsocketCodec.stream_messages(
                 request_id,
                 "data: #{frame}\n\n",
                 StreamProtocol.new_sse_block_state()
               )

      assert state == StreamProtocol.new_sse_block_state()

      assert {[direct_message], state} =
               WebsocketCodec.stream_messages(
                 request_id,
                 frame,
                 StreamProtocol.new_sse_block_state()
               )

      assert state.buffer == frame
      assert message == direct_message

      assert %{"type" => "response.failed", "error" => %{"code" => "stream_incomplete"}} =
               Jason.decode!(message)
    end

    test "drops oversized incomplete SSE buffers instead of retaining them" do
      attach_stream_buffer_telemetry()
      request_id = "websocket-buffer-oversized"
      oversized = String.duplicate("data: unavailable-upstream-prefix", 260_000)

      assert {[], state} =
               WebsocketCodec.stream_messages(
                 request_id,
                 oversized,
                 StreamProtocol.new_sse_block_state()
               )

      assert state == StreamProtocol.new_sse_block_state()

      assert_receive {[:codex_pooler, :gateway, :stream_buffer, :oversized],
                      %{bytes: bytes, count: 1, max_bytes: 8_388_608},
                      %{buffer: "websocket_sse", endpoint: "unknown", route_class: "unknown"}}

      assert bytes > 8_388_608
    end
  end

  defp unexpected_push(_frame), do: flunk("websocket stream results should not push directly")

  defp public_responses_options(payload) do
    RequestOptions.build(
      %{public_openai_responses_stream: true},
      "/backend-api/codex/responses",
      payload
    )
  end

  defp native_responses_options(payload, session_id \\ Ecto.UUID.generate()) do
    RequestOptions.build(
      %{codex_session: %{id: session_id}},
      "/backend-api/codex/responses",
      payload
    )
  end

  defp direct_responses_options(payload) do
    %{
      transport: "websocket",
      upstream_websocket_session: self(),
      codex_session: %{id: Ecto.UUID.generate()}
    }
    |> RequestOptions.build("/backend-api/codex/responses", payload)
    |> RequestOptions.put_model_serving_mode(%{
      configured_mode: "full",
      effective_mode: "full",
      source: "override"
    })
  end

  defp native_compaction_trigger_payload(client_metadata) do
    %{
      "type" => "response.create",
      "model" => "gpt-example",
      "instructions" => "compact synthetic history",
      "input" => [
        %{"type" => "message", "content" => "visible native input"},
        %{"type" => "compaction_trigger"}
      ],
      "stream" => true,
      "client_metadata" => client_metadata,
      "include" => ["reasoning.encrypted_content"],
      "tool_choice" => "auto"
    }
  end

  defp native_request_claim_payload(turn_id, previous_response_id, input) do
    %{
      "type" => "response.create",
      "model" => "gpt-example",
      "input" => input,
      "turn_id" => turn_id,
      "client_metadata" => %{"turn_id" => turn_id}
    }
    |> then(fn payload ->
      if is_binary(previous_response_id) do
        Map.put(payload, "previous_response_id", previous_response_id)
      else
        payload
      end
    end)
  end

  defp direct_admission(%PreparedWebsocketFrame{} = prepared) do
    binding = %NativeCompactionAdmission.Binding{
      semantic_turn_key: prepared.semantic_turn_key,
      window_digest: <<2::256>>,
      context_digest: <<3::256>>,
      window_number: 1,
      previous_response_digest: nil,
      serving_mode: :full,
      topology: %NativeCompactionAdmission.Topology.Direct{},
      lifecycle_id: Ecto.UUID.generate(),
      generation: 1
    }

    {:ok, ordinary} = NativeCompactionAdmission.ordinary_success(binding)
    {:ok, pending} = NativeCompactionAdmission.arm_compact(ordinary, 100)

    {:ok, _reserved, capability} =
      NativeCompactionAdmission.reserve(pending, :compact, binding, make_ref(), 0)

    {:ok, admission} =
      RequestOptions.NativeCompactionAdmission.new(
        capability,
        {:direct, self()},
        %{lifecycle_id: binding.lifecycle_id, generation: binding.generation}
      )

    admission
  end

  defp prepared_admission_frame(topology, mode) do
    payload = %{
      "type" => "response.create",
      "model" => "gpt-example",
      "input" => [],
      "turn_id" => Ecto.UUID.generate()
    }

    {owner_opts, owner} = owner_fixture(topology)

    options =
      owner_opts
      |> Map.put(:codex_session, owner_session(owner))
      |> RequestOptions.build("/backend-api/codex/responses", payload)
      |> maybe_put_test_serving_mode(mode)

    {:ok, prepared} =
      WebsocketCodec.prepare_frame(Jason.encode!(payload), options, fn _frame -> :ok end)

    {prepared, owner}
  end

  defp maybe_put_test_serving_mode(options, nil), do: options

  defp maybe_put_test_serving_mode(options, mode) do
    RequestOptions.put_model_serving_mode(options, %{
      configured_mode: Atom.to_string(mode),
      effective_mode: Atom.to_string(mode),
      source: "override"
    })
  end

  defp owner_fixture(:direct) do
    owner = self()
    {%{transport: "websocket", upstream_websocket_session: owner}, {:direct, owner}}
  end

  defp owner_fixture(:forwarded) do
    session = %CodexPooler.Gateway.Persistence.CodexSession{id: Ecto.UUID.generate()}
    lease_token = Ecto.UUID.generate()
    downstream = %{pid: self(), epoch: 1, correlation_id: Ecto.UUID.generate()}
    opts = []

    {%{
       transport: "websocket",
       websocket_owner_forwarding_enabled?: true,
       websocket_owner_session: session,
       websocket_owner_lease_token: lease_token,
       websocket_owner_downstream: downstream,
       websocket_owner_downstream_epoch: 1,
       websocket_owner_instance_id: "owner@example",
       websocket_owner_forwarder_opts: opts
     }, {:forwarded, session, lease_token, downstream, opts}}
  end

  defp owner_session({:direct, _pid}), do: %{id: Ecto.UUID.generate()}
  defp owner_session({:forwarded, session, _lease, _downstream, _opts}), do: session

  defp admission_for(prepared, owner, topology, mode) do
    binding_topology =
      case {topology, owner} do
        {:direct, _owner} ->
          %NativeCompactionAdmission.Topology.Direct{}

        {:forwarded, {:forwarded, _session, lease, downstream, _opts}} ->
          WebsocketOwnerAdmissionControlV1.forwarded_topology(
            "owner@example",
            lease,
            downstream.epoch
          )

        {:forwarded, {:direct, _pid}} ->
          WebsocketOwnerAdmissionControlV1.forwarded_topology(
            "owner@example",
            Ecto.UUID.generate(),
            1
          )
      end

    binding = %NativeCompactionAdmission.Binding{
      semantic_turn_key: prepared.semantic_turn_key,
      window_digest: <<2::256>>,
      context_digest: <<3::256>>,
      window_number: 1,
      previous_response_digest: nil,
      serving_mode: mode,
      topology: binding_topology,
      lifecycle_id: Ecto.UUID.generate(),
      generation: 1
    }

    {:ok, ordinary} = NativeCompactionAdmission.ordinary_success(binding)
    {:ok, pending} = NativeCompactionAdmission.arm_compact(ordinary, 100)

    {:ok, _reserved, capability} =
      NativeCompactionAdmission.reserve(pending, :compact, binding, make_ref(), 0)

    {:ok, admission} =
      RequestOptions.NativeCompactionAdmission.new(
        capability,
        owner,
        %{lifecycle_id: binding.lifecycle_id, generation: binding.generation}
      )

    admission
  end

  defp v2_client_metadata do
    %{
      "x-codex-turn-metadata" =>
        Jason.encode!(%{"compaction" => %{"implementation" => "responses_compaction_v2"}})
    }
  end

  defp remote_compaction_v2_client_metadata do
    @remote_compaction_v2_fixture_path
    |> File.read!()
    |> Jason.decode!()
    |> get_in(["request", "client_metadata"])
  end

  defp remote_compaction_v2_incremental_subset!(scenario) do
    @remote_compaction_v2_incremental_fixture_path
    |> File.read!()
    |> Jason.decode!()
    |> get_in(["contract", "scenarios", scenario, "projection_relevant_frame_subset"])
  end

  defp contains_stream_id?(%{__struct__: _} = value),
    do: value |> Map.from_struct() |> contains_stream_id?()

  defp contains_stream_id?(%{} = value) do
    Map.has_key?(value, "stream_id") or Map.has_key?(value, :stream_id) or
      Enum.any?(value, fn {_key, nested_value} -> contains_stream_id?(nested_value) end)
  end

  defp contains_stream_id?(value) when is_list(value),
    do: Enum.any?(value, &contains_stream_id?/1)

  defp contains_stream_id?(_value), do: false

  defp attach_stream_buffer_telemetry do
    handler_id = {__MODULE__, self(), System.unique_integer([:positive])}
    parent = self()

    :telemetry.attach(
      handler_id,
      [:codex_pooler, :gateway, :stream_buffer, :oversized],
      fn event, measurements, metadata, _config ->
        send(parent, {event, measurements, metadata})
      end,
      :ok
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
