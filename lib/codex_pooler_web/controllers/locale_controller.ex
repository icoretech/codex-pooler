defmodule CodexPoolerWeb.LocaleController do
  use CodexPoolerWeb, :controller

  alias CodexPooler.Accounts
  alias CodexPooler.Accounts.{Scope, User}
  alias CodexPoolerWeb.{Locale, SafeRedirect}

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    return_to = return_path(conn, params)

    case preference(params["locale"]) do
      {:ok, tag} -> update_preference(conn, tag, return_to)
      :error -> conn |> put_flash(:error, gettext("Unsupported language.")) |> redirect(to: return_to)
    end
  end

  defp update_preference(conn, tag, return_to) do
    case persist_preference(conn.assigns[:current_scope], tag) do
      :ok ->
        locale = Locale.resolve(tag, nil, Enum.join(get_req_header(conn, "accept-language"), ","))
        Gettext.put_locale(locale.gettext)

        conn
        |> assign(:locale, locale)
        |> assign(:locale_preference, tag)
        |> put_resp_header("content-language", locale.tag)
        |> write_preference_cookie(tag)
        |> put_flash(:info, gettext("Language updated"))
        |> redirect(to: return_to)

      {:error, _reason} ->
        conn
        |> put_flash(:error, gettext("Unable to update language. Please try again."))
        |> redirect(to: return_to)
    end
  end

  defp preference("auto"), do: {:ok, nil}

  defp preference(value) do
    case Locale.normalize(value) do
      nil -> :error
      tag -> {:ok, tag}
    end
  end

  defp persist_preference(%Scope{user: %User{} = user}, tag) do
    case Accounts.update_user_locale(user, tag) do
      {:ok, _user} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_preference(_scope, _tag), do: :ok

  defp write_preference_cookie(conn, nil) do
    delete_resp_cookie(conn, Locale.cookie_name(), Locale.cookie_options(conn))
  end

  defp write_preference_cookie(conn, tag) do
    put_resp_cookie(conn, Locale.cookie_name(), tag, Locale.cookie_options(conn))
  end

  defp return_path(conn, params) do
    SafeRedirect.local_path(params["return_to"]) || referer_path(conn) || ~p"/"
  end

  defp referer_path(conn) do
    with [referer | _rest] <- get_req_header(conn, "referer"),
         {:ok, uri} <- URI.new(referer),
         true <- local_referer?(uri, conn) do
      SafeRedirect.local_path(URI.to_string(%URI{path: uri.path || "/", query: uri.query}))
    else
      _missing_or_invalid -> nil
    end
  end

  defp local_referer?(%URI{scheme: nil, host: nil}, _conn), do: true

  defp local_referer?(%URI{scheme: scheme, host: host, port: port, userinfo: nil}, conn) do
    scheme == Atom.to_string(conn.scheme) and host == conn.host and port == conn.port
  end

  defp local_referer?(_uri, _conn), do: false
end
