defmodule CodexPooler.Gateway.OpenAICompatibility.HostedShellTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.OpenAICompatibility.Responses.Input.HostedShell

  @moduletag :hosted_shell_history

  test "accepts minimal call and output items unchanged" do
    call = shell_call()
    output = shell_output()

    assert_accepted(call)
    assert_accepted(output)
  end

  test "accepts the full closed call and output shapes unchanged" do
    skills = Enum.map(1..200, &skill("skill-#{&1}"))

    call =
      shell_call(%{
        "id" => "",
        "caller" => %{"type" => "program", "caller_id" => "program-call"},
        "status" => "in_progress",
        "environment" => %{"type" => "local", "skills" => skills},
        "action" => %{
          "commands" => ["first synthetic command", "second synthetic command"],
          "timeout_ms" => -1,
          "max_output_length" => nil
        }
      })

    output =
      shell_output(%{
        "id" => nil,
        "caller" => %{"type" => "direct"},
        "status" => "incomplete",
        "max_output_length" => nil,
        "output" => [
          output_chunk("", "", %{"type" => "timeout"}),
          output_chunk("synthetic stdout", "synthetic stderr", %{
            "type" => "exit",
            "exit_code" => -127
          })
        ]
      })

    assert_accepted(call)
    assert_accepted(output)
  end

  test "accepts direct and program callers plus nullable or omitted callers" do
    for caller <- [
          :omitted,
          nil,
          %{"type" => "direct"},
          %{"type" => "program", "caller_id" => "p"},
          %{"type" => "program", "caller_id" => String.duplicate("p", 64)}
        ],
        builder <- [&shell_call/1, &shell_output/1] do
      overrides = if caller == :omitted, do: %{}, else: %{"caller" => caller}
      assert_accepted(builder.(overrides))
    end
  end

  test "accepts local and container environments plus nullable or omitted environments" do
    environments = [
      :omitted,
      nil,
      %{"type" => "local"},
      %{"type" => "local", "skills" => []},
      %{"type" => "local", "skills" => [skill("")]},
      %{"type" => "container_reference", "container_id" => ""}
    ]

    Enum.each(environments, fn environment ->
      overrides = if environment == :omitted, do: %{}, else: %{"environment" => environment}
      assert_accepted(shell_call(overrides))
    end)
  end

  test "accepts every documented status plus null and omission" do
    for status <- [:omitted, nil, "in_progress", "completed", "incomplete"],
        builder <- [&shell_call/1, &shell_output/1] do
      overrides = if status == :omitted, do: %{}, else: %{"status" => status}
      assert_accepted(builder.(overrides))
    end
  end

  test "accepts empty arrays, allowed empty strings, and signed integers" do
    assert_accepted(
      shell_call(%{
        "id" => "",
        "action" => %{"commands" => [], "timeout_ms" => -9, "max_output_length" => 7},
        "environment" => %{"type" => "container_reference", "container_id" => ""}
      })
    )

    assert_accepted(
      shell_output(%{
        "id" => "",
        "output" => [],
        "max_output_length" => -7
      })
    )

    assert_accepted(shell_output(%{"output" => [output_chunk("", "", exit_outcome(-1))]}))
  end

  test "enforces identifier bounds by Unicode code point" do
    identifiers = ["x", String.duplicate("x", 64), String.duplicate("🙂", 64)]

    Enum.each(identifiers, fn identifier ->
      assert_accepted(shell_call(%{"call_id" => identifier}))
      assert_accepted(shell_output(%{"call_id" => identifier}))

      assert_accepted(
        shell_call(%{"caller" => %{"type" => "program", "caller_id" => identifier}})
      )
    end)

    for identifier <- ["", String.duplicate("x", 65), String.duplicate("🙂", 65)] do
      assert_rejected(shell_call(%{"call_id" => identifier}))
      assert_rejected(shell_output(%{"call_id" => identifier}))

      assert_rejected(
        shell_call(%{"caller" => %{"type" => "program", "caller_id" => identifier}})
      )
    end
  end

  test "accepts 200 local skills and rejects 201" do
    skills = Enum.map(1..201, &skill("skill-#{&1}"))

    assert_accepted(
      shell_call(%{"environment" => %{"type" => "local", "skills" => Enum.take(skills, 200)}})
    )

    assert_rejected(shell_call(%{"environment" => %{"type" => "local", "skills" => skills}}))
  end

  @tag timeout: 120_000
  test "enforces stdout and stderr limits without materializing codepoint lists" do
    maximum = String.duplicate("x", 10_485_760)
    overflow = maximum <> "x"

    assert_accepted(
      shell_output(%{"output" => [output_chunk(maximum, maximum, exit_outcome(0))]})
    )

    assert_rejected(shell_output(%{"output" => [output_chunk(overflow, "", exit_outcome(0))]}))
    assert_rejected(shell_output(%{"output" => [output_chunk("", overflow, exit_outcome(0))]}))
  end

  test "rejects unknown keys at every object boundary including created_by" do
    cases = [
      Map.put(shell_call(), "unknown", true),
      Map.put(shell_call(), "created_by", "response-only"),
      Map.put(shell_output(), "unknown", true),
      Map.put(shell_output(), "created_by", "response-only"),
      shell_call(%{"action" => Map.put(shell_call()["action"], "unknown", true)}),
      shell_call(%{"caller" => %{"type" => "direct", "unknown" => true}}),
      shell_call(%{
        "caller" => %{"type" => "program", "caller_id" => "p", "unknown" => true}
      }),
      shell_call(%{"environment" => %{"type" => "local", "unknown" => true}}),
      shell_call(%{
        "environment" => %{
          "type" => "container_reference",
          "container_id" => "container",
          "unknown" => true
        }
      }),
      shell_call(%{
        "environment" => %{
          "type" => "local",
          "skills" => [Map.put(skill("skill"), "unknown", true)]
        }
      }),
      shell_output(%{
        "output" => [Map.put(output_chunk("", "", exit_outcome(0)), "unknown", true)]
      }),
      shell_output(%{
        "output" => [output_chunk("", "", %{"type" => "timeout", "unknown" => true})]
      }),
      shell_output(%{
        "output" => [
          output_chunk("", "", %{"type" => "exit", "exit_code" => 0, "unknown" => true})
        ]
      })
    ]

    Enum.each(cases, &assert_rejected/1)
  end

  test "rejects missing required fields and malformed nested values" do
    cases = [
      %{"call_id" => "call", "action" => %{"commands" => []}},
      %{"call_id" => "call", "output" => []},
      %{"type" => "shell_call", "action" => %{"commands" => []}},
      %{"type" => "shell_call", "call_id" => "call"},
      %{"type" => "shell_call_output", "output" => []},
      %{"type" => "shell_call_output", "call_id" => "call"},
      shell_call(%{"call_id" => 1}),
      shell_output(%{"call_id" => 1}),
      shell_call(%{"action" => %{}}),
      shell_call(%{"action" => %{"commands" => "command"}}),
      shell_call(%{"action" => %{"commands" => ["command", 1]}}),
      shell_call(%{"action" => %{"commands" => [], "timeout_ms" => 1.0}}),
      shell_call(%{"action" => %{"commands" => [], "max_output_length" => "1"}}),
      shell_call(%{"id" => 1}),
      shell_call(%{"status" => "failed"}),
      shell_call(%{"caller" => %{"type" => "program"}}),
      shell_call(%{"caller" => %{"type" => "program", "caller_id" => 1}}),
      shell_call(%{"environment" => %{"type" => "local", "skills" => %{}}}),
      shell_call(%{"environment" => %{"type" => "local", "skills" => [%{}]}}),
      shell_call(%{
        "environment" => %{
          "type" => "local",
          "skills" => [%{"name" => "", "description" => ""}]
        }
      }),
      shell_call(%{
        "environment" => %{
          "type" => "local",
          "skills" => [%{"name" => 1, "description" => "", "path" => ""}]
        }
      }),
      shell_call(%{"environment" => %{"type" => "container_reference"}}),
      shell_call(%{
        "environment" => %{"type" => "container_reference", "container_id" => 1}
      }),
      shell_output(%{"output" => %{}}),
      shell_output(%{"output" => [%{}]}),
      shell_output(%{"output" => [%{"stderr" => "", "outcome" => exit_outcome(0)}]}),
      shell_output(%{"output" => [%{"stdout" => "", "outcome" => exit_outcome(0)}]}),
      shell_output(%{"output" => [%{"stdout" => "", "stderr" => ""}]}),
      shell_output(%{"output" => [output_chunk(1, "", exit_outcome(0))]}),
      shell_output(%{"output" => [output_chunk("", 1, exit_outcome(0))]}),
      shell_output(%{"output" => [output_chunk("", "", %{"type" => "exit"})]}),
      shell_output(%{
        "output" => [output_chunk("", "", %{"type" => "exit", "exit_code" => 1.0})]
      }),
      shell_output(%{"id" => 1}),
      shell_output(%{"status" => "failed"}),
      shell_output(%{"max_output_length" => "1"})
    ]

    Enum.each(cases, &assert_rejected/1)
  end

  test "rejects wrong top-level and nested discriminators" do
    cases = [
      %{"type" => 1, "call_id" => "call", "action" => %{"commands" => []}},
      %{"type" => "local_shell_call", "call_id" => "call", "action" => %{"commands" => []}},
      %{"type" => "shell_call_result", "call_id" => "call", "output" => []},
      shell_call(%{"caller" => %{"type" => "unknown"}}),
      shell_call(%{"environment" => %{"type" => "container", "container_id" => "id"}}),
      shell_output(%{"output" => [output_chunk("", "", %{"type" => "unknown"})]})
    ]

    Enum.each(cases, &assert_rejected/1)
  end

  defp shell_call(overrides \\ %{}) do
    Map.merge(
      %{
        "type" => "shell_call",
        "call_id" => "call",
        "action" => %{"commands" => []}
      },
      overrides
    )
  end

  defp shell_output(overrides \\ %{}) do
    Map.merge(
      %{
        "type" => "shell_call_output",
        "call_id" => "call",
        "output" => []
      },
      overrides
    )
  end

  defp skill(name), do: %{"name" => name, "description" => "", "path" => ""}

  defp output_chunk(stdout, stderr, outcome),
    do: %{"stdout" => stdout, "stderr" => stderr, "outcome" => outcome}

  defp exit_outcome(exit_code), do: %{"type" => "exit", "exit_code" => exit_code}

  defp assert_accepted(item), do: assert({:ok, ^item} = HostedShell.validate_item(item))

  defp assert_rejected(item) do
    assert HostedShell.validate_item(item) ==
             {:error,
              %{
                status: 400,
                code: "invalid_request",
                message: "input item shape is not translatable",
                param: "input"
              }}
  end
end
