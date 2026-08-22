defmodule CodexPooler.Gateway.Persistence.SessionAliasDeadlockRetryTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import Ecto.Query

  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{BridgeOwnerLease, BridgeSessionAlias, SessionContinuity}
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Pools.Pool
  alias CodexPooler.Repo
  alias Ecto.Adapters.SQL.Sandbox

  test "continuity registration retries a PostgreSQL deadlock" do
    fixture = committed_fixture!()

    try do
      deadlock_trigger = install_deadlock_trigger!(:once)

      try do
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
      after
        remove_deadlock_trigger!(deadlock_trigger)
      end
    after
      cleanup_fixture!(fixture)
    end
  end

  test "continuity registration returns a bounded error after deadlock retry exhaustion" do
    fixture = committed_fixture!()

    try do
      deadlock_trigger = install_deadlock_trigger!(:always)

      try do
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
      after
        remove_deadlock_trigger!(deadlock_trigger)
      end
    after
      cleanup_fixture!(fixture)
    end
  end

  test "continuity registration does not retry another PostgreSQL error" do
    fixture = committed_fixture!()

    try do
      error_trigger = install_error_trigger!(:unique_violation)

      try do
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
      after
        remove_deadlock_trigger!(error_trigger)
      end
    after
      cleanup_fixture!(fixture)
    end
  end

  defp committed_fixture! do
    Sandbox.unboxed_run(Repo, fn ->
      %{user: owner} = bootstrap_owner_fixture()
      pool = pool_fixture(%{created_by_user_id: owner.id})
      %{api_key: api_key} = active_api_key_fixture(pool, %{created_by_user_id: owner.id})
      auth = %{pool: pool, api_key: api_key}
      turn_state = "alias-deadlock-#{System.unique_integer([:positive, :monotonic])}"

      assert {:ok, session} =
               Gateway.start_codex_session(auth, request_options(turn_state))

      %{auth: auth, pool: pool, session: session, turn_state: turn_state}
    end)
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

    Sandbox.unboxed_run(Repo, fn ->
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

    %{function: function, sequence: sequence, trigger: trigger}
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

  defp remove_deadlock_trigger!(names) do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.query!("DROP TRIGGER IF EXISTS #{names.trigger} ON bridge_session_aliases")
      Repo.query!("DROP FUNCTION IF EXISTS #{names.function}()")
      Repo.query!("DROP SEQUENCE IF EXISTS #{names.sequence}")
    end)
  end

  defp cleanup_fixture!(fixture) do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.delete_all(from pool in Pool, where: pool.id == ^fixture.pool.id)
    end)
  end
end
