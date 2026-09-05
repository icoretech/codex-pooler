defmodule CodexPooler.Gateway.Transports.NativeCompactionAliasTest do
  use CodexPooler.DataCase, async: false
  import CodexPooler.PoolerFixtures
  alias CodexPooler.Gateway.Persistence.{BridgeSessionAlias, CodexSession, SessionContinuity}
  alias CodexPooler.Repo

  test "standalone alias proof requires active unexpired same authenticated scope" do
    %{pool: pool, api_key: key} = active_api_key_fixture()
    %{pool: other_pool, api_key: other_key} = active_api_key_fixture()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    session =
      Repo.insert!(%CodexSession{
        pool_id: pool.id,
        api_key_id: key.id,
        session_key: "synthetic-alias-#{System.unique_integer([:positive])}",
        status: "active",
        created_at: now,
        updated_at: now
      })

    alias_row =
      Repo.insert!(%BridgeSessionAlias{
        pool_id: pool.id,
        api_key_id: key.id,
        codex_session_id: session.id,
        alias_kind: "previous_response_id",
        alias_hash: :crypto.hash(:sha256, "resp_synthetic_alias"),
        alias_preview: "synthetic",
        status: "active",
        expires_at: DateTime.add(now, 60, :second),
        last_seen_at: now,
        created_at: now,
        updated_at: now
      })

    auth = %{pool: pool, api_key: key}

    assert SessionContinuity.previous_response_session_id(auth, "resp_synthetic_alias", now) ==
             session.id

    assert is_nil(SessionContinuity.previous_response_session_id(auth, "resp_missing", now))

    assert is_nil(
             SessionContinuity.previous_response_session_id(
               %{pool: other_pool, api_key: other_key},
               "resp_synthetic_alias",
               now
             )
           )

    assert is_nil(
             SessionContinuity.previous_response_session_id(
               %{pool: pool, api_key: other_key},
               "resp_synthetic_alias",
               now
             )
           )

    assert is_nil(
             SessionContinuity.previous_response_session_id(
               auth,
               "resp_synthetic_alias",
               DateTime.add(now, 61, :second)
             )
           )

    Repo.update!(Ecto.Changeset.change(alias_row, status: "expired"))

    assert is_nil(
             SessionContinuity.previous_response_session_id(auth, "resp_synthetic_alias", now)
           )
  end
end
