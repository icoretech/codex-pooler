defmodule CodexPoolerWeb.Runtime.EncryptedCollaborationHistory do
  @moduledoc false

  @type kind :: :send_message | :spawn_agent | :followup_task

  @spec items(kind()) :: [map()]
  def items(kind) do
    name = Atom.to_string(kind)
    call_id = "call_synthetic_#{name}"

    # provenance: observed completed Codex collaboration call and result fields;
    # identifiers, arguments, ciphertext and result are synthetic.
    [
      %{
        "type" => "function_call",
        "id" => "fc_synthetic_#{name}",
        "namespace" => "collaboration",
        "name" => name,
        "call_id" => call_id,
        "arguments" => CodexPooler.JSON.encode!(arguments(kind)),
        "status" => "completed",
        "encrypted_content" => "synthetic-encrypted-#{name}"
      },
      %{"type" => "function_call_output", "call_id" => call_id, "output" => "synthetic completed tool result"}
    ]
  end

  defp arguments(:send_message), do: %{"target" => "/root/sample", "message" => "synthetic note"}
  defp arguments(:spawn_agent), do: %{"task_name" => "sample", "message" => "synthetic task"}
  defp arguments(:followup_task), do: %{"target" => "/root/sample", "message" => "synthetic followup"}
end
