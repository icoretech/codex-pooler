defmodule CodexPooler.Gateway.Persistence.LockingContractTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.AccountsFixtures
  import CodexPooler.PoolerFixtures
  import Ecto.Query

  alias CodexPooler.Gateway.Payloads.RequestOptions

  alias CodexPooler.Gateway.Persistence.{
    BridgeOwnerLease,
    BridgeSessionAlias,
    CodexSession,
    CodexTurn,
    SessionContinuity
  }

  alias CodexPooler.Gateway.Runtime.Finalization.Interruption
  alias CodexPooler.Gateway.Websocket, as: Gateway

  describe "row lock contracts" do
    @tag :locking_contract_lock
    test "L01 start turn locks session" do
      %{auth: auth, session: session} = owner_session_fixture()
      request = request_fixture(auth, %{status: "in_progress", completed_at: nil})

      assert {:ok, %CodexTurn{}} =
               assert_for_update_lock(
                 "L01",
                 "TurnLifecycle.start_codex_turn/3",
                 "codex_sessions",
                 session.id,
                 fn ->
                   SessionContinuity.start_codex_turn(
                     session,
                     request,
                     RequestOptions.for_websocket(%{})
                   )
                 end
               )
    end

    @tag :locking_contract_lock
    test "L02 replacement locks session" do
      %{session: session} = owner_session_fixture()

      assert {:ok, %CodexSession{}} =
               assert_for_update_lock(
                 "L02",
                 "OwnerLease.replace_unavailable/2",
                 "codex_sessions",
                 session.id,
                 fn ->
                   SessionContinuity.replace_unavailable_owner_lease(
                     session,
                     request_options(owner_instance_id: "node-b")
                   )
                 end
               )
    end

    @tag :locking_contract_lock
    test "L03 renewal locks session before lease" do
      %{session: session, token: token} = owner_session_fixture()

      assert {:ok, %CodexSession{}} =
               assert_for_update_lock(
                 "L03",
                 "OwnerLease.renew_owner_token/3",
                 "codex_sessions",
                 session.id,
                 fn ->
                   SessionContinuity.renew_owner_token(
                     session.id,
                     token,
                     request_options(bridge_owner_lease_ttl_seconds: 120)
                   )
                 end
               )
    end

    @tag :locking_contract_lock
    test "L04 continuity registration locks session" do
      %{session: session} = owner_session_fixture()

      assert :ok =
               assert_for_update_lock(
                 "L04",
                 "SessionContinuity.register_codex_session_continuity/4",
                 "codex_sessions",
                 session.id,
                 fn ->
                   SessionContinuity.register_codex_session_continuity(
                     session,
                     %{},
                     %{"id" => "response-placeholder"},
                     request_options([])
                   )
                 end
               )
    end

    @tag :locking_contract_lock
    test "L05 session interrupt locks or noops" do
      %{session: session} = owner_session_fixture()

      assert {:ok, %{interrupted_turn_count: 0}} =
               assert_for_update_lock(
                 "L05",
                 "Interruption.interrupt_codex_session/2",
                 "codex_sessions",
                 session.id,
                 fn ->
                   Interruption.interrupt_codex_session(
                     session,
                     request_options(reconnect_window_seconds: 300)
                   )
                 end
               )
    end

    @tag :locking_contract_lock
    test "L06 turn interrupt locks or noops" do
      %{session: session} = owner_session_fixture()

      assert {:ok, %{interrupted_turn_count: 0}} =
               assert_for_update_lock(
                 "L06",
                 "Interruption.interrupt_codex_turn/2",
                 "codex_sessions",
                 session.id,
                 fn ->
                   Interruption.interrupt_codex_turn(
                     session,
                     request_options(
                       reconnect_window_seconds: 300,
                       request_id: "missing-turn"
                     )
                   )
                 end
               )
    end

    @tag :locking_contract_lock
    test "L07 owner recovery locks request" do
      %{auth: auth, session: session} = owner_session_fixture()
      request = request_fixture(auth)

      assert {:ok, %CodexTurn{}} =
               SessionContinuity.start_codex_turn(
                 session,
                 request,
                 RequestOptions.for_websocket(%{})
               )

      assert {:ok, %{interrupted_turn_count: 1}} =
               assert_for_update_lock(
                 "L07",
                 "Interruption.recover_owner_lifecycle_leftovers/3",
                 "requests",
                 request.id,
                 fn ->
                   Interruption.recover_owner_lifecycle_leftovers(
                     session,
                     :owner_crashed,
                     request_options(reconnect_window_seconds: 300)
                   )
                 end
               )
    end
  end

  describe "missing-row contracts" do
    @tag :locking_contract_pin
    test "L01 missing session still raises when starting a turn" do
      auth = auth_fixture()
      request = request_fixture(auth, %{status: "in_progress", completed_at: nil})
      missing_session = %CodexSession{id: Ecto.UUID.generate()}

      assert_raise Ecto.NoResultsError, fn ->
        SessionContinuity.start_codex_turn(
          missing_session,
          request,
          RequestOptions.for_websocket(%{})
        )
      end

      refute Repo.exists?(from turn in CodexTurn, where: turn.request_id == ^request.id)
    end

    @tag :locking_contract_pin
    test "L02 missing session still rolls replacement back as owner unavailable" do
      missing_session = %CodexSession{id: Ecto.UUID.generate()}
      lease_count = Repo.aggregate(BridgeOwnerLease, :count)

      assert {:error, :owner_unavailable} =
               SessionContinuity.replace_unavailable_owner_lease(
                 missing_session,
                 request_options(owner_instance_id: "node-b")
               )

      assert Repo.aggregate(BridgeOwnerLease, :count) == lease_count
    end

    @tag :locking_contract_pin
    test "L03 missing session still returns owner unavailable during renewal" do
      session_count = Repo.aggregate(CodexSession, :count)
      lease_count = Repo.aggregate(BridgeOwnerLease, :count)

      assert {:error, :owner_unavailable} =
               SessionContinuity.renew_owner_token(
                 Ecto.UUID.generate(),
                 Ecto.UUID.generate(),
                 request_options(bridge_owner_lease_ttl_seconds: 120)
               )

      assert Repo.aggregate(CodexSession, :count) == session_count
      assert Repo.aggregate(BridgeOwnerLease, :count) == lease_count
    end

    @tag :locking_contract_pin
    test "L04 missing session still raises during continuity registration" do
      missing_session = %CodexSession{id: Ecto.UUID.generate()}
      alias_count = Repo.aggregate(BridgeSessionAlias, :count)
      lease_count = Repo.aggregate(BridgeOwnerLease, :count)

      assert_raise Ecto.NoResultsError, fn ->
        SessionContinuity.register_codex_session_continuity(
          missing_session,
          %{},
          %{"id" => "response-placeholder"},
          request_options([])
        )
      end

      assert Repo.aggregate(BridgeSessionAlias, :count) == alias_count
      assert Repo.aggregate(BridgeOwnerLease, :count) == lease_count
    end

    @tag :locking_contract_pin
    test "L05 missing session interrupt still returns zero interrupted turns" do
      session_count = Repo.aggregate(CodexSession, :count)
      turn_count = Repo.aggregate(CodexTurn, :count)

      assert {:ok, %{interrupted_turn_count: 0}} =
               Interruption.interrupt_codex_session(
                 Ecto.UUID.generate(),
                 request_options(reconnect_window_seconds: 300)
               )

      assert Repo.aggregate(CodexSession, :count) == session_count
      assert Repo.aggregate(CodexTurn, :count) == turn_count
    end

    @tag :locking_contract_pin
    test "L06 missing session turn interrupt still returns zero interrupted turns" do
      session_count = Repo.aggregate(CodexSession, :count)
      turn_count = Repo.aggregate(CodexTurn, :count)

      assert {:ok, %{interrupted_turn_count: 0}} =
               Interruption.interrupt_codex_turn(
                 Ecto.UUID.generate(),
                 request_options(
                   reconnect_window_seconds: 300,
                   request_id: "missing-request"
                 )
               )

      assert Repo.aggregate(CodexSession, :count) == session_count
      assert Repo.aggregate(CodexTurn, :count) == turn_count
    end

    @tag :locking_contract_pin
    test "L07 missing request still follows the interrupted-turn fallback" do
      %{session: session} = owner_session_fixture()
      missing_request_id = Ecto.UUID.generate()

      {turn, result} =
        without_foreign_key_checks(fn ->
          turn = insert_dangling_turn!(session, missing_request_id)

          result =
            Interruption.recover_owner_lifecycle_leftovers(
              session,
              :owner_crashed,
              request_options(reconnect_window_seconds: 300)
            )

          {turn, result}
        end)

      assert {:ok, %{interrupted_turn_count: 1}} = result

      assert %CodexTurn{status: "interrupted", error_code: "client_disconnected"} =
               Repo.get!(CodexTurn, turn.id)

      assert %CodexSession{status: "interrupted"} = Repo.get!(CodexSession, session.id)

      refute Repo.exists?(
               from request in CodexPooler.Accounting.Request,
                 where: request.id == ^missing_request_id
             )
    end
  end

  defp auth_fixture do
    %{user: owner} = bootstrap_owner_fixture()
    pool = pool_fixture(%{created_by_user_id: owner.id})
    %{api_key: api_key} = active_api_key_fixture(pool, %{created_by_user_id: owner.id})
    %{pool: pool, api_key: api_key}
  end

  defp owner_session_fixture do
    auth = auth_fixture()

    assert {:ok, %CodexSession{} = session} =
             Gateway.start_codex_session(auth, %{
               accepted_turn_state:
                 "locking-contract-#{System.unique_integer([:positive, :monotonic])}",
               owner_instance_id: "node-a"
             })

    session = Repo.get!(CodexSession, session.id)
    %{auth: auth, session: session, token: session.owner_lease_token}
  end

  defp assert_for_update_lock(lock_id, caller, relation, id, fun) do
    handler_id = {__MODULE__, relation, System.unique_integer([:positive, :monotonic])}
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          query = Map.get(metadata, :query, "")

          if metadata[:repo] == Repo and metadata[:source] == relation and
               String.starts_with?(String.trim_leading(query), "SELECT") do
            send(parent, {handler_id, query, Map.get(metadata, :params, [])})
          end
        end,
        nil
      )

    try do
      result = fun.()
      signature = lock_signature(drain_queries(handler_id, []), relation, id)

      assert signature == %{
               operation: "SELECT",
               relation: relation,
               primary_key_fields: ["id"],
               parameter_count: 1,
               for_update?: true
             }

      report_lock_evidence(lock_id, caller, id, signature)

      result
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_queries(handler_id, queries) do
    receive do
      {^handler_id, query, params} ->
        drain_queries(handler_id, [{query, params} | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp lock_signature(queries, relation, id) do
    case Enum.find(queries, &primary_key_select?(&1, id)) do
      {query, params} ->
        %{
          operation: "SELECT",
          relation: relation,
          primary_key_fields: ["id"],
          parameter_count: length(params),
          for_update?: String.contains?(String.upcase(query), "FOR UPDATE")
        }

      nil ->
        flunk("caller did not emit the expected primary-key SELECT for #{relation}")
    end
  end

  defp primary_key_select?({query, params}, id) do
    Regex.match?(~r/\."id"\s*=\s*\$1/, query) and
      Enum.any?(params, &parameter_matches_id?(&1, id))
  end

  defp parameter_matches_id?(%Ecto.Query.Tagged{value: value}, id),
    do: parameter_matches_id?(value, id)

  defp parameter_matches_id?(value, id) do
    value == id or value == Ecto.UUID.dump!(id)
  end

  defp report_lock_evidence(lock_id, caller, id, signature) do
    if System.get_env("CODEX_POOLER_LOCKING_CONTRACT_REPORT") == "1" do
      IO.puts(
        "LOCKING_CONTRACT " <>
          Jason.encode!(%{
            lock_id: lock_id,
            caller: caller,
            primary_key_hash: :crypto.hash(:sha256, id) |> Base.encode16(case: :lower),
            sql_signature: signature,
            verdict: "pass"
          })
      )
    end
  end

  defp insert_dangling_turn!(session, missing_request_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %CodexTurn{
      codex_session_id: session.id,
      request_id: missing_request_id,
      turn_sequence: 1,
      transport_kind: "websocket",
      status: "in_progress",
      started_at: now,
      created_at: now,
      updated_at: now
    }
    |> Repo.insert!()
  end

  defp without_foreign_key_checks(fun) do
    Repo.query!("SET LOCAL session_replication_role = replica")

    try do
      fun.()
    after
      Repo.query!("SET LOCAL session_replication_role = origin")
    end
  end

  defp request_options(opts) do
    opts
    |> Map.new()
    |> RequestOptions.for_websocket()
  end
end
