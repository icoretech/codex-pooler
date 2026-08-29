defmodule CodexPooler.Gateway.RequestCompression.ResponsesLiveZoneTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.RequestCompression.ResponsesLiveZone

  @min_candidate_bytes 512

  describe "plan_candidates/2" do
    @tag :request_compression_characterization
    test "keeps ordinary non-read function build output compressible" do
      json =
        encode_request([
          %{
            "type" => "function_call",
            "call_id" => "call_build_log",
            "name" => "run_command",
            "arguments" => Jason.encode!(%{"cmd" => "mix compile"})
          },
          %{
            "type" => "function_call_output",
            "call_id" => "call_build_log",
            "output" => large_build_output("synthetic compiler diagnostic")
          }
        ])

      assert {:ok,
              %{
                candidate_count: 1,
                protected_tool_output_skipped_count: 0,
                candidates: [candidate]
              }} = ResponsesLiveZone.plan(json, min_bytes: @min_candidate_bytes)

      assert %{
               item_type: "function_call_output",
               output_path: ["input", 1, "output"],
               content_kind: :build,
               compressible: true,
               strategy: :log_output
             } = candidate
    end

    @tag :request_compression_characterization
    test "keeps unmatched function output protected" do
      json =
        encode_request([
          %{
            "type" => "function_call_output",
            "call_id" => "call_unmatched_function",
            "output" => large_build_output("synthetic unmatched function diagnostic")
          }
        ])

      assert {:ok,
              %{
                candidate_count: 0,
                protected_tool_output_skipped_count: 1,
                candidates: []
              }} = ResponsesLiveZone.plan(json, min_bytes: @min_candidate_bytes)
    end

    @tag :request_compression_characterization
    test "keeps unmatched local-shell output compressible" do
      json =
        encode_request([
          %{
            "type" => "local_shell_call_output",
            "call_id" => "call_unmatched_shell",
            "output" => large_build_output("synthetic unmatched shell diagnostic")
          }
        ])

      assert {:ok,
              %{
                candidate_count: 1,
                protected_tool_output_skipped_count: 0,
                candidates: [candidate]
              }} = ResponsesLiveZone.plan(json, min_bytes: @min_candidate_bytes)

      assert %{
               item_type: "local_shell_call_output",
               output_path: ["input", 0, "output"],
               content_kind: :build,
               compressible: true,
               strategy: :log_output
             } = candidate
    end

    @tag :command_read_protection
    test "protects recognized function reads before every content strategy family" do
      outputs = [
        large_build_output("private build output sentinel"),
        large_pretty_json_output("private json document sentinel"),
        large_json_array_output("private json array sentinel"),
        large_diff_output("private diff sentinel"),
        large_search_output("private search sentinel"),
        large_embedded_json_output("private embedded json sentinel")
      ]

      input =
        outputs
        |> Enum.with_index()
        |> Enum.flat_map(fn {output, index} ->
          call_id = "call_function_read_#{index}"
          command_key = if rem(index, 2) == 0, do: "cmd", else: "command"

          [
            %{
              "type" => "function_call",
              "call_id" => call_id,
              "name" => "arbitrary_tool_#{index}",
              "arguments" => Jason.encode!(%{command_key => "cat src/example-#{index}.ex"})
            },
            %{"type" => "function_call_output", "call_id" => call_id, "output" => output}
          ]
        end)

      assert {:ok,
              %{
                candidates: [],
                candidate_count: 0,
                protected_tool_output_skipped_count: 6
              }} = ResponsesLiveZone.plan(encode_request(input), min_bytes: @min_candidate_bytes)
    end

    @tag :command_read_protection
    test "protects native reads resolved by call id id or converging aliases" do
      scenarios = [
        {%{"call_id" => "call_native_only"},
         %{"type" => "local_shell_call_output", "call_id" => "call_native_only"}},
        {%{"id" => "shell_native_only"},
         %{"type" => "local_shell_call_output", "id" => "shell_native_only"}},
        {%{"call_id" => "call_native_both", "id" => "shell_native_both"},
         %{
           "type" => "local_shell_call_output",
           "call_id" => "call_native_both",
           "id" => "shell_native_both"
         }},
        {%{"call_id" => "call_native_function_output", "id" => "shell_native_function_output"},
         %{"type" => "function_call_output", "call_id" => "call_native_function_output"}}
      ]

      for {producer_ids, output_fields} <- scenarios do
        output = Map.put(output_fields, "output", large_build_output("native private sentinel"))

        producer =
          Map.merge(producer_ids, %{
            "type" => "local_shell_call",
            "action" => %{
              "type" => "exec",
              "command" => ["head", "-n", "75", "src/example.ex"]
            }
          })

        assert {:ok,
                %{
                  candidates: [],
                  candidate_count: 0,
                  protected_tool_output_skipped_count: 1
                }} =
                 ResponsesLiveZone.plan(encode_request([producer, output]),
                   min_bytes: @min_candidate_bytes
                 )
      end
    end

    @tag :command_read_protection
    test "protects every ambiguous same-frame owner resolution" do
      read_function = fn call_id ->
        %{
          "type" => "function_call",
          "call_id" => call_id,
          "name" => "arbitrary_reader",
          "arguments" => %{"cmd" => "cat src/example.ex"}
        }
      end

      ordinary_function = fn call_id ->
        %{
          "type" => "function_call",
          "call_id" => call_id,
          "name" => "arbitrary_runner",
          "arguments" => %{"cmd" => "mix compile"}
        }
      end

      local_shell = fn ids ->
        Map.merge(ids, %{
          "type" => "local_shell_call",
          "action" => %{"type" => "exec", "command" => ["cat", "src/example.ex"]}
        })
      end

      output = large_build_output("ambiguous private sentinel")

      scenarios = [
        [
          read_function.("duplicate_alias"),
          ordinary_function.("duplicate_alias"),
          %{"type" => "function_call_output", "call_id" => "duplicate_alias", "output" => output}
        ],
        [
          read_function.("cross_kind_alias"),
          local_shell.(%{"call_id" => "cross_kind_alias"}),
          %{"type" => "function_call_output", "call_id" => "cross_kind_alias", "output" => output}
        ],
        [
          local_shell.(%{"call_id" => "resolved_alias", "id" => "resolved_owner"}),
          %{
            "type" => "local_shell_call_output",
            "call_id" => "resolved_alias",
            "id" => "missing_alias",
            "output" => output
          }
        ],
        [
          local_shell.(%{"call_id" => "owner_one", "id" => "owner_one_id"}),
          local_shell.(%{"call_id" => "owner_two", "id" => "owner_two_id"}),
          %{
            "type" => "local_shell_call_output",
            "call_id" => "owner_one",
            "id" => "owner_two_id",
            "output" => output
          }
        ],
        [
          read_function.("function_owner_kind_mismatch"),
          %{
            "type" => "local_shell_call_output",
            "call_id" => "function_owner_kind_mismatch",
            "output" => output
          }
        ]
      ]

      for input <- scenarios do
        assert {:ok, %{candidate_count: 0, protected_tool_output_skipped_count: 1}} =
                 ResponsesLiveZone.plan(encode_request(input), min_bytes: @min_candidate_bytes)
      end
    end

    @tag :command_read_protection
    test "retains unresolved legacy behavior and rejects malformed or unrecognized producers" do
      output = large_build_output("legacy behavior sentinel")

      malformed_or_unrecognized = [
        %{"cmd" => "cat src/example.ex", "command" => "cat src/other.ex"},
        %{"cmd" => "cat src/example.ex && echo done"},
        %{"cmd" => "sed -n '1p;2p' src/example.ex"},
        %{"cmd" => "cat -"},
        %{"cmd" => 42},
        "not-json"
      ]

      for {arguments, index} <- Enum.with_index(malformed_or_unrecognized) do
        call_id = "ordinary_control_#{index}"

        input = [
          %{
            "type" => "function_call",
            "call_id" => call_id,
            "name" => "arbitrary_tool",
            "arguments" => arguments
          },
          %{"type" => "function_call_output", "call_id" => call_id, "output" => output}
        ]

        assert {:ok, %{candidate_count: 1, protected_tool_output_skipped_count: 0}} =
                 ResponsesLiveZone.plan(encode_request(input), min_bytes: @min_candidate_bytes)
      end

      assert {:ok, %{candidate_count: 0, protected_tool_output_skipped_count: 1}} =
               ResponsesLiveZone.plan(
                 encode_request([
                   %{
                     "type" => "function_call_output",
                     "call_id" => "unmatched_function_legacy",
                     "output" => output
                   }
                 ]),
                 min_bytes: @min_candidate_bytes
               )

      assert {:ok, %{candidate_count: 1, protected_tool_output_skipped_count: 0}} =
               ResponsesLiveZone.plan(
                 encode_request([
                   %{
                     "type" => "local_shell_call_output",
                     "id" => "unmatched_shell_legacy",
                     "output" => output
                   }
                 ]),
                 min_bytes: @min_candidate_bytes
               )
    end

    @tag :command_read_protection
    test "counts only candidate-sized protected reads and keeps mixed controls compressible" do
      private_command = "cat src/private-example.ex"
      private_call_id = "call_private_read"
      private_output = large_build_output("private output sentinel")
      ordinary_output = large_build_output("ordinary compression sentinel")

      input = [
        %{
          "type" => "function_call",
          "call_id" => private_call_id,
          "name" => "arbitrary_reader",
          "arguments" => Jason.encode!(%{"cmd" => private_command})
        },
        %{
          "type" => "function_call_output",
          "call_id" => private_call_id,
          "output" => private_output
        },
        %{
          "type" => "function_call",
          "call_id" => "call_small_read",
          "name" => "arbitrary_reader",
          "arguments" => %{"command" => "tail src/small-example.ex"}
        },
        %{
          "type" => "function_call_output",
          "call_id" => "call_small_read",
          "output" => String.duplicate("x", @min_candidate_bytes - 1)
        },
        %{
          "type" => "function_call",
          "call_id" => "call_ordinary_control",
          "name" => "arbitrary_runner",
          "arguments" => %{"cmd" => "mix compile"}
        },
        %{
          "type" => "function_call_output",
          "call_id" => "call_ordinary_control",
          "output" => ordinary_output
        }
      ]

      assert {:ok,
              %{
                candidates: [candidate],
                candidate_count: 1,
                protected_tool_output_skipped_count: 1
              }} = ResponsesLiveZone.plan(encode_request(input), min_bytes: @min_candidate_bytes)

      assert candidate.output_path == ["input", 5, "output"]
      metadata_text = inspect(candidate)
      refute metadata_text =~ private_command
      refute metadata_text =~ private_call_id
      refute metadata_text =~ "private output sentinel"
      refute Map.has_key?(Map.from_struct(candidate), :output)
      refute Map.has_key?(Map.from_struct(candidate), :call_id)
    end

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

    test "plans only function output in mixed programmatic replay shapes" do
      program = %{
        "type" => "program",
        "id" => "program-id-preserved",
        "call_id" => "program-call-id-preserved",
        "code" => "synthetic program code",
        "fingerprint" => "synthetic-program-fingerprint"
      }

      caller = %{"type" => "program", "caller_id" => "program-caller-id-preserved"}

      program_output = %{
        "type" => "program_output",
        "id" => "program-output-id-preserved",
        "call_id" => "program-call-id-preserved",
        "result" => large_output("program result preserved"),
        "status" => "completed"
      }

      unknown_program_output = %{
        "type" => "program_output_variant",
        "call_id" => "unknown-program-output-call",
        "output" => large_output("unknown program output")
      }

      malformed_program_output = %{
        "type" => "program_output",
        "result" => %{"value" => large_output("malformed program output")}
      }

      input = [
        program,
        %{
          "type" => "function_call",
          "call_id" => "call_mixed_function_output",
          "name" => "run_command",
          "caller" => caller
        },
        %{
          "type" => "function_call_output",
          "call_id" => "call_mixed_function_output",
          "output" => large_output("eligible function output"),
          "caller" => caller
        },
        program_output,
        unknown_program_output,
        malformed_program_output
      ]

      json = encode_request(input)

      assert {:ok, [candidate]} =
               ResponsesLiveZone.plan_candidates(json, min_bytes: @min_candidate_bytes)

      assert candidate.item_type == "function_call_output"
      assert candidate.output_path == ["input", 2, "output"]

      assert {:ok,
              %{
                candidate_count: 1,
                protected_tool_output_skipped_count: 0,
                candidates: [^candidate]
              }} = ResponsesLiveZone.plan(json, min_bytes: @min_candidate_bytes)

      assert Jason.decode!(json)["input"] == input
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

    test "does not plan unknown newer tool-result item shapes" do
      json =
        encode_request([
          %{
            "type" => "tool_result",
            "call_id" => "call_unknown_tool_result",
            "output" => large_output("unknown tool result")
          },
          %{
            "type" => "completed_tool",
            "call_id" => "call_completed_tool",
            "output" => large_output("completed tool")
          },
          %{
            "type" => "tool-result",
            "toolCallId" => "call_acp_tool_result",
            "toolName" => "execute_command",
            "output" => %{"output" => large_output("acp tool result"), "exitCode" => 0},
            "isError" => false
          }
        ])

      assert {:ok, []} =
               ResponsesLiveZone.plan_candidates(json, min_bytes: @min_candidate_bytes)

      assert {:ok, %{candidate_count: 0, protected_tool_output_skipped_count: 0}} =
               ResponsesLiveZone.plan(json, min_bytes: @min_candidate_bytes)
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

    test "skips only outputs bound to a function tool with an output schema" do
      schema_bound_output = Jason.encode!(%{"items" => Enum.to_list(1..180)})
      unbound_output = large_output("unbound schema-adjacent output")

      json =
        Jason.encode!(%{
          "model" => "gpt-fixture",
          "tools" => [
            %{
              "type" => "function",
              "name" => "schema_bound",
              "output_schema" => %{"type" => "object"}
            },
            %{"type" => "function", "name" => "unbound"}
          ],
          "input" => [
            %{
              "type" => "function_call",
              "call_id" => "call_schema_bound",
              "name" => "schema_bound"
            },
            %{
              "type" => "function_call_output",
              "call_id" => "call_schema_bound",
              "output" => schema_bound_output
            },
            %{"type" => "function_call", "call_id" => "call_unbound", "name" => "unbound"},
            %{
              "type" => "function_call_output",
              "call_id" => "call_unbound",
              "output" => unbound_output
            }
          ]
        })

      assert {:ok, [candidate]} =
               ResponsesLiveZone.plan_candidates(json, min_bytes: @min_candidate_bytes)

      assert candidate.output_path == ["input", 3, "output"]

      assert {:ok, %{candidate_count: 1, protected_tool_output_skipped_count: 1}} =
               ResponsesLiveZone.plan(json, min_bytes: @min_candidate_bytes)
    end

    test "does not protect outputs for malformed tools or unmatched schema names" do
      output = large_output("unmatched schema binding")

      payloads = [
        %{
          "tools" => %{"type" => "function", "name" => "schema_bound", "output_schema" => %{}},
          "input" => [
            %{
              "type" => "function_call",
              "call_id" => "call_malformed_tools",
              "name" => "schema_bound"
            },
            %{
              "type" => "function_call_output",
              "call_id" => "call_malformed_tools",
              "output" => output
            }
          ]
        },
        %{
          "tools" => [%{"type" => "function", "name" => "schema_bound", "output_schema" => %{}}],
          "input" => [
            %{"type" => "function_call", "call_id" => "call_name_mismatch", "name" => "other"},
            %{
              "type" => "function_call_output",
              "call_id" => "call_name_mismatch",
              "output" => output
            }
          ]
        }
      ]

      for payload <- payloads do
        json = Jason.encode!(Map.put(payload, "model", "gpt-fixture"))

        assert {:ok, [candidate]} =
                 ResponsesLiveZone.plan_candidates(json, min_bytes: @min_candidate_bytes)

        assert candidate.output_path == ["input", 1, "output"]
      end
    end

    test "retains the existing fail-closed behavior for an unmatched output call id" do
      json =
        Jason.encode!(%{
          "model" => "gpt-fixture",
          "tools" => [%{"type" => "function", "name" => "schema_bound", "output_schema" => %{}}],
          "input" => [
            %{"type" => "function_call", "call_id" => "call_id_source", "name" => "schema_bound"},
            %{
              "type" => "function_call_output",
              "call_id" => "call_id_other",
              "output" => large_output("unknown")
            }
          ]
        })

      assert {:ok, %{candidate_count: 0, protected_tool_output_skipped_count: 1}} =
               ResponsesLiveZone.plan(json, min_bytes: @min_candidate_bytes)
    end

    test "protects web retrieval function outputs from candidate planning" do
      input =
        ["WebSearch", "WebFetch", "web_search", "web_fetch"]
        |> Enum.with_index()
        |> Enum.flat_map(fn {tool_name, index} ->
          call_id = "call_web_#{index}"

          [
            %{
              "type" => "function_call",
              "call_id" => call_id,
              "name" => tool_name
            },
            %{
              "type" => "function_call_output",
              "call_id" => call_id,
              "output" => large_web_reference_output()
            }
          ]
        end)

      assert {:ok,
              %{
                candidates: [],
                candidate_count: 0,
                protected_tool_output_skipped_count: 4
              }} = ResponsesLiveZone.plan(encode_request(input), min_bytes: @min_candidate_bytes)
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

  defp large_pretty_json_output(marker) do
    %{
      "marker" => marker,
      "rows" => Enum.map(1..48, &%{"id" => &1, "status" => "synthetic"})
    }
    |> Jason.encode!(pretty: true)
  end

  defp large_json_array_output(marker) do
    1..64
    |> Enum.map(&%{"id" => &1, "marker" => marker})
    |> Jason.encode!(pretty: true)
  end

  defp large_diff_output(marker) do
    1..48
    |> Enum.map_join("\n", fn index ->
      "@@ -#{index},1 +#{index},1 @@\n-old synthetic line\n+new synthetic line #{marker}"
    end)
  end

  defp large_search_output(marker) do
    1..64
    |> Enum.map_join("\n", &"lib/example_#{&1}.ex:#{&1}: synthetic match #{marker}")
  end

  defp large_embedded_json_output(marker) do
    "synthetic prefix\n" <>
      Jason.encode!(%{"rows" => Enum.map(1..48, &%{"id" => &1, "marker" => marker})},
        pretty: true
      ) <> "\nsynthetic suffix"
  end

  defp large_web_reference_output do
    %{
      "results" =>
        Enum.map(1..24, fn index ->
          %{
            "rank" => index,
            "title" => "synthetic web result #{index}",
            "url" => "https://example.com/results/#{index}"
          }
        end)
    }
    |> Jason.encode!(pretty: true)
  end

  defp external_retrieval_tool_name(prefix \\ "") do
    prefix <>
      <<104, 101, 97, 100, 114, 111, 111, 109, 95, 114, 101, 116, 114, 105, 101, 118, 101>>
  end

  defp slice(json, %{byte_start: byte_start, byte_end: byte_end}) do
    binary_part(json, byte_start, byte_end - byte_start)
  end
end
