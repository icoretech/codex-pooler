defmodule CodexPooler.Gateway.Persistence.SessionAliasDeadlockRetryTest do
  @moduledoc """
  Locks the deadlock-retry contract of continuity registration.

  Every fixture here commits outside the sandbox, and one of them is a `BEFORE INSERT`
  trigger on the shared `bridge_session_aliases` table that raises `40P01` on every insert.
  Its teardown is therefore registered with `register_unboxed_cleanup!/1` rather than scoped
  in `try/after`: a scoped block runs only while the test process is alive, so an ExUnit
  timeout kill or an exit signal from a linked helper skips it, and a leaked trigger then
  makes every later insert into that table fail, in any file of the same `mix test`
  invocation.
  """
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures, only: [delete_user_graph!: 1]
  import CodexPooler.PoolerFixtures
  import CodexPooler.UnboxedFixture
  import Ecto.Query

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{BridgeOwnerLease, BridgeSessionAlias, SessionContinuity}
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  test "continuity registration retries a PostgreSQL deadlock" do
    fixture = committed_fixture!()
    deadlock_trigger = install_deadlock_trigger!(:once)

    assert :ok =
             Sandbox.unboxed_run(Repo, fn ->
               SessionContinuity.register_codex_session_continuity(
                 fixture.session,
                 %{"type" => "response.create"},
                 %{"id" => "resp_deadlock_retry"},
                 request_options(fixture.turn_state)
                 |> RequestOptions.put_continuity(response_id: "resp_deadlock_retry")
               )
             end)

    assert response_alias_count(fixture, "resp_deadlock_retry") == 1
    assert active_lease_count(fixture) == 1
    assert trigger_attempt_count(deadlock_trigger) == 2
  end

  test "continuity registration returns a bounded error after deadlock retry exhaustion" do
    fixture = committed_fixture!()
    deadlock_trigger = install_deadlock_trigger!(:always)

    assert {:error, :continuity_deadlock} =
             Sandbox.unboxed_run(Repo, fn ->
               SessionContinuity.register_codex_session_continuity(
                 fixture.session,
                 %{"type" => "response.create"},
                 %{"id" => "resp_deadlock_exhausted"},
                 request_options(fixture.turn_state)
               )
             end)

    assert response_alias_count(fixture, "resp_deadlock_exhausted") == 0
    assert active_lease_count(fixture) == 1
    assert trigger_attempt_count(deadlock_trigger) == 2
  end

  test "continuity registration does not retry another PostgreSQL error" do
    fixture = committed_fixture!()
    error_trigger = install_error_trigger!(:unique_violation)

    assert_raise Postgrex.Error, ~r/unique_violation/, fn ->
      Sandbox.unboxed_run(Repo, fn ->
        SessionContinuity.register_codex_session_continuity(
          fixture.session,
          %{"type" => "response.create"},
          %{"id" => "resp_non_deadlock"},
          request_options(fixture.turn_state)
        )
      end)
    end

    assert response_alias_count(fixture, "resp_non_deadlock") == 0
    assert active_lease_count(fixture) == 1
    assert trigger_attempt_count(error_trigger) == 1
  end

  # The pool is the whole committed graph: `api_keys`, `codex_sessions`, `bridge_owner_leases`
  # and `bridge_session_aliases` all cascade from it. Nothing here needs an owner, so the
  # fixture no longer completes the `platform_bootstrap_state` singleton for a shared
  # `owner@example.com` -- `created_by_user_id` is nullable, and a committed bootstrap owner
  # is a shared key that outlives this file and breaks absolute user counts elsewhere.
  # The cleanup is keyed on the slug and registered before the commit, so it also covers a
  # fixture that fails partway through.
  # `api_key_fixture/2` also commits an instance owner of its own when the instance has none,
  # and that user is outside the pool's cascade, so the cleanup below removes it as the key's
  # creator, with its membership and audit rows: deleting only the pool would leave a `users`
  # row behind and break the suites that assert absolute user counts.
  defp committed_fixture! do
    slug = "alias-deadlock-#{System.unique_integer([:positive, :monotonic])}"
    register_unboxed_cleanup!(fn -> delete_committed_fixture!(slug) end)

    run_unboxed(fn ->
      pool = pool_fixture(%{slug: slug})
      %{api_key: api_key} = active_api_key_fixture(pool, %{})
      auth = %{pool: pool, api_key: api_key}

      assert {:ok, session} =
               Gateway.start_codex_session(auth, request_options(slug))

      %{auth: auth, pool: pool, session: session, turn_state: slug}
    end)
  end

  defp delete_committed_fixture!(slug) do
    creator_ids =
      Repo.all(
        from api_key in "api_keys",
          join: pool in "pools",
          on: pool.id == api_key.pool_id,
          where: pool.slug == ^slug and not is_nil(api_key.created_by_user_id),
          distinct: true,
          select: type(api_key.created_by_user_id, Ecto.UUID)
      )

    Repo.delete_all(from pool in Pool, where: pool.slug == ^slug)
    delete_user_graph!(creator_ids)
    :ok
  end

  defp request_options(turn_state) do
    RequestOptions.for_websocket(%{
      accepted_turn_state: turn_state,
      owner_instance_id: Atom.to_string(node())
    })
  end

  defp install_deadlock_trigger!(mode) when mode in [:once, :always] do
    condition = if mode == :once, do: "currval('__SEQUENCE__') = 1", else: "true"

    install_trigger!(
      condition,
      "synthetic alias deadlock",
      "40P01"
    )
  end

  defp install_error_trigger!(:unique_violation) do
    install_trigger!("true", "synthetic alias unique violation", "23505")
  end

  defp install_trigger!(condition, message, code) do
    unique = System.unique_integer([:positive, :monotonic])
    sequence = "alias_deadlock_sequence_#{unique}"
    function = "alias_deadlock_function_#{unique}"
    trigger = "alias_deadlock_trigger_#{unique}"
    condition = String.replace(condition, "__SEQUENCE__", sequence)
    names = %{function: function, sequence: sequence, trigger: trigger}

    # Registered before the objects exist: the drops are `IF EXISTS`, so this also covers a
    # creation that fails partway through.
    register_unboxed_cleanup!(fn -> remove_trigger!(names) end)

    run_unboxed(fn ->
      Repo.query!("CREATE SEQUENCE #{sequence} START 1")

      Repo.query!("""
      CREATE FUNCTION #{function}() RETURNS trigger AS $$
      BEGIN
        PERFORM nextval('#{sequence}');
        IF #{condition} THEN
          RAISE EXCEPTION '#{message}' USING ERRCODE = '#{code}';
        END IF;
        RETURN NULL;
      END;
      $$ LANGUAGE plpgsql
      """)

      Repo.query!("""
      CREATE TRIGGER #{trigger}
      BEFORE INSERT ON bridge_session_aliases
      FOR EACH STATEMENT EXECUTE FUNCTION #{function}()
      """)
    end)

    names
  end

  defp trigger_attempt_count(names) do
    Sandbox.unboxed_run(Repo, fn ->
      %{rows: [[last_value]]} = Repo.query!("SELECT last_value FROM #{names.sequence}")
      last_value
    end)
  end

  defp response_alias_count(fixture, response_id) do
    alias_hash = :crypto.hash(:sha256, response_id)

    Sandbox.unboxed_run(Repo, fn ->
      Repo.aggregate(
        from(alias_record in BridgeSessionAlias,
          where:
            alias_record.codex_session_id == ^fixture.session.id and
              alias_record.alias_kind == "previous_response_id" and
              alias_record.alias_hash == ^alias_hash and alias_record.status == "active"
        ),
        :count
      )
    end)
  end

  defp active_lease_count(fixture) do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.aggregate(
        from(lease in BridgeOwnerLease,
          where: lease.codex_session_id == ^fixture.session.id and lease.status == "active"
        ),
        :count
      )
    end)
  end

  defp remove_trigger!(names) do
    Repo.query!("DROP TRIGGER IF EXISTS #{names.trigger} ON bridge_session_aliases")
    Repo.query!("DROP FUNCTION IF EXISTS #{names.function}()")
    Repo.query!("DROP SEQUENCE IF EXISTS #{names.sequence}")
  end
end
