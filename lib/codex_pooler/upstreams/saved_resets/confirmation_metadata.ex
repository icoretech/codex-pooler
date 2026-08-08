defmodule CodexPooler.Upstreams.SavedResets.ConfirmationMetadata do
  @moduledoc false

  alias CodexPooler.Upstreams.Quota.AccountQuotaWindow
  alias CodexPooler.Upstreams.Quota.Windows.CycleConfirmation

  @version 1
  @sources ~w(reconciliation runtime_headers runtime_websocket_upgrade_headers runtime_websocket_frame_headers runtime_event runtime_error finalizer)
  @outcomes ~w(confirmed_by_quota reblocked expired)

  @type read_result :: %{
          source: String.t(),
          outcome: String.t(),
          canonical_confirmed_at: DateTime.t() | nil
        }

  @spec build(
          String.t(),
          String.t() | atom(),
          [AccountQuotaWindow.t()],
          DateTime.t(),
          DateTime.t()
        ) ::
          map()
  def build(source, outcome, windows, %DateTime{} = consumed_at, %DateTime{} = decision_at)
      when is_list(windows) do
    %{
      "convergence_source" => normalize_source(source),
      "convergence_outcome" => normalize_outcome(outcome),
      "confirmation_timing" => timing(windows, consumed_at, decision_at)
    }
  end

  @spec read(term()) :: read_result()
  def read(redemption) when is_map(redemption) do
    %{
      source: read_source(redemption["convergence_source"]),
      outcome: read_outcome(redemption["convergence_outcome"]),
      canonical_confirmed_at: read_canonical_confirmed_at(redemption["confirmation_timing"])
    }
  end

  def read(_redemption),
    do: %{source: "unknown", outcome: "unknown", canonical_confirmed_at: nil}

  defp timing(windows, consumed_at, decision_at) do
    case canonical_confirmed_at(windows, consumed_at, decision_at) do
      %DateTime{} = confirmed_at ->
        %{
          "version" => @version,
          "canonical_confirmed_at" => DateTime.to_iso8601(confirmed_at)
        }

      nil ->
        %{"version" => @version}
    end
  end

  defp canonical_confirmed_at(windows, consumed_at, decision_at) do
    Enum.reduce(windows, nil, fn window, latest ->
      with {:ok, confirmed_at} <- CycleConfirmation.confirmed_at(window),
           true <- DateTime.compare(confirmed_at, consumed_at) != :lt,
           true <- DateTime.compare(confirmed_at, decision_at) != :gt do
        later_datetime(latest, confirmed_at)
      else
        _invalid_or_out_of_range -> latest
      end
    end)
  end

  defp later_datetime(nil, %DateTime{} = right), do: right

  defp later_datetime(%DateTime{} = left, %DateTime{} = right) do
    if DateTime.compare(left, right) == :lt, do: right, else: left
  end

  defp read_canonical_confirmed_at(
         %{
           "version" => @version,
           "canonical_confirmed_at" => value
         } = timing
       )
       when map_size(timing) == 2,
       do: parse_datetime(value)

  defp read_canonical_confirmed_at(%{"version" => @version} = timing)
       when map_size(timing) == 1,
       do: nil

  defp read_canonical_confirmed_at(_timing), do: nil

  defp normalize_source(source) when source in @sources, do: source
  defp normalize_source(_source), do: "unknown"

  defp normalize_outcome(outcome) when is_atom(outcome),
    do: outcome |> Atom.to_string() |> normalize_outcome()

  defp normalize_outcome(outcome) when outcome in @outcomes, do: outcome
  defp normalize_outcome(_outcome), do: "unknown"

  defp read_source(source) when source in @sources, do: source
  defp read_source(_source), do: "unknown"

  defp read_outcome(outcome) when outcome in @outcomes, do: outcome
  defp read_outcome(_outcome), do: "unknown"

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> datetime
      _invalid -> nil
    end
  end

  defp parse_datetime(_value), do: nil
end
