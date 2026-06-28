defmodule CodexPoolerWeb.Admin.UpstreamAccountsReadModel.Formatting do
  @moduledoc false

  alias CodexPoolerWeb.DateTimeDisplay

  @spec timestamp_status_label(String.t(), DateTime.t() | nil, DateTimeDisplay.preferences()) ::
          String.t()
  def timestamp_status_label(prefix, %DateTime{} = timestamp, datetime_preferences) do
    "#{prefix} #{DateTimeDisplay.format_datetime(timestamp, datetime_preferences)} · #{relative_time_label(timestamp)}"
  end

  def timestamp_status_label(prefix, _timestamp, _datetime_preferences),
    do: "#{prefix} not reported"

  @spec relative_time_label(DateTime.t()) :: String.t()
  def relative_time_label(%DateTime{} = timestamp) do
    diff = DateTime.diff(DateTime.utc_now(), timestamp, :second)

    cond do
      diff < -60 -> "in #{format_reset_duration(abs(diff))}"
      diff < 60 -> "just now"
      true -> "#{format_reset_duration(diff)} ago"
    end
  end

  @spec parse_datetime(term()) :: DateTime.t() | nil
  def parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :microsecond)
      _invalid -> nil
    end
  end

  def parse_datetime(_value), do: nil

  @spec parse_timestamp(term()) :: DateTime.t() | nil
  def parse_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> timestamp
      {:error, _reason} -> nil
    end
  end

  def parse_timestamp(%DateTime{} = timestamp), do: timestamp
  def parse_timestamp(_value), do: nil

  @spec present_string?(term()) :: boolean()
  def present_string?(value) when is_binary(value), do: String.trim(value) != ""
  def present_string?(_value), do: false

  @spec present_string(term()) :: String.t() | nil
  def present_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  def present_string(_value), do: nil

  @spec format_reset_duration(non_neg_integer()) :: String.t()
  def format_reset_duration(seconds) when seconds >= 86_400 do
    days = div(seconds, 86_400)
    hours = seconds |> rem(86_400) |> div(3_600)

    duration_parts([{days, "d"}, {hours, "h"}])
  end

  def format_reset_duration(seconds) when seconds >= 3_600 do
    total_minutes = div(seconds + 59, 60)
    hours = div(total_minutes, 60)
    minutes = rem(total_minutes, 60)

    duration_parts([{hours, "h"}, {minutes, "m"}])
  end

  def format_reset_duration(seconds) when seconds >= 60 do
    minutes = div(seconds + 59, 60)

    duration_parts([{minutes, "m"}])
  end

  def format_reset_duration(_seconds), do: "<1m"

  @spec format_integer(integer()) :: String.t()
  def format_integer(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")
  end

  defp duration_parts(parts) do
    parts
    |> Enum.reject(fn {value, _unit} -> value <= 0 end)
    |> Enum.map_join(" ", fn {value, unit} ->
      "#{format_integer(value)}#{unit}"
    end)
  end
end
