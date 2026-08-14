defmodule CodexPooler.Admin.Stats.Buckets do
  @moduledoc false

  @spec labels(%{required(:window) => atom(), required(:ended_at) => DateTime.t()}) :: [
          String.t()
        ]
  def labels(%{window: :seven_days, ended_at: ended_at}) do
    today = DateTime.to_date(ended_at)

    6..0//-1
    |> Enum.map(&Date.add(today, -&1))
    |> Enum.map(&Date.to_iso8601/1)
  end

  def labels(%{window: window, ended_at: ended_at}) do
    count = if window == :one_hour, do: 1, else: if(window == :five_hours, do: 5, else: 24)
    current_hour = truncate_to_hour(ended_at)

    (count - 1)..0//-1
    |> Enum.map(&DateTime.add(current_hour, -&1, :hour))
    |> Enum.map(&label(&1, window))
  end

  @spec stats_labels(%{
          required(:window) => atom(),
          required(:started_at) => DateTime.t(),
          required(:ended_at) => DateTime.t()
        }) :: [String.t()]
  def stats_labels(%{window: :seven_days, started_at: started_at, ended_at: ended_at}) do
    started_on = DateTime.to_date(started_at)
    ended_on = DateTime.to_date(ended_at)
    count = Date.diff(ended_on, started_on) + 1

    if count in 1..8 do
      started_on
      |> Date.range(ended_on)
      |> Enum.map(&Date.to_iso8601/1)
    else
      []
    end
  end

  def stats_labels(%{window: window, started_at: started_at, ended_at: ended_at})
      when window in [:one_hour, :five_hours, :twenty_four_hours] do
    started_hour = truncate_to_hour(started_at)
    ended_hour = truncate_to_hour(ended_at)
    count = div(DateTime.diff(ended_hour, started_hour, :second), 60 * 60) + 1

    if count in 1..max_stats_label_count(window) do
      0..(count - 1)
      |> Enum.map(&DateTime.add(started_hour, &1, :hour))
      |> Enum.map(&label(&1, window))
    else
      []
    end
  end

  def stats_labels(_context), do: []

  @spec label(DateTime.t() | nil, atom()) :: String.t() | nil
  def label(nil, _window), do: nil

  def label(datetime, :seven_days),
    do: datetime |> DateTime.to_date() |> Date.to_iso8601()

  def label(datetime, _window) do
    datetime = truncate_to_hour(datetime)
    date = datetime |> DateTime.to_date() |> Date.to_iso8601()
    hour = datetime.hour |> Integer.to_string() |> String.pad_leading(2, "0")
    date <> "T" <> hour <> ":00:00Z"
  end

  @spec model_usage_bucket_label(Date.t() | DateTime.t() | String.t() | nil, atom()) ::
          String.t() | nil
  def model_usage_bucket_label(%Date{} = date, _window), do: Date.to_iso8601(date)

  def model_usage_bucket_label(%DateTime{} = datetime, window),
    do: label(datetime, window)

  def model_usage_bucket_label(bucket, _window) when is_binary(bucket), do: bucket
  def model_usage_bucket_label(_bucket, _window), do: nil

  @spec truncate_to_hour(DateTime.t()) :: DateTime.t()
  def truncate_to_hour(datetime) do
    %{datetime | minute: 0, second: 0, microsecond: {0, 0}}
  end

  defp max_stats_label_count(:one_hour), do: 2
  defp max_stats_label_count(:five_hours), do: 6
  defp max_stats_label_count(:twenty_four_hours), do: 25
end
