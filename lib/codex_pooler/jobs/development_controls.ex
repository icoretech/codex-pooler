defmodule CodexPooler.Jobs.DevelopmentControls do
  @moduledoc false

  @build_enabled Application.compile_env(:codex_pooler, :dev_features_build_enabled, false)

  @spec account_reconciliation_paused?() :: boolean()

  if @build_enabled do
    def account_reconciliation_paused? do
      Application.get_env(:codex_pooler, :dev_features_enabled, false) == true and
        CodexPooler.InstanceSettings.get!().development.account_reconciliation_paused == true
    end
  else
    def account_reconciliation_paused?, do: false
  end
end
