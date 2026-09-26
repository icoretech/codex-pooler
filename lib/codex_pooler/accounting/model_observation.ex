defmodule CodexPooler.Accounting.ModelObservation do
  @moduledoc "Bounded, versioned facts about provider model declarations on one attempt."

  alias CodexPooler.Accounting.Metadata

  @spec normalize(term(), String.t() | nil) :: map() | nil
  def normalize(%{"version" => 1, "coverage" => coverage} = observation, served_model)
      when coverage in ["full", "partial"] do
    conflict = if is_binary(served_model), do: observation["conflict"]
    first_conflicting = Metadata.bounded_model_identifier(observation["first_conflicting_model"])

    %{
      "version" => 1,
      "coverage" => coverage,
      "terminal_status" => terminal_status(observation["terminal_status"]),
      "terminal_model" => Metadata.bounded_model_identifier(observation["terminal_model"]),
      "first_conflicting_model" => if(conflict == true, do: first_conflicting),
      "conflict" => if(is_boolean(conflict), do: conflict)
    }
  end

  def normalize(_observation, _served_model), do: nil

  @spec conflict?(term()) :: boolean()
  def conflict?(%{"version" => 1, "conflict" => true}), do: true
  def conflict?(_observation), do: false

  defp terminal_status(status) when status in ~w(completed failed incomplete cancelled json), do: status
  defp terminal_status(_status), do: nil
end
