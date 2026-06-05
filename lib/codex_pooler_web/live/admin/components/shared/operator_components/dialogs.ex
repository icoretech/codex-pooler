defmodule CodexPoolerWeb.Admin.OperatorComponents.Dialogs do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPooler.Accounts.User
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.OperatorComponents.Identity
  alias CodexPoolerWeb.Admin.OperatorForm

  attr :creating_operator, :boolean, required: true
  attr :create_form, Phoenix.HTML.Form, required: true
  attr :temporary_password_receipt, :map, default: nil
  attr :pool_options, :list, default: []

  def operator_create_dialog(assigns) do
    ~H"""
    <dialog :if={@creating_operator} id="operator-create-dialog" class="modal" open>
      <div class="modal-box max-w-2xl border border-base-300 bg-base-100 p-0 shadow-2xl">
        <div class="border-b border-base-300 px-6 py-5">
          <p class="text-sm font-semibold uppercase tracking-wide text-primary">
            Operator access
          </p>
          <h2 class="mt-1 text-2xl font-bold text-base-content">Create operator</h2>
          <p class="mt-2 text-sm leading-6 text-base-content/70">
            Add a local admin account and decide how the first password is delivered.
          </p>
        </div>

        <.temporary_password_receipt_card
          :if={@temporary_password_receipt}
          receipt={@temporary_password_receipt}
          wrapper_id="operator-create-temporary-password-receipt"
          code_id="operator-create-temporary-password-value"
          copy_button_id="operator-create-copy-temporary-password"
          close_button_id="operator-create-dialog-close"
          close_event="cancel_create_operator"
          heading_text="Copy this temporary password now."
          email_error_copy="Operator email could not be sent. Copy the temporary password now."
        />

        <.form
          :if={!@temporary_password_receipt}
          id="operator-create-form"
          for={@create_form}
          phx-submit="create_operator"
          autocomplete="off"
          class="grid gap-5 p-6"
        >
          <div class="grid gap-4 md:grid-cols-2">
            <.operator_email_input
              field={@create_form[:email]}
              label="Email"
              placeholder="operator@example.com"
              required
            />
            <.input
              field={@create_form[:display_name]}
              type="text"
              label="Display name"
              placeholder="Local operator"
            />
            <.operator_role_fields
              form={@create_form}
              pool_options={@pool_options}
              field_prefix="operator"
            />
            <.temporary_password_fields form={@create_form} />
          </div>
        </.form>

        <AdminComponents.dialog_footer
          :if={!@temporary_password_receipt}
          id="operator-create-dialog-footer"
        >
          <:actions>
            <AdminComponents.action_button
              id="operator-create-cancel"
              icon="hero-x-mark"
              label="Cancel"
              phx-click="cancel_create_operator"
            />
            <AdminComponents.action_button
              id="operator-create-submit"
              icon="hero-user-plus"
              label="Create operator"
              type="submit"
              form="operator-create-form"
              variant={:primary}
            />
          </:actions>
        </AdminComponents.dialog_footer>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button type="button" phx-click="cancel_create_operator">close</button>
      </form>
    </dialog>
    """
  end

  attr :editing_operator, :any, default: nil
  attr :edit_form, Phoenix.HTML.Form, default: nil
  attr :pool_options, :list, default: []

  def operator_edit_dialog(assigns) do
    ~H"""
    <dialog :if={@editing_operator} id="operator-edit-dialog" class="modal" open>
      <div class="modal-box max-w-2xl border border-base-300 bg-base-100 p-0 shadow-2xl">
        <div class="border-b border-base-300 px-6 py-5">
          <p class="text-sm font-semibold uppercase tracking-wide text-primary">
            Operator profile
          </p>
          <h2 class="mt-1 text-2xl font-bold text-base-content">Edit operator</h2>
          <p class="mt-2 text-sm leading-6 text-base-content/70">
            Update the local account details and whether the next sign in must change password.
          </p>
        </div>

        <.form
          id="operator-edit-form"
          for={@edit_form}
          phx-submit="save_operator"
          autocomplete="off"
          class="grid gap-5 p-6"
        >
          <.input field={@edit_form[:id]} type="hidden" />
          <div class="grid gap-4 md:grid-cols-2">
            <.operator_email_input field={@edit_form[:email]} label="Email" required />
            <.input field={@edit_form[:display_name]} type="text" label="Display name" />
            <.input
              field={@edit_form[:password_change_required]}
              type="checkbox"
              label="Require password change on next sign in"
            />
            <.operator_role_fields
              form={@edit_form}
              pool_options={@pool_options}
              field_prefix="operator_edit"
            />
          </div>
        </.form>

        <AdminComponents.dialog_footer id="operator-edit-dialog-footer">
          <:actions>
            <AdminComponents.action_button
              id="operator-edit-cancel"
              icon="hero-x-mark"
              label="Cancel"
              phx-click="cancel_edit"
            />
            <AdminComponents.action_button
              id="operator-edit-submit"
              icon="hero-check"
              label="Save operator"
              type="submit"
              form="operator-edit-form"
              variant={:primary}
            />
          </:actions>
        </AdminComponents.dialog_footer>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button type="button" phx-click="cancel_edit">close</button>
      </form>
    </dialog>
    """
  end

  attr :resetting_operator, :any, default: nil
  attr :password_dialog_receipt, :map, default: nil
  attr :reset_operation, :atom, default: nil
  attr :reset_form, Phoenix.HTML.Form, required: true

  def operator_password_dialog(assigns) do
    ~H"""
    <dialog
      :if={@resetting_operator || @password_dialog_receipt}
      id="operator-password-dialog"
      class="modal"
      open
    >
      <div class="modal-box max-w-2xl border border-base-300 bg-base-100 p-0 shadow-2xl">
        <div class="border-b border-base-300 px-6 py-5">
          <p class="text-sm font-semibold uppercase tracking-wide text-primary">
            Operator credential
          </p>
          <h2 class="mt-1 text-2xl font-bold text-base-content">
            {password_dialog_title(@reset_operation, @password_dialog_receipt)}
          </h2>
          <p class="mt-2 text-sm leading-6 text-base-content/70">
            <span class="font-medium text-base-content">
              {password_dialog_operator_label(@resetting_operator, @password_dialog_receipt)}
            </span>
            <span class="text-base-content/50">·</span>
            <span>
              {password_dialog_operator_email(@resetting_operator, @password_dialog_receipt)}
            </span>
          </p>
        </div>

        <.temporary_password_receipt_card
          :if={@password_dialog_receipt}
          receipt={@password_dialog_receipt}
          wrapper_id="operator-temporary-password-dialog-receipt"
          code_id="operator-temporary-password-dialog-value"
          copy_button_id="operator-copy-temporary-password"
          close_button_id="operator-password-dialog-close"
          close_event="cancel_reset"
          heading_text="Temporary password ready"
        />

        <.form
          :if={@resetting_operator && !@password_dialog_receipt}
          id="operator-reset-password-form"
          for={@reset_form}
          phx-submit="save_temporary_password"
          autocomplete="off"
          class="grid gap-5 p-6"
        >
          <.input field={@reset_form[:id]} type="hidden" />
          <.input field={@reset_form[:operation]} type="hidden" />
          <div class="grid gap-4 md:grid-cols-2">
            <.temporary_password_fields form={@reset_form} />
          </div>
        </.form>

        <AdminComponents.dialog_footer
          :if={@resetting_operator && !@password_dialog_receipt}
          id="operator-password-dialog-footer"
        >
          <:actions>
            <AdminComponents.action_button
              id="operator-reset-password-cancel"
              icon="hero-x-mark"
              label="Cancel"
              phx-click="cancel_reset"
            />
            <AdminComponents.action_button
              id="operator-reset-password-submit"
              icon="hero-arrow-path"
              label={reset_button_label(@reset_operation)}
              type="submit"
              form="operator-reset-password-form"
              variant={:primary}
            />
          </:actions>
        </AdminComponents.dialog_footer>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button type="button" phx-click="cancel_reset">close</button>
      </form>
    </dialog>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, default: "Email"
  attr :placeholder, :string, default: "operator@example.com"
  attr :required, :boolean, default: false

  defp operator_email_input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns =
      assigns
      |> assign(:id, field.id)
      |> assign(:name, field.name)
      |> assign(:value, field.value)
      |> assign(:errors, Enum.map(errors, &translate_error(&1)))

    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span class="label mb-1">{@label}</span>
        <span class={["input validator w-full", @errors != [] && "input-error"]}>
          <.icon name="hero-envelope" class="size-4 opacity-50" />
          <input
            type="email"
            id={@id}
            name={@name}
            value={Phoenix.HTML.Form.normalize_value("email", @value)}
            placeholder={@placeholder}
            autocomplete="email"
            required={@required}
          />
        </span>
      </label>
      <div class="validator-hint hidden">Enter valid email address</div>
      <p :for={msg <- @errors} class="mt-1.5 flex items-center gap-2 text-sm text-error">
        <.icon name="hero-exclamation-circle" class="size-5" />
        {msg}
      </p>
    </div>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :pool_options, :list, required: true
  attr :field_prefix, :string, required: true

  defp operator_role_fields(assigns) do
    assigns =
      assign(
        assigns,
        :selected_pool_ids,
        OperatorForm.selected_pool_ids(assigns.form)
      )

    ~H"""
    <.input
      field={@form[:role]}
      type="select"
      label="Operator role"
      options={OperatorForm.role_options()}
    />
    <div class="fieldset mb-2 md:col-span-2">
      <span class="label mb-1">Assigned Pools for instance admins</span>
      <input type="hidden" name={@field_prefix <> "[pool_ids][]"} value="" />
      <div
        id={@field_prefix <> "_pool_ids_group"}
        class="grid gap-2 rounded-box border border-base-300 bg-base-200/60 p-3"
      >
        <p :if={@pool_options == []} class="text-sm text-base-content/60">
          No Pools are available yet. Owners can still create another owner.
        </p>
        <label
          :for={pool <- @pool_options}
          id={@field_prefix <> "_pool_id_" <> pool.id <> "_option"}
          class="flex items-center gap-3 rounded-box bg-base-100 px-3 py-2 text-sm"
        >
          <input
            id={@field_prefix <> "_pool_id_" <> pool.id}
            type="checkbox"
            name={@field_prefix <> "[pool_ids][]"}
            value={pool.id}
            checked={MapSet.member?(@selected_pool_ids, pool.id)}
            class="checkbox checkbox-sm"
          />
          <span>{OperatorForm.pool_option_label(pool)}</span>
        </label>
      </div>
      <p class="mt-1 text-xs text-base-content/60">
        Pool assignments apply only while the operator role is instance admin. Owners keep instance-wide access.
      </p>
    </div>
    """
  end

  attr :receipt, :map, required: true
  attr :wrapper_id, :string, required: true
  attr :code_id, :string, required: true
  attr :copy_button_id, :string, required: true
  attr :close_button_id, :string, required: true
  attr :close_event, :string, required: true
  attr :heading_text, :string, required: true
  attr :email_error_copy, :string, default: nil

  defp temporary_password_receipt_card(assigns) do
    ~H"""
    <div class="grid gap-5 p-6">
      <div
        id={@wrapper_id}
        class={[
          "alert items-start",
          @receipt.email_error? && "alert-warning",
          !@receipt.email_error? && "alert-success"
        ]}
      >
        <.icon name="hero-key" class="size-5" />
        <div class="grid gap-1">
          <p class="font-semibold">{@heading_text}</p>
          <p :if={@receipt.email_error? && @email_error_copy} class="text-sm">
            {@email_error_copy}
          </p>
          <p class="text-sm">
            {@receipt.operator_email} must use this password on next sign in.
          </p>
        </div>
      </div>

      <div class="grid gap-2 rounded-box border border-base-300 bg-base-200 p-4">
        <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
          one-time password
        </p>
        <div class="join w-full">
          <code
            id={@code_id}
            class="join-item min-h-10 flex-1 break-all border border-base-300 bg-base-100 px-3 py-2.5 font-mono text-sm text-base-content"
          >
            {@receipt.temporary_password}
          </code>
          <button
            id={@copy_button_id}
            type="button"
            class="btn btn-neutral join-item min-h-10"
            phx-hook="ClipboardCopy"
            phx-update="ignore"
            data-copy-text={@receipt.temporary_password}
            data-copy-label="Copy"
            data-copied-label="Copied"
            aria-label="Copy one-time password"
          >
            <.icon name="hero-clipboard-document" class="copy-icon size-4" />
            <span data-copy-label>Copy</span>
          </button>
        </div>
      </div>
    </div>

    <AdminComponents.dialog_footer id={"#{@wrapper_id}-footer"}>
      <:actions>
        <AdminComponents.action_button
          id={@close_button_id}
          icon="hero-check"
          label="Close"
          phx-click={@close_event}
          variant={:primary}
        />
      </:actions>
    </AdminComponents.dialog_footer>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true

  defp temporary_password_fields(assigns) do
    ~H"""
    <.input
      field={@form[:password_mode]}
      type="select"
      label="Temporary password"
      options={password_mode_options()}
    />
    <.input
      field={@form[:password]}
      type="password"
      label="Manual password"
      placeholder="Used only when manual mode is selected"
      value=""
    />
    <.input
      field={@form[:password_change_required]}
      type="checkbox"
      label="Require password change on next sign in"
    />
    <.input
      field={@form[:send_email]}
      type="checkbox"
      label="Send text credential email"
    />
    """
  end

  defp password_mode_options do
    [{"Generate secure password", "generated"}, {"Use manual password", "manual"}]
  end

  defp reset_button_label(:reactivate), do: "Reactivate operator"
  defp reset_button_label(_operation), do: "Reset password"

  defp password_dialog_title(_operation, %{label: label}), do: label
  defp password_dialog_title(:reactivate, _receipt), do: "Reactivate operator"
  defp password_dialog_title(_operation, _receipt), do: "Reset password"

  defp password_dialog_operator_label(%User{} = operator, _receipt),
    do: Identity.operator_display_name(operator)

  defp password_dialog_operator_label(_operator, %{operator_label: label}), do: label
  defp password_dialog_operator_label(_operator, _receipt), do: "operator"

  defp password_dialog_operator_email(%User{email: email}, _receipt), do: email
  defp password_dialog_operator_email(_operator, %{operator_email: email}), do: email
  defp password_dialog_operator_email(_operator, _receipt), do: "unknown email"
end
