defmodule Mix.Tasks.Dev.LensFixture do
  @moduledoc "Seed synthetic Lens signals in the local development database: mix dev.lens_fixture"
  use Mix.Task
  alias CodexPooler.Dev.{LensFixture, LocalTarget, QaBackgroundWorkers}
  @requirements ["app.config"]
  @shortdoc "Seed a disabled Lens demo Pool without provider credentials"

  @impl true
  def run(args) do
    if Mix.env() != :dev or args != [], do: Mix.raise("use MIX_ENV=dev mix dev.lens_fixture without arguments")

    case LocalTarget.validate_target_database("codex_pooler_dev", Application.fetch_env!(:codex_pooler, CodexPooler.Repo)) do
      :ok -> :ok
      {:error, reason} -> Mix.raise(reason)
    end

    Logger.configure(level: :warning)
    QaBackgroundWorkers.start_application!()
    result = LensFixture.seed!()
    Mix.shell().info("Lens synthetic fixture: #{result.attempts} attempts, disabled Pool, revoked key, no provider credentials")
    Mix.shell().info(result.path)
  end
end
