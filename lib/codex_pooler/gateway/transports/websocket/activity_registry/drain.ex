defmodule CodexPooler.Gateway.Transports.Websocket.ActivityRegistry.Drain do
  @moduledoc false

  @type entry :: %{
          required(:token) => reference(),
          required(:kind) => :direct | :proxy,
          required(:pid) => pid(),
          required(:status) => :active | {:finished, :completed | :aborted | :failed}
        }

  @spec begin(nil | map(), map()) :: {map(), reference(), [map()]}
  def begin(nil, activities) do
    epoch = make_ref()
    drain = %{epoch: epoch, tokens: activities |> Map.keys() |> MapSet.new(), outcomes: %{}}
    {drain, epoch, entries(drain, activities)}
  end

  def begin(drain, activities), do: {drain, drain.epoch, entries(drain, activities)}

  @spec record_outcome(nil | map(), reference(), map(), atom()) :: nil | map()
  def record_outcome(nil, _token, _entry, _outcome), do: nil

  def record_outcome(drain, token, entry, outcome) do
    if MapSet.member?(drain.tokens, token) do
      put_in(drain.outcomes[token], %{entry: entry, outcome: outcome})
    else
      drain
    end
  end

  @spec outcome(nil | map(), reference()) :: {:finished, atom()} | :unknown
  def outcome(nil, _token), do: :unknown

  def outcome(drain, token) do
    case Map.get(drain.outcomes, token) do
      %{outcome: outcome} -> {:finished, outcome}
      nil -> :unknown
    end
  end

  defp entries(drain, activities) do
    Enum.map(drain.tokens, fn token ->
      case Map.get(activities, token) do
        nil ->
          %{entry: entry, outcome: outcome} = Map.fetch!(drain.outcomes, token)
          %{token: token, kind: entry.kind, pid: entry.pid, status: {:finished, outcome}}

        entry ->
          %{token: token, kind: entry.kind, pid: entry.pid, status: :active}
      end
    end)
  end
end
