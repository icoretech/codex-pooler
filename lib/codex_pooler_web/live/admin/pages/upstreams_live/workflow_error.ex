defmodule CodexPoolerWeb.Admin.UpstreamsLive.WorkflowError do
  @moduledoc false

  @spec message(term()) :: String.t()
  def message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field} #{&1}") end)
    |> Enum.join(", ")
  end

  def message(%{message: message}) when is_binary(message), do: message
  def message(_reason), do: "Operation failed"
end
