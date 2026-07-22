defmodule CodexPooler.Gateway.Routing.SessionContinuityTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.{BridgeSessionAlias, CodexSession, CodexTurn}
  alias CodexPooler.Gateway.Routing.SessionContinuity
  alias CodexPooler.Gateway.Runtime.Dispatch.PreDispatch
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment

  @endpoint "/backend-api/codex/responses"

  describe "filter_codex_session_assignment/2" do
    test "returns pinned reauth recovery only for revoked-refresh-token pinned assignments outside candidates" do
      setup = pinned_assignment_setup()
      session = codex_session_fixture(setup, setup.pinned.assignment)
      opts = request_options_with_session(session)

      assert {:error, error} =
               SessionContinuity.filter_codex_session_assignment([setup.other_candidate], opts)

      assert error.status == 503
      assert error.code == "pinned_continuation_reauth_required"
      assert error.retryable == false
      assert error.requires_new_upstream_session == true
      assert error.recovery["kind"] == "restart_with_full_context"

      assert error.continuity_denial == %{
               "denial_family" => "pinned_continuation_reauth",
               "continuity_family" => "pinned_codex_session",
               "upstream_lifecycle_family" => "reauth_required",
               "token_refresh_reason_code_preview" => "refresh_token_revoked",
               "pool_upstream_assignment_id" => setup.pinned.assignment.id,
               "upstream_identity_id" => setup.pinned.identity.id
             }
    end

    test "loads persisted assignment state rather than trusting only the eligible candidate set" do
      setup = pinned_assignment_setup()
      session = codex_session_fixture(setup, setup.pinned.assignment)
      opts = request_options_with_session(session)

      assert {:error, %{code: "pinned_continuation_reauth_required"}} =
               SessionContinuity.filter_codex_session_assignment([setup.other_candidate], opts)
    end

    test "returns pinned unavailable recovery for paused assignments" do
      setup =
        pinned_assignment_setup(
          assignment_status: "paused",
          identity_status: "active",
          identity_metadata: %{}
        )

      session = codex_session_fixture(setup, setup.pinned.assignment)
      opts = request_options_with_session(session)

      assert {:error, error} =
               SessionContinuity.filter_codex_session_assignment([setup.other_candidate], opts)

      assert_pinned_continuation_unavailable(error, setup, "assignment_unavailable")
    end

    test "returns pinned unavailable recovery for deleted assignments" do
      setup =
        pinned_assignment_setup(
          assignment_status: "deleted",
          identity_status: "active",
          identity_metadata: %{}
        )

      session = codex_session_fixture(setup, setup.pinned.assignment)
      opts = request_options_with_session(session)

      assert {:error, error} =
               SessionContinuity.filter_codex_session_assignment([setup.other_candidate], opts)

      assert_pinned_continuation_unavailable(error, setup, "assignment_unavailable")
    end

    test "returns pinned unavailable recovery for inactive identities" do
      setup = pinned_assignment_setup(identity_status: "paused")
      session = codex_session_fixture(setup, setup.pinned.assignment)
      opts = request_options_with_session(session)

      assert {:error, error} =
               SessionContinuity.filter_codex_session_assignment([setup.other_candidate], opts)

      assert_pinned_continuation_unavailable(error, setup, "identity_unavailable")
    end

    test "returns pinned unavailable recovery for non-revoked reauth states" do
      setup = pinned_assignment_setup(token_refresh_reason_code: "missing_refresh_token")
      session = codex_session_fixture(setup, setup.pinned.assignment)
      opts = request_options_with_session(session)

      assert {:error, error} =
               SessionContinuity.filter_codex_session_assignment([setup.other_candidate], opts)

      assert_pinned_continuation_unavailable(error, setup, "identity_unavailable")
    end

    test "returns pinned unavailable recovery for malformed token refresh metadata" do
      setup = pinned_assignment_setup(identity_metadata: %{"token_refresh" => "reauth_required"})
      session = codex_session_fixture(setup, setup.pinned.assignment)
      opts = request_options_with_session(session)

      assert {:error, error} =
               SessionContinuity.filter_codex_session_assignment([setup.other_candidate], opts)

      assert_pinned_continuation_unavailable(error, setup, "identity_unavailable")
    end

    test "returns pinned unavailable recovery for generic reauth_required state" do
      setup =
        pinned_assignment_setup(
          identity_metadata: %{"token_refresh" => %{"status" => "reauth_required"}}
        )

      session = codex_session_fixture(setup, setup.pinned.assignment)
      opts = request_options_with_session(session)

      assert {:error, error} =
               SessionContinuity.filter_codex_session_assignment([setup.other_candidate], opts)

      assert_pinned_continuation_unavailable(error, setup, "identity_unavailable")
    end
  end

  describe "filter_codex_session_assignment/3" do
    test "soft-pins fresh proxy stream sessions without hard continuity anchors" do
      setup = active_pinned_assignment_setup()
      session = codex_session_fixture(setup, setup.pinned.assignment)
      opts = streaming_request_options_with_session(session)

      model =
        model_for_assignments(setup.pool, [setup.pinned.assignment.id, setup.other.assignment.id])

      candidates = [setup.other_candidate, setup.pinned_candidate]

      assert {:ok, filtered} =
               SessionContinuity.filter_codex_session_assignment(candidates, opts, model)

      assert candidate_assignment_ids(filtered) == [
               setup.pinned.assignment.id,
               setup.other.assignment.id
             ]
    end

    test "keeps fallback candidates when a fresh proxy stream pinned assignment is absent" do
      setup = active_pinned_assignment_setup()
      session = codex_session_fixture(setup, setup.pinned.assignment)
      opts = streaming_request_options_with_session(session)

      model =
        model_for_assignments(setup.pool, [setup.pinned.assignment.id, setup.other.assignment.id])

      assert {:ok, [other_candidate]} =
               SessionContinuity.filter_codex_session_assignment(
                 [setup.other_candidate],
                 opts,
                 model
               )

      assert other_candidate == setup.other_candidate
    end

    test "keeps fallback candidates for non-stream requests without hard anchors" do
      setup = active_pinned_assignment_setup()
      session = codex_session_fixture(setup, setup.pinned.assignment)
      opts = request_options_with_session(session)

      model =
        model_for_assignments(setup.pool, [setup.pinned.assignment.id, setup.other.assignment.id])

      assert {:ok, [other_candidate]} =
               SessionContinuity.filter_codex_session_assignment(
                 [setup.other_candidate],
                 opts,
                 model
               )

      assert other_candidate == setup.other_candidate
    end

    for session_header_source <- [
          "x-codex-window-id",
          "x-codex-session-id",
          "session-id",
          "x-session-affinity",
          "session_id",
          "x-codex-conversation-id"
        ] do
      test "soft-pins local continuity header #{session_header_source}" do
        setup = active_pinned_assignment_setup()
        session = codex_session_fixture(setup, setup.pinned.assignment)

        opts =
          session
          |> streaming_request_options_with_session()
          |> RequestOptions.put_continuity(
            session_header: "local-session-alias",
            session_header_source: unquote(session_header_source)
          )

        model =
          model_for_assignments(setup.pool, [
            setup.pinned.assignment.id,
            setup.other.assignment.id
          ])

        assert {:ok, [other_candidate]} =
                 SessionContinuity.filter_codex_session_assignment(
                   [setup.other_candidate],
                   opts,
                   model
                 )

        assert other_candidate == setup.other_candidate
      end
    end

    test "hard-pins proxy stream continuations with previous_response_id" do
      setup = active_pinned_assignment_setup()
      session = codex_session_fixture(setup, setup.pinned.assignment)

      opts =
        session
        |> streaming_request_options_with_session()
        |> RequestOptions.put_continuity(previous_response_id: "resp_strong_anchor")

      model =
        model_for_assignments(setup.pool, [setup.pinned.assignment.id, setup.other.assignment.id])

      assert {:error, error} =
               SessionContinuity.filter_codex_session_assignment(
                 [setup.other_candidate],
                 opts,
                 model
               )

      assert_pinned_continuation_unavailable(error, setup, "assignment_unavailable",
        pin_reason: "previous_response_id"
      )
    end

    test "soft-pins proxy stream continuations with bare accepted turn state" do
      setup = active_pinned_assignment_setup()
      session = codex_session_fixture(setup, setup.pinned.assignment)

      opts =
        session
        |> streaming_request_options_with_session()
        |> RequestOptions.put_continuity(accepted_turn_state: "turn_soft_anchor")

      model =
        model_for_assignments(setup.pool, [setup.pinned.assignment.id, setup.other.assignment.id])

      assert {:ok, [other_candidate]} =
               SessionContinuity.filter_codex_session_assignment(
                 [setup.other_candidate],
                 opts,
                 model
               )

      assert other_candidate == setup.other_candidate
    end

    test "hard-pins accepted turn state backed by a live upstream websocket session" do
      setup = active_pinned_assignment_setup()
      session = codex_session_fixture(setup, setup.pinned.assignment)

      opts =
        session
        |> streaming_request_options_with_session()
        |> RequestOptions.put_continuity(accepted_turn_state: "turn_live_websocket")
        |> RequestOptions.put_transport(upstream_websocket_session: self())

      model =
        model_for_assignments(setup.pool, [setup.pinned.assignment.id, setup.other.assignment.id])

      assert {:error, error} =
               SessionContinuity.filter_codex_session_assignment(
                 [setup.other_candidate],
                 opts,
                 model
               )

      assert_pinned_continuation_unavailable(error, setup, "assignment_unavailable",
        pin_reason: "live_upstream_websocket"
      )
    end

    test "hard-pins accepted turn state backed by upstream websocket owner forwarding" do
      setup = active_pinned_assignment_setup()
      session = codex_session_fixture(setup, setup.pinned.assignment)

      opts =
        session
        |> streaming_request_options_with_session()
        |> RequestOptions.put_continuity(accepted_turn_state: "turn_owner_websocket")
        |> RequestOptions.put_transport(
          websocket_owner_forwarding_enabled?: true,
          websocket_owner_session: session,
          websocket_owner_lease_token: "lease-token",
          websocket_owner_downstream: %{pid: self(), correlation_id: "safe-correlation"}
        )

      model =
        model_for_assignments(setup.pool, [setup.pinned.assignment.id, setup.other.assignment.id])

      assert {:error, error} =
               SessionContinuity.filter_codex_session_assignment(
                 [setup.other_candidate],
                 opts,
                 model
               )

      assert_pinned_continuation_unavailable(error, setup, "assignment_unavailable",
        pin_reason: "live_upstream_websocket"
      )
    end

    test "keeps a first-turn owner-forwarded websocket soft until its session is assigned" do
      setup = active_pinned_assignment_setup()

      session =
        setup
        |> codex_session_fixture(setup.pinned.assignment)
        |> Ecto.Changeset.change(pool_upstream_assignment_id: nil)
        |> Repo.update!()

      opts =
        session
        |> streaming_request_options_with_session()
        |> RequestOptions.put_continuity(accepted_turn_state: "turn_owner_first_turn")
        |> RequestOptions.put_transport(
          websocket_owner_forwarding_enabled?: true,
          websocket_owner_session: session,
          websocket_owner_lease_token: "lease-token",
          websocket_owner_downstream: %{pid: self(), correlation_id: "safe-correlation"}
        )

      model =
        model_for_assignments(setup.pool, [setup.pinned.assignment.id, setup.other.assignment.id])

      assert SessionContinuity.hard_pin_metadata(opts, model) == nil

      assert {:ok, [other_candidate]} =
               SessionContinuity.filter_codex_session_assignment(
                 [setup.other_candidate],
                 opts,
                 model
               )

      assert other_candidate == setup.other_candidate
    end

    test "keeps owner-forwarded websocket continuity soft without complete live owner state" do
      setup = active_pinned_assignment_setup()
      session = codex_session_fixture(setup, setup.pinned.assignment)

      base_opts =
        session
        |> streaming_request_options_with_session()
        |> RequestOptions.put_continuity(accepted_turn_state: "turn_owner_incomplete_websocket")

      model =
        model_for_assignments(setup.pool, [setup.pinned.assignment.id, setup.other.assignment.id])

      incomplete_transport_states = [
        [
          websocket_owner_forwarding_enabled?: false,
          websocket_owner_session: session,
          websocket_owner_lease_token: "lease-token",
          websocket_owner_downstream: %{pid: self(), correlation_id: "safe-correlation"}
        ],
        [
          websocket_owner_forwarding_enabled?: true,
          websocket_owner_session: %{id: session.id},
          websocket_owner_lease_token: "lease-token",
          websocket_owner_downstream: %{pid: self(), correlation_id: "safe-correlation"}
        ],
        [
          websocket_owner_forwarding_enabled?: true,
          websocket_owner_session: session,
          websocket_owner_lease_token: nil,
          websocket_owner_downstream: %{pid: self(), correlation_id: "safe-correlation"}
        ],
        [
          websocket_owner_forwarding_enabled?: true,
          websocket_owner_session: session,
          websocket_owner_lease_token: "lease-token",
          websocket_owner_downstream: %{correlation_id: "safe-correlation"}
        ]
      ]

      for transport_updates <- incomplete_transport_states do
        opts = RequestOptions.put_transport(base_opts, transport_updates)

        assert {:ok, [other_candidate]} =
                 SessionContinuity.filter_codex_session_assignment(
                   [setup.other_candidate],
                   opts,
                   model
                 )

        assert other_candidate == setup.other_candidate
      end
    end

    test "hard-pins proxy stream continuations with file affinity" do
      setup = active_pinned_assignment_setup()
      session = codex_session_fixture(setup, setup.pinned.assignment)

      opts =
        session
        |> streaming_request_options_with_session()
        |> RequestOptions.put_routing(file_affinity_assignment_id: setup.pinned.assignment.id)

      model =
        model_for_assignments(setup.pool, [setup.pinned.assignment.id, setup.other.assignment.id])

      assert {:error, error} =
               SessionContinuity.filter_codex_session_assignment(
                 [setup.other_candidate],
                 opts,
                 model
               )

      assert_pinned_continuation_unavailable(error, setup, "assignment_unavailable",
        pin_reason: "file_affinity"
      )
    end

    test "soft-pins proxy stream sessions after a same-model successful turn" do
      setup = active_pinned_assignment_setup()
      api_key = active_api_key_fixture(setup.pool)
      session = codex_session_fixture(setup, setup.pinned.assignment, api_key.api_key)
      opts = streaming_request_options_with_session(session)

      model =
        model_for_assignments(setup.pool, [setup.pinned.assignment.id, setup.other.assignment.id])

      succeeded_codex_turn_fixture(setup, session, api_key.api_key, model.exposed_model_id)

      assert {:ok, [other_candidate]} =
               SessionContinuity.filter_codex_session_assignment(
                 [setup.other_candidate],
                 opts,
                 model
               )

      assert other_candidate == setup.other_candidate
    end

    test "does not hard-pin proxy stream sessions from a different helper model success" do
      setup = active_pinned_assignment_setup()
      api_key = active_api_key_fixture(setup.pool)
      session = codex_session_fixture(setup, setup.pinned.assignment, api_key.api_key)
      opts = streaming_request_options_with_session(session)

      model =
        model_for_assignments(setup.pool, [setup.pinned.assignment.id, setup.other.assignment.id])

      succeeded_codex_turn_fixture(setup, session, api_key.api_key, "gpt-5.4-mini")

      assert {:ok, [other_candidate]} =
               SessionContinuity.filter_codex_session_assignment(
                 [setup.other_candidate],
                 opts,
                 model
               )

      assert other_candidate == setup.other_candidate
    end
  end

  describe "PreDispatch.prepare/5" do
    test "previous_response_id alias can recover the pinned reauth classification without a live owner lease" do
      setup = pinned_assignment_setup()
      api_key = active_api_key_fixture(setup.pool)
      {:ok, auth} = Access.authenticate_authorization_header(api_key.authorization)
      previous_response_id = "resp_prev_#{System.unique_integer([:positive])}"

      session =
        setup
        |> codex_session_fixture(setup.pinned.assignment, api_key.api_key)
        |> register_previous_response_alias!(api_key.api_key, previous_response_id)

      assert is_nil(session.owner_lease_expires_at)

      model =
        model_for_assignments(setup.pool, [setup.pinned.assignment.id, setup.other.assignment.id])

      payload = %{
        "model" => model.exposed_model_id,
        "input" => "hello",
        "previous_response_id" => previous_response_id
      }

      opts = RequestOptions.build(%{api_key_policy: auth.api_key}, @endpoint, payload)

      assert {:error, error} = PreDispatch.prepare(auth, @endpoint, payload, opts, model)
      assert error.code == "pinned_continuation_reauth_required"
      assert error.continuity_denial["pool_upstream_assignment_id"] == setup.pinned.assignment.id
      assert Repo.aggregate(Request, :count) == 0
      assert Repo.aggregate(Attempt, :count) == 0
    end

    test "keeps fresh proxy stream fallback candidates after attaching codex session" do
      setup = active_pinned_assignment_setup()
      api_key = active_api_key_fixture(setup.pool)
      {:ok, auth} = Access.authenticate_authorization_header(api_key.authorization)
      session = codex_session_fixture(setup, setup.pinned.assignment, api_key.api_key)

      model =
        model_for_assignments(setup.pool, [setup.pinned.assignment.id, setup.other.assignment.id])

      payload = %{"model" => model.exposed_model_id, "input" => "hello", "stream" => true}

      opts =
        %{api_key_policy: auth.api_key}
        |> RequestOptions.build(@endpoint, payload)
        |> RequestOptions.put_continuity(codex_session: session)

      assert {:ok, %{candidates: candidates}} =
               PreDispatch.prepare(auth, @endpoint, payload, opts, model)

      assert candidate_assignment_ids(candidates) == [
               setup.pinned.assignment.id,
               setup.other.assignment.id
             ]
    end

    test "frame previous_response_id aliases override an already attached websocket session" do
      setup = active_pinned_assignment_setup()
      api_key = active_api_key_fixture(setup.pool)
      {:ok, auth} = Access.authenticate_authorization_header(api_key.authorization)
      previous_response_id = "resp_prev_#{System.unique_integer([:positive])}"

      alias_session =
        setup
        |> codex_session_fixture(setup.pinned.assignment, api_key.api_key)
        |> register_previous_response_alias!(api_key.api_key, previous_response_id)

      attached_session = codex_session_fixture(setup, setup.other.assignment, api_key.api_key)

      model =
        model_for_assignments(setup.pool, [setup.pinned.assignment.id, setup.other.assignment.id])

      payload = %{
        "model" => model.exposed_model_id,
        "input" => [
          %{
            "type" => "function_call_output",
            "call_id" => "call_ws_frame_alias",
            "output" => "sample output"
          }
        ],
        "stream" => true,
        "previous_response_id" => previous_response_id
      }

      opts =
        %{api_key_policy: auth.api_key}
        |> RequestOptions.build(@endpoint, payload)
        |> RequestOptions.put_continuity(codex_session: attached_session)

      assert {:ok, %{request_options: prepared_opts, candidates: candidates}} =
               PreDispatch.prepare(auth, @endpoint, payload, opts, model)

      assert prepared_opts.continuity.codex_session.id == alias_session.id
      assert prepared_opts.continuity.previous_response_id == previous_response_id
      assert candidate_assignment_ids(candidates) == [setup.pinned.assignment.id]
    end
  end

  defp active_pinned_assignment_setup do
    pinned_assignment_setup(
      identity_status: "active",
      identity_metadata: %{},
      health_status: "active",
      eligibility_status: "eligible",
      assignment_status: "active"
    )
  end

  defp pinned_assignment_setup(attrs \\ []) do
    attrs = Map.new(attrs)
    pool = pool_fixture()

    pinned =
      upstream_assignment_fixture(pool, %{
        identity_status: Map.get(attrs, :identity_status, "reauth_required"),
        identity_metadata: Map.get(attrs, :identity_metadata, token_refresh_metadata(attrs)),
        assignment_status: Map.get(attrs, :assignment_status, "active"),
        health_status: Map.get(attrs, :health_status, "disabled"),
        eligibility_status: Map.get(attrs, :eligibility_status, "ineligible")
      })

    other = upstream_assignment_fixture(pool)

    %{
      pool: pool,
      pinned: pinned,
      other: other,
      pinned_candidate: {pinned.assignment, pinned.identity},
      other_candidate: {other.assignment, other.identity}
    }
  end

  defp token_refresh_metadata(attrs) do
    %{
      "token_refresh" => %{
        "status" => Map.get(attrs, :token_refresh_status, "reauth_required"),
        "reason" => %{
          "code" => Map.get(attrs, :token_refresh_reason_code, "refresh_token_revoked"),
          "message" => "synthetic token refresh state"
        }
      }
    }
  end

  defp codex_session_fixture(setup, %PoolUpstreamAssignment{} = assignment, api_key \\ nil) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %CodexSession{
      pool_id: setup.pool.id,
      api_key_id: api_key && api_key.id,
      session_key: "session-#{System.unique_integer([:positive])}",
      pool_upstream_assignment_id: assignment.id,
      status: "active",
      created_at: now,
      updated_at: now
    }
    |> Repo.insert!()
  end

  defp request_options_with_session(%CodexSession{} = session) do
    %{}
    |> RequestOptions.build(@endpoint, %{"model" => "gpt-5.5", "input" => "hello"})
    |> RequestOptions.put_continuity(codex_session: session)
  end

  defp streaming_request_options_with_session(%CodexSession{} = session) do
    %{}
    |> RequestOptions.build(@endpoint, %{
      "model" => "gpt-5.5",
      "input" => "hello",
      "stream" => true
    })
    |> RequestOptions.put_continuity(codex_session: session)
  end

  defp succeeded_codex_turn_fixture(setup, %CodexSession{} = session, api_key, requested_model) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    request =
      request_fixture(%{pool: setup.pool, api_key: api_key}, %{
        requested_model: requested_model,
        transport: "http_sse",
        status: "succeeded",
        usage_status: "usage_known",
        response_status_code: 200,
        completed_at: now
      })

    %CodexTurn{
      codex_session_id: session.id,
      request_id: request.id,
      turn_sequence: 1,
      transport_kind: "http_sse",
      status: "succeeded",
      started_at: now,
      completed_at: now,
      created_at: now,
      updated_at: now
    }
    |> Repo.insert!()
  end

  defp candidate_assignment_ids(candidates) do
    Enum.map(candidates, fn {assignment, _identity} -> assignment.id end)
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

    session
  end

  defp model_for_assignments(pool, assignment_ids) do
    model_fixture(pool, %{
      exposed_model_id: "gpt-5.5-#{System.unique_integer([:positive])}",
      source_assignment_count: length(assignment_ids),
      metadata: %{"source_assignment_ids" => assignment_ids}
    })
  end

  defp assert_pinned_continuation_unavailable(error, setup, internal_reason, opts \\ []) do
    pin_reason = Keyword.get(opts, :pin_reason, "codex_session_assignment")

    assert error.status == 503
    assert error.code == "pinned_continuation_unavailable"
    assert error.retryable == false
    assert error.requires_new_upstream_session == true
    assert error.recovery["kind"] == "restart_with_full_context"
    assert error.param == "model"

    assert error.continuity_denial == %{
             "denial_family" => "pinned_continuation_unavailable",
             "continuity_family" => "pinned_codex_session",
             "pin_mode" => "hard",
             "pin_reason" => pin_reason,
             "internal_reason" => internal_reason,
             "pool_upstream_assignment_id" => setup.pinned.assignment.id,
             "upstream_identity_id" => setup.pinned.identity.id
           }
  end
end
