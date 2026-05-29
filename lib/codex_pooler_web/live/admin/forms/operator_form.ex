defmodule CodexPoolerWeb.Admin.OperatorForm do
  @moduledoc false

  import Phoenix.Component, only: [to_form: 2]

  alias CodexPooler.Accounts
  alias CodexPooler.Accounts.User
  alias CodexPooler.Pools.Pool
  alias CodexPoolerWeb.Admin.OperatorComponents

  @operator_statuses ["active", "disabled"]

  @type filter_values :: %{
          required(String.t()) => String.t()
        }
  @type temporary_password_receipt :: %{
          required(:label) => String.t(),
          required(:operator_label) => String.t(),
          required(:operator_email) => String.t(),
          required(:temporary_password) => String.t(),
          required(:emailed?) => boolean(),
          required(:email_error?) => boolean()
        }

  @spec filter(map()) :: filter_values()
  def filter(attrs \\ %{}) do
    attrs = Map.new(attrs)
    status = attrs |> Map.get("status", "all") |> to_string()

    %{
      "query" => attrs |> Map.get("query", "") |> to_string() |> String.trim(),
      "status" => if(status in ["all" | @operator_statuses], do: status, else: "all")
    }
  end

  @spec filter_form(map()) :: Phoenix.HTML.Form.t()
  def filter_form(attrs \\ filter()) do
    attrs
    |> filter()
    |> to_form(as: :operator_filters)
  end

  @spec filter_operators([User.t()], map()) :: [User.t()]
  def filter_operators(operators, filters) do
    Enum.filter(operators, fn operator ->
      operator_status_matches?(operator, filters["status"]) and
        operator_query_matches?(operator, filters["query"])
    end)
  end

  @spec create_form(map()) :: Phoenix.HTML.Form.t()
  def create_form(attrs \\ %{}) do
    defaults = %{
      "email" => "",
      "display_name" => "",
      "password_mode" => "generated",
      "password" => "",
      "password_change_required" => "true",
      "send_email" => "true",
      "role" => "instance_admin",
      "pool_ids" => []
    }

    defaults
    |> Map.merge(attrs)
    |> Accounts.change_new_operator()
    |> to_form(as: :operator)
  end

  @spec create_form_for_changeset(Ecto.Changeset.t()) :: Phoenix.HTML.Form.t()
  def create_form_for_changeset(%Ecto.Changeset{} = changeset),
    do: to_form(changeset, as: :operator)

  @spec edit_form(User.t()) :: Phoenix.HTML.Form.t()
  def edit_form(%User{} = operator) do
    lifecycle = Accounts.operator_lifecycle(operator)

    %{
      "id" => operator.id,
      "email" => operator.email,
      "display_name" => operator.display_name || "",
      "password_change_required" => operator.password_change_required,
      "role" => lifecycle.role,
      "pool_ids" => lifecycle.assigned_pool_ids
    }
    |> to_form(as: :operator_edit)
  end

  @spec edit_form_for_changeset(Ecto.Changeset.t()) :: Phoenix.HTML.Form.t()
  def edit_form_for_changeset(%Ecto.Changeset{} = changeset),
    do: to_form(changeset, as: :operator_edit)

  @spec reset_form(String.t(), atom()) :: Phoenix.HTML.Form.t()
  def reset_form(operator_id \\ "", operation \\ :reset) do
    to_form(
      %{
        "id" => operator_id,
        "operation" => Atom.to_string(operation),
        "password_mode" => "generated",
        "password" => "",
        "password_change_required" => "true",
        "send_email" => "true"
      },
      as: :operator_reset
    )
  end

  @spec reset_form_for_changeset(Ecto.Changeset.t()) :: Phoenix.HTML.Form.t()
  def reset_form_for_changeset(%Ecto.Changeset{} = changeset),
    do: to_form(changeset, as: :operator_reset)

  @spec profile_attrs(map()) :: map()
  def profile_attrs(params) do
    %{
      "email" => params |> Map.get("email", "") |> String.trim(),
      "display_name" => params |> Map.get("display_name", "") |> String.trim()
    }
  end

  @spec edit_attrs(map()) :: map()
  def edit_attrs(params) do
    params
    |> profile_attrs()
    |> Map.put("password_change_required", checkbox_value(params["password_change_required"]))
    |> Map.merge(lifecycle_attrs(params))
  end

  @spec create_attrs(map()) :: map()
  def create_attrs(params) do
    params
    |> password_attrs()
    |> Map.merge(profile_attrs(params))
    |> Map.merge(lifecycle_attrs(params))
  end

  @spec role_options() :: [{String.t(), String.t()}]
  def role_options do
    [
      {"Instance admin", "instance_admin"},
      {"Instance owner", "instance_owner"}
    ]
  end

  @spec selected_pool_ids(Phoenix.HTML.Form.t()) :: MapSet.t(String.t())
  def selected_pool_ids(%Phoenix.HTML.Form{} = form) do
    form[:pool_ids].value
    |> pool_ids_list()
    |> Enum.map(&to_string/1)
    |> MapSet.new()
  end

  @spec pool_option_label(Pool.t()) :: String.t()
  def pool_option_label(%Pool{name: name, slug: slug}), do: "#{name} (#{slug})"

  @spec password_attrs(map()) :: map()
  def password_attrs(params) do
    attrs = %{
      "send_email" => checkbox_value(params["send_email"]),
      "password_change_required" => checkbox_value(params["password_change_required"])
    }

    if params["password_mode"] == "manual" do
      Map.put(attrs, "password", params["password"] || "")
    else
      attrs
    end
  end

  @spec reset_operation(String.t() | nil) :: :reactivate | :reset
  def reset_operation("reactivate"), do: :reactivate
  def reset_operation(_operation), do: :reset

  @spec temporary_password_success(:reactivate | :reset) :: String.t()
  def temporary_password_success(:reactivate), do: "Operator reactivated"
  def temporary_password_success(:reset), do: "Operator password reset"

  @spec temporary_password_receipt(map(), String.t()) :: temporary_password_receipt()
  def temporary_password_receipt(result, label) do
    %{
      label: label,
      operator_label: OperatorComponents.operator_display_name(result.user),
      operator_email: result.user.email,
      temporary_password: result.temporary_password,
      emailed?: Map.get(result, :emailed?, false),
      email_error?: Map.get(result, :email_error?, false)
    }
  end

  @spec active_operator_count([User.t()]) :: non_neg_integer()
  def active_operator_count(operators), do: Enum.count(operators, &(&1.status == "active"))

  defp lifecycle_attrs(params) do
    %{
      "role" => role_value(params["role"]),
      "pool_ids" => pool_ids_value(params)
    }
  end

  defp role_value("instance_owner"), do: "instance_owner"
  defp role_value(_role), do: "instance_admin"

  defp pool_ids_value(params) do
    params
    |> Map.get("pool_ids", [])
    |> pool_ids_list()
  end

  defp pool_ids_list(pool_ids) when is_list(pool_ids) do
    pool_ids
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.map(&to_string/1)
  end

  defp pool_ids_list(pool_id) when is_binary(pool_id), do: [pool_id]
  defp pool_ids_list(_pool_ids), do: []

  defp checkbox_value(value) when value in [true, "true", "1", "on", 1], do: "true"
  defp checkbox_value(_value), do: "false"

  defp operator_status_matches?(_operator, status) when status in [nil, "", "all"], do: true

  defp operator_status_matches?(%User{status: status}, selected_status),
    do: status == selected_status

  defp operator_query_matches?(_operator, query) when query in [nil, ""], do: true

  defp operator_query_matches?(%User{} = operator, query) do
    haystack =
      [operator.email, operator.display_name, operator.status]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> String.downcase()

    String.contains?(haystack, String.downcase(query))
  end
end
