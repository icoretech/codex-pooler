defmodule CodexPooler.Gateway.Payloads.RequestOptionsTest do
  use ExUnit.Case, async: false

  alias CodexPooler.Access.APIKeys.ReasoningEffortPolicy.Decision
  alias CodexPooler.Gateway.OperationalSettings
  alias CodexPooler.Gateway.Payloads.CompactionTrigger
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Payloads.RequestOptions.CompactionProjectionContext
  alias CodexPooler.Gateway.Payloads.RequestOptions.Continuity
  alias CodexPooler.Gateway.Payloads.RequestOptions.OpenAICompatibility
  alias CodexPooler.Gateway.Payloads.RequestOptions.ResetProbe
  alias CodexPooler.Gateway.Runtime.Dispatch.AccountingReservation
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission
  alias CodexPooler.Gateway.Transports.Websocket.UpstreamWebsocketSession.Request
  alias CodexPooler.Gateway.Websocket
  alias CodexPooler.RouteClass

  @assignment_id "00000000-0000-0000-0000-000000000001"
  @identity_id "00000000-0000-0000-0000-000000000002"
  @effective_model "gpt-5.4"
  @reset_probe_route_class "proxy_http"

  setup do
    previous_settings = Application.get_env(:codex_pooler, OperationalSettings)

    on_exit(fn ->
      if previous_settings do
        Application.put_env(:codex_pooler, OperationalSettings, previous_settings)
      else
        Application.delete_env(:codex_pooler, OperationalSettings)
      end
    end)
  end

  describe "boundary constructors" do
    @tag :compaction_state_baseline
    test "characterizes ordinary option transforms and existing result transport state" do
      payload = %{"model" => "example-model", "input" => [%{"type" => "message"}]}

      options =
        %{}
        |> RequestOptions.build("/backend-api/codex/responses", payload)
        |> RequestOptions.put_model_serving_mode(
          configured_mode: "auto",
          effective_mode: "lite",
          source: "catalog"
        )

      transformed = [
        RequestOptions.build(options, "/backend-api/codex/responses", payload),
        RequestOptions.for_payload(options, "/backend-api/codex/responses", payload),
        RequestOptions.for_websocket(options, payload),
        RequestOptions.retarget(options, "/backend-api/codex/responses/compact", payload)
      ]

      assert Enum.all?(transformed, fn transformed_options ->
               RequestOptions.model_serving_mode_snapshot(transformed_options) ==
                 RequestOptions.model_serving_mode_snapshot(options)
             end)

      assert options.transport.transport == "http_json"
      assert options.payload_context.compaction_result_transport == :buffered
    end

    @tag :compaction_state_contract
    test "derives input mode from source payload and defaults delivery to relay" do
      anchored_payload = %{
        "previous_response_id" => "resp_fixture_typed_state_0001",
        "input" => [%{"type" => "compaction_trigger"}]
      }

      full_history_payload = %{"input" => [%{"type" => "compaction_trigger"}]}

      anchored =
        RequestOptions.build(%{}, "/backend-api/codex/responses", anchored_payload)

      full_history =
        RequestOptions.build(%{}, "/backend-api/codex/responses", full_history_payload)

      assert anchored.payload_context.compaction_input_mode == :incremental
      assert full_history.payload_context.compaction_input_mode == :full_history
      assert anchored.transport.websocket_delivery_mode == :relay
      assert full_history.transport.websocket_delivery_mode == :relay
      refute RequestOptions.connection_bound_compaction?(anchored)
      refute RequestOptions.connection_bound_compaction?(full_history)
    end

    @tag :compaction_state_contract
    @tag :compaction_input_mode_immutable
    test "typed payload updates cannot rewrite source-derived compaction input mode" do
      anchored =
        RequestOptions.build(
          %{},
          "/backend-api/codex/responses",
          %{
            "previous_response_id" => "resp_fixture_immutable_mode_0001",
            "input" => [%{"type" => "compaction_trigger"}]
          }
        )

      full_history =
        RequestOptions.build(
          %{},
          "/backend-api/codex/responses",
          %{"input" => [%{"type" => "compaction_trigger"}]}
        )

      for {options, attempted_modes, expected_mode} <- [
            {anchored, [:incremental, :full_history], :incremental},
            {full_history, [:full_history, :incremental], :full_history}
          ],
          attempted_mode <- attempted_modes do
        updated =
          RequestOptions.put_payload_context(options,
            compaction_input_mode: attempted_mode
          )

        assert updated.payload_context.compaction_input_mode == expected_mode
      end
    end

    @tag :compaction_state_contract
    test "accepts collect mode only through typed server updates" do
      anchor = "resp_fixture_private_anchor_0001"

      payload = %{
        "previous_response_id" => anchor,
        "compaction_input_mode" => "incremental",
        "websocket_delivery_mode" => "collect_compaction",
        "input" => [%{"type" => "compaction_trigger"}]
      }

      spoofed =
        RequestOptions.build(
          %{
            "compaction_input_mode" => "incremental",
            "websocket_delivery_mode" => "collect_compaction",
            compaction_input_mode: :incremental,
            websocket_delivery_mode: :collect_compaction
          },
          "/backend-api/codex/responses",
          payload
        )

      assert spoofed.payload_context.compaction_input_mode == :incremental
      assert spoofed.transport.websocket_delivery_mode == :relay
      refute RequestOptions.connection_bound_compaction?(spoofed)
      assert spoofed.extra == %{}

      connection_bound =
        spoofed
        |> RequestOptions.for_websocket(payload)
        |> RequestOptions.put_payload_context(compaction_trigger_bridge?: true)
        |> RequestOptions.put_transport(websocket_delivery_mode: :collect_compaction)

      assert RequestOptions.connection_bound_compaction?(connection_bound)

      invalid =
        connection_bound
        |> RequestOptions.put_payload_context(compaction_input_mode: :full_history)
        |> RequestOptions.put_transport(websocket_delivery_mode: :invalid)

      assert invalid.payload_context.compaction_input_mode == :incremental
      assert invalid.transport.websocket_delivery_mode == :collect_compaction
      assert RequestOptions.connection_bound_compaction?(invalid)

      refute inspect(connection_bound) =~ anchor
      refute inspect(RequestOptions.openai_compatibility_metadata(connection_bound)) =~ anchor

      refute Map.has_key?(
               RequestOptions.openai_compatibility_metadata(connection_bound),
               "websocket_delivery_mode"
             )

      refute Map.has_key?(
               RequestOptions.client_request_metadata(connection_bound),
               "websocket_delivery_mode"
             )
    end

    @tag :compaction_state_contract
    test "requires every typed connection-bound compaction condition" do
      payload = %{
        "previous_response_id" => "resp_fixture_predicate_0001",
        "input" => [%{"type" => "compaction_trigger"}]
      }

      base = RequestOptions.build(%{}, "/backend-api/codex/responses", payload)

      full_history_base =
        RequestOptions.build(
          %{},
          "/backend-api/codex/responses",
          %{"input" => [%{"type" => "compaction_trigger"}]}
        )

      cases = [
        {:ordinary, base},
        {:bridge_only,
         RequestOptions.put_payload_context(base, compaction_trigger_bridge?: true)},
        {:websocket_only, RequestOptions.for_websocket(base, payload)},
        {:collect_only,
         RequestOptions.put_transport(base, websocket_delivery_mode: :collect_compaction)},
        {:full_history,
         full_history_base
         |> RequestOptions.for_websocket(%{"input" => [%{"type" => "compaction_trigger"}]})
         |> RequestOptions.put_payload_context(compaction_trigger_bridge?: true)
         |> RequestOptions.put_transport(websocket_delivery_mode: :collect_compaction)},
        {:incremental_websocket_collect,
         base
         |> RequestOptions.for_websocket(payload)
         |> RequestOptions.put_payload_context(compaction_trigger_bridge?: true)
         |> RequestOptions.put_transport(websocket_delivery_mode: :collect_compaction)}
      ]

      for {name, options} <- cases do
        assert RequestOptions.connection_bound_compaction?(options) ==
                 (name == :incremental_websocket_collect)
      end
    end

    @tag :compaction_state_contract
    test "preserves typed compaction state through rebuild websocket retarget and reprojection" do
      source_payload = %{
        "previous_response_id" => "resp_fixture_transform_0001",
        "input" => [%{"type" => "compaction_trigger"}],
        "client_metadata" => %{
          "x-codex-turn-metadata" =>
            Jason.encode!(%{
              "compaction" => %{"implementation" => "responses_compaction_v2"}
            })
        }
      }

      projected = CompactionTrigger.project_responses_payload(source_payload, :sse)

      options =
        %{}
        |> RequestOptions.build("/backend-api/codex/responses", source_payload)
        |> RequestOptions.for_websocket(source_payload)
        |> RequestOptions.put_payload_context(
          compaction_trigger_bridge?: true,
          compaction_result_transport: :sse
        )
        |> RequestOptions.put_transport(websocket_delivery_mode: :collect_compaction)

      transformed = [
        RequestOptions.build(options, "/backend-api/codex/responses/compact", projected),
        RequestOptions.for_websocket(options, projected),
        RequestOptions.retarget(options, "/backend-api/codex/responses/compact", projected),
        options
        |> RequestOptions.retarget("/backend-api/codex/responses/compact", projected)
        |> RequestOptions.retarget("/backend-api/codex/responses/compact", projected)
      ]

      assert Enum.all?(transformed, fn transformed_options ->
               transformed_options.payload_context.compaction_input_mode == :incremental and
                 transformed_options.transport.websocket_delivery_mode == :collect_compaction and
                 transformed_options.payload_context.compaction_result_transport == :sse and
                 RequestOptions.connection_bound_compaction?(transformed_options)
             end)

      assert CompactionTrigger.project_responses_payload(projected, :sse) == projected
    end

    test "keeps compaction projection provenance typed, transient, redacted, and non-serializable" do
      downstream = %{
        "previous_response_id" => "resp_projection_raw_anchor_a",
        "input" => [
          %{"type" => "custom_tool_call_output", "output" => "raw tool output sentinel"},
          %{"type" => "compaction_trigger"}
        ]
      }

      compact = %{downstream | "input" => [%{"type" => "compaction_trigger"}]}
      context = CompactionProjectionContext.new(downstream, compact)

      options =
        RequestOptions.build(
          %{compaction_projection_context: context},
          "/backend-api/codex/responses/compact",
          compact
        )

      assert options.payload_context.compaction_projection_context == context
      assert options.extra == %{}
      assert inspect(context) == "#CompactionProjectionContext<redacted>"
      assert {:error, %Protocol.UndefinedError{}} = Jason.encode(context)

      assert {safe, finalized_options} =
               CompactionProjectionContext.finalize(options, compact)

      assert safe["action"] == "preserved"
      assert safe["downstream_frame"]["state"] == "valid"
      assert safe["downstream_frame"]["item_count"] == 2

      assert safe["downstream_frame"]["item_classes"] == %{
               "compaction_trigger" => 1,
               "tool_output" => 1
             }

      assert safe["compact_projection"]["item_classes"] == %{"compaction_trigger" => 1}
      assert safe["upstream_payload"]["state"] == "valid"
      assert safe["downstream_frame"]["anchor_fingerprint"] =~ ~r/\A[0-9a-f]{16}\z/
      refute inspect(safe) =~ "resp_projection_raw_anchor_a"
      refute inspect(safe) =~ "raw tool output sentinel"
      assert finalized_options.payload_context.compaction_projection_context == nil
      assert finalized_options.payload_context.compaction_projection == safe
    end

    test "caps compaction projection counts at one million without inspecting item bodies" do
      items = List.duplicate(%{"type" => "compaction_trigger"}, 1_000_001)
      context = CompactionProjectionContext.new(%{"input" => items}, %{"input" => []})
      safe = CompactionProjectionContext.finalize(context, %{"input" => []})

      assert safe["downstream_frame"]["item_count"] == 1_000_000
      assert safe["downstream_frame"]["count_capped"]
      assert safe["downstream_frame"]["item_classes"] == %{"compaction_trigger" => 1_000_000}
    end

    test "compaction projection provenance applies every action precedence and invalid anchor state" do
      valid_a = %{"previous_response_id" => "anchor-a", "input" => []}
      valid_b = %{"previous_response_id" => "anchor-b", "input" => []}
      absent = %{"input" => []}
      invalid = %{"previous_response_id" => 123, "input" => []}

      cases = [
        {:malformed_stage, valid_a, valid_a, "invalid"},
        {invalid, valid_a, valid_a, "invalid"},
        {absent, absent, absent, "absent"},
        {absent, valid_a, valid_a, "introduced"},
        {valid_a, absent, absent, "dropped"},
        {valid_a, valid_a, absent, "dropped"},
        {valid_a, valid_a, valid_a, "preserved"},
        {valid_a, valid_a, valid_b, "changed"}
      ]

      for {downstream, compact, upstream, action} <- cases do
        context = CompactionProjectionContext.new(downstream, compact)
        assert CompactionProjectionContext.finalize(context, upstream)["action"] == action
      end
    end

    test "compaction projection provenance uses only the fixed item class vocabulary" do
      payload = %{
        "input" => [
          %{"type" => "compaction_trigger"},
          %{"type" => "custom_tool_call"},
          %{"type" => "function_call"},
          %{"type" => "custom_tool_call_output"},
          %{"type" => "message"},
          %{"type" => "reasoning_summary"},
          %{"type" => "future_private_shape"},
          "scalar"
        ]
      }

      stage =
        payload
        |> CompactionProjectionContext.new(payload)
        |> CompactionProjectionContext.finalize(payload)
        |> Map.fetch!("downstream_frame")

      assert stage["item_classes"] == %{
               "compaction_trigger" => 1,
               "tool_call" => 2,
               "tool_output" => 1,
               "message" => 1,
               "reasoning" => 1,
               "other" => 2
             }
    end

    @tag :prompt_cache_adaptation
    test "prompt cache adaptation state is non-injectable and excluded from extra options" do
      for opts <- [
            %{prompt_cache_controls_downgraded: true},
            %{"prompt_cache_controls_downgraded" => true}
          ] do
        options =
          RequestOptions.build(
            opts,
            "/backend-api/codex/responses",
            %{"model" => "example-model"}
          )

        refute options.runtime.prompt_cache_controls_downgraded
        assert options.extra == %{}
      end
    end

    @tag :prompt_cache_adaptation
    test "prompt cache attempt metadata is exact and stays out of request compatibility metadata" do
      options =
        RequestOptions.build(
          %{},
          "/backend-api/codex/responses",
          %{"model" => "example-model"}
        )

      assert RequestOptions.prompt_cache_controls_attempt_metadata(options) == %{}
      assert RequestOptions.openai_compatibility_metadata(options) == %{}
      assert RequestOptions.payload_compression_request_metadata(options) == %{}

      updated =
        RequestOptions.put_runtime_context(options, prompt_cache_controls_downgraded: true)

      assert RequestOptions.prompt_cache_controls_attempt_metadata(updated) == %{
               "prompt_cache_controls_downgraded" => true
             }

      assert RequestOptions.openai_compatibility_metadata(updated) == %{}
      assert RequestOptions.payload_compression_request_metadata(updated) == %{}
    end

    test "defaults normalized previous response state false and permits only typed internal updates" do
      options =
        RequestOptions.build(
          %{upstream_previous_response_id?: true},
          "/backend-api/codex/responses",
          %{"model" => "example-model"}
        )

      refute options.continuity.upstream_previous_response_id?
      assert options.extra == %{}

      options = RequestOptions.put_continuity(options, upstream_previous_response_id?: true)
      assert options.continuity.upstream_previous_response_id?
      assert %Continuity{upstream_previous_response_id?: true} = options.continuity

      invalid_update =
        RequestOptions.put_continuity(options, upstream_previous_response_id?: "true")

      refute invalid_update.continuity.upstream_previous_response_id?

      assert %Request{connection_bound_continuation?: false} = %Request{}
    end

    test "uses the durable request claim without changing transient semantic identity" do
      semantic_turn_key = :crypto.strong_rand_bytes(32)
      turn_claim_key = "codex-turn:" <> Base.url_encode64(semantic_turn_key, padding: false)

      request_claim_key =
        "codex-request:" <>
          (:crypto.hash(:sha256, "synthetic-request-claim")
           |> Base.url_encode64(padding: false))

      options =
        RequestOptions.build(
          %{
            transport: "websocket",
            semantic_turn_key: semantic_turn_key,
            turn_claim_key: turn_claim_key,
            request_claim_key: request_claim_key
          },
          "/backend-api/codex/responses",
          %{"model" => "example-model"}
        )

      assert options.continuity.semantic_turn_key == semantic_turn_key
      assert options.continuity.turn_claim_key == turn_claim_key
      assert options.continuity.request_claim_key == request_claim_key
      assert RequestOptions.server_correlation_id(options) == request_claim_key
      assert RequestOptions.websocket_request_correlation_id(options) == request_claim_key

      persisted_request = %CodexPooler.Accounting.Request{correlation_id: request_claim_key}

      assert RequestOptions.websocket_denial_correlation_id(options, persisted_request) ==
               request_claim_key

      assert RequestOptions.websocket_denial_correlation_id(options, nil) == request_claim_key

      assert options.continuity.turn_claim_key == turn_claim_key

      invalid = RequestOptions.put_continuity(options, request_claim_key: "codex-request:invalid")
      assert invalid.continuity.request_claim_key == request_claim_key
    end

    test "websocket correlations fall back through turn claim and request id" do
      turn_claim_key =
        "codex-turn:" <>
          (:crypto.hash(:sha256, "fallback-turn-claim")
           |> Base.url_encode64(padding: false))

      turn_options =
        RequestOptions.build(
          %{
            transport: "websocket",
            request_id: "fallback-request-id",
            turn_claim_key: turn_claim_key
          },
          "/backend-api/codex/responses",
          %{"model" => "example-model"}
        )

      assert RequestOptions.server_correlation_id(turn_options) == turn_claim_key
      assert RequestOptions.websocket_request_correlation_id(turn_options) == turn_claim_key

      assert RequestOptions.websocket_denial_correlation_id(turn_options, nil) ==
               "fallback-request-id"

      request_options =
        RequestOptions.build(
          %{transport: "websocket", request_id: "fallback-request-id"},
          "/backend-api/codex/responses",
          %{"model" => "example-model"}
        )

      assert {:ok, _generated_id} =
               request_options
               |> RequestOptions.server_correlation_id()
               |> Ecto.UUID.cast()

      assert RequestOptions.websocket_request_correlation_id(request_options) ==
               "fallback-request-id"

      assert RequestOptions.websocket_denial_correlation_id(request_options, nil) ==
               "fallback-request-id"
    end

    test "compaction-shaped native frames keep the durable claim correlation without capability" do
      turn_claim_key =
        "codex-turn:" <>
          (:crypto.hash(:sha256, "shape-only-correlation")
           |> Base.url_encode64(padding: false))

      options =
        RequestOptions.build(
          %{transport: "websocket", turn_claim_key: turn_claim_key},
          "/backend-api/codex/responses",
          %{"model" => "example-model"}
        )

      payload = %{
        "type" => "response.create",
        "model" => "example-model",
        "input" => [%{"type" => "compaction"}]
      }

      assert RequestOptions.server_correlation_id(options, payload) == turn_claim_key
    end

    test "an attached owner capability does not mint a correlation without runtime proof" do
      turn_claim_key =
        "codex-turn:" <>
          (:crypto.hash(:sha256, "capability-correlation")
           |> Base.url_encode64(padding: false))

      options =
        RequestOptions.build(
          %{transport: "websocket", turn_claim_key: turn_claim_key},
          "/backend-api/codex/responses",
          %{"model" => "example-model"}
        )

      capability = native_compaction_capability()

      options =
        RequestOptions.put_native_compaction_admission(
          options,
          capability,
          {:direct, self()},
          %{lifecycle_id: capability.binding.lifecycle_id, generation: 1}
        )

      assert {:ok, ^capability, {:direct, owner}, %{generation: 1}} =
               RequestOptions.native_compaction_admission(options)

      assert owner == self()
      assert RequestOptions.server_correlation_id(options) == turn_claim_key
      refute inspect(options) =~ Base.encode16(capability.token)
    end

    test "a manually constructed admission carrier cannot mint a privileged correlation" do
      turn_claim_key =
        "codex-turn:" <>
          (:crypto.hash(:sha256, "forged-admission-correlation")
           |> Base.url_encode64(padding: false))

      options =
        RequestOptions.build(
          %{transport: "websocket", turn_claim_key: turn_claim_key},
          "/backend-api/codex/responses",
          %{"model" => "example-model"}
        )

      forged = %RequestOptions.NativeCompactionAdmission{
        capability: :not_a_capability,
        owner: :not_an_owner,
        expected_connection_lifecycle: :not_a_lifecycle
      }

      options = %{options | native_compaction_admission: forged}

      assert RequestOptions.native_compaction_admission(options) == {:error, :invalid_input}
      assert RequestOptions.server_correlation_id(options) == turn_claim_key
    end

    test "defaults unresolved legacy inputs to Full without manufacturing a resolved snapshot" do
      options =
        RequestOptions.build(%{}, "/backend-api/codex/responses", %{"model" => "example-model"})

      assert RequestOptions.model_serving_mode_configured(options) == nil
      assert RequestOptions.model_serving_mode(options) == "full"
      assert RequestOptions.model_serving_mode_source(options) == nil
      refute RequestOptions.use_responses_lite?(options)
    end

    test "honors the selected-assignment Lite fallback before serving mode resolution" do
      options =
        RequestOptions.build(
          %{use_responses_lite?: true},
          "/backend-api/codex/responses",
          %{"model" => "example-model"}
        )

      assert RequestOptions.model_serving_mode_snapshot(options) == nil
      assert RequestOptions.model_serving_mode_configured(options) == nil
      assert RequestOptions.model_serving_mode(options) == "full"
      assert RequestOptions.model_serving_mode_source(options) == nil
      assert RequestOptions.use_responses_lite?(options)
    end

    test "round trips every valid resolved serving mode snapshot exactly" do
      snapshots = [
        %{configured_mode: "auto", effective_mode: "lite", source: "catalog"},
        %{configured_mode: "auto", effective_mode: "full", source: "catalog"},
        %{configured_mode: "lite", effective_mode: "lite", source: "override"},
        %{configured_mode: "full", effective_mode: "full", source: "override"}
      ]

      for snapshot <- snapshots do
        options =
          %{}
          |> RequestOptions.build(
            "/backend-api/codex/responses",
            %{"model" => "example-model"}
          )
          |> RequestOptions.put_model_serving_mode(snapshot)

        assert RequestOptions.model_serving_mode_snapshot(options) == snapshot
        assert RequestOptions.model_serving_mode_configured(options) == snapshot.configured_mode
        assert RequestOptions.model_serving_mode(options) == snapshot.effective_mode
        assert RequestOptions.model_serving_mode_source(options) == snapshot.source

        assert RequestOptions.use_responses_lite?(options) ==
                 (snapshot.effective_mode == "lite")
      end
    end

    test "preserves one resolved Lite snapshot through option transformations and owner context" do
      options =
        %{}
        |> RequestOptions.build(
          "/backend-api/codex/responses",
          %{"model" => "example-model"}
        )
        |> RequestOptions.put_model_serving_mode(
          configured_mode: "auto",
          effective_mode: "lite",
          source: "catalog"
        )

      expected_snapshot = RequestOptions.model_serving_mode_snapshot(options)

      transformed = [
        RequestOptions.for_payload(
          options,
          "/backend-api/codex/responses/compact",
          %{"model" => "example-model"}
        ),
        RequestOptions.retarget(
          options,
          "/backend-api/codex/responses/compact",
          %{"model" => "example-model"}
        ),
        RequestOptions.for_websocket(options, %{"model" => "example-model"}),
        RequestOptions.put_continuity(options,
          previous_response_id: "resp_123",
          session_key: "affinity-key"
        ),
        RequestOptions.put_routing(options,
          file_affinity_assignment_id: Ecto.UUID.generate(),
          routing_attempt_metadata: %{"transform_fixture" => true}
        ),
        Websocket.websocket_owner_response_options(options, nil, "lease-token", %{
          pid: self(),
          correlation_id: "corr"
        })
      ]

      assert Enum.all?(transformed, fn transformed_options ->
               RequestOptions.model_serving_mode_snapshot(transformed_options) ==
                 expected_snapshot
             end)

      assert Enum.all?(transformed, &RequestOptions.use_responses_lite?/1)
    end

    test "rejects invalid or mutable resolved serving mode states" do
      endpoint = "/backend-api/codex/responses"
      payload = %{"model" => "example-model"}

      invalid_snapshots = [
        %{configured_mode: "auto", effective_mode: "auto", source: "catalog"},
        %{configured_mode: "auto", effective_mode: "lite", source: "override"},
        %{configured_mode: "lite", effective_mode: "full", source: "override"},
        %{configured_mode: "full", effective_mode: "full", source: "catalog"},
        %{configured_mode: "unknown", effective_mode: "full", source: "override"},
        %{configured_mode: "full", effective_mode: "full", source: "unknown"}
      ]

      for snapshot <- invalid_snapshots do
        assert_raise ArgumentError, fn ->
          %{}
          |> RequestOptions.build(endpoint, payload)
          |> RequestOptions.put_model_serving_mode(snapshot)
        end

        assert_raise ArgumentError, fn ->
          RequestOptions.build(
            %{
              requested_model: "example-model",
              model_serving_mode_configured: snapshot.configured_mode,
              model_serving_mode: snapshot.effective_mode,
              model_serving_mode_source: snapshot.source
            },
            endpoint,
            payload
          )
        end
      end

      options =
        %{}
        |> RequestOptions.build(endpoint, payload)
        |> RequestOptions.put_model_serving_mode(
          configured_mode: "full",
          effective_mode: "full",
          source: "override"
        )

      assert_raise ArgumentError, fn ->
        RequestOptions.put_model_serving_mode(options,
          configured_mode: "auto",
          effective_mode: "lite",
          source: "catalog"
        )
      end

      assert_raise ArgumentError, fn ->
        RequestOptions.put_routing(options, use_responses_lite?: true)
      end
    end

    test "accepts a resolved snapshot at construction without losing routing state" do
      options =
        RequestOptions.build(
          %{
            requested_model: "requested-model",
            effective_model: "effective-model",
            model_serving_mode_configured: "lite",
            model_serving_mode: "lite",
            model_serving_mode_source: "override"
          },
          "/backend-api/codex/responses",
          %{"model" => "requested-model"}
        )

      assert options.routing.requested_model == "requested-model"
      assert options.routing.effective_model == "effective-model"

      assert RequestOptions.model_serving_mode_snapshot(options) == %{
               configured_mode: "lite",
               effective_mode: "lite",
               source: "override"
             }

      assert RequestOptions.use_responses_lite?(options)
    end

    test "carries the reasoning decision through payload, websocket, and retargeting paths" do
      decision = %Decision{
        mode: :allow_up_to,
        configured_effort: "high",
        requested_effort: nil,
        applied_effort: "medium"
      }

      options =
        RequestOptions.build(
          %{reasoning_effort_decision: decision},
          "/backend-api/codex/responses",
          %{"model" => "example-model"}
        )

      assert options.routing.reasoning_effort_decision == decision

      assert options
             |> RequestOptions.for_payload(
               "/backend-api/codex/responses/compact",
               %{"model" => "example-model"}
             )
             |> then(&(&1.routing.reasoning_effort_decision == decision))

      assert options
             |> RequestOptions.for_websocket(%{"model" => "example-model"})
             |> then(&(&1.routing.reasoning_effort_decision == decision))

      assert options
             |> RequestOptions.retarget(
               "/backend-api/codex/responses/compact",
               %{"model" => "example-model"}
             )
             |> then(&(&1.routing.reasoning_effort_decision == decision))
    end

    test "defaults reasoning-summary parameter support true and preserves selected false" do
      options =
        RequestOptions.build(%{}, "/backend-api/codex/responses", %{"model" => "example-model"})

      assert options.routing.supports_reasoning_summary_parameter?

      selected =
        RequestOptions.put_routing(options,
          supports_reasoning_summary_parameter?: false,
          reasoning_effort_decision: options.routing.reasoning_effort_decision
        )

      refute selected.routing.supports_reasoning_summary_parameter?

      assert selected.routing.reasoning_effort_decision ==
               options.routing.reasoning_effort_decision
    end

    test "from_conn_metadata keeps request metadata and classifies payload routes" do
      options =
        RequestOptions.from_conn_metadata(
          %{
            request_id: "req_conn",
            client_ip: {127, 0, 0, 1},
            forwarded_headers: [{"x-codex-client", "fixture"}]
          },
          "/backend-api/codex/responses",
          %{"model" => "example-model", "stream" => true}
        )

      assert options.request_metadata.request_id == "req_conn"
      assert options.request_metadata.client_ip == {127, 0, 0, 1}
      assert options.transport.route_class == "proxy_stream"
      assert options.transport.forwarded_metadata_headers == [{"x-codex-client", "fixture"}]
      assert options.file_bridge.forwarded_headers == [{"x-codex-client", "fixture"}]
      assert options.extra == %{}
    end

    test "preserves ordinary request option context defaults" do
      options =
        RequestOptions.build(
          %{
            media_upload: %{size: 10},
            forced_transcription_model: "gpt-4o-transcribe"
          },
          "/backend-api/codex/responses",
          %{"model" => "example-model", "stream" => true}
        )

      assert options.payload_context.media_upload == %{size: 10}
      assert options.payload_context.forced_transcription_model == "gpt-4o-transcribe"
      assert options.transport.route_class == "proxy_stream"
      assert options.extra == %{}
    end

    test "for_websocket retargets typed options without caller-side transport maps" do
      options =
        %{request_id: "req_ws"}
        |> RequestOptions.from_conn_metadata("/v1/responses", %{})
        |> RequestOptions.put_continuity(previous_response_id: "resp_123")
        |> RequestOptions.for_websocket()

      assert options.request_metadata.request_id == "req_ws"
      assert options.continuity.previous_response_id == "resp_123"
      assert options.transport.transport == "websocket"
      assert options.transport.upstream_endpoint == "/backend-api/codex/responses"
      assert options.transport.route_class == "proxy_websocket"
    end

    test "for_websocket preserves trusted native and public origin fields" do
      payload = %{"model" => "example-model"}

      native_options =
        %{}
        |> RequestOptions.build("/backend-api/codex/responses", payload)
        |> RequestOptions.for_websocket(payload)

      public_options =
        %{
          openai_source_endpoint: "/v1/responses",
          public_openai_responses_stream: true
        }
        |> RequestOptions.build("/backend-api/codex/responses", payload)
        |> RequestOptions.for_websocket(payload)

      assert native_options.openai_compatibility.source_endpoint == nil
      refute native_options.openai_compatibility.public_openai_responses_stream
      assert public_options.openai_compatibility.source_endpoint == "/v1/responses"
      assert public_options.openai_compatibility.public_openai_responses_stream
    end

    @tag :external_issues_229_231
    @tag :issue_231
    test "translated Responses surface requires trusted source provenance and the exact backend endpoint" do
      payload = %{"model" => "example-model"}

      public_responses =
        %{}
        |> RequestOptions.build("/backend-api/codex/responses", payload)
        |> RequestOptions.mark_openai_compatibility_origin(
          "/v1/responses",
          "/backend-api/codex/responses"
        )

      public_chat =
        %{}
        |> RequestOptions.build("/backend-api/codex/responses", payload)
        |> RequestOptions.mark_openai_compatibility_origin(
          "/v1/chat/completions",
          "/backend-api/codex/responses"
        )

      backend_chat =
        %{}
        |> RequestOptions.build("/backend-api/codex/responses", payload)
        |> RequestOptions.mark_openai_compatibility_origin(
          "/backend-api/codex/v1/chat/completions",
          "/backend-api/codex/responses"
        )

      sse =
        RequestOptions.put_openai_compatibility(public_responses,
          public_openai_responses_stream: true
        )

      websocket = RequestOptions.for_websocket(sse, payload)
      raw_backend = RequestOptions.build(%{}, "/backend-api/codex/responses", payload)

      raw_backend_source =
        RequestOptions.build(
          %{openai_source_endpoint: "/backend-api/codex/responses"},
          "/backend-api/codex/responses",
          payload
        )

      wrong_media_endpoint =
        %{}
        |> RequestOptions.build("/backend-api/codex/images/generations", payload)
        |> RequestOptions.mark_openai_compatibility_origin(
          "/v1/images/generations",
          "/backend-api/codex/images/generations"
        )

      malformed_source =
        RequestOptions.build(
          %{
            openai_source_endpoint: "https://example.com/v1/responses",
            openai_translated_endpoint: "/backend-api/codex/responses"
          },
          "/backend-api/codex/responses",
          payload
        )

      assert OpenAICompatibility.translated_responses_surface?(
               public_responses.openai_compatibility
             )

      assert OpenAICompatibility.translated_responses_surface?(public_chat.openai_compatibility)
      assert OpenAICompatibility.translated_responses_surface?(backend_chat.openai_compatibility)
      assert OpenAICompatibility.translated_responses_surface?(sse.openai_compatibility)
      assert OpenAICompatibility.translated_responses_surface?(websocket.openai_compatibility)

      refute OpenAICompatibility.translated_responses_surface?(raw_backend.openai_compatibility)

      refute OpenAICompatibility.translated_responses_surface?(
               raw_backend_source.openai_compatibility
             )

      refute OpenAICompatibility.translated_responses_surface?(
               wrong_media_endpoint.openai_compatibility
             )

      refute OpenAICompatibility.translated_responses_surface?(
               malformed_source.openai_compatibility
             )

      assert websocket.openai_compatibility.source_endpoint == "/v1/responses"

      assert websocket.openai_compatibility.translated_endpoint ==
               "/backend-api/codex/responses"
    end

    test "keeps local alias provenance separate from live websocket continuity" do
      options =
        %{
          session_header: "local-session",
          session_header_source: "X-Session-Affinity",
          upstream_websocket_session: self(),
          websocket_owner_forwarding_enabled?: true,
          websocket_owner_session: %{id: "owner-session"},
          websocket_owner_lease_token: "lease-token",
          websocket_owner_downstream: %{pid: self(), correlation_id: "corr"},
          websocket_owner_downstream_epoch: 2
        }
        |> RequestOptions.from_conn_metadata("/backend-api/codex/responses", %{
          "model" => "example-model",
          "stream" => true
        })

      assert options.continuity.session_header == "local-session"
      assert options.continuity.session_header_source == "x-session-affinity"
      assert options.transport.upstream_websocket_session == self()
      assert options.transport.websocket_owner.enabled?
      assert options.transport.websocket_owner.session == %{id: "owner-session"}

      assert options.transport.websocket_owner.downstream == %{
               pid: self(),
               correlation_id: "corr"
             }

      assert options.transport.websocket_owner.downstream_epoch == 2
      assert options.extra == %{}
    end

    test "for_file_bridge applies narrow route and bridge updates" do
      options =
        RequestOptions.for_file_bridge(
          %{
            request_id: "req_file",
            forwarded_headers: [
              {"x-codex-client", "fixture"},
              {"x-codex-bad", :invalid}
            ]
          },
          "/v1/files",
          %{},
          route_class: RouteClass.file_upload(),
          operation: :create,
          endpoint: "/backend-api/files",
          route_metadata: %{"routing_strategy" => "affinity"}
        )

      assert options.request_metadata.request_id == "req_file"
      assert options.transport.route_class == "file_upload"
      assert options.transport.forwarded_metadata_headers == [{"x-codex-client", "fixture"}]
      assert options.file_bridge.operation == :create
      assert options.file_bridge.endpoint == "/backend-api/files"
      assert options.file_bridge.route_metadata == %{"routing_strategy" => "affinity"}
      assert options.file_bridge.forwarded_headers == [{"x-codex-client", "fixture"}]
    end
  end

  defp native_compaction_capability do
    binding = %NativeCompactionAdmission.Binding{
      semantic_turn_key: <<1::256>>,
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

    capability
  end

  describe "reset probe runtime context" do
    test "new/0 creates one unbound pooler-owned UUID" do
      probe = ResetProbe.new()
      token = probe.token

      assert {:ok, ^token} = Ecto.UUID.cast(token)
      assert probe.version == nil
      assert probe.pool_upstream_assignment_id == nil
      assert probe.upstream_identity_id == nil
      assert probe.effective_model == nil
      assert probe.route_class == nil
      refute ResetProbe.bound?(probe)
    end

    test "bind/5 adds the exact version 2 route scope without replacing the token" do
      probe = ResetProbe.new()

      assert {:ok, bound} =
               ResetProbe.bind(
                 probe,
                 @assignment_id,
                 @identity_id,
                 @effective_model,
                 @reset_probe_route_class
               )

      assert bound.token == probe.token
      assert bound.version == 2
      assert bound.pool_upstream_assignment_id == @assignment_id
      assert bound.upstream_identity_id == @identity_id
      assert bound.effective_model == @effective_model
      assert bound.route_class == @reset_probe_route_class
      assert ResetProbe.bound?(bound)

      assert ResetProbe.matches?(
               bound,
               @assignment_id,
               @identity_id,
               @effective_model,
               @reset_probe_route_class
             )
    end

    test "bind/5 is idempotent for the identical scope" do
      probe = ResetProbe.new()

      assert {:ok, bound} =
               ResetProbe.bind(
                 probe,
                 @assignment_id,
                 @identity_id,
                 @effective_model,
                 @reset_probe_route_class
               )

      assert {:ok, ^bound} =
               ResetProbe.bind(
                 bound,
                 @assignment_id,
                 @identity_id,
                 @effective_model,
                 @reset_probe_route_class
               )
    end

    test "bind/5 rejects malformed dimensions without changing the unbound value" do
      probe = ResetProbe.new()
      token = probe.token

      invalid_scopes = [
        {nil, @identity_id, @effective_model, @reset_probe_route_class},
        {"", @identity_id, @effective_model, @reset_probe_route_class},
        {"not-a-uuid", @identity_id, @effective_model, @reset_probe_route_class},
        {123, @identity_id, @effective_model, @reset_probe_route_class},
        {@assignment_id, nil, @effective_model, @reset_probe_route_class},
        {@assignment_id, " ", @effective_model, @reset_probe_route_class},
        {@assignment_id, "not-a-uuid", @effective_model, @reset_probe_route_class},
        {@assignment_id, 123, @effective_model, @reset_probe_route_class},
        {@assignment_id, @identity_id, nil, @reset_probe_route_class},
        {@assignment_id, @identity_id, " ", @reset_probe_route_class},
        {@assignment_id, @identity_id, " gpt-5.4", @reset_probe_route_class},
        {@assignment_id, @identity_id, 123, @reset_probe_route_class},
        {@assignment_id, @identity_id, @effective_model, nil},
        {@assignment_id, @identity_id, @effective_model, " "},
        {@assignment_id, @identity_id, @effective_model, 123}
      ]

      for {assignment_id, identity_id, effective_model, route_class} <- invalid_scopes do
        assert {:error, :invalid_scope} =
                 ResetProbe.bind(
                   probe,
                   assignment_id,
                   identity_id,
                   effective_model,
                   route_class
                 )
      end

      assert probe.version == nil
      assert probe.token == token
    end

    test "bind/5 rejects every changed or blank dimension without changing the bound value" do
      probe = ResetProbe.new()

      assert {:ok, bound} =
               ResetProbe.bind(
                 probe,
                 @assignment_id,
                 @identity_id,
                 @effective_model,
                 @reset_probe_route_class
               )

      changed_scopes = [
        {:scope_mismatch, "00000000-0000-0000-0000-000000000003", @identity_id, @effective_model,
         @reset_probe_route_class},
        {:scope_mismatch, @assignment_id, "00000000-0000-0000-0000-000000000004",
         @effective_model, @reset_probe_route_class},
        {:scope_mismatch, @assignment_id, @identity_id, "gpt-5.4-mini", @reset_probe_route_class},
        {:scope_mismatch, @assignment_id, @identity_id, "GPT-5.4", @reset_probe_route_class},
        {:scope_mismatch, @assignment_id, @identity_id, @effective_model, "proxy_stream"},
        {:invalid_scope, "", @identity_id, @effective_model, @reset_probe_route_class},
        {:invalid_scope, @assignment_id, " ", @effective_model, @reset_probe_route_class},
        {:invalid_scope, @assignment_id, @identity_id, "", @reset_probe_route_class},
        {:invalid_scope, @assignment_id, @identity_id, @effective_model, " "}
      ]

      for {expected_error, assignment_id, identity_id, effective_model, route_class} <-
            changed_scopes do
        assert {:error, ^expected_error} =
                 ResetProbe.bind(
                   bound,
                   assignment_id,
                   identity_id,
                   effective_model,
                   route_class
                 )

        refute ResetProbe.matches?(
                 bound,
                 assignment_id,
                 identity_id,
                 effective_model,
                 route_class
               )
      end

      assert bound.token == probe.token
      assert bound.version == 2
      assert bound.pool_upstream_assignment_id == @assignment_id
      assert bound.upstream_identity_id == @identity_id
      assert bound.effective_model == @effective_model
      assert bound.route_class == @reset_probe_route_class
    end

    test "one bound token survives existing update and retarget paths" do
      probe = ResetProbe.new()

      assert {:ok, bound} =
               ResetProbe.bind(
                 probe,
                 @assignment_id,
                 @identity_id,
                 @effective_model,
                 @reset_probe_route_class
               )

      options =
        RequestOptions.build(
          %{reset_probe: bound},
          "/backend-api/codex/responses",
          %{"model" => @effective_model}
        )

      transformed = [
        RequestOptions.build(options, "/backend-api/codex/responses", %{
          "model" => @effective_model
        }),
        RequestOptions.for_payload(options, "/backend-api/codex/responses", %{
          "model" => @effective_model
        }),
        RequestOptions.retarget(options, "/backend-api/codex/responses/compact", %{
          "model" => @effective_model
        }),
        RequestOptions.for_websocket(options, %{"model" => @effective_model}),
        RequestOptions.for_file_bridge(options, "/backend-api/files", %{}),
        RequestOptions.put_routing(options, quota_decision: %{"summary" => "allowed"}),
        RequestOptions.put_model_serving_mode(options,
          configured_mode: "full",
          effective_mode: "full",
          source: "override"
        )
      ]

      assert options.extra == %{}

      assert Enum.all?(transformed, fn transformed_options ->
               transformed_options.routing.reset_probe == bound
             end)

      assert Enum.all?(transformed, fn transformed_options ->
               transformed_options.routing.reset_probe.token == probe.token
             end)
    end

    test "routing updates allow only the same probe to become bound" do
      probe = ResetProbe.new()

      options =
        RequestOptions.build(
          %{reset_probe: probe},
          "/backend-api/codex/responses",
          %{"model" => @effective_model}
        )

      assert {:ok, bound} =
               ResetProbe.bind(
                 probe,
                 @assignment_id,
                 @identity_id,
                 @effective_model,
                 @reset_probe_route_class
               )

      updated = RequestOptions.put_routing(options, reset_probe: bound)
      assert updated.routing.reset_probe == bound

      replacement = ResetProbe.new()

      assert_raise ArgumentError, "reset probe context is immutable", fn ->
        RequestOptions.put_routing(updated, reset_probe: replacement)
      end

      assert_raise ArgumentError, "reset probe context is immutable", fn ->
        RequestOptions.put_routing(updated,
          reset_probe: %{bound | effective_model: String.upcase(@effective_model)}
        )
      end

      assert_raise ArgumentError, "reset probe context is immutable", fn ->
        RequestOptions.put_routing(updated,
          reset_probe: %{bound | route_class: String.upcase(@reset_probe_route_class)}
        )
      end

      assert_raise ArgumentError, "reset probe context is immutable", fn ->
        RequestOptions.put_routing(updated, reset_probe: nil)
      end

      assert updated.routing.reset_probe == bound
    end
  end

  describe "accounting quota decision projection" do
    test "omits the internal reset probe instead of serializing a redacted copy" do
      probe = ResetProbe.new()

      assert {:ok, bound} =
               ResetProbe.bind(
                 probe,
                 @assignment_id,
                 @identity_id,
                 @effective_model,
                 @reset_probe_route_class
               )

      token = probe.token

      quota_decision = %{
        "allowed" => true,
        "routing_state" => "reset_probe",
        "summary" => "guarded probe after saved reset pending confirmation",
        "reset_probe_candidate_count" => 1,
        "windowless_provider_available_candidate_count" => 2,
        "eligible_candidate_count" => 1,
        "reset_probe" => %{
          "token" => token,
          "scope" => %{
            "pool_upstream_assignment_id" => @assignment_id,
            "upstream_identity_id" => @identity_id,
            "effective_model" => @effective_model,
            "route_class" => @reset_probe_route_class
          }
        }
      }

      request_options =
        RequestOptions.build(
          %{quota_decision: quota_decision, reset_probe: bound},
          "/backend-api/codex/responses",
          %{"model" => @effective_model}
        )

      attrs =
        AccountingReservation.attrs(
          %{key_prefix: "sk-cxp-000000000000"},
          %{"model" => @effective_model},
          "/backend-api/codex/responses",
          request_options
        )

      projected_decision = attrs.request_metadata["quota_decision"]
      reset_probe_omitted = reset_probe_omitted?(projected_decision)
      token_omitted = metadata_excludes?(attrs.request_metadata, token)
      redaction_marker_omitted = metadata_excludes?(attrs.request_metadata, "[REDACTED]")

      assert reset_probe_omitted
      assert projected_decision == Map.drop(quota_decision, ["reset_probe"])
      assert token_omitted
      assert redaction_marker_omitted
    end
  end

  describe "native image request context" do
    test "default request option flows preserve native image context and projected metadata" do
      payload = %{"model" => "example-model"}

      options = [
        RequestOptions.build(%{}, "/backend-api/codex/images/generations", payload),
        RequestOptions.build(%{}, "/v1/responses", payload),
        RequestOptions.build(%{}, "/v1/chat/completions", payload),
        RequestOptions.build(%{}, "/backend-api/codex/responses", payload),
        RequestOptions.for_websocket(%{}, payload)
      ]

      assert Enum.all?(options, fn option ->
               option.payload_context.native_image_request? == false
             end)

      assert Enum.all?(options, fn option ->
               RequestOptions.openai_compatibility_metadata(option) == %{}
             end)
    end

    test "defaults false and normalizes only literal true while consuming the option" do
      endpoint = "/backend-api/codex/images/generations"
      payload = %{"model" => "example-model"}

      cases = [
        {:default, %{}, false},
        {false, %{native_image_request?: false}, false},
        {nil, %{native_image_request?: nil}, false},
        {:string, %{native_image_request?: "true"}, false},
        {:integer, %{native_image_request?: 1}, false},
        {:map, %{native_image_request?: %{}}, false},
        {:literal_true, %{native_image_request?: true}, true}
      ]

      for {label, opts, expected} <- cases do
        options = RequestOptions.build(opts, endpoint, payload)

        assert options.payload_context.native_image_request? == expected,
          message: "case: #{label}"

        assert options.extra == %{}, message: "case: #{label}"
      end
    end

    test "retargeting cannot manufacture the marker from request JSON" do
      options = RequestOptions.build(%{}, "/backend-api/codex/responses", %{})

      retargeted =
        RequestOptions.retarget(
          options,
          "/backend-api/codex/images/generations",
          %{"model" => "example-model", "native_image_request?" => true}
        )

      refute retargeted.payload_context.native_image_request?
      assert retargeted.extra == %{}
    end

    test "client request payloads cannot activate the server-owned marker" do
      for endpoint <- [
            "/backend-api/codex/images/generations",
            "/backend-api/codex/images/edits",
            "/v1/images/generations",
            "/v1/images/edits"
          ] do
        options =
          RequestOptions.build(%{}, endpoint, %{
            "model" => "example-model",
            "native_image_request?" => true
          })

        refute options.payload_context.native_image_request?
        assert options.extra == %{}
      end
    end
  end

  describe "image generation permission request context" do
    test "defaults false across native v1 chat responses and websocket option flows" do
      payload = %{"model" => "example-model"}

      options = [
        RequestOptions.build(%{}, "/backend-api/codex/images/generations", payload),
        RequestOptions.build(%{}, "/v1/responses", payload),
        RequestOptions.build(%{}, "/v1/chat/completions", payload),
        RequestOptions.build(%{}, "/backend-api/codex/responses", payload),
        RequestOptions.for_websocket(%{}, payload)
      ]

      assert Enum.all?(options, fn option ->
               option.payload_context.image_generation_permission_required? == false
             end)
    end

    test "accepts only the trusted server-side option as authority" do
      endpoint = "/backend-api/codex/images/generations"
      payload = %{"model" => "example-model"}

      trusted =
        RequestOptions.build(
          %{image_generation_permission_required?: true},
          endpoint,
          payload
        )

      untrusted_options = [
        RequestOptions.build(
          %{},
          endpoint,
          Map.put(payload, "image_generation_permission_required?", true)
        ),
        RequestOptions.build(
          %{},
          endpoint <> "?image_generation_permission_required?=true",
          payload
        ),
        RequestOptions.build(
          %{forwarded_headers: [{"x-image-generation-permission-required", "true"}]},
          endpoint,
          payload
        ),
        RequestOptions.build(
          %{extra: %{image_generation_permission_required?: true}},
          endpoint,
          payload
        ),
        RequestOptions.build(
          %{openai_chat_payload: %{image_generation_permission_required?: true}},
          endpoint,
          payload
        )
      ]

      assert trusted.payload_context.image_generation_permission_required?
      assert trusted.extra == %{}

      assert Enum.all?(untrusted_options, fn option ->
               option.payload_context.image_generation_permission_required? == false
             end)
    end

    test "preserves the trusted marker through payload enrichment and retargeting" do
      options =
        RequestOptions.build(
          %{image_generation_permission_required?: true},
          "/backend-api/codex/images/generations",
          %{"model" => "example-model"}
        )

      transformed = [
        RequestOptions.for_payload(
          options,
          "/backend-api/codex/responses",
          %{"model" => "example-model", "image_generation_permission_required?" => false}
        ),
        RequestOptions.retarget(
          options,
          "/backend-api/codex/responses",
          %{"model" => "example-model", "image_generation_permission_required?" => false}
        )
      ]

      assert Enum.all?(transformed, fn option ->
               option.payload_context.image_generation_permission_required?
             end)
    end

    test "omits the trusted marker from OpenAI and accounting metadata projections" do
      payload = %{"model" => "example-model"}

      options =
        RequestOptions.build(
          %{image_generation_permission_required?: true},
          "/backend-api/codex/images/generations",
          payload
        )

      attrs =
        AccountingReservation.attrs(
          %{key_prefix: "sk-cxp-000000000000"},
          payload,
          "/backend-api/codex/images/generations",
          options
        )

      assert options.payload_context.image_generation_permission_required?
      assert RequestOptions.openai_compatibility_metadata(options) == %{}
      refute Map.has_key?(attrs.request_metadata, "image_generation_permission_required?")
      refute Map.has_key?(attrs.request_metadata, :image_generation_permission_required?)
    end

    test "permits typed marker updates and rejects unknown payload context updates" do
      options = RequestOptions.build(%{}, "/backend-api/codex/responses", %{})

      updated =
        RequestOptions.put_payload_context(options, image_generation_permission_required?: true)

      assert updated.payload_context.image_generation_permission_required?

      assert_raise KeyError, fn ->
        RequestOptions.put_payload_context(updated, unknown_image_permission_marker?: true)
      end
    end
  end

  describe "build/3" do
    test "records inferred JSON request byte counts as numeric metadata" do
      payload = %{"model" => "example-model", "input" => "synthetic prompt"}

      options = RequestOptions.build(%{}, "/backend-api/codex/responses", payload)

      assert options.request_metadata.request_bytes == RequestOptions.json_request_bytes(payload)
      assert is_integer(options.request_metadata.request_bytes)
      refute inspect(options.request_metadata) =~ "synthetic prompt"
    end

    test "keeps explicit request byte counts from the caller" do
      options =
        RequestOptions.build(
          %{request_bytes: 123, upload_bytes: 456},
          "/backend-api/transcribe",
          %{"model" => "example-model"}
        )

      assert options.request_metadata.request_bytes == 123
      assert options.request_metadata.upload_bytes == 456
    end

    test "keeps gateway runtime context in typed fields" do
      writer = fn _frame -> :ok end
      circuit_state = %{id: "state"}
      chat_payload = %{"model" => "example-model", "messages" => []}
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      options =
        RequestOptions.build(
          %{
            now: now,
            reason: "client_disconnected",
            transport: "websocket",
            websocket_writer: writer,
            upstream_websocket_session: self(),
            session_key: "session-key",
            conversation_key: "conversation-key",
            owner_instance_id: "node-a",
            bridge_owner_lease_ttl_seconds: 120,
            reconnect_window_seconds: 30,
            quota_decision: %{"summary" => "allowed"},
            routing_attempt_metadata: %{"rank" => 1},
            routing_circuit_state: circuit_state,
            public_openai_chat_stream: true,
            collect_openai_response_stream: true,
            openai_chat_payload: chat_payload,
            defer_file_create_request: true,
            finalize_retry_timeout_ms: 1000,
            finalize_retry_interval_ms: 0,
            receive_timeout_ms: 25_000
          },
          "/backend-api/codex/responses",
          %{"model" => "example-model"}
        )

      assert options.transport.websocket_writer == writer
      assert options.transport.upstream_websocket_session == self()
      assert options.continuity.session_key == "session-key"
      assert options.continuity.session_header_source == nil
      assert options.continuity.conversation_key == "conversation-key"
      assert options.continuity.owner_instance_id == "node-a"
      assert options.continuity.bridge_owner_lease_ttl_seconds == 120
      assert options.continuity.reconnect_window_seconds == 30
      assert options.routing.quota_decision == %{"summary" => "allowed"}
      assert options.routing.routing_attempt_metadata == %{"rank" => 1}
      assert options.routing.routing_circuit_state == circuit_state
      assert options.openai_compatibility.public_openai_chat_stream
      assert options.openai_compatibility.collect_openai_response_stream
      assert options.openai_compatibility.openai_chat_payload == chat_payload
      assert options.file_bridge.defer_create_request
      assert options.file_bridge.finalize_retry_timeout_ms == 1000
      assert options.file_bridge.finalize_retry_interval_ms == 0
      assert options.runtime.now == now
      assert options.runtime.interrupt_reason == "client_disconnected"
      assert options.timeout_config.receive_timeout_ms == 25_000
      assert options.extra == %{}
    end

    test "keeps safe payload compression metadata in the runtime context" do
      sensitive_placeholder =
        "placeholder raw candidate prompt with bearer example-token and call id example-call"

      compression_metadata = %{
        "enabled" => true,
        "attempted" => true,
        "status" => "compressed",
        "reason" => nil,
        "route_class" => "proxy_stream",
        "transport" => "http",
        "tokenizer" => "local:o200k_base",
        "candidate_count" => 2,
        "compressed_count" => 1,
        "skipped_count" => 1,
        "original_bytes" => 1000,
        "compressed_bytes" => 400,
        "original_tokens" => 500,
        "compressed_tokens" => 200,
        "strategies" => ["log_output", "diff"],
        "elapsed_ms" => 4,
        "raw_candidate" => sensitive_placeholder,
        "call_id" => "call_sensitive_placeholder",
        "json_path" => "$.input[0].output"
      }

      options =
        RequestOptions.build(
          %{payload_compression: compression_metadata},
          "/backend-api/codex/responses",
          %{"model" => "example-model"}
        )

      assert options.runtime.payload_compression == %{
               "enabled" => true,
               "attempted" => true,
               "status" => "compressed",
               "route_class" => "proxy_stream",
               "transport" => "http",
               "tokenizer" => "local:o200k_base",
               "candidate_count" => 2,
               "compressed_count" => 1,
               "skipped_count" => 1,
               "original_bytes" => 1000,
               "compressed_bytes" => 400,
               "saved_bytes" => 600,
               "byte_savings_ratio" => 0.6,
               "byte_savings_percent" => 60.0,
               "compression_ratio" => 0.4,
               "original_tokens" => 500,
               "compressed_tokens" => 200,
               "saved_tokens" => 300,
               "token_savings_ratio" => 0.6,
               "token_savings_percent" => 60.0,
               "strategies" => ["log_output", "diff"],
               "elapsed_ms" => 4
             }

      assert RequestOptions.payload_compression_request_metadata(options) == %{
               "payload_compression" => options.runtime.payload_compression
             }

      metadata_text = inspect(options.runtime.payload_compression)
      refute metadata_text =~ sensitive_placeholder
      refute metadata_text =~ "call_sensitive_placeholder"
      refute metadata_text =~ "$.input[0].output"
      assert options.extra == %{}
    end

    test "allowlists payload compression strategy metadata" do
      options =
        RequestOptions.build(
          %{
            payload_compression: %{
              "attempted" => true,
              "status" => "compressed",
              "strategies" => [
                "log_output",
                "call_probe_secret",
                "json_document_lossless",
                "json_array_lossless"
              ],
              "candidate_count" => 1
            }
          },
          "/backend-api/codex/responses",
          %{"model" => "example-model"}
        )

      assert options.runtime.payload_compression["strategies"] == [
               "log_output",
               "json_document_lossless",
               "json_array_lossless"
             ]

      assert get_in(RequestOptions.payload_compression_attempt_metadata(options), [
               "payload_compression",
               "strategies"
             ]) == ["log_output", "json_document_lossless", "json_array_lossless"]

      refute inspect(options.runtime.payload_compression) =~ "call_probe_secret"
    end

    test "keeps tokenizer input limit metadata without raw skipped content" do
      sensitive_placeholder = "placeholder skipped tokenizer input body"

      options =
        RequestOptions.build(
          %{
            payload_compression: %{
              "attempted" => true,
              "status" => "skipped",
              "reason" => "tokenizer_input_limit",
              "candidate_count" => 2,
              "compressed_count" => 0,
              "skipped_count" => 2,
              "tokenizer_input_skipped_count" => 2,
              "raw_candidate" => sensitive_placeholder
            }
          },
          "/backend-api/codex/responses",
          %{"model" => "example-model"}
        )

      assert options.runtime.payload_compression == %{
               "attempted" => true,
               "status" => "skipped",
               "reason" => "tokenizer_input_limit",
               "candidate_count" => 2,
               "compressed_count" => 0,
               "skipped_count" => 2,
               "tokenizer_input_skipped_count" => 2
             }

      assert RequestOptions.payload_compression_request_metadata(options) == %{
               "payload_compression" => options.runtime.payload_compression
             }

      refute inspect(options.runtime.payload_compression) =~ sensitive_placeholder
    end

    test "normalizes payload compression updates through put_runtime_context" do
      options =
        %{}
        |> RequestOptions.build("/backend-api/codex/responses", %{"model" => "example-model"})
        |> RequestOptions.put_runtime_context(
          payload_compression: %{
            attempted: true,
            status: :no_change,
            reason: :no_token_shrink,
            original_bytes: 0,
            compressed_bytes: 0,
            original_tokens: 0,
            compressed_tokens: 0
          }
        )

      assert options.runtime.payload_compression == %{
               "attempted" => true,
               "status" => "no_change",
               "reason" => "no_token_shrink",
               "original_bytes" => 0,
               "compressed_bytes" => 0,
               "saved_bytes" => 0,
               "original_tokens" => 0,
               "compressed_tokens" => 0,
               "saved_tokens" => 0
             }
    end

    test "normalizes explicit interrupt reason without keeping legacy aliases in extra" do
      options =
        RequestOptions.build(
          %{interrupt_reason: "operator_closed", reason: "client_disconnected"},
          "/backend-api/codex/responses",
          %{"model" => "example-model"}
        )

      assert options.runtime.interrupt_reason == "operator_closed"
      assert options.extra == %{}
    end

    test "keeps usage authentication inputs typed and out of extra opts" do
      options =
        RequestOptions.build(
          %{
            authorization_header: "Bearer secret-token",
            chatgpt_account_id: "acct_usage_boundary"
          },
          "/api/codex/usage",
          %{}
        )

      assert options.usage_authentication.authorization_header == "Bearer secret-token"
      assert options.usage_authentication.chatgpt_account_id == "acct_usage_boundary"
      assert options.extra == %{}
    end

    test "keeps hashed prompt cache routing hints only for the exact routing allowlist" do
      allowed_routes = [
        "/v1/responses",
        "/v1/chat/completions",
        "/backend-api/codex/responses",
        "/backend-api/codex/v1/responses",
        "/backend-api/codex/v1/chat/completions"
      ]

      for endpoint <- allowed_routes do
        raw_prompt_cache_key = "  fixture-cache-key  "

        options =
          RequestOptions.build(
            %{request_method: "POST"},
            endpoint,
            %{"model" => "example-model", "prompt_cache_key" => raw_prompt_cache_key}
          )

        assert options.routing.prompt_cache_key == prompt_cache_key_hash("fixture-cache-key")
        assert options.routing.prompt_cache_key =~ ~r/\A[0-9a-f]{64}\z/
        refute options.routing.prompt_cache_key == raw_prompt_cache_key
        refute inspect(options.routing) =~ raw_prompt_cache_key
        assert options.extra == %{}
      end
    end

    test "canonicalizes prompt cache routing hints before hashing" do
      trimmed =
        RequestOptions.build(
          %{request_method: "POST"},
          "/backend-api/codex/responses",
          %{"model" => "example-model", "prompt_cache_key" => "fixture-cache-key"}
        )

      padded =
        RequestOptions.build(
          %{request_method: "POST"},
          "/backend-api/codex/responses",
          %{"model" => "example-model", "prompt_cache_key" => "  fixture-cache-key\n"}
        )

      assert trimmed.routing.prompt_cache_key == padded.routing.prompt_cache_key
      assert trimmed.routing.prompt_cache_key == prompt_cache_key_hash("fixture-cache-key")
    end

    test "treats blank and non-string prompt cache keys as absent" do
      for value <- ["", "   ", 123, true, nil, %{"unsafe" => "shape"}] do
        options =
          RequestOptions.build(
            %{request_method: "POST"},
            "/backend-api/codex/responses",
            %{"model" => "example-model", "prompt_cache_key" => value}
          )

        assert options.routing.prompt_cache_key == nil
        assert options.extra == %{}
      end
    end

    test "treats oversized prompt cache keys as absent" do
      oversized_key = "oversized-cache-key-" <> String.duplicate("x", 257)

      options =
        RequestOptions.build(
          %{request_method: "POST"},
          "/backend-api/codex/responses",
          %{"model" => "example-model", "prompt_cache_key" => oversized_key}
        )

      assert options.routing.prompt_cache_key == nil
      refute inspect(options.routing) =~ oversized_key
      assert options.extra == %{}
    end

    test "consumes raw prompt cache option keys without using them as routing input" do
      options =
        RequestOptions.build(
          %{
            "prompt_cache_key" => "string-opt-cache-key",
            prompt_cache_key: "atom-opt-cache-key"
          },
          "/backend-api/codex/responses",
          %{"model" => "example-model"}
        )

      assert options.routing.prompt_cache_key == nil
      assert options.extra == %{}
    end

    test "excludes prompt cache routing input from negative route surfaces" do
      negative_routes = [
        {"GET", "/backend-api/codex/responses", %{transport: "websocket"}},
        {"POST", "/backend-api/codex/responses/compact", %{}},
        {"POST", "/backend-api/codex/v1/responses/compact", %{}},
        {"POST", "/v1/responses/compact", %{}},
        {"POST", "/backend-api/files", %{}},
        {"POST", "/backend-api/files/file_fixture/uploaded", %{}},
        {"POST", "/backend-api/transcribe", %{}},
        {"POST", "/v1/audio/transcriptions", %{}},
        {"POST", "/v1/images/generations", %{}},
        {"POST", "/v1/images/edits", %{}},
        {"POST", "/backend-api/codex/images/generations", %{}},
        {"POST", "/backend-api/codex/images/edits", %{}}
      ]

      for {method, endpoint, opts} <- negative_routes do
        options =
          opts
          |> Map.put(:request_method, method)
          |> RequestOptions.build(endpoint, %{
            "model" => "example-model",
            "prompt_cache_key" => "fixture-cache-key"
          })

        assert options.routing.prompt_cache_key == nil
        assert options.extra == %{}
      end
    end

    test "websocket retargeting clears prompt cache routing input" do
      options =
        %{request_method: "POST"}
        |> RequestOptions.build("/backend-api/codex/responses", %{
          "model" => "example-model",
          "prompt_cache_key" => "fixture-cache-key"
        })
        |> RequestOptions.for_websocket(%{
          "model" => "example-model",
          "prompt_cache_key" => "fixture-cache-key"
        })

      assert options.transport.transport == "websocket"
      assert options.transport.route_class == "proxy_websocket"
      assert options.routing.prompt_cache_key == nil
    end

    test "classifies request compression route surfaces without promoting public compact" do
      cases = [
        {"POST", "/backend-api/codex/responses", %{}, nil, "proxy_http", "http_json"},
        {"POST", "/backend-api/codex/responses", %{"stream" => true}, nil, "proxy_stream",
         "http_sse"},
        {"POST", "/backend-api/codex/v1/responses", %{}, nil, "proxy_http", "http_json"},
        {"POST", "/backend-api/codex/v1/chat/completions", %{}, nil, "proxy_http", "http_json"},
        {"POST", "/v1/responses", %{}, nil, "proxy_http", "http_json"},
        {"POST", "/v1/chat/completions", %{}, nil, "proxy_http", "http_json"},
        {"POST", "/backend-api/codex/responses/compact", %{}, nil, "proxy_compact",
         "http_compact_json"},
        {"POST", "/backend-api/codex/v1/responses/compact", %{}, nil, "proxy_compact",
         "http_compact_json"},
        {"GET", "/backend-api/codex/responses", %{}, "websocket", "proxy_websocket", "websocket"},
        {"GET", "/backend-api/codex/v1/responses", %{}, "websocket", "proxy_websocket",
         "websocket"},
        {"GET", "/v1/responses", %{}, "websocket", "proxy_websocket", "websocket"},
        {"POST", "/v1/responses/compact", %{}, nil, "proxy_http", "http_json"}
      ]

      for {method, endpoint, payload, transport, route_class, transport_name} <- cases do
        opts = %{request_method: method}
        opts = if transport, do: Map.put(opts, :transport, transport), else: opts
        payload = Map.put(payload, "model", "example-model")

        options = RequestOptions.build(opts, endpoint, payload)

        assert options.transport.route_class == route_class
        assert options.transport.transport == transport_name
      end
    end

    test "keeps every consumed option key out of extra opts" do
      writer = fn _frame -> :ok end
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      codex_session = %{id: "session-id"}
      codex_turn_id = Ecto.UUID.generate()

      options =
        RequestOptions.build(
          %{
            "authorization_header" => "Bearer string-token",
            "chatgpt_account_id" => "acct_string",
            "prompt_cache_key" => "string-opt-cache-key",
            "transport" => "http_json",
            accepted_turn_state: "turn-state",
            authenticated_owner_attach: true,
            api_key_policy: %{allowed_model_identifiers: ["example-model"]},
            authorization_header: "Bearer atom-token",
            bridge_owner_lease_ttl_seconds: 30,
            chatgpt_account_id: "acct_atom",
            client_ip: "127.0.0.1",
            codex_session: codex_session,
            codex_turn_id: codex_turn_id,
            collect_openai_image_stream: true,
            collect_openai_response_stream: true,
            connect_timeout: 10,
            connect_timeout_ms: 11,
            conversation_key: "conversation-key",
            defer_file_create_request: true,
            effective_model: "example-model",
            file_affinity_assignment_id: Ecto.UUID.generate(),
            file_bridge_endpoint: "/backend-api/files",
            file_bridge_operation: :create,
            file_bridge_route_metadata: %{"route" => "file"},
            finalize_retry_interval_ms: 0,
            finalize_retry_timeout_ms: 500,
            forced_transcription_model: "gpt-4o-transcribe",
            forwarded_headers: [{"x-codex-client", "fixture"}],
            gateway_debug_payload: %{"shape" => "safe"},
            idempotency_key: "idem-key",
            interrupt_reason: "operator_closed",
            media_upload: %{size: 10},
            now: now,
            openai_chat_payload: %{"stream" => false},
            owner_instance_id: "owner-node",
            pool_timeout: 12,
            pool_timeout_ms: 13,
            pool_upstream_assignment_id: Ecto.UUID.generate(),
            previous_response_id: "resp_prev",
            prompt_cache_key: "atom-opt-cache-key",
            public_openai_chat_stream: true,
            public_openai_responses_stream: true,
            quota_decision: %{"summary" => "allowed"},
            reasoning_effort_snapshot: %{"effective_effort" => "low"},
            reason: "legacy_reason",
            receive_timeout: 14,
            receive_timeout_ms: 15,
            reconnect_window_seconds: 5,
            request_bytes: 123,
            request_content_type: "application/json",
            request_id: "req-known",
            requested_model: "example-model",
            response_id: "resp_current",
            routing_attempt_metadata: %{"rank" => 1},
            routing_circuit_state: %{state: "closed"},
            session_header: "session-header",
            session_header_source: "session-id",
            session_key: "session-key",
            timeout: 16,
            transport: "websocket",
            unknown_fixture: true,
            upload_bytes: 456,
            upstream_endpoint: "/backend-api/codex/responses",
            upstream_identity_id: Ecto.UUID.generate(),
            upstream_websocket_session: self(),
            user_agent: "codex-test",
            websocket_owner_downstream: %{pid: self()},
            websocket_owner_downstream_epoch: 1,
            websocket_owner_forwarder_opts: [timeout: 100],
            websocket_owner_forwarding_enabled?: true,
            websocket_owner_instance_id: "owner-node",
            websocket_owner_lease_token: "lease-token",
            websocket_owner_proxy_instance_id: "proxy-node",
            websocket_owner_session: %{id: "owner-session"},
            websocket_writer: writer
          },
          "/backend-api/codex/responses",
          %{"model" => "example-model"}
        )

      assert options.continuity.authenticated_owner_attach
      assert options.continuity.session_header_source == "session-id"
      assert options.extra == %{unknown_fixture: true}
    end

    test "normalizes session header provenance to the compatibility allowlist" do
      assert %{continuity: %{session_header_source: "x-codex-window-id"}} =
               RequestOptions.build(
                 %{session_header: "window-session", session_header_source: "X-Codex-Window-ID"},
                 "/backend-api/codex/responses",
                 %{"model" => "example-model"}
               )

      assert %{continuity: %{session_header_source: "session-id"}} =
               RequestOptions.build(
                 %{session_header: "local-session", session_header_source: "Session-ID"},
                 "/backend-api/codex/responses",
                 %{"model" => "example-model"}
               )

      assert %{continuity: %{session_header_source: "x-session-id"}} =
               RequestOptions.build(
                 %{session_header: "local-session", session_header_source: "X-Session-ID"},
                 "/backend-api/codex/responses",
                 %{"model" => "example-model"}
               )

      assert %{continuity: %{session_header_source: "x-session-affinity"}} =
               RequestOptions.build(
                 %{session_header: "affinity", session_header_source: :"x-session-affinity"},
                 "/backend-api/codex/responses",
                 %{"model" => "example-model"}
               )

      assert %{continuity: %{session_header_source: nil}} =
               RequestOptions.build(
                 %{session_header: "local-session", session_header_source: "x-unsafe-header"},
                 "/backend-api/codex/responses",
                 %{"model" => "example-model"}
               )
    end

    test "uses operational settings for upstream timeout defaults" do
      Application.put_env(:codex_pooler, OperationalSettings,
        settings: %OperationalSettings{
          upstream_connect_timeout_ms: 101,
          upstream_pool_timeout_ms: 202,
          upstream_receive_timeout_ms: 303
        }
      )

      options =
        RequestOptions.build(%{}, "/backend-api/codex/responses", %{"model" => "example-model"})

      assert options.timeout_config.connect_timeout_ms == 101
      assert options.timeout_config.pool_timeout_ms == 202
      assert options.timeout_config.receive_timeout_ms == 303
    end

    test "keeps explicit request timeouts ahead of operational defaults" do
      Application.put_env(:codex_pooler, OperationalSettings,
        settings: %OperationalSettings{
          upstream_connect_timeout_ms: 101,
          upstream_pool_timeout_ms: 202,
          upstream_receive_timeout_ms: 303
        }
      )

      options =
        RequestOptions.build(
          %{timeout: 10, connect_timeout_ms: 20, receive_timeout: 30},
          "/backend-api/codex/responses",
          %{"model" => "example-model"}
        )

      assert options.timeout_config.connect_timeout_ms == 20
      assert options.timeout_config.pool_timeout_ms == 10
      assert options.timeout_config.receive_timeout_ms == 30
    end

    test "ignores invalid legacy timeout values" do
      Application.put_env(:codex_pooler, OperationalSettings,
        settings: %OperationalSettings{
          upstream_connect_timeout_ms: 101,
          upstream_pool_timeout_ms: 202,
          upstream_receive_timeout_ms: 303
        }
      )

      options =
        RequestOptions.build(
          %{
            timeout: "30000",
            connect_timeout: -1,
            connect_timeout_ms: 0,
            pool_timeout: -5,
            receive_timeout: "slow",
            receive_timeout_ms: -30
          },
          "/backend-api/codex/responses",
          %{"model" => "example-model"}
        )

      assert options.timeout_config.connect_timeout_ms == 0
      assert options.timeout_config.pool_timeout_ms == 202
      assert options.timeout_config.receive_timeout_ms == 303
    end

    test "ignores invalid file bridge retry timeout values" do
      options =
        RequestOptions.build(
          %{
            finalize_retry_timeout_ms: "30000",
            finalize_retry_interval_ms: -1
          },
          "/backend-api/files/uploaded",
          %{}
        )

      assert options.file_bridge.finalize_retry_timeout_ms == nil
      assert options.file_bridge.finalize_retry_interval_ms == nil
      assert options.extra == %{}
    end

    test "normalizes legacy continuity fields and forwarded headers" do
      options =
        RequestOptions.build(
          %{
            bridge_owner_lease_ttl_seconds: 0,
            reconnect_window_seconds: -1,
            forwarded_headers: [
              {"user-agent", "codex_cli_rs/0.0.0"},
              {"x-openai-client-user-agent", "synthetic"},
              {"x-codex-client", :not_binary},
              ["x-codex-list", "not-a-tuple"],
              :invalid
            ]
          },
          "/backend-api/files",
          %{}
        )

      assert options.continuity.bridge_owner_lease_ttl_seconds == nil
      assert options.continuity.reconnect_window_seconds == nil

      assert options.transport.forwarded_metadata_headers == [
               {"user-agent", "codex_cli_rs/0.0.0"},
               {"x-openai-client-user-agent", "synthetic"}
             ]

      assert options.file_bridge.forwarded_headers == [
               {"user-agent", "codex_cli_rs/0.0.0"},
               {"x-openai-client-user-agent", "synthetic"}
             ]

      assert options.extra == %{}
    end

    test "normalizes typed continuity and file bridge updates" do
      options =
        %{}
        |> RequestOptions.build("/backend-api/files", %{})
        |> RequestOptions.put_continuity(
          bridge_owner_lease_ttl_seconds: "45",
          reconnect_window_seconds: 0
        )
        |> RequestOptions.put_file_bridge(
          forwarded_headers: [{"x-codex-client", "fixture"}, {"x-codex-client", 123}],
          finalize_retry_timeout_ms: -1,
          finalize_retry_interval_ms: 250
        )

      assert options.continuity.bridge_owner_lease_ttl_seconds == nil
      assert options.continuity.reconnect_window_seconds == 0
      assert options.file_bridge.forwarded_headers == [{"x-codex-client", "fixture"}]
      assert options.file_bridge.finalize_retry_timeout_ms == nil
      assert options.file_bridge.finalize_retry_interval_ms == 250
    end

    test "refreshes payload-sized metadata when reusing connection options" do
      connection_options =
        %{request_id: "ws-connection", transport: "websocket"}
        |> RequestOptions.build("/backend-api/codex/responses", %{})
        |> RequestOptions.put_request_metadata(request_bytes: nil)

      payload = %{"model" => "example-model", "input" => "hello"}

      options =
        RequestOptions.for_payload(
          connection_options,
          "/backend-api/codex/responses",
          payload
        )

      assert options.request_metadata.request_id == "ws-connection"
      assert options.request_metadata.request_bytes == RequestOptions.json_request_bytes(payload)
      assert options.transport.route_class == "proxy_websocket"
    end

    test "retargets typed options without a legacy option map round trip" do
      now = ~U[2026-01-02 03:04:05Z]

      request_options =
        %{request_id: "req_123", now: now, forwarded_headers: [{"x-codex-client", "fixture"}]}
        |> RequestOptions.build("/backend-api/codex/responses", %{"model" => "example-model"})
        |> RequestOptions.put_routing(quota_decision: %{"summary" => "allowed"})
        |> RequestOptions.put_file_bridge(defer_create_request: true)

      payload = %{"file_name" => "sample.txt", "file_size" => 123, "use_case" => "codex"}
      options = RequestOptions.retarget(request_options, "/backend-api/files", payload)

      assert options.request_metadata.request_id == "req_123"
      assert options.request_metadata.request_bytes == RequestOptions.json_request_bytes(payload)
      assert options.transport.transport == "http_json"
      assert options.transport.upstream_endpoint == "/backend-api/files"
      assert options.transport.route_class == "file_upload"
      assert options.transport.forwarded_metadata_headers == [{"x-codex-client", "fixture"}]
      assert options.routing.quota_decision == %{"summary" => "allowed"}
      assert options.file_bridge.defer_create_request
      assert options.file_bridge.forwarded_headers == [{"x-codex-client", "fixture"}]
      assert options.runtime.now == now
      refute Map.has_key?(options.extra, :route_class)
    end

    test "keeps owner forwarding disabled in typed defaults" do
      options =
        RequestOptions.build(%{}, "/backend-api/codex/responses", %{"model" => "example-model"})

      assert options.transport.upstream_websocket_session == nil
      refute options.transport.websocket_owner.enabled?
      assert options.transport.websocket_owner.session == nil
      assert options.transport.websocket_owner.lease_token == nil
      assert options.transport.websocket_owner.downstream == nil
      assert options.transport.websocket_owner.downstream_epoch == nil
      assert options.transport.websocket_owner.proxy_instance_id == nil
      assert options.transport.websocket_owner.owner_instance_id == nil
      assert options.continuity.owner_instance_id == nil
      assert options.extra == %{}
    end

    test "keeps owner forwarding handoff metadata typed and out of extra opts" do
      owner_session = %{id: "codex-session-id", owner_instance_id: "owner-node@example"}
      downstream = %{pid: self(), epoch: 3, correlation_id: "corr-owner-safe"}

      options =
        RequestOptions.build(
          %{
            websocket_owner_forwarding_enabled?: true,
            websocket_owner_session: owner_session,
            websocket_owner_lease_token: "lease-token-not-logged",
            websocket_owner_downstream: downstream,
            websocket_owner_downstream_epoch: 3,
            websocket_owner_proxy_instance_id: "proxy-node@example",
            websocket_owner_instance_id: "owner-node@example",
            websocket_owner_forwarder_opts: [timeout: 123]
          },
          "/backend-api/codex/responses",
          %{"model" => "example-model"}
        )

      assert options.transport.websocket_owner.enabled?
      assert options.transport.websocket_owner.session == owner_session
      assert options.transport.websocket_owner.lease_token == "lease-token-not-logged"
      assert options.transport.websocket_owner.downstream == downstream
      assert options.transport.websocket_owner.downstream_epoch == 3
      assert options.transport.websocket_owner.proxy_instance_id == "proxy-node@example"
      assert options.transport.websocket_owner.owner_instance_id == "owner-node@example"
      assert options.transport.websocket_owner.forwarder_opts == [timeout: 123]
      assert options.extra == %{}
    end

    test "rebuilds existing typed options without flattening typed updates through legacy opts" do
      connection_options =
        %{request_id: "ws-connection", transport: "websocket"}
        |> RequestOptions.build("/backend-api/codex/responses", %{})
        |> RequestOptions.put_request_metadata(request_bytes: nil)
        |> RequestOptions.put_transport(route_class: "custom_stream")

      payload = %{"model" => "example-model", "input" => "hello"}

      options =
        RequestOptions.build(
          connection_options,
          "/backend-api/codex/responses",
          payload
        )

      assert options.request_metadata.request_id == "ws-connection"
      assert options.request_metadata.request_bytes == RequestOptions.json_request_bytes(payload)
      assert options.transport.route_class == "custom_stream"
      assert options.transport.forwarded_metadata_headers == []
      refute Map.has_key?(options.extra, :route_class)
    end
  end

  describe "route_class/1" do
    test "classifies websocket transport from normalized opts" do
      options =
        RequestOptions.build(
          %{transport: "websocket"},
          "/backend-api/codex/responses",
          %{}
        )

      assert RequestOptions.route_class(options) == "proxy_websocket"
    end

    test "classifies streaming JSON from the payload" do
      options =
        RequestOptions.build(
          %{},
          "/backend-api/codex/responses",
          %{"stream" => true}
        )

      assert RequestOptions.route_class(options) == "proxy_stream"
    end

    test "returns nil when the typed transport has no route class" do
      options =
        %{}
        |> RequestOptions.build("/backend-api/codex/responses", %{"model" => "example-model"})
        |> RequestOptions.put_transport(route_class: nil)

      assert RequestOptions.route_class(options) == nil
    end
  end

  describe "section updaters" do
    test "apply known keyword updates to typed sections" do
      writer = fn _frame -> :ok end

      options =
        %{}
        |> RequestOptions.build("/backend-api/codex/responses", %{"model" => "example-model"})
        |> RequestOptions.put_transport(
          websocket_writer: writer,
          forwarded_metadata_headers: [
            {"x-codex-client", "fixture"},
            {"x-codex-client", :invalid},
            ["x-openai-client-user-agent", "invalid"],
            :invalid
          ]
        )
        |> RequestOptions.put_continuity(previous_response_id: "resp_123")
        |> RequestOptions.put_routing(quota_decision: %{"summary" => "allowed"})
        |> RequestOptions.put_runtime_context(interrupt_reason: "operator_closed")
        |> RequestOptions.put_openai_compatibility(public_openai_responses_stream: true)
        |> RequestOptions.put_file_bridge(pool_upstream_assignment_id: "assignment-id")

      assert options.transport.websocket_writer == writer
      assert options.transport.forwarded_metadata_headers == [{"x-codex-client", "fixture"}]
      assert options.continuity.previous_response_id == "resp_123"
      assert options.routing.quota_decision == %{"summary" => "allowed"}
      assert options.runtime.interrupt_reason == "operator_closed"
      assert options.openai_compatibility.public_openai_responses_stream
      assert options.file_bridge.pool_upstream_assignment_id == "assignment-id"
    end

    test "optional normalizers ignore invalid updates instead of clearing existing values" do
      options =
        RequestOptions.build(
          %{
            session_header_source: "session-id",
            forwarded_headers: [{"x-codex-client", "fixture"}],
            finalize_retry_timeout_ms: 500,
            payload_compression: %{"attempted" => true, "status" => "compressed"},
            websocket_owner_forwarding_enabled?: true,
            websocket_owner_downstream: %{pid: self()},
            websocket_owner_downstream_epoch: 3
          },
          "/backend-api/codex/responses",
          %{"model" => "example-model"}
        )

      updated =
        options
        |> RequestOptions.put_continuity(
          session_header_source: "x-unsafe-header",
          reconnect_window_seconds: -1
        )
        |> RequestOptions.put_transport(
          forwarded_metadata_headers: [{"x-codex-client", :invalid}],
          websocket_owner_downstream_epoch: "stale"
        )
        |> RequestOptions.put_file_bridge(
          forwarded_headers: [{"x-codex-client", :invalid}],
          finalize_retry_timeout_ms: -1
        )
        |> RequestOptions.put_runtime_context(
          payload_compression: %{"enabled" => true, "attempted" => false, "status" => "disabled"}
        )

      assert updated.continuity.session_header_source == "session-id"
      assert updated.continuity.reconnect_window_seconds == nil
      assert updated.transport.forwarded_metadata_headers == [{"x-codex-client", "fixture"}]
      assert updated.transport.websocket_owner.downstream_epoch == 3
      assert updated.file_bridge.forwarded_headers == [{"x-codex-client", "fixture"}]
      assert updated.file_bridge.finalize_retry_timeout_ms == 500

      assert updated.runtime.payload_compression == %{
               "attempted" => true,
               "status" => "compressed"
             }
    end

    test "optional normalizers still accept explicit valid replacements" do
      options =
        RequestOptions.build(
          %{
            session_header_source: "session-id",
            forwarded_headers: [{"x-codex-client", "fixture"}],
            finalize_retry_timeout_ms: 500,
            payload_compression: %{"attempted" => true, "status" => "compressed"},
            websocket_owner_forwarding_enabled?: true,
            websocket_owner_downstream_epoch: 3
          },
          "/backend-api/codex/responses",
          %{"model" => "example-model"}
        )

      updated =
        options
        |> RequestOptions.put_continuity(session_header_source: "x-session-id")
        |> RequestOptions.put_transport(
          forwarded_metadata_headers: [{"x-openai-client-user-agent", "synthetic"}],
          websocket_owner_downstream_epoch: 4
        )
        |> RequestOptions.put_file_bridge(
          forwarded_headers: [{"user-agent", "codex_cli_rs/0.0.0"}],
          finalize_retry_timeout_ms: 0
        )
        |> RequestOptions.put_runtime_context(
          payload_compression: %{"attempted" => true, "status" => "no_change"}
        )

      assert updated.continuity.session_header_source == "x-session-id"

      assert updated.transport.forwarded_metadata_headers == [
               {"x-openai-client-user-agent", "synthetic"}
             ]

      assert updated.transport.websocket_owner.downstream_epoch == 4
      assert updated.file_bridge.forwarded_headers == [{"user-agent", "codex_cli_rs/0.0.0"}]
      assert updated.file_bridge.finalize_retry_timeout_ms == 0

      assert updated.runtime.payload_compression == %{
               "attempted" => true,
               "status" => "no_change"
             }
    end

    test "reject unknown section fields" do
      options =
        RequestOptions.build(%{}, "/backend-api/codex/responses", %{"model" => "example-model"})

      assert_raise KeyError, fn ->
        RequestOptions.put_request_metadata(options, unknown_field: true)
      end

      assert_raise KeyError, fn ->
        RequestOptions.put_transport(options, unknown_field: true)
      end

      assert_raise KeyError, fn ->
        RequestOptions.put_continuity(options, unknown_field: true)
      end

      assert_raise KeyError, fn ->
        RequestOptions.put_routing(options, unknown_field: true)
      end

      assert_raise KeyError, fn ->
        RequestOptions.put_runtime_context(options, unknown_field: true)
      end

      assert_raise KeyError, fn ->
        RequestOptions.put_openai_compatibility(options, unknown_field: true)
      end

      assert_raise KeyError, fn ->
        RequestOptions.put_file_bridge(options, unknown_field: true)
      end
    end
  end

  describe "json_request_bytes/1" do
    test "returns nil for payloads that cannot be encoded as JSON" do
      assert RequestOptions.json_request_bytes(%{"callback" => fn -> :ok end}) == nil
    end
  end

  defp prompt_cache_key_hash(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end

  defp reset_probe_omitted?(decision),
    do: is_map(decision) and not Map.has_key?(decision, "reset_probe")

  defp metadata_excludes?(metadata, value), do: not String.contains?(inspect(metadata), value)
end
