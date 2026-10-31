defmodule CodexPoolerWeb.DateTimeDisplay do
  @moduledoc """
  Browser/admin datetime display policy for operator-facing UI.
  """

  use Gettext, backend: CodexPoolerWeb.Gettext

  alias CodexPooler.Accounts.User

  @default_format "default"
  @default_timezone "Etc/UTC"
  @default_missing_label "-"
  @format_values ~w(default short long iso8601)

  @type preferences :: %{
          required(:datetime_format) => String.t(),
          required(:timezone) => String.t()
        }
  @type datetime_value :: DateTime.t() | NaiveDateTime.t() | nil
  @type format_opt :: {:missing_label, String.t()}
  @type user_or_nil :: User.t() | map() | nil

  @spec preferences_for_user(user_or_nil()) :: preferences()
  def preferences_for_user(nil) do
    %{datetime_format: @default_format, timezone: @default_timezone}
  end

  def preferences_for_user(user) when is_map(user) do
    %{
      datetime_format: normalize_format(Map.get(user, :datetime_format)),
      timezone: normalize_timezone_value(Map.get(user, :timezone))
    }
  end

  @spec format_datetime(datetime_value(), preferences(), [format_opt()]) :: String.t()
  def format_datetime(value, preferences, opts \\ [])

  def format_datetime(nil, _preferences, opts) do
    missing_label(opts)
  end

  def format_datetime(%NaiveDateTime{} = datetime, preferences, opts) do
    datetime
    |> DateTime.from_naive!(@default_timezone, Calendar.UTCOnlyTimeZoneDatabase)
    |> format_datetime(preferences, opts)
  end

  def format_datetime(%DateTime{} = datetime, preferences, _opts) when is_map(preferences) do
    format = normalize_format(Map.get(preferences, :datetime_format))
    datetime = shift_for_display(datetime, Map.get(preferences, :timezone))

    case format do
      "short" ->
        Calendar.strftime(datetime, "%Y-%m-%d %H:%M")

      "long" ->
        "#{long_date(datetime)} #{Calendar.strftime(datetime, "%H:%M:%S")} #{timezone_label(datetime)}"

      "iso8601" ->
        datetime
        |> DateTime.truncate(:second)
        |> DateTime.to_iso8601()

      _default ->
        "#{Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S")} #{timezone_label(datetime)}"
    end
  end

  @doc """
  Formats a datetime as separate date and time strings so callers can style
  the two parts differently while honoring the operator's format preference.
  """
  @spec format_datetime_parts(datetime_value(), preferences()) ::
          %{date: String.t(), time: String.t()} | nil
  def format_datetime_parts(nil, _preferences), do: nil

  def format_datetime_parts(%NaiveDateTime{} = datetime, preferences) do
    datetime
    |> DateTime.from_naive!(@default_timezone, Calendar.UTCOnlyTimeZoneDatabase)
    |> format_datetime_parts(preferences)
  end

  def format_datetime_parts(%DateTime{} = datetime, preferences) when is_map(preferences) do
    format = normalize_format(Map.get(preferences, :datetime_format))
    datetime = shift_for_display(datetime, Map.get(preferences, :timezone))

    case format do
      "short" ->
        %{
          date: Calendar.strftime(datetime, "%Y-%m-%d"),
          time: Calendar.strftime(datetime, "%H:%M")
        }

      "long" ->
        %{
          date: long_date(datetime),
          time: "#{Calendar.strftime(datetime, "%H:%M:%S")} #{timezone_label(datetime)}"
        }

      "iso8601" ->
        iso =
          datetime
          |> DateTime.truncate(:second)
          |> DateTime.to_iso8601()

        case String.split(iso, "T", parts: 2) do
          [date, time] -> %{date: date, time: time}
          _no_time -> %{date: iso, time: ""}
        end

      _default ->
        %{
          date: Calendar.strftime(datetime, "%Y-%m-%d"),
          time: "#{Calendar.strftime(datetime, "%H:%M:%S")} #{timezone_label(datetime)}"
        }
    end
  end

  @spec format_options() :: [{String.t(), String.t()}]
  def format_options do
    [
      {gettext("Default"), "default"},
      {gettext("Short"), "short"},
      {gettext("Long"), "long"},
      {gettext("ISO 8601"), "iso8601"}
    ]
  end

  @spec timezone_options() :: [{String.t(), String.t()}]
  def timezone_options do
    key = {__MODULE__, :timezone_options}

    case :persistent_term.get(key, nil) do
      nil ->
        options = build_timezone_options()
        :persistent_term.put(key, options)
        options

      options ->
        options
    end
  end

  # Host zoneinfo supplies names; bundled Tz rules validate and convert them.
  # Both are fixed for the lifetime of the release VM.
  defp build_timezone_options do
    zones =
      Zoneinfo.time_zones()
      |> Enum.uniq()
      |> Enum.filter(&match?({:ok, _datetime}, DateTime.shift_zone(DateTime.utc_now(), &1, Tz.TimeZoneDatabase)))
      |> Enum.reject(&(&1 == @default_timezone))
      |> Enum.sort()

    Enum.map([@default_timezone | zones], &{&1, &1})
  end

  defp long_date(datetime) do
    case Gettext.get_locale() do
      "zh_CN" -> Calendar.strftime(datetime, "%Y年%-m月%-d日")
      _locale -> Calendar.strftime(datetime, "%b %-d, %Y")
    end
  end

  @spec normalize_format(String.t() | nil | term()) :: String.t()
  defp normalize_format(format) when format in @format_values, do: format
  defp normalize_format(_format), do: @default_format

  @spec normalize_timezone_value(String.t() | nil | term()) :: String.t()
  defp normalize_timezone_value(timezone) when is_binary(timezone) and timezone != "",
    do: timezone

  defp normalize_timezone_value(_timezone), do: @default_timezone

  @spec shift_for_display(DateTime.t(), String.t() | nil | term()) :: DateTime.t()
  defp shift_for_display(datetime, timezone) do
    timezone = normalize_timezone_value(timezone)

    case DateTime.shift_zone(datetime, timezone, Tz.TimeZoneDatabase) do
      {:ok, shifted} ->
        shifted

      {:error, :time_zone_not_found} ->
        DateTime.shift_zone!(datetime, @default_timezone, Calendar.UTCOnlyTimeZoneDatabase)
    end
  end

  @spec timezone_label(DateTime.t()) :: String.t()
  defp timezone_label(%DateTime{time_zone: @default_timezone}), do: "UTC"
  defp timezone_label(%DateTime{time_zone: timezone}), do: timezone

  @spec missing_label([format_opt()]) :: String.t()
  defp missing_label(opts) do
    case Keyword.fetch(opts, :missing_label) do
      {:ok, label} when is_binary(label) -> label
      _missing_or_invalid -> @default_missing_label
    end
  end
end
