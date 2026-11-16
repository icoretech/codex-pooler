defmodule CodexPoolerWeb.Admin.UsageCapPolicyForm do
  @moduledoc false

  use Gettext, backend: CodexPoolerWeb.Gettext

  import Phoenix.Component, only: [to_form: 2]

  alias Ecto.Changeset

  @types %{usage_cap_percent: :integer}
  @param_keys ["usage_cap_percent"]

  @type attrs :: %{required(:usage_cap_percent) => 1..99 | nil}
  @type policy :: %{required(:usage_cap_percent) => 1..99 | nil}
  @type params :: %{optional(String.t() | atom()) => term()}
  @type action :: :validate | :submit | nil

  @spec form(policy(), params(), action()) :: Phoenix.HTML.Form.t()
  def form(policy, params \\ %{}, action \\ nil)

  def form(%{usage_cap_percent: cap}, params, action) do
    changeset =
      if params == %{} and is_nil(action) do
        Changeset.change({%{usage_cap_percent: cap}, @types})
      else
        changeset(params)
      end

    changeset
    |> Map.put(:action, action)
    |> form_for_changeset()
  end

  @spec form_for_changeset(Changeset.t()) :: Phoenix.HTML.Form.t()
  def form_for_changeset(%Changeset{} = changeset) do
    to_form(changeset, as: :usage_cap_policy)
  end

  @spec changeset(term()) :: Changeset.t()
  def changeset(params) when is_map(params) and not is_struct(params) do
    {%{usage_cap_percent: nil}, @types}
    |> Changeset.cast(Map.take(params, @param_keys), [:usage_cap_percent])
    |> Changeset.validate_number(:usage_cap_percent, greater_than_or_equal_to: 1, less_than_or_equal_to: 99)
    |> validate_param_keys(params)
  end

  def changeset(_params) do
    {%{usage_cap_percent: nil}, @types}
    |> Changeset.change()
    |> Changeset.add_error(:usage_cap_percent, dgettext("errors", "must be a policy form"))
  end

  @spec parse(term()) :: {:ok, attrs()} | {:error, Changeset.t()}
  def parse(params) do
    params
    |> changeset()
    |> Changeset.apply_action(:submit)
  end

  @spec validate_param_keys(Changeset.t(), params()) :: Changeset.t()
  defp validate_param_keys(changeset, params) do
    if Enum.all?(Map.keys(params), &(&1 in @param_keys)) do
      changeset
    else
      Changeset.add_error(changeset, :usage_cap_percent, dgettext("errors", "contains unexpected fields"))
    end
  end
end
