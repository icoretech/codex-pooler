defmodule CodexPoolerWeb.Admin.LensPresentation do
  @moduledoc false
  use CodexPoolerWeb, :html
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.LensCharts

  attr :history, :map, required: true

  def history(assigns) do
    ~H"""
    <AdminComponents.empty_state :if={@history.counts.total == 0} id="model-history-empty" title="No retained attempts" description="No attempts match this window and scope. Adjust the filters to inspect existing history." icon="hero-magnifying-glass" />
    <div :if={@history.counts.total > 0} class="grid min-w-0 gap-6">
      <div id="model-history-counts" class="grid grid-cols-2 gap-3 rounded-box border border-base-300 bg-base-100 p-4 lg:grid-cols-4">
        <div :for={{key, label} <- count_labels()} data-role={"model-count-#{key}"}>
          <div class="text-xs text-base-content/60">{label}</div>
          <div class="text-xl font-semibold tabular-nums">{@history.counts[key]}</div>
        </div>
      </div>
      <LensCharts.charts history={@history} />
      <details id="model-history-coverage" class="text-xs text-base-content/60">
        <summary class="cursor-pointer">Recording details (info): {@history.counts.observed} recorded with a model name · {@history.counts.missing} without a model name · {@history.counts.uncollected} not collected</summary>
        <div class="mt-3 flex flex-wrap gap-x-6 gap-y-2">
          <span :for={{key, label} <- coverage_labels()} data-role={"model-count-#{key}"}>{label}: {@history.counts[key]}</span>
        </div>
        <p class="mt-2">A response without a model name does not show that a different model was used. Interrupted or older recordings may be incomplete; missing earlier events cannot be reconstructed.</p>
      </details>
      <p class="text-xs text-base-content/60" id="model-history-denominators">
        Name changed within a response: {rate(@history.counts.conflicts, @history.counts.observed)} of {@history.counts.observed} attempts recorded with a model name, including interrupted responses.
        Different from sent: {rate(@history.counts.mismatches, @history.counts.comparable)} of {@history.counts.comparable} attempts with both the sent and first reported model names, including historical rows.
        Reported names do not independently verify which model generated the answer. History ends when attempt retention removes its source rows.
      </p>
      <section :if={@history.groups != []} class="grid min-w-0 gap-3" aria-labelledby="model-history-groups-heading">
        <h2 id="model-history-groups-heading" class="font-semibold">Affected Pools and models</h2>
        <p class="text-xs text-base-content/60">Only attempts where the first reported name differs from the model sent, or the provider changes that name during the response, grouped by Pool, upstream and sent model. Up to 100 groups; overlapping signals count once per affected attempt.</p>
        <div class="overflow-x-auto rounded-box border border-base-300">
          <table id="model-history-groups" class="table table-sm">
            <caption class="sr-only">Affected attempts grouped by Pool, upstream identity and sent model</caption>
            <thead>
              <tr>
                <th>Pool / upstream</th><th>Sent model</th><th class="text-right">Affected attempts</th><th class="text-right">Different from sent</th><th class="text-right">Name changed</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={group <- @history.groups}>
                <td>
                  <.link :if={group.upstream_identity_id && group.sent_model} patch={~p"/admin/lens?#{group_filters(@history.filters, group)}"} class="link link-hover">{group.pool_name} / {group.upstream_label || "Unavailable"}</.link>
                  <span :if={!group.upstream_identity_id || !group.sent_model}>{group.pool_name} / {group.upstream_label || "Unavailable"}</span>
                </td>
                <td class="text-xs">{group.sent_model || "Unavailable"}</td>
                <td class="text-right tabular-nums">{group.total}</td><td class="text-right tabular-nums">{group.mismatches}</td><td class="text-right tabular-nums">{group.conflicts}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
      <section :if={@history.attempts != [] || @history.counts.mismatches > 0 || @history.counts.conflicts > 0} class="grid min-w-0 gap-3" aria-labelledby="model-history-attempts-heading">
        <h2 id="model-history-attempts-heading" class="font-semibold">Attempt evidence</h2>
        <p class="text-xs text-base-content/60">Latest 100 matching attempts. Model differences are shown by default; missing recordings are informational. Repeated name changes in one attempt count once.</p>
        <AdminComponents.empty_state :if={@history.attempts == []} id="model-history-empty" title="No matching attempts" description="No retained attempts match this evidence filter. Select another evidence type or adjust the window." icon="hero-document-magnifying-glass" />
        <div :if={@history.attempts != []} class="rounded-box border border-base-300 bg-base-100 lg:overflow-x-auto">
          <table id="model-history-attempts" data-ledger-dense class="admin-ledger-table table table-sm lg:min-w-[56rem]">
            <caption class="sr-only">Latest retained upstream attempts and their model declaration evidence</caption>
            <colgroup><col class="w-28" /><col /><col class="w-36" /><col class="w-32" /><col class="w-48" /><col class="w-40" /></colgroup>
            <thead>
              <tr>
                <th>Attempt / UTC</th><th>Pool / upstream</th><th>Sent / first reported</th><th>Changed to</th><th>Final report / outcome</th><th>Recording / name change</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={attempt <- @history.attempts} id={"model-history-attempt-#{attempt.id}"}>
                <td class="max-lg:col-span-2 max-lg:col-start-2 max-lg:row-start-1 max-lg:sm:col-span-1 max-lg:sm:col-start-2">
                  <.link navigate={~p"/admin/request-logs?#{%{selected_request_id: attempt.request_id}}"} class="link link-hover">Attempt {attempt.attempt_number}</.link><div class="text-xs text-base-content/60">{Calendar.strftime(attempt.started_at, "%m-%d %H:%M:%S")}</div>
                </td>
                <td class="min-w-0 max-lg:col-span-2 max-lg:col-start-2 max-lg:row-start-2 max-lg:sm:col-start-3 max-lg:sm:row-start-1">
                  {attempt.pool_name}
                  <div class="text-xs text-base-content/60">{attempt.upstream_label || "Unavailable"}</div>
                </td>
                <td class="max-lg:col-span-2 max-lg:col-start-2 max-lg:row-start-3 max-lg:sm:col-span-1 max-lg:sm:col-start-2 max-lg:sm:row-start-2">
                  <div class="text-xs"><span class="lg:sr-only">Sent: </span>{attempt.sent_model || "Unavailable"}</div><div class="text-xs"><span class="lg:sr-only">First report: </span>{attempt.served_model || "No model reported"}</div>
                </td>
                <td class="text-xs max-lg:col-span-2 max-lg:col-start-2 max-lg:row-start-4 max-lg:sm:col-start-3 max-lg:sm:row-start-2"><span class="lg:sr-only">Changed to: </span>{fact(attempt, "first_conflicting_model") || "Unavailable"}</td>
                <td class="max-lg:col-span-2 max-lg:col-start-2 max-lg:row-start-5 max-lg:sm:col-span-1 max-lg:sm:col-start-2 max-lg:sm:row-start-3">
                  <div class="text-xs"><span :if={fact(attempt, "terminal_model")} class="lg:sr-only">Final report: </span>{fact(attempt, "terminal_model") || "No final model reported"}</div><div class="text-xs text-base-content/60">{fact(attempt, "terminal_status") || if(attempt.model_observation, do: "No final event recorded", else: "Not collected")}</div>
                </td>
                <td class="max-lg:col-span-2 max-lg:col-start-2 max-lg:row-start-6 max-lg:sm:col-start-3 max-lg:sm:row-start-3">
                  <div><span class="lg:sr-only">Recording: </span>{fact(attempt, "coverage") || "Not collected"}</div><div class={if(fact(attempt, "conflict") == true, do: "text-warning", else: "text-base-content/60")}>{conflict_label(fact(attempt, "conflict"))}</div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </div>
    """
  end

  defp fact(attempt, key), do: (attempt.model_observation || %{})[key]
  defp conflict_label(true), do: "Model name changed"
  defp conflict_label(false), do: "No name change observed"
  defp conflict_label(nil), do: "Unknown"
  defp rate(_numerator, 0), do: "Unavailable"
  defp rate(numerator, denominator), do: "#{Float.round(numerator * 100 / denominator, 1)}%"
  defp group_filters(filters, group), do: Map.merge(filters, %{"pool_id" => group.pool_id, "upstream_identity_id" => group.upstream_identity_id || "", "sent_model" => group.sent_model || "", "evidence" => "signals"})
  defp count_labels, do: [total: "Attempts", comparable: "With both model names", mismatches: "Different from sent", conflicts: "Name changed in response"]
  defp coverage_labels, do: [observed: "Recorded with a model name", missing: "Without a model name", uncollected: "Not collected", partial: "Incomplete recording", without_terminal: "No final event recorded", collected: "Recorded attempts"]
end
