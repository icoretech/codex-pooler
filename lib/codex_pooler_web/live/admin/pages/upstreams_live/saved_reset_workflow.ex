defmodule CodexPoolerWeb.Admin.UpstreamsLive.SavedResetWorkflow do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
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
          {:noreply, Phoenix.LiveView.Socket.t()}
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
        {:noreply,
         socket
         |> put_flash(:info, "Saved reset policy updated")
         |> close_fun.()
         |> reload_fun.()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, WorkflowError.message(reason))}
    end
  end

  @spec redeem(Phoenix.LiveView.Socket.t(), map(), keyword()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def redeem(socket, account, opts) do
    reload_fun = Keyword.fetch!(opts, :reload)
    refresh_editing_fun = Keyword.fetch!(opts, :refresh_editing)

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
          do: "Saved reset redemption is already queued",
          else: "Saved reset redemption queued"

      socket =
        socket
        |> put_flash(:info, message)
        |> assign(:confirming_saved_reset_redemption, nil)
        |> reload_fun.()

      {:noreply, refresh_editing_fun.(socket, account.identity.id)}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, WorkflowError.message(reason))}
    end
  end

  @spec maybe_confirm_redemption(Phoenix.LiveView.Socket.t(), Ecto.UUID.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def maybe_confirm_redemption(socket, identity_id) do
    case socket.assigns.editing_saved_reset_policy do
      %{identity: %UpstreamIdentity{id: ^identity_id}} = account ->
        if account.saved_reset_redemption_action.available? do
          {:noreply, assign(socket, :confirming_saved_reset_redemption, account)}
        else
          {:noreply, put_flash(socket, :error, account.saved_reset_redemption_action.reason)}
        end

      _account ->
        {:noreply, put_flash(socket, :error, "Upstream account was not found")}
    end
  end

  @spec confirmed_account(Phoenix.LiveView.Socket.t(), Ecto.UUID.t()) ::
          {:ok, map()} | {:error, String.t()}
  def confirmed_account(socket, identity_id) do
    case socket.assigns.confirming_saved_reset_redemption do
      %{identity: %UpstreamIdentity{id: ^identity_id}} = account ->
        if account.saved_reset_redemption_action.available? do
          {:ok, account}
        else
          {:error, account.saved_reset_redemption_action.reason}
        end

      _account ->
        {:error, "Confirm saved reset redemption before continuing"}
    end
  end

  defp redemption_pool_id(%{assignments: [%{pool_id: pool_id} | _assignments]})
       when is_binary(pool_id),
       do: {:ok, pool_id}

  defp redemption_pool_id(_account),
    do: {:error, %{message: "Saved reset redemption requires a Pool assignment"}}
end
