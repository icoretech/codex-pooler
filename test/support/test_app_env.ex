defmodule CodexPooler.TestAppEnv do
  @moduledoc """
  `:codex_pooler` application env a test changes and puts back the way it found it.
  """

  @doc """
  Registers with `on_exit` the restore of `key` as it is now, and returns its current value, or
  `default` when the key is absent.

  Call it before the first `Application.put_env/3` of the key, so a test that dies before its own
  cleanup still puts the env back. An absent key is deleted on exit, never written back as
  `default` or `nil`.
  """
  @spec restore_on_exit(atom(), term()) :: term()
  def restore_on_exit(key, default \\ []) when is_atom(key) do
    previous = Application.fetch_env(:codex_pooler, key)
    ExUnit.Callbacks.on_exit(fn -> restore(key, previous) end)

    case previous do
      {:ok, value} -> value
      :error -> default
    end
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:codex_pooler, key, value)
  defp restore(key, :error), do: Application.delete_env(:codex_pooler, key)
end
