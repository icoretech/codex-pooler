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
end
