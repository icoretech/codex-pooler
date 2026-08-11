defmodule CodexPooler.Verification.CodexAgentV2Contract do
  @expected_sha "c9c6c0daa994109cec50fddcb57d076fdf9e738c"
  @default_fixture Path.expand(
                     "../../test/fixtures/codex/#{@expected_sha}/agent-v2-handoffs.json",
                     __DIR__
                   )
  @namespace_description "Tools for spawning and managing sub-agents."
  @source_paths %{
    "protocol_path" => "codex-rs/protocol/src/protocol.rs",
    "models_path" => "codex-rs/protocol/src/models.rs",
    "router_path" => "codex-rs/core/src/tools/router.rs",
    "multi_agent_spec_path" => "codex-rs/core/src/tools/handlers/multi_agents_spec.rs",
    "v2_handler_path" => "codex-rs/core/src/tools/handlers/multi_agents_v2.rs",
    "spec_plan_path" => "codex-rs/core/src/tools/spec_plan.rs"
  }

  def run(args) do
    with {:ok, fixture_path} <- fixture_path(args),
         {:ok, reference_dir} <- reference_dir(),
         {:ok, fixture} <- read_fixture(fixture_path),
         :ok <- validate_fixture(fixture),
         :ok <- validate_reference(reference_dir) do
      IO.puts("codex_agent_v2_contract sha=#{@expected_sha} version=2 verified")
      :ok
    else
      _ ->
        IO.puts(:stderr, "codex_agent_v2_contract validation_failed")
        System.halt(1)
    end
  end

  defp fixture_path([]), do: {:ok, @default_fixture}

  defp fixture_path(["--fixture", path]) when is_binary(path) and byte_size(path) > 0,
    do: {:ok, path}

  defp fixture_path(_), do: :error

  defp reference_dir do
    case System.get_env("CODEX_REFERENCE_DIR") do
      path when is_binary(path) and byte_size(path) > 0 -> {:ok, path}
      _ -> :error
    end
  end

  defp read_fixture(path) do
    with {:ok, content} <- File.read(path),
         {:ok, fixture} <- Jason.decode(content),
         true <- is_map(fixture) do
      {:ok, fixture}
    else
      _ -> :error
    end
  end

  defp validate_fixture(fixture) do
    with :ok <- exact_keys(fixture, ~w(contract_version source v1 v2 plaintext final_answer)),
         true <- fixture["contract_version"] == 2,
         :ok <- validate_source(fixture["source"]),
         :ok <- validate_v1(fixture["v1"]),
         :ok <- validate_v2(fixture["v2"]),
         :ok <- validate_plaintext(fixture["plaintext"]),
         :ok <- validate_final_answer(fixture["final_answer"]) do
      :ok
    else
      _ -> :error
    end
  end

  defp validate_source(source) when is_map(source) do
    with :ok <- exact_keys(source, ["commit" | Map.keys(@source_paths)]),
         true <- source["commit"] == @expected_sha,
         true <- Map.drop(source, ["commit"]) == @source_paths do
      :ok
    else
      _ -> :error
    end
  end

  defp validate_source(_), do: :error

  defp validate_v1(%{"ordinary_user_role_handoff" => %{"item" => item}} = v1) do
    with :ok <- exact_keys(v1, ["ordinary_user_role_handoff"]),
         :ok <- validate_v1_item(item) do
      :ok
    else
      _ -> :error
    end
  end

  defp validate_v1(_), do: :error

  defp validate_v1_item(item) when is_map(item) do
    expected = %{
      "type" => "message",
      "id" => "item_v1_ordinary_synthetic",
      "role" => "user",
      "content" => [
        %{
          "type" => "input_text",
          "text" => "SYNTHETIC_V1_ORDINARY_PAYLOAD"
        }
      ],
      "internal_chat_message_metadata_passthrough" => %{"synthetic_turn" => "v1-ordinary"}
    }

    if item == expected, do: :ok, else: :error
  end

  defp validate_v1_item(_), do: :error

  defp validate_v2(%{"namespace_tools" => namespace_tools, "handoffs" => handoffs} = v2)
       when is_list(namespace_tools) and is_map(handoffs) do
    with :ok <- exact_keys(v2, ~w(namespace_tools handoffs)),
         :ok <- validate_namespace_tools(namespace_tools),
         :ok <- exact_keys(handoffs, ~w(spawn_agent send_message followup_task)),
         :ok <- validate_encrypted_handoff(handoffs["spawn_agent"], "NEW_TASK"),
         :ok <- validate_encrypted_handoff(handoffs["send_message"], "MESSAGE"),
         :ok <- validate_encrypted_handoff(handoffs["followup_task"], "NEW_TASK") do
      :ok
    else
      _ -> :error
    end
  end

  defp validate_v2(_), do: :error

  defp validate_namespace_tools([send_message, followup_task]) do
    with :ok <-
           validate_namespace_tool(
             send_message,
             "send_message",
             "Message text to queue on the target agent."
           ),
         :ok <-
           validate_namespace_tool(
             followup_task,
             "followup_task",
             "Message text to send to the target agent."
           ) do
      :ok
    else
      _ -> :error
    end
  end

  defp validate_namespace_tools(_), do: :error

  defp validate_namespace_tool(namespace, name, message_description) when is_map(namespace) do
    target_description =
      if name == "send_message" do
        "Relative or canonical task name to message (from spawn_agent)."
      else
        "Agent id or canonical task name to send a follow-up task to (from spawn_agent)."
      end

    with :ok <- exact_keys(namespace, ~w(type name description tools)),
         true <- namespace["type"] == "namespace",
         true <- namespace["name"] == "collaboration",
         true <- namespace["description"] == @namespace_description,
         [tool] when is_map(tool) <- namespace["tools"],
         :ok <- exact_keys(tool, ~w(type name description strict parameters)),
         true <- tool["type"] == "function",
         true <- tool["name"] == name,
         true <- tool["strict"] == false,
         :ok <-
           validate_namespace_parameters(
             tool["parameters"],
             target_description,
             message_description
           ) do
      :ok
    else
      _ -> :error
    end
  end

  defp validate_namespace_tool(_, _, _), do: :error

  defp validate_namespace_parameters(parameters, target_description, message_description)
       when is_map(parameters) do
    with :ok <- exact_keys(parameters, ~w(type properties required additionalProperties)),
         true <- parameters["type"] == "object",
         true <- parameters["required"] == ["target", "message"],
         true <- parameters["additionalProperties"] == false,
         %{"target" => target, "message" => message} <- parameters["properties"],
         :ok <- exact_keys(target, ~w(type description)),
         :ok <- exact_keys(message, ~w(type description encrypted)),
         true <- target == %{"type" => "string", "description" => target_description},
         true <-
           message == %{
             "type" => "string",
             "description" => message_description,
             "encrypted" => true
           } do
      :ok
    else
      _ -> :error
    end
  end

  defp validate_namespace_parameters(_, _, _), do: :error

  defp validate_encrypted_handoff(
         %{"message_type" => message_type, "item" => item} = handoff,
         type
       ) do
    with :ok <- exact_keys(handoff, ~w(message_type item)),
         true <- message_type == type,
         :ok <- validate_encrypted_item(item, type) do
      :ok
    else
      _ -> :error
    end
  end

  defp validate_encrypted_handoff(_, _), do: :error

  defp validate_encrypted_item(item, message_type) when is_map(item) do
    expected_text =
      "Message Type: #{message_type}\nTask name: /root/worker\nSender: /root\nPayload:\n"

    with :ok <- validate_item_base(item),
         [input_text, encrypted_content] <- item["content"],
         true <- input_text == %{"type" => "input_text", "text" => expected_text},
         :ok <- exact_keys(encrypted_content, ~w(type encrypted_content)),
         true <- encrypted_content["type"] == "encrypted_content",
         true <- nonblank_string?(encrypted_content["encrypted_content"]) do
      :ok
    else
      _ -> :error
    end
  end

  defp validate_encrypted_item(_, _), do: :error

  defp validate_plaintext(
         %{"encrypted_function_args" => [], "function_call" => call, "handoff" => handoff} =
           plaintext
       ) do
    with :ok <- exact_keys(plaintext, ~w(encrypted_function_args function_call handoff)),
         :ok <- validate_plaintext_call(call),
         :ok <- exact_keys(handoff, ["item"]),
         :ok <- validate_plain_item(handoff["item"], "SYNTHETIC_V2_PLAINTEXT_PAYLOAD") do
      :ok
    else
      _ -> :error
    end
  end

  defp validate_plaintext(_), do: :error

  defp validate_plaintext_call(call) when is_map(call) do
    expected = %{
      "type" => "function_call",
      "id" => "item_v2_plain_function_synthetic",
      "call_id" => "call_v2_plain_synthetic",
      "name" => "send_message",
      "namespace" => "collaboration",
      "arguments" => "{}",
      "encrypted_function_args" => [],
      "internal_chat_message_metadata_passthrough" => %{"synthetic_turn" => "v2-plaintext"}
    }

    if call == expected, do: :ok, else: :error
  end

  defp validate_plaintext_call(_), do: :error

  defp validate_plain_item(item, payload) when is_map(item) do
    expected_text =
      "Message Type: MESSAGE\nTask name: /root/worker\nSender: /root\nPayload:\n#{payload}"

    with :ok <- validate_item_base(item),
         [%{"type" => "input_text", "text" => ^expected_text}] <- item["content"] do
      :ok
    else
      _ -> :error
    end
  end

  defp validate_plain_item(_, _), do: :error

  defp validate_item_base(item) when is_map(item) do
    with :ok <-
           exact_keys(
             item,
             ~w(type id author recipient content internal_chat_message_metadata_passthrough)
           ),
         true <- item["type"] == "agent_message",
         true <- nonblank_string?(item["id"]),
         true <- item["author"] == "/root",
         true <- item["recipient"] == "/root/worker",
         true <- is_list(item["content"]),
         :ok <- exact_keys(item["internal_chat_message_metadata_passthrough"], ["synthetic_turn"]),
         true <-
           nonblank_string?(item["internal_chat_message_metadata_passthrough"]["synthetic_turn"]) do
      :ok
    else
      _ -> :error
    end
  end

  defp validate_final_answer(%{"text" => text} = answer) do
    with :ok <- exact_keys(answer, ["text"]),
         true <-
           text ==
             "Message Type: FINAL_ANSWER\nTask name: /root\nSender: /root/worker\nPayload:\nSYNTHETIC_FINAL_ANSWER_SENTINEL" do
      :ok
    else
      _ -> :error
    end
  end

  defp validate_final_answer(_), do: :error

  defp validate_reference(reference_dir) do
    with :ok <- expected_revision(reference_dir),
         :ok <-
           source_contains(reference_dir, "codex-rs/protocol/src/protocol.rs", [
             "Message Type: {message_type}\\nTask name: {}\\nSender: {}\\nPayload:\\n",
             "EncryptedContent"
           ]),
         :ok <-
           source_contains(reference_dir, "codex-rs/protocol/src/models.rs", [
             "internal_chat_message_metadata_passthrough",
             "encrypted_function_args",
             "Self::Message { role, .. } if role == \"user\""
           ]),
         :ok <-
           source_contains(reference_dir, "codex-rs/core/src/tools/router.rs", [
             "namespace.as_deref() == Some(\"collaboration\")",
             "Vec::is_empty"
           ]),
         :ok <-
           source_contains(
             reference_dir,
             "codex-rs/core/src/tools/handlers/multi_agents_spec.rs",
             [
               "pub fn create_send_message_tool()",
               "Message text to queue on the target agent.",
               "pub fn create_followup_task_tool()",
               "Message text to send to the target agent.",
               ".with_encrypted()"
             ]
           ),
         :ok <-
           source_contains(reference_dir, "codex-rs/core/src/tools/handlers/multi_agents_v2.rs", [
             "DirectPlaintextMessage"
           ]),
         :ok <-
           source_contains(reference_dir, "codex-rs/core/src/tools/spec_plan.rs", [
             @namespace_description,
             "multi_agent_v2_handler"
           ]) do
      :ok
    else
      _ -> :error
    end
  end

  defp expected_revision(reference_dir) do
    case System.cmd("git", ["-C", reference_dir, "rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> if(String.trim(sha) == @expected_sha, do: :ok, else: :error)
      _ -> :error
    end
  end

  defp source_contains(reference_dir, relative_path, terms) do
    with {:ok, content} <- File.read(Path.join(reference_dir, relative_path)),
         true <- Enum.all?(terms, &String.contains?(content, &1)) do
      :ok
    else
      _ -> :error
    end
  end

  defp exact_keys(map, keys) when is_map(map) do
    if MapSet.new(Map.keys(map)) == MapSet.new(keys), do: :ok, else: :error
  end

  defp exact_keys(_, _), do: :error

  defp nonblank_string?(value), do: is_binary(value) and String.trim(value) != ""
end

CodexPooler.Verification.CodexAgentV2Contract.run(System.argv())
