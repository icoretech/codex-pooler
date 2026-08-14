defmodule CodexPoolerWeb.Admin.StatsPresentation.BucketLabel do
  @moduledoc false

  @spec format(term()) :: String.t()
  def format(<<date::binary-size(10), "T", hour::binary-size(2), ":00:00Z">>),
    do: String.slice(date, 5, 5) <> " " <> hour <> ":00"

  def format(<<_year::binary-size(4), "-", month::binary-size(2), "-", day::binary-size(2)>>),
    do: month <> "-" <> day

  def format(bucket), do: to_string(bucket)
end
