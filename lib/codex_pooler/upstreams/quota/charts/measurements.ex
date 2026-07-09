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

  @spec apply_weekly_cap(map(), [map()]) :: map()
  def apply_weekly_cap(primary, weekly_items) do
    case matching_weekly_cap(primary, weekly_items) do
      %{remaining: weekly_remaining} when not is_nil(weekly_remaining) ->
        capped_remaining = decimal_min(primary.remaining, weekly_remaining)
        capacity = primary.capacity
        used = used(capacity, capped_remaining)
        percentages = percentages(capped_remaining, capacity)

        primary
        |> Map.merge(%{remaining: capped_remaining, used: used})
        |> Map.merge(percentages)

      _weekly ->
        primary
    end
  end

  @spec sum([map()], atom()) :: Decimal.t() | nil
  def sum(items, field) do
    sum_known(items, field)
  end

  @spec sum_known([map()], atom()) :: Decimal.t() | nil
  def sum_known(items, field) do
    values = items |> Enum.map(&Map.get(&1, field)) |> Enum.reject(&is_nil/1)

    if values == [] or length(values) != length(items) do
      nil
    else
      Enum.reduce(values, Decimal.new(0), &Decimal.add/2)
    end
  end

  @spec items_used_percent([map()]) :: Decimal.t() | nil
  def items_used_percent(items) do
    capacity = sum_known(items, :capacity)
    remaining = sum_known(items, :remaining)

    if is_nil(capacity) or is_nil(remaining) or Decimal.compare(capacity, Decimal.new(0)) != :gt do
      nil
    else
      used_percent(remaining, capacity, nil)
    end
  end

  defp matching_weekly_cap(primary, weekly_items) do
    Enum.find(weekly_items, fn weekly ->
      not is_nil(primary.window_assignment_id) and
        primary.window_assignment_id == item_assignment_id(weekly)
    end) ||
      Enum.find(weekly_items, fn weekly ->
        weekly.upstream_identity_id == primary.upstream_identity_id
      end)
  end

  defp item_assignment_id(item),
    do: Map.get(item, :window_assignment_id) || item.assignment_id

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

  defp percentages(remaining, capacity) do
    %{
      remaining_percent: remaining_percent(remaining, capacity, nil),
      used_percent: used_percent(remaining, capacity, nil)
    }
  end

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

  defp decimal_min(nil, value), do: value

  defp decimal_min(%Decimal{} = left, %Decimal{} = right) do
    if Decimal.compare(left, right) == :gt, do: right, else: left
  end
end
