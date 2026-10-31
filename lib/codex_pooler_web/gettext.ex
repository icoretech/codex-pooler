defmodule CodexPoolerWeb.Gettext do
  @moduledoc """
  Gettext backend used by CodexPooler UI and validation messages.
  """
  use Gettext.Backend, otp_app: :codex_pooler, plural_forms: CodexPoolerWeb.Gettext.Plural
end
