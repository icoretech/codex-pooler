defmodule CodexPooler.Gateway.Transports.Websocket.OwnerErrorVocabulary do
  @moduledoc false

  # Dependency-free vocabulary leaf. The owner contract sources its
  # `@owner_errors` list here, and the diagnostic taxonomy derives its
  # compile-time cleartext allowlist from the same list, so neither module
  # needs a compile-connected reference to the other.

  @owner_errors [
    :owner_unavailable,
    :stale_owner,
    :owner_forward_timeout,
    :owner_crashed,
    :owner_drained,
    :duplicate_downstream,
    :stale_downstream,
    :owner_forwarding_disabled,
    :owner_busy,
    :client_disconnected,
    :upstream_stream_error,
    :upstream_websocket_terminal_delivery_timeout
  ]

  @owner_error_codes Enum.map(@owner_errors, &Atom.to_string/1)

  @spec owner_errors() :: [atom()]
  def owner_errors, do: @owner_errors

  @spec owner_error_codes() :: [String.t()]
  def owner_error_codes, do: @owner_error_codes
end
