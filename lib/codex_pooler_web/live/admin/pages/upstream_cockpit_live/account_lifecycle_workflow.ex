defmodule CodexPoolerWeb.Admin.UpstreamCockpitLive.AccountLifecycleWorkflow do
  @moduledoc false

  use Gettext, backend: CodexPoolerWeb.Gettext

  import Phoenix.Component, only: [assign: 2, assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias CodexPooler.Upstreams
  alias CodexPoolerWeb.Admin.UpstreamsLive.WorkflowError

  @reason "admin_upstream_cockpit_live"

  @spec open_rename(Phoenix.LiveView.Socket.t(), Ecto.UUID.t()) :: Phoenix.LiveView.Socket.t()
  def open_rename(socket, identity_id) do
    if action_available?(socket, :rename, identity_id) do
      assign(socket,
        renaming_account: %{id: identity_id, label: current_label(socket)},
        rename_account_form: rename_form(current_label(socket)),
        confirming_saved_reset_redemption: nil
      )
    else
      put_unavailable_action_error(socket, :rename)
    end
  end

  @spec close_rename(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def close_rename(socket), do: assign(socket, renaming_account: nil, rename_account_form: nil)

  @spec validate_rename(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def validate_rename(socket, rename_params) do
    assign(
      socket,
      :rename_account_form,
      rename_form(current_label(socket), rename_params, :validate)
    )
  end

  @spec rename(Phoenix.LiveView.Socket.t(), map(), (Phoenix.LiveView.Socket.t() ->
                                                      Phoenix.LiveView.Socket.t())) ::
          Phoenix.LiveView.Socket.t()
  def rename(socket, rename_params, reload_fun) do
    identity_id = socket.assigns.cockpit.identity.id

    case Upstreams.rename_account_for_scope(
           socket.assigns.current_scope,
           identity_id,
           rename_params
         ) do
      {:ok, _result} ->
        socket
        |> put_flash(:info, gettext("Upstream account renamed"))
        |> close_rename()
        |> reload_fun.()

      {:error, %Ecto.Changeset{} = changeset} ->
        assign(socket, :rename_account_form, to_form(changeset, as: :rename))

      {:error, reason} ->
        put_flash(socket, :error, error_message(reason))
    end
  end

  @spec pause(Phoenix.LiveView.Socket.t(), Ecto.UUID.t(), (Phoenix.LiveView.Socket.t() ->
                                                             Phoenix.LiveView.Socket.t())) ::
          Phoenix.LiveView.Socket.t()
  def pause(socket, identity_id, reload_fun) do
    lifecycle_action(
      socket,
      identity_id,
      :pause,
      &Upstreams.pause_account_for_scope/3,
      gettext("Upstream account paused"),
      reload_fun
    )
  end

  @spec reactivate(Phoenix.LiveView.Socket.t(), Ecto.UUID.t(), (Phoenix.LiveView.Socket.t() ->
                                                                  Phoenix.LiveView.Socket.t())) ::
          Phoenix.LiveView.Socket.t()
  def reactivate(socket, identity_id, reload_fun) do
    lifecycle_action(
      socket,
      identity_id,
      :reactivate,
      &Upstreams.reactivate_account_for_scope/3,
      gettext("Upstream account reactivated"),
      reload_fun
    )
  end

  @spec refresh(Phoenix.LiveView.Socket.t(), Ecto.UUID.t(), (Phoenix.LiveView.Socket.t() ->
                                                               Phoenix.LiveView.Socket.t())) ::
          Phoenix.LiveView.Socket.t()
  def refresh(socket, identity_id, reload_fun) do
    cond do
      identity_id != socket.assigns.cockpit.identity.id ->
        put_flash(socket, :error, gettext("Upstream account was not found"))

      action_available?(socket, :refresh_token, identity_id) ->
        enqueue_token_refresh(socket, identity_id, reload_fun)

      true ->
        put_unavailable_action_error(socket, :refresh_token)
    end
  end

  @spec open_delete(Phoenix.LiveView.Socket.t(), Ecto.UUID.t()) :: Phoenix.LiveView.Socket.t()
  def open_delete(socket, identity_id) do
    if action_available?(socket, :delete, identity_id) do
      account = %{id: identity_id, label: socket.assigns.cockpit.header.title}

      assign(socket,
        deleting_account: account,
        delete_account_form: delete_form(account),
        confirming_saved_reset_redemption: nil
      )
    else
      put_unavailable_action_error(socket, :delete)
    end
  end

  @spec close_delete(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def close_delete(socket),
    do: assign(socket, deleting_account: nil, delete_account_form: delete_form(nil))

  @spec confirm_delete(Phoenix.LiveView.Socket.t(), map(), (Phoenix.LiveView.Socket.t() ->
                                                              Phoenix.LiveView.Socket.t())) ::
          Phoenix.LiveView.Socket.t()
  def confirm_delete(socket, delete_params, success_fun) do
    case validate_delete_confirmation(socket.assigns.deleting_account, delete_params) do
      :ok ->
        delete_account(socket, delete_params, success_fun)

      {:error, form} ->
        assign(socket, :delete_account_form, form)
    end
  end

  defp delete_account(socket, delete_params, success_fun) do
    identity_id = socket.assigns.cockpit.identity.id

    case Upstreams.delete_account_for_scope(socket.assigns.current_scope, identity_id, %{
           reason: @reason,
           confirmation_label: delete_params["confirmation_label"]
         }) do
      {status, _result} when status in [:ok, :deleting] ->
        message = if status == :ok, do: gettext("Upstream account deleted"), else: gettext("Upstream account deletion queued")

        socket
        |> put_flash(:info, message)
        |> close_delete()
        |> success_fun.()

      {:error, %{code: code} = reason} when code in [:not_found, :upstream_identity_not_found] ->
        socket
        |> put_flash(:error, error_message(reason))
        |> close_delete()
        |> success_fun.()

      {:error, reason} ->
        put_flash(socket, :error, error_message(reason))
    end
  end

  @spec rename_form(String.t(), map(), atom() | nil) :: Phoenix.HTML.Form.t()
  def rename_form(label, attrs \\ %{}, action \\ nil) do
    data = %{account_label: label}

    {data, %{account_label: :string}}
    |> Ecto.Changeset.cast(attrs, [:account_label])
    |> Ecto.Changeset.validate_required([:account_label])
    |> Map.put(:action, action)
    |> to_form(as: :rename)
  end

  @spec delete_form(map() | nil) :: Phoenix.HTML.Form.t()
  def delete_form(nil),
    do: to_form(%{"id" => "", "confirmation_label" => ""}, as: :upstream_delete)

  def delete_form(%{id: id}),
    do: to_form(%{"id" => id, "confirmation_label" => ""}, as: :upstream_delete)

  defp lifecycle_action(socket, identity_id, action_key, operation, success_message, reload_fun) do
    cond do
      identity_id != socket.assigns.cockpit.identity.id ->
        put_flash(socket, :error, gettext("Upstream account was not found"))

      action_available?(socket, action_key, identity_id) ->
        case operation.(socket.assigns.current_scope, identity_id, %{reason: @reason}) do
          {:ok, _result} ->
            socket
            |> put_flash(:info, success_message)
            |> reload_fun.()

          {:error, reason} ->
            put_flash(socket, :error, error_message(reason))
        end

      true ->
        put_unavailable_action_error(socket, action_key)
    end
  end

  defp enqueue_token_refresh(socket, identity_id, reload_fun) do
    case Upstreams.enqueue_token_refresh_for_scope(socket.assigns.current_scope, identity_id, trigger_kind: @reason) do
      {:ok, %{job: job}} ->
        message =
          if job.conflict?, do: gettext("Token refresh is already queued"), else: gettext("Token refresh queued")

        socket
        |> put_flash(:info, message)
        |> reload_fun.()

      {:error, reason} ->
        put_flash(socket, :error, error_message(reason))
    end
  end

  defp validate_delete_confirmation(%{id: id, label: label}, %{
         "id" => id,
         "confirmation_label" => confirmation
       }) do
    if String.trim(to_string(confirmation)) == label do
      :ok
    else
      {:error, delete_account_error_form(id, "type the account label exactly")}
    end
  end

  defp validate_delete_confirmation(%{id: id}, _params),
    do: {:error, delete_account_error_form(id, "type the account label exactly")}

  defp validate_delete_confirmation(nil, _params),
    do: {:error, delete_account_error_form("", "account was not selected")}

  defp delete_account_error_form(id, message) do
    data = %{id: id || "", confirmation_label: ""}

    {%{}, %{id: :string, confirmation_label: :string}}
    |> Ecto.Changeset.cast(data, [:id, :confirmation_label])
    |> Ecto.Changeset.add_error(:confirmation_label, message)
    |> Map.put(:action, :validate)
    |> to_form(as: :upstream_delete)
  end

  defp action_available?(socket, action_key, identity_id) do
    cockpit = socket.assigns.cockpit

    identity_id == cockpit.identity.id and
      cockpit.actions |> Map.fetch!(action_key) |> Map.fetch!(:available?)
  end

  defp put_unavailable_action_error(socket, action_key) do
    action = Map.fetch!(socket.assigns.cockpit.actions, action_key)
    reason = action.reason || gettext("action is unavailable")
    put_flash(socket, :error, gettext("%{action} is not available: %{reason}", action: action_label(action_key), reason: reason))
  end

  defp action_label(:refresh_token), do: gettext("Refresh token")
  defp action_label(:rename), do: gettext("Rename")
  defp action_label(:pause), do: gettext("Pause")
  defp action_label(:reactivate), do: gettext("Reactivate")
  defp action_label(:delete), do: gettext("Delete")

  defp current_label(socket), do: socket.assigns.cockpit.header.title

  defp error_message(reason), do: WorkflowError.message(reason)
end
