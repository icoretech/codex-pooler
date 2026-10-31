defmodule CodexPoolerWeb.Admin.UpstreamsLive.InviteWorkflow do
  @moduledoc false

  use Gettext, backend: CodexPoolerWeb.Gettext

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias CodexPooler.Access
  alias CodexPooler.Accounts
  alias CodexPoolerWeb.Admin.PoolInviteForm

  @type socket :: Phoenix.LiveView.Socket.t()

  @spec initial_assigns(String.t() | nil) :: map()
  def initial_assigns(current_ui_locale) do
    %{
      creating_invite: false,
      invite_form: PoolInviteForm.empty_form(current_ui_locale),
      invite_form_valid?: false,
      invite_locale_explicit?: false,
      invite_locale_source: :inviter,
      last_invite: nil
    }
  end

  @spec open(socket()) :: socket()
  def open(socket) do
    assign(socket,
      creating_invite: true,
      invite_form: PoolInviteForm.empty_form(socket.assigns.locale.tag),
      invite_form_valid?: false,
      invite_locale_explicit?: false,
      invite_locale_source: :inviter,
      last_invite: nil
    )
  end

  @spec close(socket()) :: socket()
  def close(socket), do: assign(socket, initial_assigns(socket.assigns.locale.tag))

  @spec validate(socket(), map(), [String.t()] | nil) :: socket()
  def validate(socket, invite_params, target) do
    explicit? = socket.assigns.invite_locale_explicit? or target == ["invite", "locale"]
    {invite_params, default} = PoolInviteForm.derive_locale(invite_params, Accounts.get_user_by_email(invite_params["invited_email"]), socket.assigns.locale.tag, explicit?)
    pool = selected_pool(socket.assigns.pools, invite_params["pool_id"])
    changeset = PoolInviteForm.changeset(invite_params, pool)

    socket
    |> assign(:invite_form, PoolInviteForm.form_for_changeset(changeset))
    |> assign(:invite_form_valid?, changeset.valid?)
    |> assign(:invite_locale_explicit?, explicit?)
    |> assign(:invite_locale_source, default.source)
    |> assign(:last_invite, nil)
  end

  @spec create(socket(), map(), (String.t() -> String.t())) :: socket()
  def create(socket, invite_params, invite_url_fun) do
    explicit? = socket.assigns.invite_locale_explicit? or Map.has_key?(invite_params, "locale")
    {invite_params, default} = PoolInviteForm.derive_locale(invite_params, Accounts.get_user_by_email(invite_params["invited_email"]), socket.assigns.locale.tag, explicit?)
    socket = assign(socket, invite_locale_explicit?: explicit?, invite_locale_source: default.source)
    pool = selected_pool(socket.assigns.pools, invite_params["pool_id"])
    send_email? = PoolInviteForm.send_email?(invite_params, socket.assigns.mailer_configured?)
    changeset = PoolInviteForm.changeset(invite_params, pool)

    if changeset.valid? do
      create_valid_invite(socket, pool, invite_params, send_email?, invite_url_fun)
    else
      message =
        if pool,
          do: gettext("Pool invite could not be created"),
          else: gettext("Select an active Pool before creating an invite")

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
        |> assign(:invite_form, PoolInviteForm.empty_form(socket.assigns.locale.tag))
        |> assign(:invite_form_valid?, false)
        |> assign(:invite_locale_explicit?, false)
        |> assign(:invite_locale_source, :inviter)
        |> assign(:creating_invite, true)
        |> assign(:last_invite, PoolInviteForm.receipt(pool, invite, invite_url, result))

      nil ->
        socket
        |> put_flash(:error, gettext("Select an active Pool before creating an invite"))
        |> assign(:invite_form, PoolInviteForm.form_for_params(invite_params))
        |> assign(:invite_form_valid?, false)
        |> assign(:creating_invite, true)
        |> assign(:last_invite, nil)

      {:error, %Ecto.Changeset{} = changeset} ->
        socket
        |> put_flash(:error, gettext("Pool invite could not be created"))
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

  defp error_message(%{message: "An active invite already exists for this Codex account and Pool."}), do: gettext("An active invite already exists for this Codex account and Pool.")
  defp error_message(%{message: "pool was not found"}), do: gettext("pool was not found")
  defp error_message(%{message: "user scope is required"}), do: gettext("user scope is required")
  defp error_message(%{message: "only node admins can perform this capability"}), do: gettext("only node admins can perform this capability")
  defp error_message(%{message: "the actor role cannot perform this capability in the requested scope"}), do: gettext("the actor role cannot perform this capability in the requested scope")
  defp error_message(%{message: "this capability requires a Pool scope"}), do: gettext("this capability requires a Pool scope")
  defp error_message(%{message: "only the instance owner can perform this global capability"}), do: gettext("only the instance owner can perform this global capability")
  defp error_message(%{message: "assigned-pool admin capabilities require a Pool scope"}), do: gettext("assigned-pool admin capabilities require a Pool scope")
  defp error_message(%{message: "the assigned-pool admin cannot access the requested Pool"}), do: gettext("the assigned-pool admin cannot access the requested Pool")
  defp error_message(_reason), do: gettext("Pool invite could not be created")
end
