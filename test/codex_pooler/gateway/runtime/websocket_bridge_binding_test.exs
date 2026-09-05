defmodule CodexPooler.Gateway.Runtime.WebsocketBridgeBindingTest do
  use CodexPooler.DataCase, async: false

  import Ecto.Query

  import CodexPoolerWeb.Runtime.BackendCodexTestSupport,
    only: [gateway_setup: 1, start_upstream: 1]

  alias CodexPooler.{Access, Accounting, FakeUpstream}
  alias CodexPooler.Accounting.{Attempt, LedgerEntry, Request}
  alias CodexPooler.Gateway.Payloads.RequestOptions
  alias CodexPooler.Gateway.Persistence.CodexTurn

  alias CodexPooler.Gateway.Runtime.Dispatch.{
    PreparedContext,
    SelectedCandidateContext,
    UpstreamAttempt
  }

  alias CodexPooler.Gateway.Transports.Websocket.WebsocketOwnerSession
  alias CodexPooler.Gateway.Websocket

  test "a conflicting owner binding rejects before websocket or HTTP dispatch and settles once" do
    previous = Application.get_env(:codex_pooler, :websocket_owner_forwarding_enabled)
    Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, true)

    on_exit(fn ->
      Application.put_env(:codex_pooler, :websocket_owner_forwarding_enabled, previous)
    end)

    upstream = start_upstream(FakeUpstream.json_response(%{"id" => "must-not-be-sent"}))
    setup = gateway_setup(upstream)
    {:ok, auth} = Access.authenticate_authorization_header(setup.authorization)
    {:ok, session} = Websocket.start_codex_session(auth, %{})
    payload = %{"model" => setup.model.exposed_model_id, "input" => [], "stream" => true}

    binding = %{
      "enabled" => true,
      "owner_instance_id" => "old-owner",
      "proxy_instance_id" => "old-proxy",
      "downstream_epoch" => 99
    }

    {:ok, reserved} =
      Accounting.reserve(auth, setup.model, payload, %{
        endpoint: "/v1/responses",
        transport: "http_sse",
        correlation_id: Ecto.UUID.generate(),
        request_metadata: %{"websocket_owner_forwarding" => binding}
      })

    {:ok, attempt} = Accounting.create_attempt(reserved.request, setup.assignment)
    now = DateTime.utc_now()

    Repo.insert!(%CodexTurn{
      codex_session_id: session.id,
      request_id: reserved.request.id,
      turn_sequence: 1,
      transport_kind: "http_sse",
      status: "in_progress",
      started_at: now,
      created_at: now,
      updated_at: now
    })

    options =
      RequestOptions.build(%{}, "/v1/responses", payload)
      |> RequestOptions.put_continuity(codex_session: session)
      |> RequestOptions.put_transport(transport: "http_sse")
      |> RequestOptions.put_openai_compatibility(
        source_endpoint: "/v1/responses",
        public_openai_responses_stream: true
      )

    prepared = %PreparedContext{
      context: %SelectedCandidateContext{
        auth: auth,
        endpoint: "/v1/responses",
        payload: payload,
        model: setup.model,
        reserved: reserved,
        request_options: options,
        assignment: setup.assignment,
        identity: setup.identity,
        attempt: attempt,
        index: 0,
        retry_count: 0,
        allow_retry?: true,
        started: System.monotonic_time(:millisecond)
      },
      url: FakeUpstream.url(upstream) <> "/backend-api/codex/responses",
      token: "synthetic-token",
      upstream_payload: Jason.encode!(payload),
      routing_hint_authorized?: false
    }

    try do
      assert {:error, %{code: "owner_unavailable"}} = UpstreamAttempt.dispatch(prepared, %{})
      assert FakeUpstream.count(upstream) == 0
      assert FakeUpstream.http_request_count(upstream) == 0
      assert FakeUpstream.websocket_connection_count(upstream) == 0
      request = Repo.get!(Request, reserved.request.id)
      assert request.status == "failed"
      assert request.request_metadata["websocket_owner_forwarding"] == binding
      assert Repo.get!(Attempt, attempt.id).retryable == false

      assert Repo.aggregate(
               from(l in LedgerEntry,
                 where: l.request_id == ^request.id and l.entry_kind == "settlement"
               ),
               :count
             ) == 1
    after
      Repo.delete_all(from turn in CodexTurn, where: turn.request_id == ^reserved.request.id)

      if match?({:ok, _}, WebsocketOwnerSession.lookup(session.id)) do
        {:ok, owner} = WebsocketOwnerSession.lookup(session.id)
        GenServer.stop(owner)
      end
    end
  end
end
