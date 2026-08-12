defmodule Mix.Tasks.Dev.ExactAssignmentFullProof do
  @moduledoc """
  Proves Full-mode exact assignment routing against the task-owned loopback fake.

      MIX_ENV=dev mix dev.exact_assignment_full_proof \
        --scope loopback-fake \
        --owner-id OWNER_UUID \
        --dry-run

  `--dry-run` parses and preflights only: it never starts the application,
  writes a journal, provisions rows, or sends traffic.

  Run the proof only after reviewing the dry-run result:

      MIX_ENV=dev mix dev.exact_assignment_full_proof \
        --scope loopback-fake \
        --owner-id OWNER_UUID

  Recover a recorded exact-id run with the same explicit owner:

      MIX_ENV=dev mix dev.exact_assignment_full_proof \
        --scope loopback-fake \
        --owner-id OWNER_UUID \
        --cleanup-run-id RUN_ID
  """

  use Mix.Task

  alias CodexPooler.Dev.ExactAssignmentFullProof

  @shortdoc "Prove Full exact assignment only against the loopback fake"

  @impl Mix.Task
  def run(args) do
    with {:ok, receipt} <- ExactAssignmentFullProof.run(args) do
      Mix.shell().info(Jason.encode!(receipt))
    else
      {:error, message} -> Mix.raise(message)
    end
  end
end
