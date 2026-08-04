defmodule Mix.Tasks.Dev.SavedResetSafetyProbe do
  @moduledoc """
  Runs the local saved-reset safety certification against synthetic loopback data.

      MIX_ENV=dev mix dev.saved_reset_safety_probe --scenario all
  """

  use Mix.Task

  alias CodexPooler.Dev.SavedResetSafetyProbe

  @shortdoc "Certify saved-reset safety on the isolated dev database"

  @impl Mix.Task
  def run(args) do
    with {:ok, command} <- SavedResetSafetyProbe.parse_args(args),
         {:ok, receipt} <- SavedResetSafetyProbe.execute(command) do
      Mix.shell().info(Jason.encode!(receipt))
    else
      {:error, message} -> Mix.raise(message)
    end
  end
end
