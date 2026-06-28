defmodule CodexPooler.Gateway.ErrorSanitizer do
  @moduledoc false

  alias CodexPooler.Gateway.Runtime.Finalization.Metadata

  @spec safe_reason(term()) :: String.t()
  defdelegate safe_reason(reason), to: Metadata
end
