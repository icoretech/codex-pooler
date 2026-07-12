defmodule CodexPooler.Quotas.Evidence.CodexParsers.WindowKinds do
  @moduledoc false

  @weekly_minutes 10_080

  @doc """
  Remaps a provider `primary` window slot that carries a weekly duration to the
  normalized `secondary` (weekly) window kind.

  The Codex provider can move the weekly limit into the `primary` slot when an
  account stops receiving a shorter primary window. The usage API parser
  already normalizes that shape to the weekly secondary window; header, event,
  and rate-limit-error evidence must agree so one logical weekly window keeps
  refreshing instead of forking into a duplicate `primary/10080` identity.
  """
  @spec normalize_window_kind(String.t(), pos_integer() | nil) :: String.t()
  def normalize_window_kind("primary", @weekly_minutes), do: "secondary"
  def normalize_window_kind(kind, _window_minutes), do: kind
end
