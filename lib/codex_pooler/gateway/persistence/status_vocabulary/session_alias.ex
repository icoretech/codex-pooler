defmodule CodexPooler.Gateway.Persistence.StatusVocabulary.SessionAlias do
  @moduledoc false

  @alias_kinds ~w(turn_state previous_response_id session_header canonical_session_key)
  @statuses ~w(active expired replaced)

  @type alias_kind :: String.t()
  @type status :: String.t()

  @spec alias_kinds() :: [alias_kind()]
  def alias_kinds, do: @alias_kinds

  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @spec active_status() :: status()
  def active_status, do: "active"

  @spec expired_status() :: status()
  def expired_status, do: "expired"

  @spec replaced_status() :: status()
  def replaced_status, do: "replaced"
end
