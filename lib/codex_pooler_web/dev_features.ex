defmodule CodexPoolerWeb.DevFeatures do
  @moduledoc false

  @build_enabled Application.compile_env(:codex_pooler, :dev_features_build_enabled, false)
  @script_src "http://localhost:8400/live.js"

  alias CodexPooler.Jobs.DevelopmentControls

  @spec enabled?() :: boolean()

  if @build_enabled do
    def enabled? do
      Application.get_env(:codex_pooler, :dev_features_enabled, false) == true
    end
  else
    def enabled?, do: false
  end

  @spec impeccable_live_enabled?() :: boolean()

  if @build_enabled do
    def impeccable_live_enabled? do
      enabled?() and
        CodexPooler.InstanceSettings.current().development.impeccable_live_enabled == true
    end
  else
    def impeccable_live_enabled?, do: false
  end

  @spec account_reconciliation_paused?() :: boolean()
  def account_reconciliation_paused?, do: DevelopmentControls.account_reconciliation_paused?()

  @spec impeccable_live_script_src() :: String.t()
  def impeccable_live_script_src, do: @script_src

  @spec browser_csp_extra_sources() :: keyword([String.t()])
  if @build_enabled do
    def browser_csp_extra_sources do
      if impeccable_live_enabled?() do
        helper_origin = "http://localhost:8400"
        [script_src: [helper_origin], connect_src: [helper_origin], img_src: ["blob:"]]
      else
        []
      end
    end
  else
    def browser_csp_extra_sources, do: []
  end
end
