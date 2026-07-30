defmodule CodexPooler.Gateway.Persistence.StatusVocabularyTest do
  use ExUnit.Case, async: true

  alias CodexPooler.Gateway.Persistence.{
    BridgeOwnerLease,
    BridgeSessionAlias,
    CodexSession,
    CodexTurn,
    RoutingCircuitState
  }

  alias CodexPooler.Gateway.Persistence.StatusVocabulary.{
    Circuit,
    OwnerLease,
    Session,
    SessionAlias,
    Turn
  }

  test "persistence schemas delegate to dependency-free status vocabularies" do
    assert Session.statuses() == CodexSession.statuses()
    assert Session.reconnectable_statuses() == CodexSession.reconnectable_statuses()

    assert helper_values(Session, [:active_status, :interrupted_status, :closed_status]) ==
             CodexSession.statuses()

    assert Turn.statuses() == CodexTurn.statuses()

    assert helper_values(Turn, [
             :in_progress_status,
             :succeeded_status,
             :failed_status,
             :interrupted_status
           ]) == CodexTurn.statuses()

    assert OwnerLease.statuses() == BridgeOwnerLease.statuses()

    assert helper_values(OwnerLease, [:active_status, :expired_status, :released_status]) ==
             BridgeOwnerLease.statuses()

    assert SessionAlias.alias_kinds() == BridgeSessionAlias.alias_kinds()
    assert SessionAlias.statuses() == BridgeSessionAlias.statuses()

    assert helper_values(SessionAlias, [:active_status, :expired_status, :replaced_status]) ==
             BridgeSessionAlias.statuses()

    assert Circuit.statuses() == RoutingCircuitState.statuses()

    assert helper_values(Circuit, [:closed_status, :open_status, :half_open_status]) ==
             RoutingCircuitState.statuses()
  end

  defp helper_values(module, helpers) do
    Enum.map(helpers, &apply(module, &1, []))
  end
end
