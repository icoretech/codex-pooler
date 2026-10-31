defmodule CodexPoolerWeb.Plugs.Locale do
  @moduledoc "Resolves browser language without persisting the automatic result."
  @behaviour Plug

  import Plug.Conn

  alias CodexPoolerWeb.Locale

  @impl true
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @impl true
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    cookie_tag = Locale.normalize(conn.cookies[Locale.cookie_name()])
    user_tag = user_preference(conn.assigns[:current_scope])
    explicit = user_tag || cookie_tag
    locale = Locale.resolve(user_tag, cookie_tag, accept_language(conn))

    Gettext.put_locale(locale.gettext)

    conn
    |> assign(:locale, locale)
    |> assign(:locale_preference, explicit)
    |> put_resp_header("content-language", locale.tag)
    |> merge_vary_accept_language()
  end

  defp user_preference(%{user: %{locale: locale}}), do: Locale.normalize(locale)
  defp user_preference(_scope), do: nil

  defp accept_language(conn) do
    case get_req_header(conn, "accept-language") do
      [] -> nil
      values -> Enum.join(values, ",")
    end
  end

  defp merge_vary_accept_language(conn) do
    tokens =
      conn
      |> get_resp_header("vary")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if Enum.any?(tokens, &(String.downcase(&1) in ["*", "accept-language"])) do
      conn
    else
      put_resp_header(conn, "vary", Enum.join(tokens ++ ["accept-language"], ", "))
    end
  end
end
