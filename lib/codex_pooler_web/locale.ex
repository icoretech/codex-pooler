defmodule CodexPoolerWeb.Locale do
  @moduledoc """
  Browser locale resolution and the signed LiveView locale handoff.

  Only explicit preferences are persisted. The resolved locale is assigned per
  request and copied into the signed LiveView session, never the browser session.
  """

  alias CodexPooler.SupportedLocales

  @default_tag "en"
  @cookie_name "codex_pooler_locale"
  @cookie_max_age 365 * 24 * 60 * 60
  @presentation %{
    "en" => %{label: "English", dir: "ltr"},
    "zh-CN" => %{label: "简体中文", dir: "ltr"}
  }

  if Enum.sort(Map.keys(@presentation)) != Enum.sort(SupportedLocales.tags()) do
    raise ArgumentError, "locale presentation must match the supported storage tags"
  end

  @locales Enum.map(SupportedLocales.tags(), fn tag ->
             @presentation
             |> Map.fetch!(tag)
             |> Map.put(:tag, tag)
             |> Map.put(:gettext, SupportedLocales.gettext_locale(tag))
           end)
  @language_tag ~r/^[a-z]{1,8}(?:-[a-z0-9]{1,8})*$/
  @quality ~r/^q=(0(?:\.[0-9]{0,3})?|1(?:\.0{0,3})?)$/i

  @type t :: %{
          tag: String.t(),
          label: String.t(),
          dir: String.t(),
          gettext: String.t()
        }
  @type live_session :: %{
          required(String.t()) => String.t()
        }

  @spec locales() :: [t()]
  def locales, do: @locales

  @spec default() :: t()
  def default, do: fetch!(@default_tag)

  @spec cookie_name() :: String.t()
  def cookie_name, do: @cookie_name

  @spec cookie_max_age() :: pos_integer()
  def cookie_max_age, do: @cookie_max_age

  @spec cookie_options(Plug.Conn.t()) :: keyword()
  def cookie_options(conn) do
    [path: "/", http_only: true, same_site: "Lax", max_age: @cookie_max_age, secure: conn.scheme == :https]
  end

  @spec fetch(term()) :: t() | nil
  def fetch(tag) do
    normalized = normalize(tag)
    Enum.find(@locales, &(&1.tag == normalized))
  end

  @spec fetch!(term()) :: t()
  def fetch!(tag), do: fetch(tag) || raise(ArgumentError, "unsupported locale: #{inspect(tag)}")

  @doc "Normalizes supported language spellings without matching Traditional Chinese."
  @spec normalize(term()) :: String.t() | nil
  def normalize(tag) when is_binary(tag) do
    if String.valid?(tag) do
      normalized = tag |> String.trim() |> String.replace("_", "-") |> String.downcase()
      if Regex.match?(@language_tag, normalized), do: base_match(normalized)
    end
  end

  def normalize(_tag), do: nil

  @spec resolve(term(), term(), String.t() | nil) :: t()
  def resolve(user_locale, cookie_locale, accept_language \\ nil) do
    fetch(user_locale) || fetch(cookie_locale) || from_accept_language(accept_language) || default()
  end

  @spec from_accept_language(term()) :: t() | nil
  def from_accept_language(header) when is_binary(header) do
    if String.valid?(header) do
      entries =
        header
        |> String.split(",")
        |> Enum.with_index()
        |> Enum.flat_map(&weighted_entry/1)

      excluded = Enum.reduce(entries, MapSet.new(), &exclude_zero_quality/2)

      entries
      |> Enum.filter(fn {_tag, quality, _index} -> quality > 0.0 end)
      |> Enum.sort_by(fn {_tag, quality, index} -> {-quality, index} end)
      |> Enum.find_value(&matching_locale(&1, excluded))
    end
  end

  def from_accept_language(_header), do: nil

  @spec gettext_locale(t() | nil) :: String.t()
  def gettext_locale(%{gettext: gettext}), do: gettext
  def gettext_locale(_locale), do: SupportedLocales.gettext_locale(nil)

  @spec html_lang(t() | nil) :: String.t()
  def html_lang(%{tag: tag}), do: tag
  def html_lang(_locale), do: @default_tag

  @spec dir(t() | nil) :: String.t()
  def dir(%{dir: dir}), do: dir
  def dir(_locale), do: "ltr"

  @spec live_session(Plug.Conn.t()) :: live_session()
  def live_session(conn) do
    locale = conn.assigns[:locale] || default()
    session = %{"locale" => locale.tag}

    case normalize(conn.assigns[:locale_preference]) do
      nil -> session
      preference -> Map.put(session, "locale_preference", preference)
    end
  end

  @spec on_mount(:assign_locale, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:assign_locale, _params, session, socket) do
    locale = fetch(session["locale"]) || default()
    preference = normalize(session["locale_preference"])
    Gettext.put_locale(locale.gettext)

    {:cont, Phoenix.Component.assign(socket, locale: locale, locale_preference: preference)}
  end

  defp base_match(tag) do
    case String.split(tag, "-") do
      ["en" | _subtags] -> "en"
      ["zh" | subtags] -> if Enum.any?(subtags, &(&1 in ~w(hant tw hk mo))), do: nil, else: "zh-CN"
      _unsupported -> nil
    end
  end

  defp exclude_zero_quality({tag, quality, _index}, excluded) do
    locale = normalize(tag)
    if quality == 0.0 and not is_nil(locale), do: MapSet.put(excluded, locale), else: excluded
  end

  defp matching_locale({"*", _quality, _index}, excluded), do: Enum.find(@locales, &(not MapSet.member?(excluded, &1.tag)))
  defp matching_locale({tag, _quality, _index}, _excluded), do: fetch(tag)

  defp weighted_entry({entry, index}) do
    case parse_entry(entry) do
      {tag, quality} -> [{tag, quality, index}]
      _invalid -> []
    end
  end

  @spec parse_entry(String.t()) :: {String.t(), float()} | nil
  defp parse_entry(entry) do
    case entry |> String.split(";") |> Enum.map(&String.trim/1) do
      [tag] -> valid_entry(tag, 1.0)
      [tag, quality] -> valid_entry(tag, parse_quality(quality))
      _malformed -> nil
    end
  end

  defp valid_entry(_tag, nil), do: nil

  defp valid_entry(tag, quality) do
    if tag == "*" or Regex.match?(@language_tag, String.downcase(tag)), do: {tag, quality}
  end

  defp parse_quality(parameter) do
    case Regex.run(@quality, parameter) do
      [_match, value] -> value |> Float.parse() |> elem(0)
      nil -> nil
    end
  end
end
