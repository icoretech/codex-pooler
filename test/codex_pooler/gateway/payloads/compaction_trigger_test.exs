defmodule CodexPooler.Gateway.Payloads.CompactionTriggerTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Payloads.CompactionTrigger

  @fixture_path Path.expand(
                  "../../../fixtures/codex/rust-v0.153.3-b1a547b1f73ce86205d9222ac19cff334b3b7a2e/remote_compaction_v2_request.json",
                  __DIR__
                )
  @external_resource @fixture_path

  @incremental_fixture_path Path.expand(
                              "../../../fixtures/codex/rust-v0.153.3-b1a547b1f73ce86205d9222ac19cff334b3b7a2e/remote_compaction_v2_incremental_request.json",
                              __DIR__
                            )
  @external_resource @incremental_fixture_path

  describe "prepare_bridge/2" do
    test "accepts a final native trigger after a zero-byte function output" do
      payload = zero_byte_compaction_payload()

      assert {:ok, projected} =
               CompactionTrigger.prepare_bridge("/backend-api/codex/responses", payload)

      assert projected["input"] == payload["input"]
      assert projected["store"] == false
      refute Map.has_key?(projected, "stream")
    end

    test "keeps public visible-input strictness for a zero-byte function output" do
      assert {:error, %{status: 400, code: "invalid_request", param: "input"}} =
               CompactionTrigger.prepare_bridge("/v1/responses", zero_byte_compaction_payload())
    end

    test "keeps public singleton trigger rejection" do
      assert {:error, %{status: 400, code: "invalid_request", param: "input"}} =
               CompactionTrigger.prepare_bridge("/v1/responses", %{
                 "input" => [%{"type" => "compaction_trigger"}]
               })
    end

    test "preserves native singleton and nonempty controls while rejecting malformed triggers" do
      trigger = %{"type" => "compaction_trigger"}

      assert {:ok, _projected} =
               CompactionTrigger.prepare_bridge("/backend-api/codex/responses", %{
                 "input" => [trigger],
                 "stream" => true
               })

      nonempty = put_in(zero_byte_compaction_payload(), ["input", Access.at(0), "output"], "ok")

      assert {:ok, _projected} =
               CompactionTrigger.prepare_bridge("/backend-api/codex/responses", nonempty)

      for input <- [
            [
              trigger,
              %{"type" => "function_call_output", "call_id" => "call_fixture", "output" => ""}
            ],
            [
              %{"type" => "function_call_output", "call_id" => "call_fixture", "output" => ""},
              trigger,
              trigger
            ]
          ] do
        assert {:error, %{status: 400, code: "invalid_request", param: "input"}} =
                 CompactionTrigger.prepare_bridge("/backend-api/codex/responses", %{
                   "input" => input,
                   "stream" => true
                 })
      end
    end
  end

  describe "Responses compact projection" do
    @tag :compaction_state_baseline
    test "characterizes anchor projection and the bounded result transport before typed state" do
      anchored = incremental_scenario!("anchored_tool_output_and_trigger")
      trigger_only = incremental_scenario!("anchored_trigger_only")

      for payload <- [anchored, trigger_only] do
        projected = CompactionTrigger.project_responses_payload(payload, :sse)

        assert projected["previous_response_id"] == payload["previous_response_id"]
        assert projected["input"] == payload["input"]
        assert CompactionTrigger.compaction_result_transport(payload) == :sse
      end

      for anchor <- [:absent, nil, 7, false, [], %{}, "", " \t\r\n"] do
        payload =
          if anchor == :absent,
            do: Map.delete(trigger_only, "previous_response_id"),
            else: Map.put(trigger_only, "previous_response_id", anchor)

        refute Map.has_key?(
                 CompactionTrigger.project_responses_payload(payload, :sse),
                 "previous_response_id"
               )
      end

      assert CompactionTrigger.compaction_result_transport(%{}) == :buffered
    end

    @tag :compaction_state_contract
    test "classifies compaction input mode only from a valid top-level anchor" do
      anchored_output = incremental_scenario!("anchored_tool_output_and_trigger")
      anchored_trigger = incremental_scenario!("anchored_trigger_only")
      full_history = incremental_scenario!("full_history_without_anchor")

      assert CompactionTrigger.compaction_input_mode(anchored_output) == :incremental
      assert CompactionTrigger.compaction_input_mode(anchored_trigger) == :incremental
      assert CompactionTrigger.compaction_input_mode(full_history) == :full_history

      for anchor <- [nil, 7, false, [], %{}, "", " \t\r\n"] do
        assert full_history
               |> Map.put("previous_response_id", anchor)
               |> CompactionTrigger.compaction_input_mode() == :full_history
      end
    end

    @tag :compaction_state_contract
    test "classifies anchored custom tool output solely from the top-level anchor" do
      payload = %{
        "previous_response_id" => "resp_fixture_custom_output_0001",
        "input" => [
          %{
            "type" => "custom_tool_call_output",
            "call_id" => "call_fixture_custom_output",
            "output" => "synthetic output"
          },
          %{"type" => "compaction_trigger"}
        ]
      }

      assert CompactionTrigger.compaction_input_mode(payload) == :incremental

      assert payload
             |> Map.put("input", [%{"type" => "future_item_without_tool_semantics"}])
             |> CompactionTrigger.compaction_input_mode() == :incremental
    end

    @tag :compaction_state_contract
    test "keeps source-derived mode stable across repeated compact projection" do
      for {scenario, expected_mode} <- [
            {"anchored_tool_output_and_trigger", :incremental},
            {"anchored_trigger_only", :incremental},
            {"full_history_without_anchor", :full_history}
          ] do
        payload = incremental_scenario!(scenario)
        mode = CompactionTrigger.compaction_input_mode(payload)

        first = CompactionTrigger.project_responses_payload(payload, :sse)
        second = CompactionTrigger.project_responses_payload(first, :sse)

        assert mode == expected_mode
        assert CompactionTrigger.compaction_input_mode(first) == expected_mode
        assert CompactionTrigger.compaction_input_mode(second) == expected_mode
        assert second == first
      end
    end

    test "locks the released Codex projection-relevant incremental frame contract" do
      fixture = load_incremental_fixture!()

      assert fixture["fixture_source"] == %{
               "tag" => "rust-v0.153.3",
               "annotated_tag_object" => "29d1e7f316229cd65c7e4a70476050c14962cf10",
               "peeled_commit" => "b1a547b1f73ce86205d9222ac19cff334b3b7a2e",
               "source_paths" => [
                 "codex-rs/codex-api/src/common.rs",
                 "codex-rs/core/src/client.rs",
                 "codex-rs/core/src/compact_remote_v2.rs",
                 "codex-rs/core/src/compact_remote_v2_attempt.rs",
                 "codex-rs/core/src/responses_metadata.rs",
                 "codex-rs/core/src/session/session.rs",
                 "codex-rs/core/src/turn_metadata_tests.rs",
                 "codex-rs/protocol/src/models.rs",
                 "codex-rs/core/tests/suite/realtime_conversation.rs"
               ]
             }

      contract = fixture["contract"]
      assert contract["durability_boundary"] == "projection_relevant_incremental_frame_subset"

      assert contract["zero_byte_function_call_output"] == %{
               "type" => "function_call_output",
               "output_byte_length" => 0,
               "followed_by_final_compaction_trigger" => true
             }

      assert contract["v2_trigger_metadata"]
             |> Map.fetch!("x-codex-turn-metadata")
             |> Jason.decode!() == %{
               "window_number" => 0,
               "context_window_id" => "00000000-0000-4000-8000-000000000153",
               "compaction" => %{"implementation" => "responses_compaction_v2"}
             }

      assert contract["provider_response_id"] == "resp_fixture_incremental_0001"
      assert Enum.map(contract["previous_request_input"], & &1["type"]) == ["message"]

      assert Enum.map(contract["provider_added_response_items"], & &1["type"]) == [
               "function_call"
             ]

      anchored_output = incremental_scenario!("anchored_tool_output_and_trigger")
      anchored_trigger = incremental_scenario!("anchored_trigger_only")

      assert frame_types(anchored_output) == [
               "function_call_output",
               "compaction_trigger"
             ]

      assert anchored_output["input"] |> Enum.at(0) |> Map.take(["name", "namespace"]) == %{
               "name" => "fixture_tool",
               "namespace" => "fixture.tools"
             }

      assert frame_types(anchored_trigger) == [
               "compaction_trigger"
             ]

      full_history = incremental_scenario!("full_history_without_anchor")
      baseline = contract["previous_request_input"] ++ contract["provider_added_response_items"]

      assert get_in(contract, [
               "scenarios",
               "anchored_tool_output_and_trigger",
               "current_logical_history"
             ]) ==
               baseline ++ anchored_output["input"]

      assert get_in(contract, ["scenarios", "anchored_trigger_only", "current_logical_history"]) ==
               baseline ++ anchored_trigger["input"]

      assert get_in(contract, [
               "scenarios",
               "full_history_without_anchor",
               "current_logical_history"
             ]) ==
               full_history["input"]

      assert anchored_output["previous_response_id"] == contract["provider_response_id"]
      assert anchored_trigger["previous_response_id"] == contract["provider_response_id"]

      assert frame_types(full_history) == [
               "message",
               "function_call",
               "function_call_output",
               "compaction_trigger"
             ]

      refute Map.has_key?(full_history, "previous_response_id")

      for subset <- [anchored_output, anchored_trigger, full_history] do
        assert_projection_relevant_subset(subset, contract["v2_trigger_metadata"])
      end
    end

    test "preserves exact anchors for every released incremental subset" do
      for scenario <- ["anchored_tool_output_and_trigger", "anchored_trigger_only"] do
        subset = incremental_scenario!(scenario)
        projected = CompactionTrigger.project_responses_payload(subset, :sse)

        assert projected["previous_response_id"] == subset["previous_response_id"]
        assert projected["input"] == subset["input"]
      end
    end

    test "keeps an explicit nonblank binary anchor byte-for-byte across repeated projections" do
      anchor = " \tresp_fixture_bytes_0001\n"

      payload =
        incremental_scenario!("anchored_tool_output_and_trigger")
        |> Map.put("previous_response_id", anchor)

      first = CompactionTrigger.project_responses_payload(payload, :sse)
      second = CompactionTrigger.project_responses_payload(first, :sse)
      third = CompactionTrigger.project_responses_payload(second, :sse)

      assert first["previous_response_id"] == anchor
      assert second == first
      assert third == first
    end

    test "preserves the anchor independently of an unknown future output suffix" do
      payload = %{
        "model" => "gpt-fixture",
        "previous_response_id" => "resp_fixture_future_0001",
        "input" => [
          %{
            "type" => "future_tool_output_v9",
            "call_id" => "call_fixture_future",
            "result" => "fixture future output"
          },
          %{"type" => "compaction_trigger"}
        ]
      }

      projected = CompactionTrigger.project_responses_payload(payload)

      assert projected["previous_response_id"] == payload["previous_response_id"]
      assert projected["input"] == payload["input"]
    end

    test "omits absent, nonbinary, and whitespace-only anchors" do
      frame = incremental_scenario!("anchored_trigger_only")

      invalid_anchors = [:absent, nil, 7, false, [], %{}, "", " \t\r\n"]

      for anchor <- invalid_anchors do
        payload =
          if anchor == :absent,
            do: Map.delete(frame, "previous_response_id"),
            else: Map.put(frame, "previous_response_id", anchor)

        projected = CompactionTrigger.project_responses_payload(payload, :sse)

        refute Map.has_key?(projected, "previous_response_id")
      end
    end

    test "keeps full-history no-anchor projection and native projection unchanged" do
      full_history = incremental_scenario!("full_history_without_anchor")
      anchored = incremental_scenario!("anchored_tool_output_and_trigger")

      responses_projection = CompactionTrigger.project_responses_payload(full_history, :sse)
      native_projection = CompactionTrigger.project_native_payload(anchored)

      refute Map.has_key?(responses_projection, "previous_response_id")
      assert responses_projection["input"] == full_history["input"]
      refute Map.has_key?(native_projection, "previous_response_id")
      refute Map.has_key?(native_projection, "store")
      refute Map.has_key?(native_projection, "stream")

      refute Enum.any?(
               native_projection["input"],
               &match?(%{"type" => "compaction_trigger"}, &1)
             )
    end
  end

  describe "V2 compaction result transport" do
    test "keeps the historical minimal V2 marker streaming and buffers malformed or nonmatching metadata" do
      assert result_transport(%{
               "client_metadata" => %{
                 "x-codex-turn-metadata" =>
                   Jason.encode!(%{
                     "compaction" => %{"implementation" => "responses_compaction_v2"}
                   })
               }
             }) == :sse

      for payload <- [
            %{"client_metadata" => %{"x-codex-turn-metadata" => "not-json"}},
            %{"client_metadata" => %{"x-codex-turn-metadata" => "[]"}},
            %{"client_metadata" => %{"x-codex-turn-metadata" => "true"}},
            %{"client_metadata" => %{"x-codex-turn-metadata" => Jason.encode!(%{})}},
            %{
              "client_metadata" => %{
                "x-codex-turn-metadata" =>
                  Jason.encode!(%{"compaction" => %{"implementation" => "other"}})
              }
            },
            %{"client_metadata" => ["not", "a", "map"]},
            %{}
          ] do
        assert result_transport(payload) == :buffered
      end
    end

    test "streams the version-pinned rich RemoteCompactionV2 request with additive auto metadata" do
      fixture = load_fixture!()

      assert fixture["fixture_source"] == %{
               "tag" => "rust-v0.153.3",
               "annotated_tag_object" => "29d1e7f316229cd65c7e4a70476050c14962cf10",
               "peeled_commit" => "b1a547b1f73ce86205d9222ac19cff334b3b7a2e",
               "source_paths" => [
                 "codex-rs/core/src/client.rs",
                 "codex-rs/core/src/compact_remote_v2.rs",
                 "codex-rs/core/src/compact_remote_v2_attempt.rs",
                 "codex-rs/core/src/responses_metadata.rs",
                 "codex-rs/core/src/session/session.rs",
                 "codex-rs/core/src/turn_metadata_tests.rs",
                 "codex-rs/protocol/src/models.rs",
                 "codex-rs/core/tests/suite/realtime_conversation.rs"
               ]
             }

      assert fixture["request"]
             |> get_in(["client_metadata", "x-codex-turn-metadata"])
             |> Jason.decode!()
             |> Map.take(["window_number", "context_window_id", "request_kind", "compaction"]) ==
               %{
                 "window_number" => 0,
                 "context_window_id" => "00000000-0000-4000-8000-000000000153",
                 "request_kind" => "compaction",
                 "compaction" => %{
                   "trigger" => "auto",
                   "reason" => "context_limit",
                   "implementation" => "responses_compaction_v2",
                   "phase" => "mid_turn",
                   "strategy" => "memento"
                 }
               }

      assert result_transport(fixture["request"]) == :sse
    end

    test "streams V2 metadata with pre-turn phase and unrelated prompt-like additive metadata" do
      turn_metadata = %{
        "request_kind" => "compaction",
        "compaction" => %{
          "trigger" => "auto",
          "implementation" => "responses_compaction_v2",
          "phase" => "pre_turn"
        },
        "unrelated_additive_metadata" => "synthetic instruction-like content"
      }

      assert result_transport(%{
               "client_metadata" => %{
                 "x-codex-turn-metadata" => Jason.encode!(turn_metadata)
               }
             }) == :sse
    end
  end

  defp result_transport(payload), do: CompactionTrigger.compaction_result_transport(payload)

  defp load_fixture! do
    @fixture_path
    |> File.read!()
    |> Jason.decode!()
  end

  defp incremental_scenario!(scenario) do
    load_incremental_fixture!()
    |> get_in(["contract", "scenarios", scenario, "projection_relevant_frame_subset"])
  end

  defp load_incremental_fixture! do
    @incremental_fixture_path
    |> File.read!()
    |> Jason.decode!()
  end

  defp frame_types(frame), do: Enum.map(frame["input"], & &1["type"])

  defp assert_projection_relevant_subset(subset, v2_trigger_metadata) do
    assert subset["type"] == "response.create"
    assert subset["stream"]
    assert subset["client_metadata"] == v2_trigger_metadata
    assert CompactionTrigger.compaction_result_transport(subset) == :sse
    assert is_list(subset["input"])
  end

  defp zero_byte_compaction_payload do
    %{
      "input" => [
        %{
          "type" => "function_call_output",
          "call_id" => "call_fixture_zero_byte",
          "output" => ""
        },
        %{"type" => "compaction_trigger"}
      ],
      "stream" => true
    }
  end
end
