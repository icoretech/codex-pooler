defmodule CodexPoolerWeb.Admin.OperatorComponents.Dialogs do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPooler.Accounts.User
  alias CodexPoolerWeb.Admin.Components, as: AdminComponents
  alias CodexPoolerWeb.Admin.OperatorComponents.Identity
  alias CodexPoolerWeb.Admin.OperatorForm
  alias Phoenix.HTML.{Form, FormField}

  @operator_docs_url "https://docs.codex-pooler.com/operators/operators/#create-operator"
  @operator_actions_docs_url "https://docs.codex-pooler.com/operators/operators/#action-menu"
  @operator_password_docs_url "https://docs.codex-pooler.com/operators/operators/#password-reset"

  attr :creating_operator, :boolean, required: true
  attr :create_form, Form, required: true
  attr :temporary_password_receipt, :map, default: nil
  attr :pool_options, :list, default: []

  def operator_create_dialog(assigns) do
    assigns = assign(assigns, :operator_docs_url, @operator_docs_url)

    ~H"""
    <dialog
      :if={@creating_operator}
      id="operator-create-dialog"
      class="modal modal-bottom overflow-x-hidden sm:modal-middle"
      open
    >
      <div class="modal-box sm:max-w-2xl border border-base-300 bg-base-100 p-0 shadow-2xl">
        <div class="border-b border-base-300 px-5 py-4 sm:px-6 sm:py-5">
          <p class="text-sm font-semibold uppercase tracking-wide text-primary">
            Operator access
          </p>
          <h2 class="mt-1 text-2xl font-bold text-base-content">
            {create_dialog_title(@temporary_password_receipt)}
          </h2>
          <p class="mt-2 text-sm leading-6 text-base-content/70">
            {create_dialog_description(@temporary_password_receipt)}
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
          email_error_copy="Operator email could not be sent. Copy the temporary password now."
        />

        <.form
          :if={!@temporary_password_receipt}
          id="operator-create-form"
          for={@create_form}
          phx-submit="create_operator"
          autocomplete="off"
          class="grid gap-5 p-5 sm:p-6"
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
          docs_url={@operator_docs_url}
        >
          <:actions>
            <AdminComponents.action_button
              id="operator-create-cancel"
              label="Cancel"
              variant={:ghost}
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
  attr :edit_form, Form, default: nil
  attr :pool_options, :list, default: []

  def operator_edit_dialog(assigns) do
    assigns = assign(assigns, :operator_actions_docs_url, @operator_actions_docs_url)

    ~H"""
    <dialog
      :if={@editing_operator}
      id="operator-edit-dialog"
      class="modal modal-bottom overflow-x-hidden sm:modal-middle"
      open
    >
      <div class="modal-box sm:max-w-2xl border border-base-300 bg-base-100 p-0 shadow-2xl">
        <div class="border-b border-base-300 px-5 py-4 sm:px-6 sm:py-5">
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
          class="grid gap-5 p-5 sm:p-6"
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

        <AdminComponents.dialog_footer
          id="operator-edit-dialog-footer"
          docs_url={@operator_actions_docs_url}
        >
          <:actions>
            <AdminComponents.action_button
              id="operator-edit-cancel"
              label="Cancel"
              variant={:ghost}
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
  attr :reset_form, Form, required: true

  def operator_password_dialog(assigns) do
    assigns = assign(assigns, :operator_password_docs_url, @operator_password_docs_url)

    ~H"""
    <dialog
      :if={@resetting_operator || @password_dialog_receipt}
      id="operator-password-dialog"
      class="modal modal-bottom overflow-x-hidden sm:modal-middle"
      open
    >
      <div class="modal-box sm:max-w-2xl border border-base-300 bg-base-100 p-0 shadow-2xl">
        <div class="border-b border-base-300 px-5 py-4 sm:px-6 sm:py-5">
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
        />

        <.form
          :if={@resetting_operator && !@password_dialog_receipt}
          id="operator-reset-password-form"
          for={@reset_form}
          phx-submit="save_temporary_password"
          autocomplete="off"
          class="grid gap-5 p-5 sm:p-6"
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
          docs_url={@operator_password_docs_url}
        >
          <:actions>
            <AdminComponents.action_button
              id="operator-reset-password-cancel"
              label="Cancel"
              variant={:ghost}
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

  attr :field, FormField, required: true
  attr :label, :string, default: "Email"
  attr :placeholder, :string, default: "operator@example.com"
  attr :required, :boolean, default: false

  defp operator_email_input(%{field: %FormField{} = field} = assigns) do
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
            value={Form.normalize_value("email", @value)}
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

  attr :form, Form, required: true
  attr :pool_options, :list, required: true
  attr :field_prefix, :string, required: true

  defp operator_role_fields(assigns) do
    assigns =
      assigns
      |> assign(:selected_pool_ids, OperatorForm.selected_pool_ids(assigns.form))
      |> assign(:selected_role, to_string(Form.input_value(assigns.form, :role)))

    ~H"""
    <div class="contents group/rolegate">
      <fieldset id={@field_prefix <> "_role"} class="grid gap-2 md:col-span-2">
        <legend class="mb-1 text-[0.6rem] font-bold uppercase tracking-wide text-base-content/50">
          Operator role
          <span class="ml-1 text-[11px] font-medium normal-case tracking-normal text-base-content/45">
            Instance-wide owner or Pool-scoped admin
          </span>
        </legend>
        <div class="grid gap-2 sm:grid-cols-2">
          <.operator_role_card
            id={@field_prefix <> "_role_instance_admin"}
            field_prefix={@field_prefix}
            value="instance_admin"
            selected_role={@selected_role}
            label="Instance admin"
            description="Manages only the Pools assigned below."
          />
          <.operator_role_card
            id={@field_prefix <> "_role_instance_owner"}
            field_prefix={@field_prefix}
            value="instance_owner"
            selected_role={@selected_role}
            label="Instance owner"
            description="Instance-wide access to every Pool and setting."
          />
        </div>
      </fieldset>
      <div class="fieldset mb-2 transition-opacity md:col-span-2 group-has-[.operator-role-owner:checked]/rolegate:opacity-45">
        <p class="mb-1 text-[0.6rem] font-bold uppercase tracking-wide text-base-content/50">
          Assigned Pools
          <span class="ml-1 text-[11px] font-medium normal-case tracking-normal text-base-content/45">
            Apply only while the role is instance admin; owners keep instance-wide access
          </span>
        </p>
        <input type="hidden" name={@field_prefix <> "[pool_ids][]"} value="" />
        <div id={@field_prefix <> "_pool_ids_group"} class="grid gap-2 sm:grid-cols-2">
          <p :if={@pool_options == []} class="text-sm text-base-content/60 sm:col-span-2">
            No Pools are available yet. Owners can still create another owner.
          </p>
          <label
            :for={pool <- @pool_options}
            id={@field_prefix <> "_pool_id_" <> pool.id <> "_option"}
            class="flex min-h-10 min-w-0 cursor-pointer items-center gap-3 rounded-box border border-base-300 bg-base-100 px-3 py-1.5 transition-colors hover:border-primary/50 hover:bg-primary/5 has-[:checked]:border-primary/40 has-[:checked]:bg-primary/5"
          >
            <input
              id={@field_prefix <> "_pool_id_" <> pool.id}
              type="checkbox"
              name={@field_prefix <> "[pool_ids][]"}
              value={pool.id}
              checked={MapSet.member?(@selected_pool_ids, pool.id)}
              class="checkbox checkbox-primary checkbox-sm shrink-0"
            />
            <span class="truncate text-sm font-medium text-base-content">{pool.name}</span>
          </label>
        </div>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :field_prefix, :string, required: true
  attr :value, :string, required: true
  attr :selected_role, :string, required: true
  attr :label, :string, required: true
  attr :description, :string, required: true

  defp operator_role_card(assigns) do
    ~H"""
    <label class="group/rolecard relative flex min-w-0 cursor-pointer items-start gap-2.5 rounded-box border border-base-300 bg-base-100 p-2.5 transition-colors hover:border-primary/50 has-[.operator-role-radio:checked]:border-primary/60 has-[.operator-role-radio:checked]:bg-primary/5 has-[.operator-role-radio:focus-visible]:outline has-[.operator-role-radio:focus-visible]:outline-2 has-[.operator-role-radio:focus-visible]:outline-offset-2 has-[.operator-role-radio:focus-visible]:outline-primary">
      <span class="pointer-events-none absolute right-2.5 top-3">
        <.icon
          name="hero-check"
          class="hidden size-3 text-primary group-has-[.operator-role-radio:checked]/rolecard:inline-block"
        />
      </span>
      <input
        id={@id}
        type="radio"
        class={[
          "operator-role-radio sr-only",
          @value == "instance_owner" && "operator-role-owner"
        ]}
        name={@field_prefix <> "[role]"}
        value={@value}
        checked={@selected_role == @value}
      />
      <span class="grid min-w-0 gap-0.5">
        <span class="text-[13px] font-semibold leading-tight text-base-content">{@label}</span>
        <span class="text-[11px] leading-4 text-base-content/55">{@description}</span>
      </span>
    </label>
    """
  end

  # The header follows the flow rather than freezing on the form's opening line:
  # once the receipt exists the operator does too, and "add a local admin
  # account" is describing a step already taken.
  defp create_dialog_title(nil), do: "Create operator"
  defp create_dialog_title(_receipt), do: "Copy this password before closing"

  defp create_dialog_description(nil),
    do: "Add a local admin account and decide how the first password is delivered."

  defp create_dialog_description(_receipt),
    do: "It is shown once, and cannot be recovered afterwards."

  attr :receipt, :map, required: true
  attr :wrapper_id, :string, required: true
  attr :code_id, :string, required: true
  attr :copy_button_id, :string, required: true
  attr :close_button_id, :string, required: true
  attr :close_event, :string, required: true
  attr :email_error_copy, :string, default: nil

  defp temporary_password_receipt_card(assigns) do
    assigns = assign(assigns, :operator_password_docs_url, @operator_password_docs_url)

    ~H"""
    <div id={@wrapper_id} class="grid gap-4 p-5 sm:p-6">
      <div :if={@receipt.email_error?} class="alert alert-warning items-start">
        <.icon name="hero-exclamation-triangle" class="size-5" />
        <div class="grid gap-1">
          <p class="font-semibold">{@email_error_copy}</p>
          <p class="text-sm">Hand it over yourself: they have no other way to receive it.</p>
        </div>
      </div>

      <p class="text-sm leading-6 text-base-content/70">
        <span class="font-semibold text-base-content">{@receipt.operator_email}</span>
        must use it on next sign in.
      </p>

      <AdminComponents.one_time_secret
        value={@receipt.temporary_password}
        value_id={@code_id}
        copy_id={@copy_button_id}
        copy_label="Copy password"
        copy_aria_label="Copy one-time password"
      />
    </div>

    <AdminComponents.dialog_footer id={"#{@wrapper_id}-footer"} docs_url={@operator_password_docs_url}>
      <:actions>
        <AdminComponents.action_button
          id={@close_button_id}
          icon="hero-check"
          label="Done"
          phx-click={@close_event}
          variant={:primary}
        />
      </:actions>
    </AdminComponents.dialog_footer>
    """
  end

  attr :form, Form, required: true

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
