defmodule Mix.Tasks.Dev.ResponsesToolCompatSmoke do
  @moduledoc """
  Certifies Responses tool compatibility against an isolated localhost instance.

  The task owns its temporary Pools, assignments, API keys, catalog rows, and
  serving overrides. It records exact identifiers in a private journal and
  cleans up only those identifiers.

  ## Provision and certify

      mix dev.responses_tool_compat_smoke \
        --base-url http://localhost:4000 \
        --owner-id OWNER_UUID \
        --identity-label codex01 \
        --identity-label codex02 \
        --identity-label codex03

  Add `--dry-run` to perform argument, isolation, owner, and identity checks
  without booting the application, writing database rows, or sending requests.

  ## Recovery

      mix dev.responses_tool_compat_smoke \
        --cleanup-run-id RUN_ID \
        --owner-id OWNER_UUID

  ## Resolve the sole active owner

      mix dev.responses_tool_compat_smoke --resolve-owner-id
  """

  use Mix.Task

  alias CodexPooler.Dev.ResponsesToolCompatSmoke

  @shortdoc "Certify Responses tools on an isolated localhost instance"

  @impl Mix.Task
  def run(args) do
    with {:ok, command} <- ResponsesToolCompatSmoke.parse_args(args),
         {:ok, output} <- ResponsesToolCompatSmoke.execute(command) do
      if output != "", do: Mix.shell().info(output)
    else
      {:error, message} -> Mix.raise(message)
    end
  end
end
