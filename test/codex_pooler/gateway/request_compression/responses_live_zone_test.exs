defmodule CodexPooler.Gateway.RequestCompression.ResponsesLiveZoneTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.RequestCompression.ResponsesLiveZone

  @min_candidate_bytes 512

  describe "plan_candidates/2" do
    test "plans every supported same-frame tool-output item type" do
      json =
        encode_request([
          %{
            "type" => "function_call",
            "call_id" => "call_function",
            "name" => "run_command"
          },
          %{
            "type" => "function_call_output",
            "call_id" => "call_function",
            "output" => large_output("function")
          },
          %{
            "type" => "local_shell_call_output",
            "call_id" => "call_shell",
            "output" => large_output("shell")
          },
          %{
            "type" => "apply_patch_call_output",
            "call_id" => "call_patch",
            "output" => large_output("patch")
          }
        ])

      assert {:ok, candidates} =
               ResponsesLiveZone.plan_candidates(json, min_bytes: @min_candidate_bytes)

      assert Enum.map(candidates, & &1.item_type) == [
               "function_call_output",
               "local_shell_call_output",
               "apply_patch_call_output"
             ]

      assert Enum.map(candidates, & &1.output_path) == [
               ["input", 1, "output"],
               ["input", 2, "output"],
               ["input", 3, "output"]
             ]

      assert Enum.all?(candidates, &(&1.output_byte_size >= @min_candidate_bytes))

      Enum.each(candidates, fn candidate ->
        encoded_output = slice(json, candidate)
        assert String.starts_with?(encoded_output, ~S("))
        assert String.ends_with?(encoded_output, ~S("))
      end)
    end

    test "handles item key order differences" do
      output = large_output("order")

      json =
        ~s({"model":"gpt-fixture","input":[{"output":#{Jason.encode!(output)},"call_id":"call_order","type":"local_shell_call_output"}]})

      assert {:ok, [candidate]} =
               ResponsesLiveZone.plan_candidates(json, min_bytes: @min_candidate_bytes)

      assert candidate.item_type == "local_shell_call_output"
      assert candidate.output_path == ["input", 0, "output"]
    end

    test "skips supported output strings below the minimum byte threshold" do
      json =
        encode_request([
          %{
            "type" => "function_call_output",
            "call_id" => "call_small",
            "output" => String.duplicate("x", @min_candidate_bytes - 1)
          }
        ])

      assert {:ok, []} =
               ResponsesLiveZone.plan_candidates(json, min_bytes: @min_candidate_bytes)
    end

    test "returns invalid JSON errors and no-ops malformed input shapes" do
      assert {:error, :invalid_json} =
               ResponsesLiveZone.plan_candidates(~S({"input":[), min_bytes: @min_candidate_bytes)

      malformed_payloads = [
        ~S({"model":"gpt-fixture"}),
        ~S({"model":"gpt-fixture","input":null}),
        ~S({"model":"gpt-fixture","input":{"type":"function_call_output","output":"ignored"}}),
        ~S({"model":"gpt-fixture","input":"ignored"}),
        Jason.encode!(%{
          "model" => "gpt-fixture",
          "input" => [
            %{
              "type" => "function_call_output",
              "call_id" => "call_object_output",
              "output" => %{"value" => large_output("object")}
            }
          ]
        })
      ]

      for payload <- malformed_payloads do
        assert {:ok, []} =
                 ResponsesLiveZone.plan_candidates(payload, min_bytes: @min_candidate_bytes)
      end
    end

    test "skips outputs whose call id belongs to external retrieval calls" do
      json =
        encode_request([
          %{
            "type" => "function_call",
            "call_id" => "call_retrieve_direct",
            "name" => external_retrieval_tool_name()
          },
          %{
            "type" => "function_call_output",
            "call_id" => "call_retrieve_direct",
            "output" => large_output("retrieve direct")
          },
          %{
            "type" => "function_call",
            "call_id" => "call_retrieve_suffix",
            "name" => external_retrieval_tool_name("example__")
          },
          %{
            "type" => "local_shell_call_output",
            "call_id" => "call_retrieve_suffix",
            "output" => large_output("retrieve suffix")
          },
          %{
            "type" => "apply_patch_call_output",
            "call_id" => "call_keep",
            "output" => large_output("kept")
          }
        ])

      assert {:ok, [candidate]} =
               ResponsesLiveZone.plan_candidates(json, min_bytes: @min_candidate_bytes)

      assert candidate.item_type == "apply_patch_call_output"
      assert candidate.output_path == ["input", 4, "output"]
    end

    test "skips outputs whose call id belongs to excluded function tool names" do
      json =
        encode_request([
          %{
            "type" => "function_call",
            "call_id" => "call_read",
            "name" => "Read"
          },
          %{
            "type" => "function_call_output",
            "call_id" => "call_read",
            "output" => large_output("read")
          },
          %{
            "type" => "function_call",
            "call_id" => "call_custom",
            "name" => "Serena.Find_Symbol"
          },
          %{
            "type" => "function_call_output",
            "call_id" => "call_custom",
            "output" => large_output("custom")
          },
          %{
            "type" => "function_call",
            "call_id" => "call_keep",
            "name" => "run_command"
          },
          %{
            "type" => "function_call_output",
            "call_id" => "call_keep",
            "output" => large_output("kept")
          }
        ])

      assert {:ok, [candidate]} =
               ResponsesLiveZone.plan_candidates(json,
                 min_bytes: @min_candidate_bytes,
                 excluded_function_tool_names: ["serena.find_symbol"]
               )

      assert candidate.output_path == ["input", 5, "output"]

      assert {:ok, %{protected_tool_output_skipped_count: 2, candidate_count: 1}} =
               ResponsesLiveZone.plan(json,
                 min_bytes: @min_candidate_bytes,
                 excluded_function_tool_names: ["serena.find_symbol"]
               )
    end

    test "does not retain external retrieval state between calls" do
      blocked_json =
        encode_request([
          %{
            "type" => "function_call",
            "call_id" => "call_reused",
            "name" => external_retrieval_tool_name()
          },
          %{
            "type" => "function_call_output",
            "call_id" => "call_reused",
            "output" => large_output("blocked")
          }
        ])

      fresh_json =
        encode_request([
          %{
            "type" => "function_call_output",
            "call_id" => "call_reused",
            "output" => large_output("fresh")
          }
        ])

      assert {:ok, []} =
               ResponsesLiveZone.plan_candidates(blocked_json, min_bytes: @min_candidate_bytes)

      assert {:ok, []} =
               ResponsesLiveZone.plan_candidates(fresh_json, min_bytes: @min_candidate_bytes)

      assert {:ok, %{candidate_count: 0, protected_tool_output_skipped_count: 1}} =
               ResponsesLiveZone.plan(fresh_json, min_bytes: @min_candidate_bytes)
    end

    test "finds supported candidates nested inside JSON arrays" do
      json =
        %{
          "model" => "gpt-fixture",
          "input" => [
            [
              %{
                "type" => "function_call",
                "call_id" => "call_nested",
                "name" => "run_command"
              },
              %{
                "type" => "function_call_output",
                "call_id" => "call_nested",
                "output" => large_output("nested")
              }
            ]
          ]
        }
        |> Jason.encode!()

      assert {:ok, [candidate]} =
               ResponsesLiveZone.plan_candidates(json, min_bytes: @min_candidate_bytes)

      assert candidate.item_type == "function_call_output"
      assert candidate.output_path == ["input", 0, 1, "output"]
    end

    test "does not plan ordinary message items" do
      json =
        encode_request([
          %{
            "type" => "message",
            "role" => "user",
            "content" => large_output("ordinary message")
          },
          %{
            "type" => "message",
            "role" => "assistant",
            "content" => [
              %{
                "type" => "output_text",
                "text" => large_output("ordinary assistant message")
              }
            ]
          }
        ])

      assert {:ok, []} =
               ResponsesLiveZone.plan_candidates(json, min_bytes: @min_candidate_bytes)
    end

    test "plans only input-level output items when message content mimics one" do
      json =
        encode_request([
          %{
            "type" => "function_call",
            "call_id" => "call_real",
            "name" => "run_command"
          },
          %{
            "type" => "function_call_output",
            "call_id" => "call_real",
            "output" => large_output("real")
          },
          %{
            "type" => "message",
            "role" => "assistant",
            "content" => [
              %{
                "type" => "function_call_output",
                "call_id" => "call_fake",
                "output" => large_output("fake")
              }
            ]
          }
        ])

      assert {:ok, [candidate]} =
               ResponsesLiveZone.plan_candidates(json, min_bytes: @min_candidate_bytes)

      assert candidate.item_type == "function_call_output"
      assert candidate.output_path == ["input", 1, "output"]
    end

    test "orders candidates deterministically by their output range" do
      json =
        encode_request([
          %{
            "type" => "apply_patch_call_output",
            "call_id" => "call_patch",
            "output" => large_output("patch")
          },
          %{
            "type" => "function_call",
            "call_id" => "call_function",
            "name" => "run_command"
          },
          %{
            "type" => "function_call_output",
            "call_id" => "call_function",
            "output" => large_output("function")
          }
        ])

      assert {:ok, first_run} =
               ResponsesLiveZone.plan_candidates(json, min_bytes: @min_candidate_bytes)

      assert {:ok, second_run} =
               ResponsesLiveZone.plan_candidates(json, min_bytes: @min_candidate_bytes)

      assert Enum.map(first_run, & &1.output_path) == [
               ["input", 0, "output"],
               ["input", 2, "output"]
             ]

      assert second_run == first_run
    end

    test "classifies candidate content without returning raw output or call ids" do
      call_id = "call_private_marker"
      marker = "synthetic private marker"

      json =
        encode_request([
          %{
            "type" => "function_call",
            "call_id" => call_id,
            "name" => "run_command"
          },
          %{
            "type" => "function_call_output",
            "call_id" => call_id,
            "output" => large_build_output(marker)
          }
        ])

      assert {:ok, [candidate]} =
               ResponsesLiveZone.plan_candidates(json, min_bytes: @min_candidate_bytes)

      assert %{
               content_kind: :build,
               compressible: true,
               strategy: :log_output
             } = candidate

      candidate_fields = Map.from_struct(candidate)

      refute Map.has_key?(candidate_fields, :call_id)
      refute Map.has_key?(candidate_fields, :output)
      refute inspect(candidate) =~ call_id
      refute inspect(candidate) =~ marker
    end
  end

  describe "plan/2" do
    test "wraps candidates with safe aggregate metadata" do
      json =
        encode_request([
          %{
            "type" => "function_call",
            "call_id" => "call_plan",
            "name" => "run_command"
          },
          %{
            "type" => "function_call_output",
            "call_id" => "call_plan",
            "output" => large_output("plan")
          }
        ])

      assert {:ok,
              %{
                candidate_count: 1,
                protected_tool_output_skipped_count: 0,
                candidates: [candidate]
              }} = ResponsesLiveZone.plan(json, min_bytes: @min_candidate_bytes)

      refute Map.has_key?(Map.from_struct(candidate), :call_id)
      refute Map.has_key?(Map.from_struct(candidate), :output)
    end
  end

  defp encode_request(input) do
    Jason.encode!(%{"model" => "gpt-fixture", "input" => input})
  end

  defp large_output(label) do
    line = "example #{label} command output line\n"
    String.duplicate(line, 40)
  end

  defp large_build_output(marker) do
    """
    example command output line
    example command output line
    warning: #{marker}
    error: example failure without private details
    """
    |> String.duplicate(30)
  end

  defp external_retrieval_tool_name(prefix \\ "") do
    prefix <>
      <<104, 101, 97, 100, 114, 111, 111, 109, 95, 114, 101, 116, 114, 105, 101, 118, 101>>
  end

  defp slice(json, %{byte_start: byte_start, byte_end: byte_end}) do
    binary_part(json, byte_start, byte_end - byte_start)
  end
end
