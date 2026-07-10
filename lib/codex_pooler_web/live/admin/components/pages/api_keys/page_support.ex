defmodule CodexPoolerWeb.Admin.ApiKeyPageSupport do
  @moduledoc false

  alias CodexPooler.Access.APIKey
  alias Phoenix.Component

  def blank_to_nil(nil), do: nil

  def blank_to_nil(value) do
    value = String.trim(to_string(value))
    if value == "", do: nil, else: value
  end

  @spec api_key_delete_form(%{required(:id) => Ecto.UUID.t()}) :: Phoenix.HTML.Form.t()
  def api_key_delete_form(%{id: api_key_id}) do
    %{"id" => api_key_id, "confirmation_prefix" => ""}
    |> Component.to_form(as: :api_key_delete)
  end

  def created_secret(%APIKey{} = api_key, raw_key) do
    %{api_key_id: api_key.id, key_prefix: api_key.key_prefix, raw_key: raw_key}
  end

  def maybe_clear_secret(socket, opts) do
    if Keyword.get(opts, :clear_secret, false) do
      Component.assign(socket, :created_secret, nil)
    else
      socket
    end
  end

  def error_message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field} #{&1}") end)
    |> Enum.join(", ")
  end

  def error_message(%{message: message}) when is_binary(message), do: message
  def error_message(_reason), do: "Operation failed"
end
