defmodule CodexPooler.AgentV2ContractFixture do
  @moduledoc false

  @fixture_path Path.expand(
                  "../fixtures/codex/rust-v0.146.0/agent-v2-handoffs.json",
                  __DIR__
                )
  @external_resource @fixture_path
  @fixture @fixture_path |> File.read!() |> Jason.decode!()

  @spec load!() :: map()
  def load!, do: @fixture

  @spec handoff!(atom() | String.t()) :: map()
  def handoff!(name) do
    @fixture
    |> get_in(["handoffs", to_string(name), "item"])
    |> case do
      %{} = item -> item
      nil -> raise KeyError, key: name, term: @fixture["handoffs"]
    end
  end

  @spec final_answer!() :: String.t()
  def final_answer!, do: get_in(@fixture, ["final_answer", "text"])
end
