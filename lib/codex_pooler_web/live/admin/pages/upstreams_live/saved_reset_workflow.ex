defmodule CodexPoolerWeb.Admin.UpstreamsLive.SavedResetWorkflow do
  @moduledoc false

  use Gettext, backend: CodexPoolerWeb.Gettext

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3, clear_flash: 2]

  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.SavedResetProjection
  alias CodexPoolerWeb.Admin.UpstreamsLive.WorkflowError

  @spec assign_form(Phoenix.LiveView.Socket.t(), Ecto.Changeset.t()) ::
          Phoenix.LiveView.Socket.t()
  def assign_form(socket, changeset) do
    assign(
      socket,
      :saved_reset_policy_form,
      to_form(changeset, as: :saved_reset_policy)
    )
  end

  @spec save_policy(Phoenix.LiveView.Socket.t(), Ecto.UUID.t(), Ecto.Changeset.t(), keyword()) ::
          Phoenix.LiveView.Socket.t()
  def save_policy(socket, identity_id, changeset, opts) do
    close_fun = Keyword.fetch!(opts, :close)
    reload_fun = Keyword.fetch!(opts, :reload)

    attrs =
      changeset
      |> Ecto.Changeset.apply_changes()
      |> Map.put(:trigger_kind, "admin_upstreams_live")

    case Upstreams.update_saved_reset_policy_for_scope(
           socket.assigns.current_scope,
           identity_id,
           attrs
         ) do
      {:ok, _result} ->
        socket
        |> put_flash(:info, gettext("Saved reset policy updated"))
        |> close_fun.()
        |> reload_fun.()

      {:error, %Ecto.Changeset{} = changeset} ->
        assign_form(socket, changeset)

      {:error, reason} ->
        put_flash(socket, :error, WorkflowError.message(reason))
    end
  end

  @spec redeem(Phoenix.LiveView.Socket.t(), Ecto.UUID.t(), keyword()) ::
          Phoenix.LiveView.Socket.t()
  def redeem(socket, identity_id, opts) do
    reload_fun = Keyword.fetch!(opts, :reload)
    refresh_editing_fun = Keyword.fetch!(opts, :refresh_editing)
    confirmed? = confirmed?(socket, identity_id)
    socket = reload_fun.(socket)

    case visible_account(socket, identity_id) do
      nil ->
        put_flash(socket, :error, gettext("Upstream account was not found"))

      account ->
        cond do
          status_only?(account) ->
            resume_status(socket, account, refresh_editing_fun)

          not confirmed? ->
            put_flash(socket, :error, gettext("Confirm saved reset redemption before continuing"))

          not account.saved_reset_redemption_action.available? ->
            socket
            |> put_flash(:error, account.saved_reset_redemption_action.reason || gettext("Saved reset redemption is not available"))
            |> then(&refresh_editing_fun.(&1, identity_id))

          true ->
            enqueue_redemption(socket, account, reload_fun, refresh_editing_fun)
        end
    end
  end

  @spec maybe_confirm_redemption(Phoenix.LiveView.Socket.t(), Ecto.UUID.t(), map()) ::
          Phoenix.LiveView.Socket.t()
  def maybe_confirm_redemption(socket, identity_id, _params \\ %{}) do
    case socket.assigns.editing_saved_reset_policy do
      %{identity: %UpstreamIdentity{id: ^identity_id}} = account ->
        cond do
          status_only?(account) ->
            socket
            |> clear_flash(:error)
            |> assign(:confirming_saved_reset_redemption, nil)
            |> put_flash(:info, gettext("Review the recorded saved reset status before taking another action"))

          account.saved_reset_redemption_action.available? ->
            assign(
              clear_flash(socket, :error),
              :confirming_saved_reset_redemption,
              redemption_confirmation(account)
            )

          true ->
            put_flash(socket, :error, account.saved_reset_redemption_action.reason)
        end

      _account ->
        put_flash(socket, :error, gettext("Upstream account was not found"))
    end
  end

  defp enqueue_redemption(socket, account, reload_fun, refresh_editing_fun) do
    with {:ok, pool_id} <- redemption_pool_id(account),
         {:ok, %{job: job}} <-
           Upstreams.enqueue_saved_reset_redemption_for_scope(
             socket.assigns.current_scope,
             account.identity.id,
             pool_id,
             trigger_kind: "admin_upstreams_live"
           ) do
      message =
        if job.conflict?,
          do: gettext("Saved reset redemption is already queued"),
          else: gettext("Saved reset redemption queued")

      socket =
        socket
        |> clear_flash(:error)
        |> put_flash(:info, message)
        |> assign(:confirming_saved_reset_redemption, nil)
        |> reload_fun.()

      refresh_editing_fun.(socket, account.identity.id)
    else
      {:error, %{code: :saved_reset_redemption_in_progress}} ->
        socket = reload_fun.(socket)

        case visible_account(socket, account.identity.id) do
          nil -> put_flash(socket, :error, gettext("Upstream account was not found"))
          current -> resume_status(socket, current, refresh_editing_fun)
        end

      {:error, _reason} ->
        socket
        |> put_flash(:error, gettext("Saved reset request was not accepted. Use Refresh to see the current account state."))
        |> reload_fun.()
        |> then(&refresh_editing_fun.(&1, account.identity.id))
    end
  end

  defp status_only?(%{saved_reset_operation: operation}), do: SavedResetProjection.status_hold(operation) != nil

  defp resume_status(socket, account, refresh_editing_fun) do
    socket
    |> clear_flash(:error)
    |> assign(:confirming_saved_reset_redemption, nil)
    |> put_flash(:info, gettext("Review the recorded saved reset status before taking another action"))
    |> then(&refresh_editing_fun.(&1, account.identity.id))
  end

  defp visible_account(socket, identity_id) do
    Enum.find(socket.assigns.upstream_accounts, &(&1.identity.id == identity_id))
  end

  defp confirmed?(socket, identity_id) do
    case socket.assigns.confirming_saved_reset_redemption do
      %{identity_id: ^identity_id} -> true
      _confirmation -> false
    end
  end

  defp redemption_confirmation(account) do
    %{
      identity_id: account.identity.id
    }
  end

  defp redemption_pool_id(%{assignments: [%{pool_id: pool_id} | _assignments]})
       when is_binary(pool_id),
       do: {:ok, pool_id}

  defp redemption_pool_id(_account),
    do: {:error, %{message: gettext("Saved reset redemption requires a Pool assignment")}}
end
