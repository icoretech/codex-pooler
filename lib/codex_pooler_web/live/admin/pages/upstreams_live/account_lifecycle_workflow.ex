defmodule CodexPoolerWeb.Admin.UpstreamsLive.AccountLifecycleWorkflow do
  @moduledoc false

  import Phoenix.Component, only: [assign: 2, assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias CodexPoolerWeb.Admin.UpstreamsLive.WorkflowError

  @reason "admin_upstreams_live"

  @spec pause(Phoenix.LiveView.Socket.t(), Ecto.UUID.t(), (Phoenix.LiveView.Socket.t() ->
                                                             Phoenix.LiveView.Socket.t())) ::
          Phoenix.LiveView.Socket.t()
  def pause(socket, identity_id, reload_fun),
    do:
      lifecycle_action(
        socket,
        identity_id,
        &Upstreams.pause_account_for_scope/3,
        "Upstream account paused",
        reload_fun
      )

  @spec reactivate(Phoenix.LiveView.Socket.t(), Ecto.UUID.t(), (Phoenix.LiveView.Socket.t() ->
                                                                  Phoenix.LiveView.Socket.t())) ::
          Phoenix.LiveView.Socket.t()
  def reactivate(socket, identity_id, reload_fun),
    do:
      lifecycle_action(
        socket,
        identity_id,
        &Upstreams.reactivate_account_for_scope/3,
        "Upstream account reactivated",
        reload_fun
      )

  @spec refresh(Phoenix.LiveView.Socket.t(), Ecto.UUID.t(), (Phoenix.LiveView.Socket.t() ->
                                                               Phoenix.LiveView.Socket.t())) ::
          Phoenix.LiveView.Socket.t()
  def refresh(socket, identity_id, reload_fun) do
    case Upstreams.enqueue_token_refresh_for_scope(socket.assigns.current_scope, identity_id,
           trigger_kind: "admin_upstreams_live"
         ) do
      {:ok, %{job: job}} ->
        message =
          if job.conflict?, do: "Token refresh is already queued", else: "Token refresh queued"

        socket
        |> put_flash(:info, message)
        |> reload_fun.()

      {:error, reason} ->
        put_flash(socket, :error, WorkflowError.message(reason))
    end
  end

  @spec reconcile(Phoenix.LiveView.Socket.t(), Ecto.UUID.t(), (Phoenix.LiveView.Socket.t() ->
                                                                 Phoenix.LiveView.Socket.t())) ::
          Phoenix.LiveView.Socket.t()
  def reconcile(socket, identity_id, reload_fun) do
    case Upstreams.enqueue_quota_reconciliation_for_scope(
           socket.assigns.current_scope,
           identity_id,
           trigger_kind: "admin_upstreams_live"
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
        put_flash(socket, :error, WorkflowError.message(reason))
    end
  end

  @spec open_delete(Phoenix.LiveView.Socket.t(), Ecto.UUID.t()) :: Phoenix.LiveView.Socket.t()
  def open_delete(socket, identity_id) do
    case find_account(socket, identity_id) do
      nil ->
        put_flash(socket, :error, "Upstream account was not found")

      %{identity: %UpstreamIdentity{status: "deleted"}} ->
        put_flash(socket, :error, "Upstream account is already deleted")

      account ->
        assign(socket,
          deleting_account: account,
          delete_account_form: delete_form(account),
          confirming_saved_reset_redemption: nil
        )
    end
  end

  @spec close_delete(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def close_delete(socket),
    do: assign(socket, deleting_account: nil, delete_account_form: delete_form(nil))

  @spec confirm_delete(
          Phoenix.LiveView.Socket.t(),
          map(),
          (Phoenix.LiveView.Socket.t() -> Phoenix.LiveView.Socket.t())
        ) :: Phoenix.LiveView.Socket.t()
  def confirm_delete(socket, delete_params, reload_fun) do
    case validate_delete_confirmation(socket.assigns.deleting_account, delete_params) do
      :ok ->
        identity_id = socket.assigns.deleting_account.identity.id

        lifecycle_action(
          socket,
          identity_id,
          &Upstreams.soft_delete_account_for_scope/3,
          "Upstream account deleted",
          fn socket ->
            socket
            |> close_delete()
            |> reload_fun.()
          end
        )

      {:error, form} ->
        assign(socket, :delete_account_form, form)
    end
  end

  @spec delete_form(map() | nil) :: Phoenix.HTML.Form.t()
  def delete_form(nil),
    do: to_form(%{"id" => "", "confirmation_label" => ""}, as: :upstream_delete)

  def delete_form(%{identity: %UpstreamIdentity{id: id}}),
    do: to_form(%{"id" => id, "confirmation_label" => ""}, as: :upstream_delete)

  @spec rename(
          Phoenix.LiveView.Socket.t(),
          UpstreamIdentity.t(),
          map(),
          (Phoenix.LiveView.Socket.t() -> Phoenix.LiveView.Socket.t()),
          (Phoenix.LiveView.Socket.t() -> Phoenix.LiveView.Socket.t())
        ) ::
          Phoenix.LiveView.Socket.t()
  def rename(socket, %UpstreamIdentity{} = identity, rename_params, close_fun, reload_fun) do
    case Upstreams.rename_account_for_scope(
           socket.assigns.current_scope,
           identity.id,
           rename_params
         ) do
      {:ok, _result} ->
        socket
        |> put_flash(:info, "Upstream account renamed")
        |> close_fun.()
        |> reload_fun.()

      {:error, %Ecto.Changeset{} = changeset} ->
        assign(socket,
          rename_account_form: to_form(changeset, as: :rename),
          renaming_account: socket.assigns.renaming_account
        )

      {:error, reason} ->
        put_flash(socket, :error, WorkflowError.message(reason))
    end
  end

  defp lifecycle_action(socket, identity_id, operation, success_message, reload_fun) do
    case operation.(socket.assigns.current_scope, identity_id, %{reason: @reason}) do
      {:ok, _result} ->
        socket
        |> put_flash(:info, success_message)
        |> reload_fun.()

      {:error, reason} ->
        put_flash(socket, :error, WorkflowError.message(reason))
    end
  end

  defp find_account(socket, identity_id) do
    Enum.find(socket.assigns.upstream_accounts, &(&1.identity.id == identity_id))
  end

  defp validate_delete_confirmation(%{identity: %UpstreamIdentity{id: id}, label: label}, %{
         "id" => id,
         "confirmation_label" => confirmation
       }) do
    if String.trim(to_string(confirmation)) == label do
      :ok
    else
      {:error, delete_account_error_form(id, "type the account label exactly")}
    end
  end

  defp validate_delete_confirmation(%{identity: %UpstreamIdentity{id: id}}, _params),
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
end
