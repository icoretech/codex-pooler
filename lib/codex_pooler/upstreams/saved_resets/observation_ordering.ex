defmodule CodexPooler.Upstreams.SavedResets.ObservationOrdering do
  @moduledoc """
  Canonical ordering for saved-reset provider observations.

  Writers call `authorize/2` while holding the upstream identity row lock.
  Invalid candidates and candidates older than the persisted observation cannot
  overwrite saved-reset state.
  """

  @type authorization :: {:apply, String.t()} | :skip

  @spec authorize(term(), term()) :: authorization()
  def authorize(candidate, persisted) do
    case parse(candidate) do
      {:ok, candidate_datetime} ->
        case parse(persisted) do
          {:ok, persisted_datetime} ->
            authorize_ordered(candidate_datetime, persisted_datetime)

          :error ->
            {:apply, DateTime.to_iso8601(candidate_datetime)}
        end

      :error ->
        :skip
    end
  end

  defp authorize_ordered(candidate, persisted) do
    if DateTime.compare(candidate, persisted) == :lt do
      :skip
    else
      {:apply, DateTime.to_iso8601(candidate)}
    end
  end

  defp parse(%DateTime{} = datetime), do: {:ok, DateTime.truncate(datetime, :microsecond)}

  defp parse(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.truncate(datetime, :microsecond)}
      {:error, _reason} -> :error
    end
  end

  defp parse(_value), do: :error
end
