defmodule CodexPoolerWeb.Admin.UpstreamCockpitLive.SavedResetWorkflow do
  @moduledoc false

  use Gettext, backend: CodexPoolerWeb.Gettext

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3, clear_flash: 2]

  alias CodexPooler.Upstreams
  alias CodexPoolerWeb.Admin.UpstreamAccountsReadModel.SavedResetProjection
  alias CodexPoolerWeb.Admin.UpstreamsLive.WorkflowError

  @reason "admin_upstream_cockpit_live"

  @spec policy_form(map()) :: Phoenix.HTML.Form.t()
  def policy_form(policy) when is_map(policy) do
    to_form(
      %{
        "auto_redeem_enabled" => Map.get(policy, :enabled?, false),
        "trigger_mode" => Map.get(policy, :trigger_mode, "blocked"),
        "quota_threshold_percent" => Map.get(policy, :quota_threshold_percent, 95),
        "min_blocked_minutes" => Map.get(policy, :min_blocked_minutes, 60),
        "keep_credits" => Map.get(policy, :keep_credits, 0)
      },
      as: :saved_reset_policy
    )
  end

  @spec save_policy(Phoenix.LiveView.Socket.t(), map(), (Phoenix.LiveView.Socket.t() ->
                                                           Phoenix.LiveView.Socket.t())) ::
          Phoenix.LiveView.Socket.t()
  def save_policy(socket, params, reload_fun) do
    case Upstreams.update_saved_reset_policy_for_scope(
           socket.assigns.current_scope,
           socket.assigns.cockpit.identity.id,
           params
         ) do
      {:ok, _result} ->
        socket
        |> put_flash(:info, gettext("Saved reset policy updated"))
        |> reload_fun.()

      {:error, reason} ->
        put_flash(socket, :error, error_message(reason))
    end
  end

  @spec open_redemption_confirmation(Phoenix.LiveView.Socket.t(), Ecto.UUID.t(), String.t() | nil) ::
          Phoenix.LiveView.Socket.t()
  def open_redemption_confirmation(socket, identity_id, pool_id) do
    cond do
      identity_id != socket.assigns.cockpit.identity.id ->
        put_flash(socket, :error, gettext("Upstream account was not found"))

      confirming_redemption_for?(socket, identity_id) ->
        close_redemption_confirmation(socket)

      status_only?(socket.assigns.cockpit) ->
        resume_status(socket)

      action_available?(socket, :redeem_saved_reset, identity_id) ->
        assign(clear_flash(socket, :error), :confirming_saved_reset_redemption, %{
          identity_id: identity_id,
          pool_id: pool_id,
          label: socket.assigns.cockpit.header.title
        })

      true ->
        put_unavailable_action_error(socket, :redeem_saved_reset)
    end
  end

  defp confirming_redemption_for?(socket, identity_id) do
    match?(
      %{identity_id: ^identity_id},
      socket.assigns.confirming_saved_reset_redemption
    )
  end

  @spec close_redemption_confirmation(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def close_redemption_confirmation(socket) do
    assign(socket, :confirming_saved_reset_redemption, nil)
  end

  @spec redeem(
          Phoenix.LiveView.Socket.t(),
          Ecto.UUID.t(),
          String.t() | nil,
          (Phoenix.LiveView.Socket.t() ->
             Phoenix.LiveView.Socket.t())
        ) ::
          Phoenix.LiveView.Socket.t()
  def redeem(socket, identity_id, pool_id, reload_fun) do
    confirmed? = confirmed?(socket, identity_id, pool_id)
    socket = reload_fun.(socket)

    cond do
      not match?(%{identity: %{id: ^identity_id}}, socket.assigns.cockpit) ->
        put_flash(socket, :error, gettext("Upstream account was not found"))

      status_only?(socket.assigns.cockpit) ->
        resume_status(socket)

      not confirmed? ->
        put_flash(socket, :error, gettext("Confirm saved reset redemption before queueing it"))

      action_available?(socket, :redeem_saved_reset, identity_id) ->
        enqueue_redemption(socket, identity_id, pool_id, reload_fun)

      true ->
        put_unavailable_action_error(socket, :redeem_saved_reset)
    end
  end

  defp enqueue_redemption(socket, identity_id, pool_id, reload_fun) do
    case Upstreams.enqueue_saved_reset_redemption_for_scope(
           socket.assigns.current_scope,
           identity_id,
           pool_id,
           trigger_kind: @reason
         ) do
      {:ok, %{status: :already_queued}} ->
        socket
        |> clear_flash(:error)
        |> close_redemption_confirmation()
        |> put_flash(:info, gettext("Saved reset redemption is already queued"))
        |> reload_fun.()

      {:ok, _result} ->
        socket
        |> clear_flash(:error)
        |> close_redemption_confirmation()
        |> put_flash(:info, gettext("Saved reset redemption queued"))
        |> reload_fun.()

      {:error, %{code: :saved_reset_redemption_in_progress}} ->
        socket |> reload_fun.() |> resume_status()

      {:error, _reason} ->
        socket
        |> put_flash(:error, gettext("Saved reset request was not accepted. Use Refresh to see the current account state."))
        |> reload_fun.()
    end
  end

  defp status_only?(%{saved_reset_operation: operation}), do: SavedResetProjection.status_hold(operation) != nil

  defp resume_status(socket) do
    socket
    |> clear_flash(:error)
    |> close_redemption_confirmation()
    |> put_flash(:info, gettext("Review the recorded saved reset status before taking another action"))
  end

  defp confirmed?(socket, identity_id, pool_id) do
    case socket.assigns.confirming_saved_reset_redemption do
      %{identity_id: ^identity_id, pool_id: ^pool_id} -> true
      _confirmation -> false
    end
  end

  defp action_available?(socket, action_key, identity_id) do
    cockpit = socket.assigns.cockpit

    identity_id == cockpit.identity.id and
      cockpit.actions |> Map.fetch!(action_key) |> Map.fetch!(:available?)
  end

  defp put_unavailable_action_error(socket, action_key) do
    action = Map.fetch!(socket.assigns.cockpit.actions, action_key)
    reason = action.reason || gettext("action is unavailable")
    put_flash(socket, :error, gettext("Redeem saved reset is not available: %{reason}", reason: reason))
  end

  defp error_message(reason), do: WorkflowError.message(reason)
end
