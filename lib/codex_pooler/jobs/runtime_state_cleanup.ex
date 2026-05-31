defmodule CodexPooler.Jobs.RuntimeStateCleanup do
  @moduledoc false

  alias CodexPooler.Accounting
  alias CodexPooler.Catalog
  alias CodexPooler.Files
  alias CodexPooler.Gateway.Persistence.RuntimeCleanup
  alias CodexPooler.Upstreams.Reconciliation.AccountReconciliation

  @type orchestration_result :: {:ok, map()} | {:error, term()}

  @spec run(DateTime.t()) :: orchestration_result()
  def run(now \\ DateTime.utc_now()) do
    with {:ok, file_summary} <- Files.cleanup_expired(now),
         {:ok, gateway_summary} <- RuntimeCleanup.cleanup_expired_runtime_state(now),
         {:ok, accounting_summary} <- Accounting.recover_stale_reservations(now),
         {:ok, catalog_summary} <- Catalog.cleanup_stale_sync_runs(now),
         {:ok, reconciliation_summary} <- AccountReconciliation.cleanup_stale_state(now) do
      {:ok,
       file_summary
       |> Map.merge(gateway_summary)
       |> Map.merge(accounting_summary)
       |> Map.merge(catalog_summary)
       |> Map.merge(reconciliation_summary)}
    end
  end
end
