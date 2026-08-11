defmodule CodexPooler.AgentV2ContractFixture do
  @moduledoc false

  @fixture_path Path.expand(
                  "../fixtures/codex/c9c6c0daa994109cec50fddcb57d076fdf9e738c/agent-v2-handoffs.json",
                  __DIR__
                )
  @external_resource @fixture_path
  @fixture @fixture_path |> File.read!() |> Jason.decode!()

  @spec load!() :: map()
  def load!, do: @fixture

  @spec handoff!(atom() | String.t()) :: map()
  def handoff!(name) do
    @fixture
    |> get_in(["v2", "handoffs", to_string(name), "item"])
    |> case do
      %{} = item -> item
      nil -> raise KeyError, key: name, term: get_in(@fixture, ["v2", "handoffs"])
    end
  end

  @spec v1_handoff!() :: map()
  def v1_handoff!, do: get_in(@fixture, ["v1", "ordinary_user_role_handoff", "item"])

  @spec plaintext_handoff!() :: map()
  def plaintext_handoff!, do: get_in(@fixture, ["plaintext", "handoff", "item"])

  @spec plaintext_function_call!() :: map()
  def plaintext_function_call!, do: get_in(@fixture, ["plaintext", "function_call"])

  @spec namespace_tools!() :: [map()]
  def namespace_tools!, do: get_in(@fixture, ["v2", "namespace_tools"])

  @spec final_answer!() :: String.t()
  def final_answer!, do: get_in(@fixture, ["final_answer", "text"])
end
