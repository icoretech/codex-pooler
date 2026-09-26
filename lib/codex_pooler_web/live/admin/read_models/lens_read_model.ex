defmodule CodexPoolerWeb.Admin.LensReadModel do
  @moduledoc false

  alias CodexPooler.Accounting
  alias CodexPooler.Accounting.RequestLogs.ModelHistory
  alias CodexPooler.Accounts.Scope
  alias CodexPoolerWeb.Admin.LensFilterForm
  alias CodexPoolerWeb.Admin.PoolFilterComponents

  @type result :: %{history: ModelHistory.result(), pool_options: [map()], model_options: [map()], pool_ids: MapSet.t(String.t())}

  @spec load(Scope.t(), map()) :: result()
  def load(scope, filters) do
    history = Accounting.model_declaration_history(scope, filters)

    watched_pools =
      Enum.filter(history.pools, fn pool -> filters["pool_id"] in ["", pool.id] end)

    %{
      history: history,
      pool_options: PoolFilterComponents.pool_filter_options(history.pools),
      model_options: LensFilterForm.model_options(history.models, filters["sent_model"]),
      pool_ids: MapSet.new(watched_pools, & &1.id)
    }
  end
end
