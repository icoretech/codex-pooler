defmodule CodexPoolerWeb.Admin.OperatorComponents.Identity do
  @moduledoc false

  use CodexPoolerWeb, :html

  alias CodexPoolerWeb.Admin.AvatarComponents

  attr :id, :string, required: true
  attr :operator, :map, required: true
  attr :status, :string, default: "active"
  attr :class, :any, default: nil

  @spec operator_avatar(map()) :: Phoenix.LiveView.Rendered.t()
  def operator_avatar(assigns) do
    ~H"""
    <div
      id={@id}
      class={[operator_avatar_class(@status), @class]}
      aria-label={gettext("Operator %{operator}", operator: operator_display_name(@operator))}
      title={operator_display_name(@operator)}
    >
      <div class="size-10 rounded-full ring-1 ring-base-300">
        <img
          src={AvatarComponents.gravatar_url(@operator.email, size: 80)}
          alt=""
          loading="lazy"
          referrerpolicy="no-referrer"
          aria-hidden="true"
        />
      </div>
    </div>
    """
  end

  @spec operator_display_name(map()) :: String.t()
  def operator_display_name(%{display_name: display_name, email: email}) do
    case display_name && String.trim(display_name) do
      value when is_binary(value) and value != "" -> value
      _value -> email
    end
  end

  defp operator_avatar_class("active"), do: "avatar avatar-online"
  defp operator_avatar_class(_status), do: "avatar avatar-offline"
end
