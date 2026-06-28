defmodule CodexPoolerWeb.Admin.UpstreamCockpitLive.SavedResetWorkflow do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias CodexPooler.Upstreams

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
        |> put_flash(:info, "Saved reset policy updated")
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
        put_flash(socket, :error, "Upstream account was not found")

      action_available?(socket, :redeem_saved_reset, identity_id) ->
        assign(socket, :confirming_saved_reset_redemption, %{
          identity_id: identity_id,
          pool_id: pool_id,
          label: socket.assigns.cockpit.header.title
        })

      true ->
        put_unavailable_action_error(socket, :redeem_saved_reset)
    end
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
    cond do
      identity_id != socket.assigns.cockpit.identity.id ->
        put_flash(socket, :error, "Upstream account was not found")

      not confirmed?(socket, identity_id, pool_id) ->
        put_flash(socket, :error, "Confirm saved reset redemption before queueing it")

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
        |> close_redemption_confirmation()
        |> put_flash(:info, "Saved reset redemption is already queued")
        |> reload_fun.()

      {:ok, _result} ->
        socket
        |> close_redemption_confirmation()
        |> put_flash(:info, "Saved reset redemption queued")
        |> reload_fun.()

      {:error, reason} ->
        put_flash(socket, :error, error_message(reason))
    end
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
    reason = action.reason || "action is unavailable"
    put_flash(socket, :error, "Redeem saved reset is not available: #{reason}")
  end

  defp error_message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field} #{&1}") end)
    |> Enum.join(", ")
  end

  defp error_message(%{message: message}) when is_binary(message), do: message
  defp error_message(_reason), do: "Operation failed"
end
