defmodule CodexPooler.Admin.Stats.EmptyStates do
  @moduledoc false

  @spec build([map()], [map()], [map()]) :: [map()]
  def build(requests, settlements, assignments) do
    []
    |> maybe_empty(requests == [], :no_requests, "No requests in this range")
    |> maybe_empty(
      settlements == [],
      :no_usage,
      "No settled usage in this range"
    )
    |> maybe_empty(
      assignments == [],
      :no_upstreams,
      "No upstream assignments in this scope"
    )
    |> Enum.reverse()
  end

  defp maybe_empty(states, true, code, message), do: [%{code: code, message: message} | states]
  defp maybe_empty(states, false, _code, _message), do: states
end
