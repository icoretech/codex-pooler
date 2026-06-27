defmodule CodexPoolerWeb.Admin.UpstreamsLive.AccountLifecycleWorkflow do
  @moduledoc false

  import Phoenix.Component, only: [assign: 2, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias CodexPooler.Upstreams
  alias CodexPooler.Upstreams.Schemas.UpstreamIdentity
  alias CodexPoolerWeb.Admin.UpstreamsLive.WorkflowError

  @spec pause(Phoenix.LiveView.Socket.t(), Ecto.UUID.t(), (Phoenix.LiveView.Socket.t() ->
                                                             Phoenix.LiveView.Socket.t())) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
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
          {:noreply, Phoenix.LiveView.Socket.t()}
  def reactivate(socket, identity_id, reload_fun),
    do:
      lifecycle_action(
        socket,
        identity_id,
        &Upstreams.reactivate_account_for_scope/3,
        "Upstream account reactivated",
        reload_fun
      )

  @spec delete(Phoenix.LiveView.Socket.t(), Ecto.UUID.t(), (Phoenix.LiveView.Socket.t() ->
                                                              Phoenix.LiveView.Socket.t())) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def delete(socket, identity_id, reload_fun),
    do:
      lifecycle_action(
        socket,
        identity_id,
        &Upstreams.soft_delete_account_for_scope/3,
        "Upstream account deleted",
        reload_fun
      )

  @spec refresh(Phoenix.LiveView.Socket.t(), Ecto.UUID.t(), (Phoenix.LiveView.Socket.t() ->
                                                               Phoenix.LiveView.Socket.t())) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def refresh(socket, identity_id, reload_fun) do
    case Upstreams.enqueue_token_refresh_for_scope(socket.assigns.current_scope, identity_id,
           trigger_kind: "admin_upstreams_live"
         ) do
      {:ok, %{job: job}} ->
        message =
          if job.conflict?, do: "Token refresh is already queued", else: "Token refresh queued"

        {:noreply,
         socket
         |> put_flash(:info, message)
         |> reload_fun.()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, WorkflowError.message(reason))}
    end
  end

  @spec rename(
          Phoenix.LiveView.Socket.t(),
          UpstreamIdentity.t(),
          map(),
          (Phoenix.LiveView.Socket.t() -> Phoenix.LiveView.Socket.t()),
          (Phoenix.LiveView.Socket.t() -> Phoenix.LiveView.Socket.t())
        ) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def rename(socket, %UpstreamIdentity{} = identity, rename_params, close_fun, reload_fun) do
    case Upstreams.rename_account_for_scope(
           socket.assigns.current_scope,
           identity.id,
           rename_params
         ) do
      {:ok, _result} ->
        {:noreply,
         socket
         |> put_flash(:info, "Upstream account renamed")
         |> close_fun.()
         |> reload_fun.()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket,
           rename_account_form: to_form(changeset, as: :rename),
           renaming_account: socket.assigns.renaming_account
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, WorkflowError.message(reason))}
    end
  end

  defp lifecycle_action(socket, identity_id, operation, success_message, reload_fun) do
    case operation.(socket.assigns.current_scope, identity_id, %{reason: "admin_upstreams_live"}) do
      {:ok, _result} ->
        {:noreply,
         socket
         |> put_flash(:info, success_message)
         |> reload_fun.()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, WorkflowError.message(reason))}
    end
  end
end
