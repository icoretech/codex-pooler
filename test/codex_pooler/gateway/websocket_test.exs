defmodule CodexPooler.Gateway.WebsocketTest do
  use CodexPooler.DataCase, async: false

  import ExUnit.CaptureLog
  import CodexPooler.PoolerFixtures

  alias CodexPooler.Access
  alias CodexPooler.Gateway.Persistence.{BridgeSessionAlias, CodexSession}
  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Websocket, as: Gateway
  alias CodexPooler.Repo

  describe "retarget_websocket_owner_runtime/4" do
    setup do
      previous = Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)
      Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

      on_exit(fn ->
        cleanup_local_owner_sessions()

        case previous do
          nil -> Application.delete_env(:codex_pooler, :websocket_owner_forwarding_enabled)
          value -> Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, value)
        end
      end)

      key = active_api_key_fixture()
      {:ok, auth} = Access.authenticate_authorization_header(key.authorization)

      %{api_key: key.api_key, auth: auth}
    end

    test "returns the current runtime unchanged when the frame has no previous response alias", %{
      auth: auth
    } do
      {:ok, runtime} = owner_runtime(auth, "owner-runtime-no-alias")

      assert {:ok, ^runtime} =
               Gateway.retarget_websocket_owner_runtime(auth, runtime, %{
                 "type" => "response.create"
               })
    end

    test "returns the current runtime unchanged when the frame alias targets the same session", %{
      api_key: api_key,
      auth: auth
    } do
      {:ok, runtime} = owner_runtime(auth, "owner-runtime-same-session")
      previous_response_id = previous_response_id("same")
      register_previous_response_alias!(runtime.codex_session, api_key, previous_response_id)

      assert {:ok, ^runtime} =
               Gateway.retarget_websocket_owner_runtime(auth, runtime, %{
                 "type" => "response.create",
                 "previous_response_id" => previous_response_id
               })
    end

    test "attaches the authorized different-session owner runtime before returning it", %{
      api_key: api_key,
      auth: auth
    } do
      {:ok, current_runtime} = owner_runtime(auth, "owner-runtime-current")

      {:ok, target_session} =
        Gateway.start_codex_session(auth, owner_opts("owner-runtime-target"))

      target_session = Repo.get!(CodexSession, target_session.id)
      previous_response_id = previous_response_id("target")
      register_previous_response_alias!(target_session, api_key, previous_response_id)

      assert {:ok, retargeted_runtime} =
               Gateway.retarget_websocket_owner_runtime(auth, current_runtime, %{
                 "type" => "response.create",
                 "previous_response_id" => previous_response_id
               })

      assert retargeted_runtime.codex_session.id == target_session.id
      assert retargeted_runtime.codex_session.id != current_runtime.codex_session.id
      assert retargeted_runtime.websocket_owner_lease_token == target_session.owner_lease_token
      assert is_map(retargeted_runtime.websocket_owner_downstream)
      assert retargeted_runtime.websocket_owner_downstream.pid == self()
      assert is_boolean(retargeted_runtime.websocket_owner_active_turn_reconnect?)
      assert {:ok, _owner_pid} = WebsocketOwnerSession.lookup(target_session.id)
      assert {:ok, _owner_pid} = WebsocketOwnerSession.lookup(current_runtime.codex_session.id)
    end

    test "uses backend frame turn-state to attach a different-session owner runtime", %{
      auth: auth
    } do
      {:ok, current_runtime} = owner_runtime(auth, "owner-runtime-turn-state-current")
      target_turn_state = owner_turn_state("owner-runtime-turn-state-target")

      {:ok, target_session} =
        Gateway.start_codex_session(auth, %{accepted_turn_state: target_turn_state})

      target_session = Repo.get!(CodexSession, target_session.id)

      assert {:ok, retargeted_runtime} =
               Gateway.retarget_websocket_owner_runtime(auth, current_runtime, %{
                 "type" => "response.create",
                 "client_metadata" => %{"x-codex-turn-state" => target_turn_state}
               })

      assert retargeted_runtime.codex_session.id == target_session.id
      assert retargeted_runtime.codex_session.id != current_runtime.codex_session.id
      assert retargeted_runtime.websocket_owner_lease_token == target_session.owner_lease_token
      assert is_map(retargeted_runtime.websocket_owner_downstream)
      assert retargeted_runtime.websocket_owner_downstream.pid == self()
      assert is_boolean(retargeted_runtime.websocket_owner_active_turn_reconnect?)
      assert {:ok, _owner_pid} = WebsocketOwnerSession.lookup(target_session.id)
      assert {:ok, _owner_pid} = WebsocketOwnerSession.lookup(current_runtime.codex_session.id)
    end

    test "keeps the current owner runtime when backend frame turn-state is unknown", %{
      auth: auth
    } do
      {:ok, runtime} = owner_runtime(auth, "owner-runtime-unknown-turn-state")
      owner_pid = owner_pid!(runtime.codex_session.id)
      owner_state_before = :sys.get_state(owner_pid)

      assert {:ok, ^runtime} =
               Gateway.retarget_websocket_owner_runtime(auth, runtime, %{
                 "type" => "response.create",
                 "client_metadata" => %{
                   "x-codex-turn-state" => owner_turn_state("unknown")
                 }
               })

      assert :sys.get_state(owner_pid) == owner_state_before
      assert {:ok, ^owner_pid} = WebsocketOwnerSession.lookup(runtime.codex_session.id)
    end

    test "previous response aliases take precedence over backend frame turn-state", %{
      api_key: api_key,
      auth: auth
    } do
      {:ok, current_runtime} = owner_runtime(auth, "owner-runtime-precedence-current")
      target_turn_state = owner_turn_state("owner-runtime-precedence-target")

      {:ok, target_session} =
        Gateway.start_codex_session(auth, %{accepted_turn_state: target_turn_state})

      target_session = Repo.get!(CodexSession, target_session.id)
      owner_pid = owner_pid!(current_runtime.codex_session.id)
      owner_state_before = :sys.get_state(owner_pid)

      assert {:error, :owner_unavailable} =
               Gateway.retarget_websocket_owner_runtime(auth, current_runtime, %{
                 "type" => "response.create",
                 "previous_response_id" => previous_response_id("guessed-precedence"),
                 "client_metadata" => %{"x-codex-turn-state" => target_turn_state}
               })

      assert :sys.get_state(owner_pid) == owner_state_before
      assert {:ok, ^owner_pid} = WebsocketOwnerSession.lookup(current_runtime.codex_session.id)
      assert {:error, :owner_unavailable} = WebsocketOwnerSession.lookup(target_session.id)

      previous_response_id = previous_response_id("valid-precedence")

      register_previous_response_alias!(
        current_runtime.codex_session,
        api_key,
        previous_response_id
      )

      assert {:ok, ^current_runtime} =
               Gateway.retarget_websocket_owner_runtime(auth, current_runtime, %{
                 "type" => "response.create",
                 "previous_response_id" => previous_response_id,
                 "client_metadata" => %{"x-codex-turn-state" => target_turn_state}
               })
    end

    test "refuses guessed aliases with a sanitized owner error and preserves current runtime", %{
      auth: auth
    } do
      {:ok, runtime} = owner_runtime(auth, "owner-runtime-refusal")
      owner_pid = owner_pid!(runtime.codex_session.id)
      owner_state_before = :sys.get_state(owner_pid)

      assert {:error, :owner_unavailable} =
               Gateway.retarget_websocket_owner_runtime(auth, runtime, %{
                 "type" => "response.create",
                 "previous_response_id" => previous_response_id("guessed")
               })

      assert ^runtime = runtime
      assert :sys.get_state(owner_pid) == owner_state_before
      assert {:ok, ^owner_pid} = WebsocketOwnerSession.lookup(runtime.codex_session.id)
    end
  end

  defp owner_runtime(auth, session_key) do
    Gateway.prepare_websocket_session(auth, owner_opts(session_key))
  end

  defp owner_opts(session_key) do
    %{accepted_turn_state: owner_turn_state(session_key)}
  end

  defp owner_turn_state(session_key) do
    "#{session_key}-#{System.unique_integer([:positive])}"
  end

  defp previous_response_id(label) do
    "resp_owner_runtime_#{label}_#{System.unique_integer([:positive])}"
  end

  defp register_previous_response_alias!(%CodexSession{} = session, api_key, previous_response_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %BridgeSessionAlias{}
    |> BridgeSessionAlias.changeset(%{
      codex_session_id: session.id,
      pool_id: session.pool_id,
      api_key_id: api_key.id,
      alias_kind: "previous_response_id",
      alias_hash: :crypto.hash(:sha256, previous_response_id),
      alias_preview: "synthetic-prev",
      status: "active",
      expires_at: DateTime.add(now, 300, :second),
      last_seen_at: now,
      metadata: %{},
      created_at: now,
      updated_at: now
    })
    |> Repo.insert!()
  end

  defp owner_pid!(codex_session_id) do
    assert {:ok, owner_pid} = WebsocketOwnerSession.lookup(codex_session_id)
    owner_pid
  end

  defp cleanup_local_owner_sessions do
    capture_log(fn ->
      WebsocketOwnerSession.Registry
      |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
      |> Enum.each(fn codex_session_id ->
        try do
          with {:ok, owner_pid} <- WebsocketOwnerSession.lookup(codex_session_id) do
            _result = GenServer.stop(owner_pid, :shutdown, 1_000)
          end
        catch
          :exit, _reason -> :ok
        end
      end)
    end)

    :ok
  end
end
