defmodule CodexPooler.Upstreams.SavedResets.FirstSeenLedger do
  @moduledoc """
  Canonical durable history for saved-reset first-seen timestamps.

  Version-one ledgers contain only expiration and first-seen timestamps.
  Unknown versions remain opaque so callers cannot accidentally rewrite data
  owned by a newer ledger contract.
  """

  @version 1
  @retention_days 30
  @non_current_limit 128

  @type entry :: %{required(String.t()) => String.t()}
  @type t :: %{required(String.t()) => pos_integer() | [entry()]}
  @type merge_result :: {:ok, t()} | {:opaque, term()}
  @type lookup_result :: {:ok, String.t()} | :error | {:opaque, term()}

  @spec empty() :: t()
  def empty, do: %{"version" => @version, "entries" => []}

  @spec merge(term(), [term()], [term()], DateTime.t()) :: merge_result()
  def merge(%{"version" => @version} = ledger, incoming_entries, current_expirations, now)
      when is_list(incoming_entries) and is_list(current_expirations) and
             is_struct(now, DateTime) do
    entries =
      ledger
      |> Map.get("entries", [])
      |> normalize_entry_list()
      |> merge_entries(normalize_entry_list(incoming_entries))
      |> retain(current_expirations, now)
      |> serialize()

    {:ok, %{"version" => @version, "entries" => entries}}
  end

  def merge(ledger, _incoming_entries, _current_expirations, _now), do: {:opaque, ledger}

  @spec lookup(term(), term()) :: lookup_result()
  def lookup(%{"version" => @version} = ledger, expires_at) do
    with {:ok, expiration} <- parse_datetime(expires_at),
         entries <- ledger |> Map.get("entries", []) |> normalize_entry_list(),
         %{first_seen_at: first_seen_at} <-
           Map.get(entries, DateTime.to_unix(expiration, :microsecond)) do
      {:ok, canonical(first_seen_at)}
    else
      _missing_or_malformed -> :error
    end
  end

  def lookup(ledger, _expires_at), do: {:opaque, ledger}

  defp normalize_entry_list(entries) when is_list(entries) do
    Enum.reduce(entries, %{}, fn entry, normalized ->
      case parse_entry(entry) do
        {:ok, parsed} -> put_earliest(normalized, parsed)
        :error -> normalized
      end
    end)
  end

  defp normalize_entry_list(_entries), do: %{}

  defp parse_entry(%{
         "expires_at" => expires_at,
         "first_seen_at" => first_seen_at
       }) do
    with {:ok, expiration} <- parse_datetime(expires_at),
         {:ok, first_seen} <- parse_datetime(first_seen_at) do
      {:ok, %{expires_at: expiration, first_seen_at: first_seen}}
    end
  end

  defp parse_entry(_entry), do: :error

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, normalize_precision(datetime)}
      {:error, _reason} -> :error
    end
  end

  defp parse_datetime(_value), do: :error

  defp normalize_precision(%DateTime{microsecond: {0, _precision}} = datetime) do
    %{datetime | microsecond: {0, 0}}
  end

  defp normalize_precision(%DateTime{microsecond: {microsecond, _precision}} = datetime) do
    %{datetime | microsecond: {microsecond, 6}}
  end

  defp merge_entries(existing, incoming) do
    Enum.reduce(incoming, existing, fn {_key, entry}, merged ->
      put_earliest(merged, entry)
    end)
  end

  defp put_earliest(entries, entry) do
    key = DateTime.to_unix(entry.expires_at, :microsecond)

    Map.update(entries, key, entry, fn existing ->
      if DateTime.before?(entry.first_seen_at, existing.first_seen_at), do: entry, else: existing
    end)
  end

  defp retain(entries, current_expirations, now) do
    current_keys =
      current_expirations
      |> Enum.reduce(MapSet.new(), fn expires_at, keys ->
        case parse_datetime(expires_at) do
          {:ok, datetime} -> MapSet.put(keys, DateTime.to_unix(datetime, :microsecond))
          :error -> keys
        end
      end)

    {current, non_current} =
      entries
      |> Enum.filter(fn {key, entry} ->
        MapSet.member?(current_keys, key) or within_retention?(entry.expires_at, now)
      end)
      |> Enum.split_with(fn {key, _entry} -> MapSet.member?(current_keys, key) end)

    non_current =
      non_current
      |> Enum.sort_by(fn {key, _entry} -> key end, :desc)
      |> Enum.take(@non_current_limit)

    Map.new(current ++ non_current)
  end

  defp within_retention?(expires_at, now) do
    expires_at
    |> DateTime.add(@retention_days, :day)
    |> DateTime.compare(now)
    |> Kernel.!==(:lt)
  end

  defp serialize(entries) do
    entries
    |> Enum.sort_by(fn {key, _entry} -> key end)
    |> Enum.map(fn {_key, entry} ->
      %{
        "expires_at" => canonical(entry.expires_at),
        "first_seen_at" => canonical(entry.first_seen_at)
      }
    end)
  end

  defp canonical(datetime), do: DateTime.to_iso8601(datetime)
end
