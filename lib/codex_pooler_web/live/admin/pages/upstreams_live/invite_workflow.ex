defmodule CodexPoolerWeb.Admin.UpstreamsLive.InviteWorkflow do
  @moduledoc false

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias CodexPooler.Access
  alias CodexPoolerWeb.Admin.PoolInviteForm

  @type socket :: Phoenix.LiveView.Socket.t()

  @spec initial_assigns() :: map()
  def initial_assigns do
    %{
      creating_invite: false,
      invite_form: PoolInviteForm.empty_form(),
      invite_form_valid?: false,
      last_invite: nil
    }
  end

  @spec open(socket()) :: socket()
  def open(socket) do
    assign(socket,
      creating_invite: true,
      invite_form: PoolInviteForm.empty_form(),
      invite_form_valid?: false,
      last_invite: nil
    )
  end

  @spec close(socket()) :: socket()
  def close(socket), do: assign(socket, initial_assigns())

  @spec validate(socket(), map()) :: socket()
  def validate(socket, invite_params) do
    pool = selected_pool(socket.assigns.pools, invite_params["pool_id"])
    changeset = PoolInviteForm.changeset(invite_params, pool)

    socket
    |> assign(:invite_form, PoolInviteForm.form_for_changeset(changeset))
    |> assign(:invite_form_valid?, changeset.valid?)
    |> assign(:last_invite, nil)
  end

  @spec create(socket(), map(), (String.t() -> String.t())) :: socket()
  def create(socket, invite_params, invite_url_fun) do
    pool = selected_pool(socket.assigns.pools, invite_params["pool_id"])
    send_email? = PoolInviteForm.send_email?(invite_params, socket.assigns.mailer_configured?)
    changeset = PoolInviteForm.changeset(invite_params, pool)

    if changeset.valid? do
      create_valid_invite(socket, pool, invite_params, send_email?, invite_url_fun)
    else
      message =
        if pool,
          do: "Pool invite could not be created",
          else: "Select an active Pool before creating an invite"

      socket
      |> put_flash(:error, message)
      |> assign(:invite_form, PoolInviteForm.form_for_changeset(changeset))
      |> assign(:invite_form_valid?, false)
      |> assign(:creating_invite, true)
      |> assign(:last_invite, nil)
    end
  end

  defp create_valid_invite(socket, pool, invite_params, send_email?, invite_url_fun) do
    case pool && Access.create_invite(socket.assigns.current_scope, pool, invite_params) do
      {:ok, %{invite: invite, token: token} = result} ->
        invite_url = invite_url_fun.(token)

        result =
          Access.maybe_deliver_pool_invite_email(
            result,
            send_email?,
            invite_url,
            pool,
            socket.assigns.current_scope
          )

        socket
        |> put_flash(:info, PoolInviteForm.created_flash(result))
        |> assign(:invite_form, PoolInviteForm.empty_form())
        |> assign(:invite_form_valid?, false)
        |> assign(:creating_invite, true)
        |> assign(:last_invite, PoolInviteForm.receipt(pool, invite, invite_url, result))

      nil ->
        socket
        |> put_flash(:error, "Select an active Pool before creating an invite")
        |> assign(:invite_form, PoolInviteForm.form_for_params(invite_params))
        |> assign(:invite_form_valid?, false)
        |> assign(:creating_invite, true)
        |> assign(:last_invite, nil)

      {:error, %Ecto.Changeset{} = changeset} ->
        socket
        |> put_flash(:error, "Pool invite could not be created")
        |> assign(:invite_form, PoolInviteForm.form_for_changeset(changeset))
        |> assign(:invite_form_valid?, false)
        |> assign(:creating_invite, true)
        |> assign(:last_invite, nil)

      {:error, reason} ->
        socket
        |> put_flash(:error, error_message(reason))
        |> assign(:invite_form, PoolInviteForm.form_for_params(invite_params))
        |> assign(:invite_form_valid?, false)
        |> assign(:creating_invite, true)
        |> assign(:last_invite, nil)
    end
  end

  defp selected_pool(pools, pool_id) when is_binary(pool_id),
    do: Enum.find(pools, &(&1.id == pool_id))

  defp selected_pool(_pools, _pool_id), do: nil

  defp error_message(%{message: message}) when is_binary(message), do: message
  defp error_message(_reason), do: "Pool invite could not be created"
end
