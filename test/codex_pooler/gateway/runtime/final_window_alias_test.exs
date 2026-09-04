defmodule CodexPooler.Gateway.Runtime.FinalWindowAliasTest do
  use CodexPooler.DataCase, async: false

  alias CodexPooler.Gateway.Payloads.NativeCodexTurnMetadata
  alias CodexPooler.Gateway.Payloads.RequestOptions

  alias CodexPooler.Gateway.Payloads.RequestOptions.NativeCompactionAdmission,
    as: AdmissionContext

  alias CodexPooler.Gateway.Persistence.{BridgeSessionAlias, CodexSession}
  alias CodexPooler.Gateway.Persistence.SessionContinuity.Aliases
  alias CodexPooler.Gateway.Runtime.Dispatch.ReplayPreparation
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.{Binding, Capability}
  alias CodexPooler.Gateway.Transports.Websocket.NativeCompactionAdmission.Topology.Direct
  alias CodexPooler.Gateway.Websocket
  import CodexPooler.PoolerFixtures
  import Ecto.Query

  test "only bound final authority derives the session lookup hash" do
    {options, payload} = final_options()
    expected = :crypto.hash(:sha256, "sample-final-window")
    assert {:ok, ^expected} = ReplayPreparation.final_window_alias_hash(options, payload)

    for input <- [
          put_in(payload, ["client_metadata", "x-codex-turn-metadata"], "{}"),
          put_in(payload, ["client_metadata", "x-codex-turn-metadata"], %{
            "window_id" => "changed"
          }),
          %{}
        ] do
      assert {:error, :invalid_final_window} =
               ReplayPreparation.final_window_alias_hash(options, input)
    end

    no_authority = %{options | native_compaction_admission: nil}
    assert :none = ReplayPreparation.final_window_alias_hash(no_authority, payload)

    translated =
      RequestOptions.mark_openai_compatibility_origin(
        options,
        "/v1/responses",
        "/backend-api/codex/responses"
      )

    assert :none = ReplayPreparation.final_window_alias_hash(translated, payload)

    changed =
      put_in(options.native_compaction_admission.capability.binding.window_digest, <<0::256>>)

    assert {:error, :invalid_final_window} =
             ReplayPreparation.final_window_alias_hash(changed, payload)
  end

  test "scoped window alias cannot reassign a different session and refreshes its own expiry" do
    key = active_api_key_fixture()
    auth = %{pool: key.pool, api_key: key.api_key}

    assert {:ok, first} =
             Websocket.start_codex_session(auth, %{accepted_turn_state: "sample-first"})

    assert {:ok, second} =
             Websocket.start_codex_session(auth, %{accepted_turn_state: "sample-second"})

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    hash = :crypto.hash(:sha256, "sample-bound-window")

    assert :ok = Aliases.register_session_header_hash(first, auth, hash, now)

    assert {:error, :session_alias_conflict} =
             Aliases.register_session_header_hash(second, auth, hash, now)

    query =
      from row in BridgeSessionAlias,
        where: row.pool_id == ^auth.pool.id and row.alias_hash == ^hash

    assert %{codex_session_id: session_id} = Repo.one!(query)
    assert session_id == first.id
    assert Repo.aggregate(query, :count) == 1

    expired = DateTime.add(now, -1, :second)
    Repo.update_all(query, set: [expires_at: expired])
    assert :ok = Aliases.register_session_header_hash(first, auth, hash, now)
    assert DateTime.compare(Repo.one!(query).expires_at, now) == :gt
  end

  defp final_options do
    session_id = Ecto.UUID.generate()

    canonical = %{
      "turn_id" => "sample-turn",
      "window_id" => "sample-final-window",
      "context_window_id" => Ecto.UUID.generate(),
      "window_number" => 2,
      "request_kind" => "turn"
    }

    payload = %{"client_metadata" => %{"x-codex-turn-metadata" => canonical}}
    assert {:ok, metadata} = NativeCodexTurnMetadata.parse(payload, session_id)

    binding = %Binding{
      semantic_turn_key: metadata.semantic_turn_key,
      window_digest: metadata.window_id_digest,
      context_digest: metadata.context_window_id_digest,
      window_number: 2,
      serving_mode: :full,
      topology: %Direct{},
      lifecycle_id: Ecto.UUID.generate(),
      generation: 1
    }

    capability = %Capability{
      phase: :final,
      binding: binding,
      control_ref: make_ref(),
      token: <<0::256>>,
      expires_at_ms: 1
    }

    admission = %AdmissionContext{
      capability: capability,
      owner: {:direct, self()},
      expected_connection_lifecycle: %{lifecycle_id: binding.lifecycle_id, generation: 1}
    }

    options =
      RequestOptions.for_websocket(%{}, %{})
      |> RequestOptions.put_continuity(codex_session: %CodexSession{id: session_id})
      |> RequestOptions.put_payload_context(native_codex_turn_metadata: metadata)
      |> Map.put(:native_compaction_admission, admission)

    {options,
     put_in(
       payload,
       ["client_metadata", "x-codex-turn-metadata"],
       Map.delete(canonical, "turn_id")
     )}
  end
end
