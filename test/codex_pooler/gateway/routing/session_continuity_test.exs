defmodule CodexPooler.Gateway.Routing.SessionContinuityTest do
  use CodexPooler.DataCase, async: false

  import CodexPooler.PoolerFixtures

  alias CodexPooler.Access
  alias CodexPooler.Accounting.{Attempt, Request}
  alias CodexPooler.Files.FileRecord
  alias CodexPooler.Gateway.Payloads.RequestOptions

  alias CodexPooler.Gateway.Persistence.{
    BridgeOwnerLease,
    BridgeSessionAlias,
    CodexSession,
    CodexTurn
  }

  alias CodexPooler.Gateway.Routing.BridgeRing
  alias CodexPooler.Gateway.Routing.RoutePlanInput
  alias CodexPooler.Gateway.Routing.SessionContinuity
  alias CodexPooler.Gateway.Runtime.Dispatch.PreDispatch
  alias CodexPooler.Pools
  alias CodexPooler.Repo
  alias CodexPooler.Upstreams.Schemas.PoolUpstreamAssignment

  @endpoint "/backend-api/codex/responses"

  test "HTTP session start classifies only PostgreSQL shutdown availability failures" do
    for code <- [:admin_shutdown, :crash_shutdown, :cannot_connect_now] do
      assert SessionContinuity.http_session_database_unavailable?(%Postgrex.Error{
               postgres: %{code: code}
             })
    end

    refute SessionContinuity.http_session_database_unavailable?(%Postgrex.Error{
             postgres: %{code: :unique_violation}
           })

    refute SessionContinuity.http_session_database_unavailable?(%Postgrex.Error{})
  end

  describe "attach_file_affinity/4" do
    test "collects nested mixed-key file ids once while preserving one assignment" do
      setup = active_pinned_assignment_setup()
      api_key = active_api_key_fixture(setup.pool)
      {:ok, auth} = Access.authenticate_authorization_header(api_key.authorization)

      first_file_id = "file-first-#{System.unique_integer([:positive])}"
      second_file_id = "file-second-#{System.unique_integer([:positive])}"

      insert_response_file!(setup, api_key.api_key, first_file_id)
      insert_response_file!(setup, api_key.api_key, second_file_id)

      payload = %{
        "input" => [
          %{:type => "input_file", :file_id => first_file_id},
          %{
            "content" => [
              %{"type" => "input_file", "file_id" => second_file_id},
              %{"type" => "input_file", "file_id" => first_file_id}
            ]
          }
        ]
      }

      request_options = RequestOptions.build(%{}, @endpoint, payload)

      assert {:ok, attached} =
               SessionContinuity.attach_file_affinity(
                 auth,
                 @endpoint,
                 payload,
                 request_options
               )

      assert attached.routing.file_affinity_assignment_id == setup.pinned.assignment.id
    end

    test "resolves session aliases once in candidate priority order" do
      setup = active_pinned_assignment_setup()
      api_key = active_api_key_fixture(setup.pool)
      {:ok, auth} = Access.authenticate_authorization_header(api_key.authorization)
      file_id = "file-priority-#{System.unique_integer([:positive])}"
      turn_state = "turn-priority-#{System.unique_integer([:positive])}"
      previous_response_id = "previous-lower-#{System.unique_integer([:positive])}"

      insert_response_file!(setup, api_key.api_key, file_id)

      pinned_session =
        setup
        |> codex_session_fixture(setup.pinned.assignment, api_key.api_key)
        |> activate_owner_lease!()

      other_session =
        setup
        |> codex_session_fixture(setup.other.assignment, api_key.api_key)
        |> activate_owner_lease!()

      register_session_alias!(pinned_session, api_key.api_key, "turn_state", turn_state)

      register_session_alias!(
        other_session,
        api_key.api_key,
        "previous_response_id",
        previous_response_id
      )

      payload = %{"input" => [%{"type" => "input_file", "file_id" => file_id}]}

      request_options =
        %{
          accepted_turn_state: turn_state,
          previous_response_id: previous_response_id
        }
        |> RequestOptions.build(@endpoint, payload)

      {result, queries} =
        capture_repo_queries(fn ->
          SessionContinuity.attach_file_affinity(
            auth,
            @endpoint,
            payload,
            request_options
          )
        end)

      assert {:ok, attached} = result
      assert attached.routing.file_affinity_assignment_id == setup.pinned.assignment.id

      assert [alias_lookup] =
               Enum.filter(queries, fn query ->
                 query.command == "SELECT" and
                   String.contains?(query.query, ~s(JOIN "bridge_session_aliases"))
               end)

      assert String.contains?(alias_lookup.query, "CASE WHEN")
    end
  end

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

  describe "recreated session assignment preference" do
    test "soft-prefers the previous assignment of a lease-expiry recreation" do
      setup = active_pinned_assignment_setup()
      session = recreated_session_fixture(setup, setup.pinned.assignment)
      opts = streaming_request_options_with_session(session)

      model =
        model_for_assignments(setup.pool, [setup.pinned.assignment.id, setup.other.assignment.id])

      assert SessionContinuity.hard_pin_metadata(opts, model) == nil

      assert {:ok, filtered} =
               SessionContinuity.filter_codex_session_assignment(
                 [setup.other_candidate, setup.pinned_candidate],
                 opts,
                 model
               )

      assert candidate_assignment_ids(filtered) == [
               setup.pinned.assignment.id,
               setup.other.assignment.id
             ]
    end

    test "falls through to ordinary ordering when the previous assignment is absent" do
      setup = active_pinned_assignment_setup()
      session = recreated_session_fixture(setup, setup.pinned.assignment)
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

    test "a hard pin outranks the recreation preference" do
      setup = active_pinned_assignment_setup()
      session = recreated_session_fixture(setup, setup.pinned.assignment)

      opts =
        session
        |> streaming_request_options_with_session()
        |> RequestOptions.put_continuity(
          previous_response_id: "resp_recreation_#{System.unique_integer([:positive])}"
        )

      model =
        model_for_assignments(setup.pool, [setup.pinned.assignment.id, setup.other.assignment.id])

      assert SessionContinuity.hard_pin_metadata(opts, model) == %{
               "pin_mode" => "hard",
               "pin_reason" => "previous_response_id"
             }

      assert {:ok, filtered} =
               SessionContinuity.filter_codex_session_assignment(
                 [setup.other_candidate, setup.pinned_candidate],
                 opts,
                 model
               )

      assert candidate_assignment_ids(filtered) == [
               setup.other.assignment.id,
               setup.pinned.assignment.id
             ]
    end

    test "a session that was never recreated keeps ordinary ordering" do
      setup = active_pinned_assignment_setup()

      session =
        setup
        |> codex_session_fixture(setup.pinned.assignment)
        |> Ecto.Changeset.change(pool_upstream_assignment_id: nil)
        |> Repo.update!()

      opts = streaming_request_options_with_session(session)

      model =
        model_for_assignments(setup.pool, [setup.pinned.assignment.id, setup.other.assignment.id])

      assert {:ok, filtered} =
               SessionContinuity.filter_codex_session_assignment(
                 [setup.other_candidate, setup.pinned_candidate],
                 opts,
                 model
               )

      assert candidate_assignment_ids(filtered) == [
               setup.other.assignment.id,
               setup.pinned.assignment.id
             ]
    end

    test "an ineligible previous assignment is excluded before the preference can order it" do
      setup = pinned_assignment_setup()
      api_key = active_api_key_fixture(setup.pool)
      {:ok, auth} = Access.authenticate_authorization_header(api_key.authorization)
      session = recreated_session_fixture(setup, setup.pinned.assignment, api_key.api_key)

      model =
        model_for_assignments(setup.pool, [setup.pinned.assignment.id, setup.other.assignment.id])

      payload = %{
        "model" => model.exposed_model_id,
        "input" => native_text_input("hello"),
        "stream" => true
      }

      opts =
        %{api_key_policy: auth.api_key}
        |> RequestOptions.build(@endpoint, payload)
        |> RequestOptions.put_continuity(codex_session: session)

      assert {:ok, %{candidates: candidates}} =
               PreDispatch.prepare(auth, @endpoint, payload, opts, model)

      assert candidate_assignment_ids(candidates) == [setup.other.assignment.id]
    end
  end

  describe "lease-expiry recreation preference, end to end" do
    # Drives the real path instead of a hand-built struct: PreDispatch attaches
    # the session through persistence `start_codex_session/2`, which recreates
    # it because the previous session's owner lease expired, and the preference
    # has to survive every link from that transaction to candidate ordering.
    # The preference is only proven by moving an assignment the ring would
    # otherwise rank last. Asserting that the ring's own first choice comes
    # first passes whether or not the preference reached routing at all, which
    # is exactly how this went unnoticed in production.
    test "the previous assignment moves to the front of ordinary ordering" do
      context = recreation_context()
      ordinary_ids = ordinary_candidate_order(context)
      preferred_id = List.last(ordinary_ids)

      expired = expired_assigned_session!(context, preferred_id, context.session_header)

      assert {:ok, %{request_options: options, candidates: candidates}} =
               prepare_session_turn(context, context.session_header)

      replacement = options.continuity.codex_session

      refute replacement.id == expired.id
      assert is_nil(replacement.pool_upstream_assignment_id)
      assert replacement.recreated_from_assignment_id == preferred_id

      assert candidate_assignment_ids(candidates) ==
               [preferred_id | List.delete(ordinary_ids, preferred_id)]
    end

    # Pre-dispatch ordering is not the decision: `BridgeRing.plan_route/1`
    # re-sorts the whole shortlist afterwards. Both assignments are driven
    # through a real recreation against one fixed ring seed, so the ring's own
    # order is the same in both runs and exactly one of them contradicts it.
    # A single run would pass whenever the ring already favoured the preferred
    # assignment, which is how this went unnoticed in production.
    test "the ring selects the previous assignment over its own ordering" do
      context = recreation_context()
      pin_ring_seed!(context)
      route_plan_input = fixed_ring_seed()

      outcomes =
        Enum.map(context.assignment_ids, fn assignment_id ->
          session_header = "window-#{System.unique_integer([:positive])}"
          expired = expired_assigned_session!(context, assignment_id, session_header)

          assert {:ok, %{request_options: options, candidates: candidates}} =
                   prepare_session_turn(context, session_header)

          replacement = options.continuity.codex_session

          refute replacement.id == expired.id
          assert replacement.recreated_from_assignment_id == assignment_id

          %{
            expected: assignment_id,
            preferred: selected_assignment_id(context, route_plan_input, options, candidates),
            baseline:
              selected_assignment_id(
                context,
                route_plan_input,
                without_recreation_preference(options),
                candidates
              )
          }
        end)

      assert Enum.map(outcomes, & &1.preferred) == Enum.map(outcomes, & &1.expected)
      assert Enum.any?(outcomes, &(&1.baseline != &1.expected))
    end

    test "an expired session with no assignment leaves ordinary ordering alone" do
      context = recreation_context()
      ordinary_ids = ordinary_candidate_order(context)

      assert {:ok, %{request_options: first_options}} =
               prepare_session_turn(context, context.session_header)

      expired = first_options.continuity.codex_session
      expire_owner_lease!(expired.id)

      assert {:ok, %{request_options: options, candidates: candidates}} =
               prepare_session_turn(context, context.session_header)

      replacement = options.continuity.codex_session

      refute replacement.id == expired.id
      assert is_nil(replacement.recreated_from_assignment_id)
      assert candidate_assignment_ids(candidates) == ordinary_ids
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
        "input" => native_text_input("hello"),
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

      payload = %{
        "model" => model.exposed_model_id,
        "input" => native_text_input("hello"),
        "stream" => true
      }

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

  defp insert_response_file!(setup, api_key, file_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %FileRecord{}
    |> FileRecord.changeset(%{
      pool_id: setup.pool.id,
      api_key_id: api_key.id,
      file_id: file_id,
      purpose: "user_data",
      filename: "sample.txt",
      byte_size: 12,
      status: "uploaded",
      pool_upstream_assignment_id: setup.pinned.assignment.id,
      upstream_identity_id: setup.pinned.identity.id,
      finalize_status: "succeeded",
      uploaded_at: now,
      expires_at: DateTime.add(now, 3600, :second),
      metadata: %{},
      created_at: now,
      updated_at: now
    })
    |> Repo.insert!()
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

  # A session recreated after owner-lease expiry: no assignment of its own, and
  # the closed session's assignment carried only on the struct.
  defp recreated_session_fixture(setup, %PoolUpstreamAssignment{} = previous, api_key \\ nil) do
    setup
    |> codex_session_fixture(previous, api_key)
    |> Ecto.Changeset.change(pool_upstream_assignment_id: nil)
    |> Repo.update!()
    |> Map.put(:recreated_from_assignment_id, previous.id)
  end

  defp native_text_input(text) do
    [
      %{
        "type" => "message",
        "role" => "user",
        "content" => [%{"type" => "input_text", "text" => text}]
      }
    ]
  end

  defp request_options_with_session(%CodexSession{} = session) do
    %{}
    |> RequestOptions.build(@endpoint, %{
      "model" => "gpt-5.5",
      "input" => native_text_input("hello")
    })
    |> RequestOptions.put_continuity(codex_session: session)
  end

  defp streaming_request_options_with_session(%CodexSession{} = session) do
    %{}
    |> RequestOptions.build(@endpoint, %{
      "model" => "gpt-5.5",
      "input" => native_text_input("hello"),
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

  defp streaming_payload(model) do
    %{
      "model" => model.exposed_model_id,
      "input" => native_text_input("hello"),
      "stream" => true
    }
  end

  # The shape a sessioned native HTTP turn arrives in: a session header and its
  # source, exactly as `GatewayControllerHelpers.request_opts/1` builds them.
  defp http_session_request_options(auth, payload, session_header) do
    RequestOptions.build(
      %{
        api_key_policy: auth.api_key,
        session_header: session_header,
        session_header_source: "x-codex-window-id"
      },
      @endpoint,
      payload
    )
  end

  defp recreation_context do
    setup = active_pinned_assignment_setup()
    api_key = active_api_key_fixture(setup.pool)
    {:ok, auth} = Access.authenticate_authorization_header(api_key.authorization)

    model =
      model_for_assignments(setup.pool, [setup.pinned.assignment.id, setup.other.assignment.id])

    %{
      auth: auth,
      pool: setup.pool,
      model: model,
      assignment_ids: [setup.pinned.assignment.id, setup.other.assignment.id],
      payload: streaming_payload(model),
      session_header: "window-#{System.unique_integer([:positive])}"
    }
  end

  # Sticky session affinity would seed the ring from the replacement session id,
  # which is new on every recreation. Seeding from a fixed correlation id
  # instead keeps the ring's own order identical across runs, so the preference
  # is the only thing that can move the selection.
  defp pin_ring_seed!(context) do
    context.pool
    |> Pools.ensure_routing_settings()
    |> Ecto.Changeset.change(%{
      routing_strategy: "bridge_ring",
      bridge_ring_size: length(context.assignment_ids),
      sticky_websocket_sessions: false,
      sticky_http_sessions: false,
      updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })
    |> Repo.update!()
  end

  defp fixed_ring_seed do
    %RoutePlanInput{
      request_id: nil,
      correlation_id: "ring-seed-#{System.unique_integer([:positive])}"
    }
  end

  defp selected_assignment_id(context, %RoutePlanInput{} = route_plan_input, options, candidates) do
    BridgeRing.plan_route(%{
      auth: context.auth,
      model: context.model,
      candidates: candidates,
      route_plan_input: route_plan_input,
      request_options: options
    }).selected_assignment_id
  end

  defp without_recreation_preference(options) do
    RequestOptions.put_continuity(options,
      codex_session: %{options.continuity.codex_session | recreated_from_assignment_id: nil}
    )
  end

  # The ring's ordering for this pool, measured on a key that has no history,
  # so the recreation assertions compare against the real baseline instead of a
  # hardcoded order.
  defp ordinary_candidate_order(context) do
    assert {:ok, %{request_options: options, candidates: candidates}} =
             prepare_session_turn(context, "baseline-#{System.unique_integer([:positive])}")

    assert is_nil(options.continuity.codex_session.recreated_from_assignment_id)

    ids = candidate_assignment_ids(candidates)
    assert length(ids) == 2
    ids
  end

  defp prepare_session_turn(context, session_header) do
    PreDispatch.prepare(
      context.auth,
      @endpoint,
      context.payload,
      http_session_request_options(context.auth, context.payload, session_header),
      context.model
    )
  end

  # A session that held `assignment_id` and whose owner lease has since expired:
  # the state a lease-expiry recreation replaces.
  defp expired_assigned_session!(context, assignment_id, session_header) do
    assert {:ok, %{request_options: options}} = prepare_session_turn(context, session_header)

    session = options.continuity.codex_session

    bind_session_assignment!(session, assignment_id)
    expire_owner_lease!(session.id)

    session
  end

  defp bind_session_assignment!(%CodexSession{} = session, assignment_id)
       when is_binary(assignment_id) do
    session
    |> Ecto.Changeset.change(%{pool_upstream_assignment_id: assignment_id})
    |> Repo.update!()
  end

  defp expire_owner_lease!(session_id) do
    expired_at =
      DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:microsecond)

    CodexSession
    |> Repo.get!(session_id)
    |> Ecto.Changeset.change(%{
      owner_lease_expires_at: expired_at,
      last_heartbeat_at: expired_at,
      updated_at: expired_at
    })
    |> Repo.update!()

    BridgeOwnerLease
    |> where([lease], lease.codex_session_id == ^session_id)
    |> Repo.update_all(set: [expires_at: expired_at, updated_at: expired_at])

    :ok
  end

  defp candidate_assignment_ids(candidates) do
    Enum.map(candidates, fn {assignment, _identity} -> assignment.id end)
  end

  defp register_previous_response_alias!(%CodexSession{} = session, api_key, previous_response_id) do
    register_session_alias!(session, api_key, "previous_response_id", previous_response_id)
    session
  end

  defp register_session_alias!(%CodexSession{} = session, api_key, kind, value) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %BridgeSessionAlias{}
    |> BridgeSessionAlias.changeset(%{
      codex_session_id: session.id,
      pool_id: session.pool_id,
      api_key_id: api_key.id,
      alias_kind: kind,
      alias_hash: :crypto.hash(:sha256, value),
      alias_preview: "synthetic-alias",
      status: "active",
      expires_at: DateTime.add(now, 300, :second),
      last_seen_at: now,
      metadata: %{},
      created_at: now,
      updated_at: now
    })
    |> Repo.insert!()
  end

  defp activate_owner_lease!(session) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    session
    |> Ecto.Changeset.change(%{
      owner_instance_id: "test-node",
      owner_lease_token: Ecto.UUID.generate(),
      owner_lease_expires_at: DateTime.add(now, 300, :second),
      last_heartbeat_at: now
    })
    |> Repo.update!()
  end

  defp capture_repo_queries(fun) when is_function(fun, 0) do
    parent = self()
    handler_id = {__MODULE__, :query_count, System.unique_integer([:positive, :monotonic])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:codex_pooler, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata[:repo] == Repo and self() == parent do
            query = Map.get(metadata, :query, "")

            send(parent, {
              handler_id,
              %{
                source: metadata[:source],
                command: query_command(query),
                query: query
              }
            })
          end
        end,
        nil
      )

    try do
      result = fun.()
      {result, drain_repo_queries(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_repo_queries(handler_id, queries) do
    receive do
      {^handler_id, query} -> drain_repo_queries(handler_id, [query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp query_command(query) do
    query
    |> String.trim_leading()
    |> String.split(~r/\s+/, parts: 2)
    |> List.first()
    |> String.upcase()
  end

  defp model_for_assignments(pool, assignment_ids) do
    exposed_model_id = "gpt-5.5-#{System.unique_integer([:positive])}"

    model_fixture(pool, %{
      exposed_model_id: exposed_model_id,
      source_assignment_count: length(assignment_ids),
      metadata: %{
        "source_assignment_ids" => assignment_ids,
        "source_assignment_models" =>
          Map.new(assignment_ids, &{&1, %{"slug" => exposed_model_id}})
      }
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
