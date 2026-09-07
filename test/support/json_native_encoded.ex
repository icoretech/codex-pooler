defmodule CodexPooler.JSONNativeEncoded do
  @moduledoc false
  @derive {JSON.Encoder, only: [:visible]}
  defstruct [:visible, :private]
end
