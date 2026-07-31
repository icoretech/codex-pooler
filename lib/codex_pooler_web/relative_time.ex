defmodule CodexPoolerWeb.RelativeTime do
  @moduledoc false

  @spec seconds_until(DateTime.t(), DateTime.t()) :: integer()
  def seconds_until(%DateTime{} = target, %DateTime{} = now) do
    DateTime.diff(target, now, :second)
  end
end
