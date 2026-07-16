defmodule CodexPoolerWeb.Admin.UpstreamPageComponents.AssignPoolDialog do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.Components, as: AdminComponents

  @upstream_actions_docs_url "https://docs.codex-pooler.com/operators/upstreams/#card-action-menu"

  attr :account, :map, default: nil
  attr :form, :any, required: true
  attr :pool_options, :list, required: true

  def assign_pool_dialog(assigns) do
    assigns =
      assigns
      |> assign(:pool_available?, Enum.any?(assigns.pool_options, &pool_option_available?/1))
      |> assign(:upstream_actions_docs_url, @upstream_actions_docs_url)

    ~H"""
    <dialog :if={@account} id="assign-pool-dialog" class="modal" open>
      <div class="modal-box max-w-xl border border-base-300 bg-base-100 p-0 shadow-2xl">
        <div class="border-b border-base-300 px-6 py-5">
          <p class="text-sm font-semibold uppercase tracking-wide text-primary">
            Upstream account
          </p>
          <h2 class="mt-1 text-2xl font-bold text-base-content">Assign to Pool</h2>
          <p class="mt-2 text-sm leading-6 text-base-content/70">
            Select a target Pool for <strong>{@account.label}</strong>.
          </p>
        </div>

        <.form
          id="assign-pool-form"
          for={@form}
          phx-submit="assign_pool_account"
          autocomplete="off"
          class="grid gap-5 p-6"
        >
          <.input
            field={@form[:pool_id]}
            type="select"
            label="Target Pool"
            options={@pool_options}
            prompt="Select Pool"
            required
          />
        </.form>

        <AdminComponents.dialog_footer
          id="assign-pool-dialog-footer"
          docs_url={@upstream_actions_docs_url}
        >
          <:actions>
            <AdminComponents.action_button
              id="assign-pool-cancel"
              icon="hero-x-mark"
              label="Cancel"
              phx-click="close_assign_pool"
            />
            <AdminComponents.action_button
              id="assign-pool-submit"
              icon="hero-server-stack"
              label="Assign to Pool"
              type="submit"
              form="assign-pool-form"
              variant={:primary}
              disabled={!@pool_available?}
            />
          </:actions>
        </AdminComponents.dialog_footer>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button type="button" phx-click="close_assign_pool">close</button>
      </form>
    </dialog>
    """
  end

  defp pool_option_available?({_label, value}) when is_binary(value), do: value != ""
  defp pool_option_available?(_option), do: false
end
