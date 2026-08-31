defmodule CodexPooler.Gateway.Payloads.NativeCodexTurnMetadataTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Payloads.NativeCodexTurnMetadata

  @session_id "018f60df-713f-7ca8-b9a0-0d12c508a123"

  test "parses the bounded canonical turn snapshot" do
    assert {:ok, metadata} =
             NativeCodexTurnMetadata.parse(
               payload(%{
                 "turn_id" => "turn:1",
                 "window_id" => "window-1",
                 "context_window_id" => "00000000-0000-4000-8000-000000000151",
                 "window_number" => 7,
                 "request_kind" => "compaction",
                 "compaction" => %{
                   "trigger" => "auto",
                   "reason" => "context_limit",
                   "implementation" => "responses_compaction_v2",
                   "phase" => "mid_turn",
                   "strategy" => "memento"
                 }
               }),
               @session_id
             )

    assert metadata.request_kind == :compaction
    assert metadata.window_number == 7
    assert metadata.compaction.phase == :mid_turn
    assert byte_size(metadata.semantic_turn_key) == 32
    refute inspect(metadata) =~ "window-1"
  end

  test "accepts a canonical JSON string and regular turns without compaction metadata" do
    metadata = %{
      "turn_id" => "turn-1",
      "window_id" => "window-1",
      "context_window_id" => "00000000-0000-4000-8000-000000000151",
      "request_kind" => "turn"
    }

    assert {:ok, parsed} =
             NativeCodexTurnMetadata.parse(
               %{
                 "client_metadata" => %{
                   "x-codex-turn-metadata" => Jason.encode!(metadata)
                 }
               },
               @session_id
             )

    assert parsed.request_kind == :turn
    assert parsed.compaction == nil
    assert parsed.window_number == nil
  end

  test "accepts released fresh ordinary and prewarm metadata without compaction authority" do
    for request_kind <- ["turn", "prewarm"], encoding <- [:direct, :encoded] do
      canonical = %{
        "session_id" => "client-supplied-session-is-not-authority",
        "thread_id" => "018f60df-713f-7ca8-b9a0-0d12c508a456",
        "turn_id" => "turn-fresh-#{request_kind}",
        "request_kind" => request_kind,
        "sandbox_mode" => "danger-full-access"
      }

      canonical = if encoding == :encoded, do: Jason.encode!(canonical), else: canonical

      assert {:ok, parsed} = NativeCodexTurnMetadata.parse(payload(canonical), @session_id)
      assert parsed.request_kind == String.to_existing_atom(request_kind)
      assert parsed.compaction == nil
      assert parsed.window_id_digest == nil
      assert parsed.context_window_id_digest == nil
      assert parsed.window_number == nil
    end
  end

  test "accepts released startup prewarm without a turn id or compaction binding" do
    canonical = %{
      "session_id" => "client-supplied-session-is-not-authority",
      "thread_id" => Ecto.UUID.generate(),
      "turn_id" => "",
      "request_kind" => "prewarm",
      "sandbox_mode" => "read-only"
    }

    for value <- [Jason.encode!(canonical), canonical] do
      assert {:ok, parsed} = NativeCodexTurnMetadata.parse(payload(value), @session_id)
      assert parsed.request_kind == :prewarm
      assert parsed.semantic_turn_key == nil
      assert parsed.window_id_digest == nil
      assert parsed.context_window_id_digest == nil
      assert parsed.compaction == nil
    end
  end

  test "keeps explicit compaction metadata strict and classifies rejection without raw values" do
    sentinel = "raw-native-metadata-sentinel"

    malformed = %{
      "turn_id" => "turn-compaction",
      "window_id" => "window-compaction",
      "context_window_id" => "not-a-uuid-#{sentinel}",
      "window_number" => 1,
      "request_kind" => "compaction",
      "compaction" => %{
        "trigger" => "auto",
        "reason" => "context_limit",
        "implementation" => "responses_compaction_v2",
        "phase" => "mid_turn",
        "strategy" => "memento"
      }
    }

    assert {:error, reason} = NativeCodexTurnMetadata.parse(payload(malformed), @session_id)
    assert NativeCodexTurnMetadata.rejection_class(reason) == :invalid_context_window_id
    refute inspect(NativeCodexTurnMetadata.rejection_class(reason)) =~ sentinel
  end

  test "accepts every released compaction enum value and rejects unsupported values" do
    defaults = %{
      "trigger" => "auto",
      "reason" => "context_limit",
      "implementation" => "responses_compaction_v2",
      "phase" => "mid_turn",
      "strategy" => "memento"
    }

    values = %{
      "trigger" => ["auto", "manual"],
      "reason" => [
        "user_requested",
        "context_limit",
        "model_downshift",
        "comp_hash_changed"
      ],
      "implementation" => ["responses", "responses_compaction_v2", "responses_compact"],
      "phase" => ["standalone_turn", "pre_turn", "mid_turn"],
      "strategy" => ["memento", "prefix_compaction"]
    }

    for {field, allowed_values} <- values, value <- allowed_values do
      assert {:ok, %{request_kind: :compaction}} =
               NativeCodexTurnMetadata.parse(
                 payload(compaction_metadata(Map.put(defaults, field, value))),
                 @session_id
               )
    end

    for field <- Map.keys(values) do
      assert {:error, reason} =
               NativeCodexTurnMetadata.parse(
                 payload(compaction_metadata(Map.put(defaults, field, "unsupported"))),
                 @session_id
               )

      assert NativeCodexTurnMetadata.rejection_class(reason) == :invalid_compaction
    end
  end

  test "recognizes released memory metadata without turn identity or native authority" do
    canonical = %{
      "session_id" => "untrusted-memory-session",
      "thread_id" => Ecto.UUID.generate(),
      "request_kind" => "memory",
      "unknown_sibling" => "ignored"
    }

    for value <- [Jason.encode!(canonical), canonical] do
      assert {:ok, parsed} = NativeCodexTurnMetadata.parse(payload(value), @session_id)
      assert parsed.request_kind == :memory
      assert parsed.semantic_turn_key == nil
      assert parsed.window_id_digest == nil
      assert parsed.context_window_id_digest == nil
      assert parsed.compaction == nil
    end
  end

  test "rejects explicit null compaction on every non-compaction request kind" do
    for request_kind <- ["turn", "prewarm", "memory"] do
      canonical =
        %{"request_kind" => request_kind, "compaction" => nil}
        |> then(fn metadata ->
          if request_kind == "memory" do
            metadata
          else
            Map.put(metadata, "turn_id", "turn-#{request_kind}")
          end
        end)

      assert {:error, reason} = NativeCodexTurnMetadata.parse(payload(canonical), @session_id)
      assert NativeCodexTurnMetadata.rejection_class(reason) == :invalid_compaction
    end
  end

  test "rejects malformed, missing, blank, oversized, and unsupported canonical fields" do
    valid = %{
      "turn_id" => "turn-1",
      "window_id" => "window-1",
      "context_window_id" => "00000000-0000-4000-8000-000000000151",
      "request_kind" => "turn"
    }

    invalid_metadata = [
      [],
      Map.delete(valid, "turn_id"),
      Map.put(valid, "turn_id", "bad/value"),
      Map.put(valid, "window_id", ""),
      Map.put(valid, "window_id", String.duplicate("w", 257)),
      Map.put(valid, "context_window_id", "not-a-uuid"),
      Map.put(valid, "context_window_id", String.duplicate("c", 257)),
      Map.put(valid, "window_number", -1),
      Map.put(valid, "window_number", 1.5),
      Map.put(valid, "request_kind", "unsupported"),
      Map.put(valid, "compaction", %{"implementation" => "responses_compaction_v2"}),
      Map.merge(valid, %{"request_kind" => "compaction", "compaction" => nil}),
      Map.merge(valid, %{
        "request_kind" => "compaction",
        "compaction" => %{
          "trigger" => "unexpected",
          "reason" => "context_limit",
          "implementation" => "responses_compaction_v2",
          "phase" => "mid_turn",
          "strategy" => "memento"
        }
      })
    ]

    for metadata <- invalid_metadata do
      assert {:error, %{status: 400, code: "invalid_request"}} =
               NativeCodexTurnMetadata.parse(payload(metadata), @session_id)
    end

    assert {:error, %{status: 400, code: "invalid_request"}} =
             NativeCodexTurnMetadata.parse(
               %{
                 "client_metadata" => %{
                   "x-codex-turn-metadata" => String.duplicate("x", 4_097)
                 }
               },
               @session_id
             )
  end

  test "produces domain-separated deterministic keyed digests without raw leakage" do
    sentinel = "raw-sentinel-#{System.unique_integer([:positive])}"

    assert NativeCodexTurnMetadata.response_id_digest(sentinel) ==
             NativeCodexTurnMetadata.response_id_digest(sentinel)

    refute NativeCodexTurnMetadata.response_id_digest(sentinel) ==
             NativeCodexTurnMetadata.response_id_digest(sentinel <> "-different")

    refute NativeCodexTurnMetadata.response_id_digest(sentinel) ==
             NativeCodexTurnMetadata.window_id_digest(sentinel)

    assert NativeCodexTurnMetadata.compaction_item_digest(%{
             "encrypted_content" => "opaque",
             "type" => "compaction"
           }) ==
             NativeCodexTurnMetadata.compaction_item_digest(%{
               "type" => "compaction",
               "encrypted_content" => "opaque"
             })

    for digest <- [
          NativeCodexTurnMetadata.response_id_digest(sentinel),
          NativeCodexTurnMetadata.window_id_digest(sentinel),
          NativeCodexTurnMetadata.context_id_digest(sentinel),
          NativeCodexTurnMetadata.compaction_item_digest(%{"value" => sentinel})
        ] do
      assert byte_size(digest) == 32
      refute inspect(digest) =~ sentinel
    end
  end

  defp payload(metadata) do
    %{"client_metadata" => %{"x-codex-turn-metadata" => metadata}}
  end

  defp compaction_metadata(compaction) do
    %{
      "turn_id" => "turn-compaction-enums",
      "window_id" => "window-compaction-enums",
      "context_window_id" => "00000000-0000-4000-8000-000000000151",
      "window_number" => 1,
      "request_kind" => "compaction",
      "compaction" => compaction
    }
  end
end
