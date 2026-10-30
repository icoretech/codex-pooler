defmodule CodexPooler.Gateway.Transports.RetryAfter do
  @moduledoc false

  @private_key :codex_pooler_retry_after
  @max_delay_seconds 18_446_744_073_709_551_615

  @spec capture({:ok, Req.Response.t()} | {:error, term()}, integer()) :: {:ok, Req.Response.t()} | {:error, term()}
  def capture(result, now \\ System.monotonic_time(:millisecond))

  def capture({:ok, %Req.Response{} = response}, now) do
    {:ok, Req.Response.put_private(response, @private_key, advice(response, now))}
  end

  def capture(result, _now), do: result

  @spec header(Req.Response.t(), integer()) :: String.t() | nil
  def header(response, now \\ System.monotonic_time(:millisecond)) do
    case Req.Response.get_private(response, @private_key, :uncaptured) do
      :uncaptured -> render(advice(response, now), now)
      advice -> render(advice, now)
    end
  end

  @spec normalize(term()) :: String.t() | nil
  def normalize(value), do: value |> parse_value(0) |> render(0)

  defp advice(%Req.Response{status: status} = response, now) when status == 429 or status in 500..599 do
    case Req.Response.get_header(response, "retry-after") do
      [value | _rest] when is_binary(value) -> parse_value(value, now)
      _other -> nil
    end
  end

  defp advice(_response, _now), do: nil

  defp parse_value(value, now) when is_integer(value) and value >= 0 and value <= @max_delay_seconds,
    do: {:deadline, now + value * 1_000}

  defp parse_value(value, now) when is_binary(value) and byte_size(value) <= 128 do
    if String.valid?(value) and not String.match?(value, ~r/[\x00-\x1f\x7f]/),
      do: value |> String.trim(" ") |> parse(now)
  end

  defp parse_value(_value, _now), do: nil

  defp parse(value, now) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 and seconds <= @max_delay_seconds ->
        if String.match?(value, ~r/\A[0-9]+\z/), do: {:deadline, now + seconds * 1_000}

      _other ->
        parse_date(value)
    end
  end

  defp parse_date(value) do
    with {:ok, date} <- Req.Utils.parse_http_date(value),
         true <- Calendar.strftime(date, "%a, %d %b %Y %H:%M:%S GMT") == value do
      {:date, value}
    else
      _invalid -> nil
    end
  end

  defp render({:deadline, deadline}, now), do: Integer.to_string(div(max(deadline - now, 0) + 999, 1_000))
  defp render({:date, value}, _now), do: value
  defp render(nil, _now), do: nil
end
