defmodule CodexPooler.Gateway.RequestCompression.TokenCounter.RanksTest do
  use ExUnit.Case, async: false

  alias CodexPooler.Gateway.RequestCompression.TokenCounter.Ranks

  test "loads rank files from a CRLF checkout" do
    Enum.each(Ranks.supported_encodings(), fn encoding ->
      cache_key = {Ranks, :ranks, encoding}
      :persistent_term.erase(cache_key)

      assert {:ok, ranks} = Ranks.load(encoding)
      assert map_size(ranks) > 0

      :persistent_term.erase(cache_key)
    end)
  end
end
