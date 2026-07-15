defmodule CodexPoolerWeb.Admin.UpstreamCockpitLive.AccountLifecycleWorkflow do
  @moduledoc false

  import Phoenix.Component, only: [assign: 2, assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias CodexPooler.Upstreams

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
        |> put_flash(:info, "Upstream account renamed")
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
      "Upstream account paused",
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
      "Upstream account reactivated",
      reload_fun
    )
  end

  @spec refresh(Phoenix.LiveView.Socket.t(), Ecto.UUID.t(), (Phoenix.LiveView.Socket.t() ->
                                                               Phoenix.LiveView.Socket.t())) ::
          Phoenix.LiveView.Socket.t()
  def refresh(socket, identity_id, reload_fun) do
    cond do
      identity_id != socket.assigns.cockpit.identity.id ->
        put_flash(socket, :error, "Upstream account was not found")

      action_available?(socket, :refresh_token, identity_id) ->
        enqueue_token_refresh(socket, identity_id, reload_fun)

      true ->
        put_unavailable_action_error(socket, :refresh_token)
    end
  end

  @spec reconcile(Phoenix.LiveView.Socket.t(), Ecto.UUID.t(), (Phoenix.LiveView.Socket.t() ->
                                                                 Phoenix.LiveView.Socket.t())) ::
          Phoenix.LiveView.Socket.t()
  def reconcile(socket, identity_id, reload_fun) do
    cond do
      identity_id != socket.assigns.cockpit.identity.id ->
        put_flash(socket, :error, "Upstream account was not found")

      action_available?(socket, :reconcile_quota, identity_id) ->
        enqueue_quota_reconciliation(socket, identity_id, reload_fun)

      true ->
        put_unavailable_action_error(socket, :reconcile_quota)
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
        identity_id = socket.assigns.cockpit.identity.id

        case Upstreams.soft_delete_account_for_scope(socket.assigns.current_scope, identity_id, %{
               reason: @reason
             }) do
          {:ok, _result} ->
            socket
            |> put_flash(:info, "Upstream account deleted")
            |> close_delete()
            |> success_fun.()

          {:error, reason} ->
            put_flash(socket, :error, error_message(reason))
        end

      {:error, form} ->
        assign(socket, :delete_account_form, form)
    end
  end

  @spec rename_form(String.t(), map(), atom() | nil) :: Phoenix.HTML.Form.t()
  def rename_form(label, attrs \\ %{}, action \\ nil) do
    data = %{account_label: label}

    {%{}, %{account_label: :string}}
    |> Ecto.Changeset.cast(Map.merge(data, attrs), [:account_label])
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
        put_flash(socket, :error, "Upstream account was not found")

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
    case Upstreams.enqueue_token_refresh_for_scope(socket.assigns.current_scope, identity_id,
           trigger_kind: @reason
         ) do
      {:ok, %{job: job}} ->
        message =
          if job.conflict?, do: "Token refresh is already queued", else: "Token refresh queued"

        socket
        |> put_flash(:info, message)
        |> reload_fun.()

      {:error, reason} ->
        put_flash(socket, :error, error_message(reason))
    end
  end

  defp enqueue_quota_reconciliation(socket, identity_id, reload_fun) do
    case Upstreams.enqueue_quota_reconciliation_for_scope(
           socket.assigns.current_scope,
           identity_id,
           trigger_kind: @reason
         ) do
      {:ok, %{status: status}} ->
        message =
          if status == :already_queued,
            do: "Quota refresh is already queued",
            else:
              "Quota refresh queued; reset changes, if detected, are confirmed automatically after about 3 minutes"

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
    reason = action.reason || "action is unavailable"
    put_flash(socket, :error, "#{action_label(action_key)} is not available: #{reason}")
  end

  defp action_label(:refresh_token), do: "Refresh token"
  defp action_label(:reconcile_quota), do: "Refresh quota"

  defp action_label(action_key),
    do: action_key |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp current_label(socket), do: socket.assigns.cockpit.header.title

  defp error_message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field} #{&1}") end)
    |> Enum.join(", ")
  end

  defp error_message(%{message: message}) when is_binary(message), do: message
  defp error_message(_reason), do: "Operation failed"
end
