defmodule CodexPooler.ObservatorySecrecy do
  @moduledoc """
  Assertions for keeping Observatory test observables sanitized and metadata-only.
  """

  @spec safe_observable?(iodata(), [String.t()]) :: boolean()
  def safe_observable?(observables, protected_values) do
    rendered = IO.iodata_to_binary(observables)
    Enum.all?(protected_values, &(not String.contains?(rendered, &1)))
  end
end
