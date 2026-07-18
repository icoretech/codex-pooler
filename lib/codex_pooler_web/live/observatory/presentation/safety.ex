defmodule CodexPoolerWeb.Observatory.Presentation.Safety do
  @moduledoc false

  @max_text_length 80
  @forbidden_terms ["pool", "upstream", "operator"]
  @failure_labels %{
    "rate_limited" => "Rate limited",
    "authentication" => "Authentication issue",
    "timeout" => "Timed out",
    "service_unavailable" => "Service unavailable",
    "invalid_request" => "Invalid request",
    "request_failed" => "Request failed"
  }
  @unavailable_trend %{label: "not available", tone: :neutral, direction: :unavailable}

  @spec sanitize_text(term(), term()) :: term()
  def sanitize_text(value, fallback) when is_binary(value) do
    case bounded_text(value, fallback) do
      value when is_binary(value) -> if forbidden?(value), do: fallback, else: value
      value -> value
    end
  end

  def sanitize_text(_value, fallback), do: fallback

  @spec sanitize_code(term()) :: binary() | nil
  def sanitize_code(value) do
    case bounded_text(value, nil) do
      code when is_binary(code) ->
        if code in Map.keys(@failure_labels) and not forbidden?(code),
          do: code,
          else: "request_failed"

      _value ->
        nil
    end
  end

  @spec failure_label(term()) :: binary()
  def failure_label(value) do
    value
    |> sanitize_code()
    |> then(&Map.get(@failure_labels, &1, "Request failed"))
  end

  @spec trend(term(), atom()) :: map()
  def trend(value, unit) when is_map(value) do
    case finite_number(Map.get(value, :delta)) do
      nil -> @unavailable_trend
      delta -> trend_map(Float.round(delta, 1), unit)
    end
  end

  def trend(_value, _unit), do: @unavailable_trend

  defp bounded_text(value, fallback) when is_binary(value) do
    if String.valid?(value) do
      value =
        value
        |> String.replace(~r/[\r\n\t]+/u, " ")
        |> String.trim()
        |> String.slice(0, @max_text_length)

      if value == "", do: fallback, else: value
    else
      fallback
    end
  end

  defp bounded_text(_value, fallback), do: fallback

  defp forbidden?(value) do
    value = String.downcase(value)
    Enum.any?(@forbidden_terms, &String.contains?(value, &1))
  end

  defp finite_number(value) when is_integer(value), do: value * 1.0

  defp finite_number(value) when is_float(value) do
    if value > -1.0e308 and value < 1.0e308, do: value
  end

  defp finite_number(_value), do: nil

  defp trend_map(delta, unit) do
    direction = direction(delta)

    %{
      label: delta_label(delta, unit),
      tone: tone(direction),
      direction: direction
    }
  end

  defp direction(delta) when delta > 0, do: :up
  defp direction(delta) when delta < 0, do: :down
  defp direction(_delta), do: :flat

  defp tone(:up), do: :success
  defp tone(:down), do: :error
  defp tone(_direction), do: :neutral

  defp delta_label(delta, unit) do
    sign = if delta > 0, do: "+", else: if(delta < 0, do: "-", else: "")
    "#{sign}#{number_label(abs(delta))}#{unit_label(unit)}"
  end

  defp number_label(value) do
    value = Float.round(value, 1)
    if value == trunc(value), do: "#{trunc(value)}.0", else: to_string(value)
  end

  defp unit_label(:percentage_points), do: " pp"
  defp unit_label(:percent), do: "%"
  defp unit_label(_unit), do: "%"
end
