defmodule CodexPooler.Quotas.ModelWeeklyResetSemantics do
  @moduledoc """
  Classifies reset semantics for weekly model quota evidence.

  The result is a pure interpretation of shared quota fields. It does not make
  freshness, expiry, routing, or persistence decisions.
  """

  alias CodexPooler.Quotas.Evidence

  @weekly_minutes 10_080
  @target_scopes ~w(model upstream_model)
  @recognized_scopes ~w(account feature model upstream_model)
  @zero Decimal.new(0)
  @hundred Decimal.new(100)

  @type semantic :: :anchored | :floating | :unknown | :not_applicable
  @type map_value ::
          nil
          | boolean()
          | number()
          | atom()
          | String.t()
          | Decimal.t()
          | Date.t()
          | DateTime.t()
          | [map_value()]
          | shared_window()

  @type shared_window :: %{
          optional(atom()) => map_value(),
          optional(String.t()) => map_value()
        }

  @type input :: Evidence.t() | shared_window()

  @spec classify(input()) :: semantic()
  def classify(window) when is_map(window) do
    case applicability(window) do
      :applicable -> classify_applicable(window)
      :not_applicable -> :not_applicable
      :unknown -> :unknown
    end
  end

  @spec rank(semantic()) :: 0..3
  def rank(:anchored), do: 3
  def rank(:floating), do: 2
  def rank(:unknown), do: 1
  def rank(:not_applicable), do: 0

  @spec applicability(input()) :: :applicable | :not_applicable | :unknown
  defp applicability(window) do
    quota_scope = field(window, :quota_scope)
    window_minutes = field(window, :window_minutes)

    cond do
      quota_scope not in @recognized_scopes ->
        :unknown

      not is_integer(window_minutes) or window_minutes <= 0 ->
        :unknown

      quota_scope in @target_scopes and window_minutes == @weekly_minutes ->
        :applicable

      true ->
        :not_applicable
    end
  end

  @spec classify_applicable(input()) :: semantic()
  defp classify_applicable(window) do
    with %DateTime{} <- field(window, :reset_at),
         metadata when is_map(metadata) <- field(window, :metadata),
         percentage_kind when percentage_kind in [:zero, :positive] <-
           percentage_kind(field(window, :used_percent)) do
      classify_metadata(metadata, percentage_kind)
    else
      _invalid -> :unknown
    end
  end

  @spec classify_metadata(shared_window(), :zero | :positive) :: semantic()
  defp classify_metadata(metadata, percentage_kind) do
    cond do
      Map.has_key?(metadata, :reset_state) ->
        :unknown

      Map.get(metadata, "reset_state") == "anchored" ->
        :anchored

      Map.get(metadata, "reset_state") == "floating" and percentage_kind == :zero ->
        :floating

      not Map.has_key?(metadata, "reset_state") and percentage_kind == :positive ->
        :anchored

      true ->
        :unknown
    end
  end

  @spec percentage_kind(map_value()) :: :zero | :positive | :invalid
  defp percentage_kind(%Decimal{} = used_percent) do
    cond do
      Decimal.nan?(used_percent) or Decimal.inf?(used_percent) ->
        :invalid

      Decimal.compare(used_percent, @zero) == :lt ->
        :invalid

      Decimal.compare(used_percent, @hundred) == :gt ->
        :invalid

      Decimal.compare(used_percent, @zero) == :eq ->
        :zero

      true ->
        :positive
    end
  end

  defp percentage_kind(_used_percent), do: :invalid

  @spec field(input(), atom()) :: map_value()
  defp field(window, field_name) do
    if Map.has_key?(window, field_name) do
      Map.get(window, field_name)
    else
      Map.get(window, Atom.to_string(field_name))
    end
  end
end
