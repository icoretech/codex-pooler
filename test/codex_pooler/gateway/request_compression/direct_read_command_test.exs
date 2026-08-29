defmodule CodexPooler.Gateway.RequestCompression.DirectReadCommandTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.RequestCompression.DirectReadCommand

  @tag :command_read_protection
  test "recognizes the complete direct scalar read grammar from cmd and command arguments" do
    accepted = [
      %{"cmd" => "cat src/example.ex"},
      %{"command" => "cat -- -generated.txt"},
      %{"cmd" => "nl src/example.ex"},
      %{"cmd" => "nl -ba -- src/example.ex"},
      %{"cmd" => "head src/example.ex"},
      %{"cmd" => "head -n 75 -- src/example.ex"},
      %{"cmd" => "head -75 src/example.ex"},
      %{"cmd" => "tail src/example.ex"},
      %{"cmd" => "tail -n 75 src/example.ex"},
      %{"cmd" => "tail -75 -- -generated.txt"},
      %{"cmd" => "sed -n 1p src/example.ex"},
      %{"cmd" => "sed -n 1,75p -- src/example.ex"},
      %{"cmd" => "sed -n '$p' src/example.ex"},
      %{"cmd" => "sed -n '1,$p' src/example.ex"}
    ]

    for arguments <- accepted do
      assert DirectReadCommand.read?(arguments), inspect(arguments)
      assert DirectReadCommand.read?(Jason.encode!(Map.put(arguments, "trace", "synthetic")))
    end
  end

  @tag :command_read_protection
  test "recognizes quoted filenames and treats quoted operator bytes as filename content" do
    accepted = [
      %{"cmd" => ~s(cat "src/example file.ex")},
      %{"cmd" => "cat 'src/example|file.ex'"},
      %{"cmd" => ~s(head -n 5 "src/#example.ex")},
      %{"cmd" => ~s(tail -- "-synthetic file.txt")},
      %{"cmd" => ~s(nl -ba "src/example;file.ex")},
      %{"cmd" => ~s(sed -n 1p "src/example>file.ex")}
    ]

    assert Enum.all?(accepted, &DirectReadCommand.read?/1)
  end

  @tag :command_read_protection
  test "recognizes only the whitespace-delimited nl to print-only sed scalar pipeline" do
    accepted = [
      %{"cmd" => "nl src/example.ex | sed -n 1,75p"},
      %{"cmd" => "nl -ba -- -generated.txt\t|\tsed -n '$p'"},
      %{"cmd" => ~s(nl "src/example file.ex" | sed -n '10,$p')}
    ]

    rejected = [
      %{"cmd" => "nl src/example.ex| sed -n 1p"},
      %{"cmd" => "nl src/example.ex |sed -n 1p"},
      %{"cmd" => "nl src/example.ex | sed -n 1p | cat src/other.ex"},
      %{"cmd" => "cat src/example.ex | sed -n 1p"},
      %{"cmd" => "nl src/example.ex | head -n 1"},
      %{"cmd" => "nl src/example.ex || sed -n 1p"},
      %{"cmd" => "nl src/example.ex | sed -n 1p src/other.ex"}
    ]

    assert Enum.all?(accepted, &DirectReadCommand.read?/1)
    refute Enum.any?(rejected, &DirectReadCommand.read?/1)
  end

  @tag :command_read_protection
  test "rejects shell control syntax wrappers executable paths redirects and substitutions" do
    rejected_commands = [
      "cat src/example.ex && echo done",
      "cat src/example.ex || true",
      "cat src/example.ex; echo done",
      "cat src/example.ex &",
      "cat src/example.ex > copy.txt",
      "cat < src/example.ex",
      "cat <<EOF",
      "(cat src/example.ex)",
      "{ cat src/example.ex; }",
      "! cat src/example.ex",
      "cat src/example.ex # comment",
      "env cat src/example.ex",
      "sudo cat src/example.ex",
      "sh -c 'cat src/example.ex'",
      "/bin/cat src/example.ex",
      "cat src/example\\.ex",
      "cat `pwd`/example.ex",
      "cat $FILE",
      "cat ${FILE}",
      "cat $(pwd)/example.ex",
      "cat src/example.ex | tee copy.txt"
    ]

    for command <- rejected_commands do
      refute DirectReadCommand.read?(%{"cmd" => command}), command
    end
  end

  @tag :command_read_protection
  test "rejects malformed scalar lexical input" do
    rejected_commands = [
      "",
      " \t ",
      "cat ''",
      ~s(cat ""),
      "cat 'unterminated",
      ~s(cat "unterminated),
      ~s(cat src/"mixed.ex"),
      "cat src/example.ex\nhead src/other.ex",
      "cat src/example.ex\r",
      "cat src/example.ex" <> <<0>>,
      "cat src/example.ex" <> <<1>>,
      "cat src/example.ex" <> <<127>>
    ]

    for command <- rejected_commands do
      refute DirectReadCommand.read?(%{"cmd" => command}), inspect(command)
    end
  end

  @tag :command_read_protection
  test "rejects unsupported options operands counts and separators" do
    rejected_commands = [
      "cat",
      "cat -",
      "cat -generated.txt",
      "cat --",
      "cat -- -- src/example.ex",
      "cat src/example.ex --",
      "nl -b a src/example.ex",
      "nl '-ba' src/example.ex",
      "head -n src/example.ex",
      "head -n -1 src/example.ex",
      "head -n 1x src/example.ex",
      "head '-n' 1 src/example.ex",
      "head -- -n src/example.ex",
      "tail -c 10 src/example.ex",
      "sed -n 1p",
      "sed -ne 1p src/example.ex",
      "sed --quiet 1p src/example.ex",
      "sed -e 1p src/example.ex",
      "sed '-n' 1p src/example.ex",
      "sed -n '1p;2p' src/example.ex",
      "sed -n 1p -n 2p src/example.ex"
    ]

    for command <- rejected_commands do
      refute DirectReadCommand.read?(%{"cmd" => command}), command
    end
  end

  @tag :command_read_protection
  test "rejects every non-print or write-capable sed script" do
    scripts = [
      "1",
      "p",
      "1,",
      ",2p",
      "1,2",
      "1,2d",
      "1,2w",
      "1,2W",
      "1,2e",
      "1,2r",
      "1,2s/x/y/p",
      "1~2p",
      "/needle/p",
      "1p;2p"
    ]

    for script <- scripts do
      refute DirectReadCommand.read?(%{"cmd" => "sed -n #{script} src/example.ex"}), script
    end
  end

  @tag :command_read_protection
  test "rejects malformed function argument envelopes" do
    rejected = [
      nil,
      [],
      "not json",
      Jason.encode!([%{"cmd" => "cat src/example.ex"}]),
      %{},
      %{"cmd" => nil},
      %{"cmd" => "cat src/example.ex", "command" => "cat src/other.ex"},
      %{"cmd" => " ", "trace" => "synthetic"},
      %{"command" => 42}
    ]

    refute Enum.any?(rejected, &DirectReadCommand.read?/1)
  end

  @tag :command_read_protection
  test "recognizes direct native exec argv and both local-shell identifier forms" do
    accepted = [
      native_call(%{"call_id" => "call_native"}, ["cat", "src/example.ex"]),
      native_call(%{"id" => "shell_native"}, ["head", "-n", "75", "src/example.ex"]),
      native_call(%{"call_id" => "call_native", "id" => "shell_native"}, [
        "sed",
        "-n",
        "1,$p",
        "src/example.ex"
      ]),
      native_call(%{"id" => "shell_hyphen"}, ["tail", "--", "-generated.txt"])
    ]

    assert Enum.all?(accepted, &DirectReadCommand.read?/1)
  end

  @tag :command_read_protection
  test "rejects malformed native calls pipelines and non-exec actions" do
    rejected = [
      %{"type" => "local_shell_call"},
      native_call(%{"id" => "shell_empty"}, []),
      native_call(%{"id" => "shell_blank"}, ["cat", ""]),
      native_call(%{"id" => "shell_nonbinary"}, ["cat", 42]),
      native_call(%{"id" => "shell_pipe"}, ["nl", "src/example.ex", "|", "sed", "-n", "1p"]),
      native_call(%{"id" => "shell_stdin"}, ["cat", "-"]),
      put_in(
        native_call(%{"id" => "shell_spawn"}, ["cat", "src/example.ex"]),
        ["action", "type"],
        "spawn"
      ),
      put_in(native_call(%{"id" => "shell_commands"}, ["cat", "src/example.ex"]), ["action"], %{
        "type" => "exec",
        "commands" => [["cat", "src/example.ex"]]
      })
    ]

    refute Enum.any?(rejected, &DirectReadCommand.read?/1)
  end

  defp native_call(identifiers, command) do
    Map.merge(
      %{
        "type" => "local_shell_call",
        "action" => %{"type" => "exec", "command" => command}
      },
      identifiers
    )
  end
end
