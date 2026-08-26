defmodule CodexPooler.Gateway.Payloads.CompactionTriggerTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Payloads.CompactionTrigger

  @fixture_path Path.expand(
                  "../../../fixtures/codex/rust-v0.150.0-3b3b4f8fb3f6403e72c2d0533ed0d2f309c59717/remote_compaction_v2_request.json",
                  __DIR__
                )
  @external_resource @fixture_path

  @incremental_fixture_path Path.expand(
                              "../../../fixtures/codex/rust-v0.150.0-3b3b4f8fb3f6403e72c2d0533ed0d2f309c59717/remote_compaction_v2_incremental_request.json",
                              __DIR__
                            )
  @external_resource @incremental_fixture_path

  describe "Responses compact projection" do
    test "locks the released Codex projection-relevant incremental frame contract" do
      fixture = load_incremental_fixture!()

      assert fixture["fixture_source"] == %{
               "tag" => "rust-v0.150.0",
               "annotated_tag_object" => "9bdd7a39c5034657dfbbb89381cd9364f61eee11",
               "peeled_commit" => "3b3b4f8fb3f6403e72c2d0533ed0d2f309c59717",
               "source_paths" => [
                 "codex-rs/codex-api/src/common.rs",
                 "codex-rs/core/src/client.rs",
                 "codex-rs/core/src/compact_remote_v2_attempt.rs",
                 "codex-rs/protocol/src/models.rs"
               ]
             }

      contract = fixture["contract"]
      assert contract["durability_boundary"] == "projection_relevant_incremental_frame_subset"

      assert contract["v2_trigger_metadata"]
             |> Map.fetch!("x-codex-turn-metadata")
             |> Jason.decode!() == %{
               "context_window_id" => "00000000-0000-4000-8000-000000000150",
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
               "tag" => "rust-v0.150.0",
               "annotated_tag_object" => "9bdd7a39c5034657dfbbb89381cd9364f61eee11",
               "peeled_commit" => "3b3b4f8fb3f6403e72c2d0533ed0d2f309c59717",
               "source_paths" => [
                 "codex-rs/core/src/compact_remote_v2_attempt.rs",
                 "codex-rs/core/src/client.rs",
                 "codex-rs/core/src/responses_metadata.rs",
                 "codex-rs/core/src/turn_metadata_tests.rs"
               ]
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
end
