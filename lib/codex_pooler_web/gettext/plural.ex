defmodule CodexPoolerWeb.Gettext.Plural do
  @moduledoc """
  Locale-string plural context for `CodexPoolerWeb.Gettext`.

  Gettext embeds the result of `init/1` in generated backend functions. The
  default pluralizer embeds an `Expo.PluralForms` value whose expression is
  opaque to Dialyzer, so this adapter keeps only the locale in that generated
  context and delegates the rule lookup to `Gettext.Plural` at runtime.
  """

  @behaviour Gettext.Plural

  @impl true
  @spec init(Gettext.Plural.pluralization_context()) :: String.t()
  def init(%{locale: locale}), do: locale

  @impl true
  @spec nplurals(Gettext.Plural.plural_info()) :: pos_integer()
  def nplurals(plural_info), do: Gettext.Plural.nplurals(plural_info)

  @impl true
  @spec plural(Gettext.Plural.plural_info(), integer()) :: non_neg_integer()
  def plural(plural_info, count), do: Gettext.Plural.plural(plural_info, count)

  @impl true
  @spec plural_forms_header(Gettext.Plural.locale()) :: String.t() | nil
  def plural_forms_header(locale), do: Gettext.Plural.plural_forms_header(locale)
end
