defmodule CodexPooler.Gateway.OpenAICompatibility.ChatCompletions.ToolArguments do
  @moduledoc false

  @type entry :: %{identity: map(), bytes: non_neg_integer(), digest: term()}
  @type t :: %{optional(non_neg_integer()) => entry()}

  # Final snapshots must extend the bytes already sent on the append-only Chat
  # stream. A count and incremental digest avoid retaining another argument copy.

  @spec register(t(), non_neg_integer(), map(), binary()) :: t()
  def register(tracked, index, item, value) do
    entry = %{identity: Map.take(item, ~w(type id call_id name)), bytes: 0, digest: :crypto.hash_init(:sha256)}
    tracked |> Map.put(index, entry) |> append(index, value)
  end

  @spec append(t(), non_neg_integer(), binary()) :: t()
  def append(tracked, index, value) do
    case Map.fetch(tracked, index) do
      {:ok, entry} -> Map.put(tracked, index, %{entry | bytes: entry.bytes + byte_size(value), digest: :crypto.hash_update(entry.digest, value)})
      :error -> tracked
    end
  end

  @spec reconcile(t(), non_neg_integer(), map(), binary()) :: {:ok, binary(), t()} | :unknown | {:error, :inconsistent_snapshot}
  def reconcile(tracked, index, identity, value) do
    case Map.fetch(tracked, index) do
      {:ok, entry} -> reconcile_entry(tracked, index, entry, identity, value)
      :error -> :unknown
    end
  end

  defp reconcile_entry(tracked, index, entry, identity, value) do
    emitted_bytes = entry.bytes

    with true <- matching_identity?(entry.identity, identity),
         :ok <- require_shared_identity(entry.identity, identity),
         true <- byte_size(value) >= entry.bytes,
         <<prefix::binary-size(^emitted_bytes), suffix::binary>> <- value,
         true <- :crypto.hash(:sha256, prefix) == :crypto.hash_final(entry.digest) do
      {:ok, suffix, append(tracked, index, suffix)}
    else
      :unknown -> :unknown
      _mismatch -> {:error, :inconsistent_snapshot}
    end
  end

  defp matching_identity?(original, snapshot) do
    Enum.all?(snapshot, fn {key, value} ->
      case Map.fetch(original, key) do
        {:ok, original_value} -> value == original_value
        :error -> true
      end
    end)
  end

  defp require_shared_identity(original, snapshot) do
    if Enum.any?(~w(id call_id), &(is_binary(original[&1]) and original[&1] != "" and original[&1] == snapshot[&1])),
      do: :ok,
      else: :unknown
  end
end
