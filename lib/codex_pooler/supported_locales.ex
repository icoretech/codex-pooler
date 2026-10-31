defmodule CodexPooler.SupportedLocales do
  @moduledoc """
  Locale storage tags shared by accounts, email delivery, and browser presentation.

  Persist BCP-47 tags; Gettext catalog names are confined to the rendering boundary.
  """

  @tags ~w(en zh-CN)

  @spec tags() :: [String.t()]
  def tags, do: @tags

  @doc "Returns the catalog locale, falling back to English for an unset or unsupported tag."
  @spec gettext_locale(term()) :: String.t()
  def gettext_locale("zh-CN"), do: "zh_CN"
  def gettext_locale(_tag), do: "en"
end
