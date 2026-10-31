defmodule CodexPoolerWeb.Admin.PoolInviteForm do
  @moduledoc false

  use Gettext, backend: CodexPoolerWeb.Gettext

  import Phoenix.Component, only: [to_form: 2]

  alias CodexPooler.Accounts.User
  alias CodexPooler.SupportedLocales
  alias CodexPoolerWeb.Locale

  @type locale_source :: :recipient | :inviter | :default | :explicit | :stored

  @type receipt :: %{
          required(:pool_name) => String.t(),
          required(:invited_email) => String.t() | nil,
          required(:locale) => String.t(),
          required(:url) => String.t(),
          required(:emailed?) => boolean(),
          required(:email_error?) => boolean()
        }

  @spec empty_form(String.t() | nil) :: Phoenix.HTML.Form.t()
  def empty_form(current_ui_locale \\ nil) do
    to_form(%{"pool_id" => "", "invited_email" => "", "send_email" => "false", "locale" => supported_tag(current_ui_locale) || "en"}, as: :invite)
  end

  @spec form_for_params(map()) :: Phoenix.HTML.Form.t()
  def form_for_params(params) when is_map(params), do: to_form(params, as: :invite)

  @spec form_for_changeset(Ecto.Changeset.t()) :: Phoenix.HTML.Form.t()
  def form_for_changeset(%Ecto.Changeset{} = changeset), do: to_form(changeset, as: :invite)

  @spec changeset(map(), term()) :: Ecto.Changeset.t()
  def changeset(params, pool) when is_map(params) do
    data = %{
      pool_id: params["pool_id"],
      invited_email: params["invited_email"],
      send_email: params["send_email"],
      locale: params["locale"]
    }

    {%{}, %{pool_id: :string, invited_email: :string, send_email: :boolean, locale: :string}}
    |> Ecto.Changeset.cast(data, Map.keys(data))
    |> Ecto.Changeset.validate_required([:pool_id, :invited_email])
    |> validate_selected_pool(pool)
    |> Ecto.Changeset.validate_format(:invited_email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, message: "must be a valid email")
    |> Ecto.Changeset.validate_inclusion(:locale, SupportedLocales.tags())
    |> Map.put(:action, :validate)
  end

  @spec invite_locale(String.t() | nil, User.t() | nil, String.t() | nil) :: String.t()
  def invite_locale(invited_email, recipient, current_ui_locale) do
    {_params, source} = derive_locale(%{"invited_email" => invited_email}, recipient, current_ui_locale, false)
    source.locale
  end

  @spec derive_locale(map(), User.t() | nil, String.t() | nil, boolean()) ::
          {map(), %{locale: String.t() | nil, source: locale_source()}}
  def derive_locale(params, _recipient, _current_ui_locale, true) do
    {params, %{locale: params["locale"], source: :explicit}}
  end

  def derive_locale(params, recipient, current_ui_locale, false) do
    recipient_locale = matching_recipient_locale(recipient, params["invited_email"])
    default = locale_default(recipient_locale, current_ui_locale)
    {Map.put(params, "locale", default.locale), default}
  end

  @spec locale_default(String.t() | nil, String.t() | nil) :: %{locale: String.t(), source: locale_source()}
  def locale_default(recipient_locale, current_ui_locale) do
    cond do
      tag = supported_tag(recipient_locale) -> %{locale: tag, source: :recipient}
      tag = supported_tag(current_ui_locale) -> %{locale: tag, source: :inviter}
      true -> %{locale: "en", source: :default}
    end
  end

  @spec locale_options() :: [{String.t(), String.t()}]
  def locale_options, do: Enum.map(Locale.locales(), &{&1.label, &1.tag})

  @spec locale_label(String.t() | nil) :: String.t()
  def locale_label(tag), do: (Locale.fetch(supported_tag(tag)) || Locale.default()).label

  @spec locale_hint(locale_source()) :: String.t()
  def locale_hint(:recipient), do: gettext("Default: recipient account language")
  def locale_hint(:inviter), do: gettext("Default: your current interface language")
  def locale_hint(:default), do: gettext("Default: English")
  def locale_hint(:explicit), do: gettext("Your selected email language is kept when the recipient changes.")
  def locale_hint(:stored), do: gettext("Stored invitation email language")

  @spec reinvite_params(String.t(), [term()]) :: map()
  def reinvite_params(pool_id, candidates \\ []) when is_binary(pool_id) do
    pool_id = String.trim(pool_id)
    params = %{"create" => "1", "reinvite" => "1", "pool_id" => pool_id}

    case reinvite_email(candidates, pool_id) do
      nil -> params
      invited_email -> Map.put(params, "invited_email", invited_email)
    end
  end

  @spec send_email?(map(), boolean()) :: boolean()
  def send_email?(params, true), do: params["send_email"] in ["true", true]
  def send_email?(_params, false), do: false

  @spec created_flash(map()) :: String.t()
  def created_flash(%{emailed?: true}), do: gettext("Pool invite created and emailed")
  def created_flash(_result), do: gettext("Pool invite created")

  @spec receipt(term(), map(), String.t(), map()) :: receipt()
  def receipt(pool, invite, invite_url, result) do
    %{
      pool_name: pool.name,
      invited_email: invite.invited_email,
      locale: supported_tag(invite.locale) || "en",
      url: invite_url,
      emailed?: result.emailed?,
      email_error?: result.email_error?
    }
  end

  defp validate_selected_pool(changeset, nil),
    do: Ecto.Changeset.add_error(changeset, :pool_id, "must be an active Pool")

  defp validate_selected_pool(changeset, _pool), do: changeset

  defp reinvite_email(candidates, pool_id) do
    candidates
    |> Enum.map(&present_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.find(&valid_reinvite_email?(&1, pool_id))
  end

  defp valid_reinvite_email?(candidate, pool_id) do
    %{"pool_id" => pool_id, "invited_email" => candidate, "send_email" => "false"}
    |> changeset(%{id: pool_id})
    |> Map.fetch!(:valid?)
  end

  defp matching_recipient_locale(%User{email: email, locale: locale}, invited_email) when is_binary(invited_email) do
    if String.downcase(String.trim(email)) == String.downcase(String.trim(invited_email)), do: locale
  end

  defp matching_recipient_locale(_recipient, _invited_email), do: nil

  defp supported_tag(tag), do: if(tag in SupportedLocales.tags(), do: tag)

  defp present_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp present_string(_value), do: nil
end
