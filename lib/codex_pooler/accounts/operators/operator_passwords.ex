defmodule CodexPooler.Accounts.OperatorPasswords do
  @moduledoc false

  @temporary_password_bytes 24

  @spec generate_temporary_password() :: binary()
  def generate_temporary_password do
    @temporary_password_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  @spec temporary_password_from_attrs(term()) :: binary()
  def temporary_password_from_attrs(attrs) when is_map(attrs) do
    case Map.get(attrs, "temporary_password") || Map.get(attrs, :temporary_password) ||
           Map.get(attrs, "new_password") || Map.get(attrs, :new_password) ||
           Map.get(attrs, "password") || Map.get(attrs, :password) do
      value when is_binary(value) and value != "" -> value
      _value -> generate_temporary_password()
    end
  end

  def temporary_password_from_attrs(_attrs), do: generate_temporary_password()

  @spec temporary_password_changeset_attrs(term(), binary()) :: map()
  def temporary_password_changeset_attrs(attrs, temporary_password) do
    %{"password" => temporary_password}
    |> maybe_put_password_change_required(attrs)
  end

  @spec send_email?(term()) :: boolean()
  def send_email?(attrs) when is_map(attrs) do
    case Map.get(attrs, "send_email") || Map.get(attrs, :send_email) do
      true -> true
      "true" -> true
      "1" -> true
      1 -> true
      _value -> false
    end
  end

  def send_email?(_attrs), do: false

  defp maybe_put_password_change_required(password_attrs, attrs) when is_map(attrs) do
    cond do
      Map.has_key?(attrs, "password_change_required") ->
        Map.put(
          password_attrs,
          "password_change_required",
          Map.fetch!(attrs, "password_change_required")
        )

      Map.has_key?(attrs, :password_change_required) ->
        Map.put(
          password_attrs,
          :password_change_required,
          Map.fetch!(attrs, :password_change_required)
        )

      true ->
        password_attrs
    end
  end

  defp maybe_put_password_change_required(password_attrs, _attrs), do: password_attrs
end
