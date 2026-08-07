defmodule CodexPooler.Upstreams.Quota.Charts.Measurements do
  @moduledoc false

  alias CodexPooler.Upstreams.Quota

  @spec for_window(Quota.AccountQuotaWindow.t()) :: map()
  def for_window(%Quota.AccountQuotaWindow{} = window) do
    remaining = remaining(window)
    capacity = capacity(window, remaining)
    used = used(capacity, remaining)

    %{
      remaining: remaining,
      capacity: capacity,
      used: used,
      used_percent: used_percent(remaining, capacity, window.used_percent),
      remaining_percent: remaining_percent(remaining, capacity, window.used_percent)
    }
  end

  defp remaining(%Quota.AccountQuotaWindow{
         active_limit: active_limit,
         credits: 0,
         used_percent: %Decimal{} = used_percent
       })
       when active_limit in [nil, 0] do
    if Decimal.compare(used_percent, Decimal.new(100)) == :lt, do: nil, else: Decimal.new(0)
  end

  defp remaining(%Quota.AccountQuotaWindow{credits: credits}) when is_integer(credits) do
    credits |> Decimal.new() |> decimal_non_negative()
  end

  defp remaining(%Quota.AccountQuotaWindow{
         active_limit: active_limit,
         used_percent: %Decimal{} = used_percent
       })
       when is_integer(active_limit) do
    active_limit
    |> Decimal.new()
    |> Decimal.mult(Decimal.sub(Decimal.new(100), used_percent))
    |> Decimal.div(Decimal.new(100))
    |> decimal_non_negative()
  end

  defp remaining(%Quota.AccountQuotaWindow{used_percent: %Decimal{} = used_percent}) do
    if Decimal.compare(used_percent, Decimal.new(100)) != :lt, do: Decimal.new(0), else: nil
  end

  defp remaining(%Quota.AccountQuotaWindow{}), do: nil

  defp capacity(%Quota.AccountQuotaWindow{active_limit: active_limit}, _remaining)
       when is_integer(active_limit) and active_limit > 0 do
    active_limit |> Decimal.new() |> decimal_non_negative()
  end

  defp capacity(%Quota.AccountQuotaWindow{used_percent: %Decimal{} = used_percent}, remaining)
       when not is_nil(remaining) do
    cond do
      Decimal.compare(used_percent, Decimal.new(0)) != :gt ->
        remaining

      Decimal.compare(used_percent, Decimal.new(100)) == :lt ->
        remaining
        |> Decimal.div(Decimal.sub(Decimal.new(1), Decimal.div(used_percent, Decimal.new(100))))
        |> decimal_non_negative()

      true ->
        nil
    end
  end

  defp capacity(%Quota.AccountQuotaWindow{}, _remaining), do: nil

  defp used(nil, _remaining), do: nil
  defp used(_capacity, nil), do: nil

  defp used(capacity, remaining) do
    capacity
    |> Decimal.sub(remaining)
    |> decimal_non_negative()
  end

  defp used_percent(_remaining, _capacity, %Decimal{} = used_percent) do
    used_percent |> decimal_non_negative() |> decimal_clamp_percent()
  end

  defp used_percent(remaining, capacity, _used_percent)
       when not is_nil(remaining) and not is_nil(capacity) do
    if Decimal.compare(capacity, Decimal.new(0)) == :gt do
      capacity
      |> Decimal.sub(remaining)
      |> decimal_non_negative()
      |> Decimal.mult(Decimal.new(100))
      |> Decimal.div(capacity)
      |> decimal_clamp_percent()
    else
      Decimal.new(0)
    end
  end

  defp used_percent(_remaining, _capacity, _used_percent), do: nil

  defp remaining_percent(remaining, capacity, _used_percent)
       when not is_nil(remaining) and not is_nil(capacity) do
    if Decimal.compare(capacity, Decimal.new(0)) == :gt do
      remaining
      |> Decimal.mult(Decimal.new(100))
      |> Decimal.div(capacity)
      |> decimal_clamp_percent()
    else
      Decimal.new(0)
    end
  end

  defp remaining_percent(nil, nil, %Decimal{} = used_percent) do
    if Decimal.compare(used_percent, Decimal.new(0)) == :gt do
      Decimal.new(100)
      |> Decimal.sub(used_percent)
      |> decimal_clamp_percent()
    end
  end

  defp remaining_percent(%Decimal{} = remaining, nil, _used_percent) do
    if Decimal.compare(remaining, Decimal.new(0)) == :gt, do: nil, else: Decimal.new(0)
  end

  defp remaining_percent(_remaining, _capacity, %Decimal{} = used_percent) do
    Decimal.new(100)
    |> Decimal.sub(used_percent)
    |> decimal_clamp_percent()
  end

  defp remaining_percent(_remaining, _capacity, _used_percent), do: nil

  defp decimal_non_negative(%Decimal{} = value) do
    if Decimal.compare(value, Decimal.new(0)) == :lt, do: Decimal.new(0), else: value
  end

  defp decimal_clamp_percent(%Decimal{} = value) do
    cond do
      Decimal.compare(value, Decimal.new(0)) == :lt -> Decimal.new(0)
      Decimal.compare(value, Decimal.new(100)) == :gt -> Decimal.new(100)
      true -> value
    end
  end
end
